import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:chatgpt_app_core/util/bounded_file_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

typedef DraftDirectoryResolver = Future<Directory> Function();

/// 草稿与消息历史独立；旧会话不需要迁移，也不会在读取时被改写。
class ConversationDraft {
  final String text;
  final List<String> imagePaths;
  final List<String> filePaths;

  /// 被系统清理、移除或校验失败的附件不会恢复成可发送的路径。
  final int missingAttachmentCount;

  const ConversationDraft({
    required this.text,
    this.imagePaths = const [],
    this.filePaths = const [],
    this.missingAttachmentCount = 0,
  });

  bool get isEmpty => text.isEmpty && imagePaths.isEmpty && filePaths.isEmpty;
}

class DraftStorageException implements Exception {
  final String message;
  const DraftStorageException(this.message);

  @override
  String toString() => message;
}

/// 按账号和会话保存草稿。附件先复制到 documents 下的托管目录，再原子写入
/// 小型 manifest，避免重启后继续依赖照片选择器/文件提供器的临时路径。
class ConversationDraftStore {
  static const directoryName = 'conversation_drafts';
  static const maxTextCharacters = 128 * 1024;
  static const maxManifestBytes = 1024 * 1024;
  static const maxImageBytes = 20 * 1024 * 1024;
  static const maxFileBytes = 32 * 1024 * 1024;
  static const maxDraftBytes = 128 * 1024 * 1024;
  static const maxConversationBytes = 256 * 1024 * 1024;
  static const maxAccountBytes = 512 * 1024 * 1024;
  static final Map<String, Future<void>> _tails = {};
  static final Map<String, Future<void>> _accountTails = {};
  static final Map<String, int> _revisions = {};

  final String conversationId;
  final String accountHash;
  final bool _explicitAccount;
  final DraftDirectoryResolver _directoryResolver;

  ConversationDraftStore({
    required this.conversationId,
    String? accountHash,
    DraftDirectoryResolver? directoryResolver,
  })  : accountHash = AccountResourceScope.currentAccountHash(accountHash),
        _explicitAccount =
            AccountResourceScope.hasExplicitAccountHash(accountHash),
        _directoryResolver =
            directoryResolver ?? getApplicationDocumentsDirectory {
    if (conversationId.trim().isEmpty || conversationId.length > 4096) {
      throw ArgumentError.value(conversationId, 'conversationId', '会话标识无效');
    }
  }

  String get _accountToken => AccountResourceScope.tokenFor(accountHash);
  String get _conversationToken =>
      sha256.convert(utf8.encode(conversationId)).toString();
  String get _queueKey => '$_accountToken:$_conversationToken';
  List<String> get _segments => [
        AccountResourceScope.accountsDirectoryName,
        _accountToken,
        _conversationToken,
      ];

  void _verifyAccount() => AccountResourceScope.verifyCapturedAccount(
        capturedAccountHash: accountHash,
        explicitAccountHash: _explicitAccount,
      );

  Future<ConversationDraft?> load() async {
    await _tails[_queueKey];
    _verifyAccount();
    final base = await _directoryResolver();
    _verifyAccount();
    final root = Directory('${base.path}/$directoryName');
    final directory = Directory('${root.path}/${_segments.join('/')}');
    try {
      await AccountResourceScope.ensureNoLinks(
        root: root,
        relativeSegments: [..._segments, 'draft.json'],
      );
      final file = File('${directory.path}/draft.json');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final bytes = await readFileBytesBounded(
        file,
        maxBytes: maxManifestBytes,
        label: '草稿',
      );
      _verifyAccount();
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map ||
          json['version'] != 1 ||
          json['text'] is! String ||
          (json['text'] as String).length > maxTextCharacters ||
          json['images'] is! List ||
          json['files'] is! List) {
        return null;
      }
      var missing = 0;
      var total = 0;
      Future<List<String>> restore(List<dynamic> entries, int limit) async {
        final restored = <String>[];
        for (final entry in entries) {
          try {
            if (entry is! Map ||
                entry['digest'] is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry['digest']) ||
                entry['name'] is! String ||
                !_isSafeFilename(entry['name']) ||
                entry['bytes'] is! int ||
                entry['bytes'] < 0 ||
                entry['bytes'] > limit) {
              missing++;
              continue;
            }
            final digest = entry['digest'] as String;
            final name = entry['name'] as String;
            await AccountResourceScope.ensureNoLinks(
              root: root,
              relativeSegments: [..._segments, digest, name],
            );
            final owned = File('${directory.path}/$digest/$name');
            if (await FileSystemEntity.type(owned.path, followLinks: false) !=
                    FileSystemEntityType.file ||
                !await AccountResourceScope.isCanonicalWithin(
                    owned, directory)) {
              missing++;
              continue;
            }
            final content = await readFileBytesBounded(
              owned,
              maxBytes: limit,
              label: '草稿附件',
            );
            if (content.length != entry['bytes'] ||
                sha256.convert(content).toString() != digest ||
                total + content.length > maxDraftBytes) {
              missing++;
              continue;
            }
            total += content.length;
            restored.add(owned.path);
          } catch (_) {
            missing++;
          }
        }
        return List.unmodifiable(restored);
      }

      final images = await restore(json['images'], maxImageBytes);
      final files = await restore(json['files'], maxFileBytes);
      _verifyAccount();
      return ConversationDraft(
        text: json['text'],
        imagePaths: images,
        filePaths: files,
        missingAttachmentCount: missing,
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// 返回保存后的托管路径；较新的 save/clear 已排队时返回 null。
  Future<ConversationDraft?> save({
    required String text,
    List<String> images = const [],
    List<String> files = const [],
  }) {
    if (text.length > maxTextCharacters) {
      return Future.error(const DraftStorageException('草稿内容超出保存上限'));
    }
    final imageSnapshot = List<String>.of(images);
    final fileSnapshot = List<String>.of(files);
    return _mutate((isCurrent) async {
      if (!isCurrent()) return null;
      if (text.isEmpty && imageSnapshot.isEmpty && fileSnapshot.isEmpty) {
        await _removeManifest(isCurrent);
        return const ConversationDraft(text: '');
      }
      final base = await _directoryResolver();
      _verifyAccount();
      if (!isCurrent()) return null;
      return AccountResourceScope.runCapturedAccountMutation(
        capturedAccountHash: accountHash,
        explicitAccountHash: _explicitAccount,
        action: () async {
          final root = Directory('${base.path}/$directoryName');
          final directory = await AccountResourceScope.createManagedDirectory(
            root: root,
            relativeSegments: _segments,
          );
          var total = 0;
          var missing = 0;
          final imageEntries = <Map<String, dynamic>>[];
          final fileEntries = <Map<String, dynamic>>[];
          Future<void> importAll(List<String> paths, int limit,
              List<Map<String, dynamic>> entries) async {
            for (final path in paths) {
              if (!isCurrent()) return;
              try {
                final entry = await _importAttachment(
                  path,
                  root: root,
                  directory: directory,
                  maxBytes: limit,
                  isCurrent: isCurrent,
                );
                if (entry == null) return;
                total += entry['bytes'] as int;
                if (total > maxDraftBytes) {
                  throw const DraftStorageException('待发送附件合计超过 128 MiB');
                }
                entries.add(entry);
              } on DraftStorageException {
                missing++;
                entries.add({'unavailable': true});
              } on FormatException {
                missing++;
                entries.add({'unavailable': true});
              } on FileSystemException {
                missing++;
                entries.add({'unavailable': true});
              }
            }
          }

          await importAll(imageSnapshot, maxImageBytes, imageEntries);
          await importAll(fileSnapshot, maxFileBytes, fileEntries);
          if (!isCurrent()) return null;
          final encoded = utf8.encode(jsonEncode({
            'version': 1,
            'text': text,
            'images': imageEntries,
            'files': fileEntries,
          }));
          if (encoded.length > maxManifestBytes) {
            throw const DraftStorageException('草稿内容超出保存上限');
          }
          final target = File('${directory.path}/draft.json');
          await AccountResourceScope.ensureNoLinks(
            root: root,
            relativeSegments: [..._segments, 'draft.json'],
          );
          final temporary = File('${directory.path}/.${_randomToken()}.tmp');
          try {
            await temporary.create(exclusive: true);
            await temporary.writeAsBytes(encoded, flush: true);
            _verifyAccount();
            if (!isCurrent()) return null;
            await temporary.rename(target.path);
          } finally {
            if (await temporary.exists()) await temporary.delete();
          }
          String pathOf(Map<String, dynamic> entry) =>
              '${directory.path}/${entry['digest']}/${entry['name']}';
          return ConversationDraft(
            text: text,
            imagePaths: List.unmodifiable(imageEntries
                .where((entry) => entry['unavailable'] != true)
                .map(pathOf)),
            filePaths: List.unmodifiable(fileEntries
                .where((entry) => entry['unavailable'] != true)
                .map(pathOf)),
            missingAttachmentCount: missing,
          );
        },
      );
    });
  }

  /// 默认保留附件副本，正在发送或失败后重试的请求可能仍引用这些路径。
  /// 附件已转交消息存储，或删除会话且没有请求使用路径时，可以清理副本。
  Future<void> clear({bool discardAttachments = false}) =>
      _mutate<void>((isCurrent) async {
        await _removeManifest(isCurrent, removeAttachments: discardAttachments);
      });

  Future<void> _removeManifest(bool Function() isCurrent,
      {bool removeAttachments = false}) async {
    final base = await _directoryResolver();
    _verifyAccount();
    if (!isCurrent()) return;
    await AccountResourceScope.runCapturedAccountMutation(
      capturedAccountHash: accountHash,
      explicitAccountHash: _explicitAccount,
      action: () async {
        final root = Directory('${base.path}/$directoryName');
        final directory = Directory('${root.path}/${_segments.join('/')}');
        await AccountResourceScope.ensureNoLinks(
          root: root,
          relativeSegments: [..._segments, 'draft.json'],
        );
        if (!isCurrent()) return;
        if (removeAttachments) {
          if (await FileSystemEntity.type(directory.path, followLinks: false) ==
              FileSystemEntityType.directory) {
            await directory.delete(recursive: true);
          }
          return;
        }
        final manifest = File('${directory.path}/draft.json');
        if (await FileSystemEntity.type(manifest.path, followLinks: false) ==
            FileSystemEntityType.file) {
          await manifest.delete();
        }
      },
    );
  }

  Future<T> _mutate<T>(Future<T> Function(bool Function()) action) {
    final key = _queueKey;
    final revision = (_revisions[key] ?? 0) + 1;
    _revisions[key] = revision;
    // 同账号的不同会话也串行落盘，空间预算不会被并发导入穿透。
    final previous = _accountTails[_accountToken] ?? Future<void>.value();
    final result = previous.then((_) async {
      _verifyAccount();
      return action(() => _revisions[key] == revision);
    });
    late final Future<void> tail;
    tail = result
        .then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() {
      if (identical(_tails[key], tail)) {
        _tails.remove(key);
        _revisions.remove(key);
      }
      if (identical(_accountTails[_accountToken], tail)) {
        _accountTails.remove(_accountToken);
      }
    });
    _tails[key] = tail;
    _accountTails[_accountToken] = tail;
    return result;
  }

  Future<Map<String, dynamic>?> _importAttachment(
    String path, {
    required Directory root,
    required Directory directory,
    required int maxBytes,
    required bool Function() isCurrent,
  }) async {
    final source = File(path);
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const DraftStorageException('草稿附件已不可用，请重新选择');
    }
    final name = path.split(RegExp(r'[/\\]')).last;
    if (!_isSafeFilename(name)) {
      throw const DraftStorageException('附件文件名不适合保存，请重新选择');
    }
    final content = await readFileBytesBounded(
      source,
      maxBytes: maxBytes,
      label: '草稿附件',
    );
    if (!isCurrent()) return null;
    final digest = sha256.convert(content).toString();
    final ownedDirectory = await AccountResourceScope.createManagedDirectory(
      root: root,
      relativeSegments: [..._segments, digest],
    );
    final target = File('${ownedDirectory.path}/$name');
    await AccountResourceScope.ensureNoLinks(
      root: root,
      relativeSegments: [..._segments, digest, name],
    );
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      final conversationBytes = await _directoryBytes(directory);
      final accountDirectory = directory.parent;
      final accountBytes = await _directoryBytes(accountDirectory);
      if (conversationBytes + content.length > maxConversationBytes ||
          accountBytes + content.length > maxAccountBytes) {
        throw const DraftStorageException('草稿附件空间已满，请清理不需要的会话草稿');
      }
      if (!isCurrent()) return null;
      final temporary = File('${ownedDirectory.path}/.${_randomToken()}.tmp');
      try {
        await temporary.create(exclusive: true);
        await temporary.writeAsBytes(content, flush: true);
        if (!isCurrent()) return null;
        await temporary.rename(target.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    } else if (type == FileSystemEntityType.file) {
      final existing = await readFileBytesBounded(
        target,
        maxBytes: maxBytes,
        label: '草稿附件',
      );
      if (sha256.convert(existing).toString() != digest) {
        throw const DraftStorageException('草稿附件校验失败，请重新选择');
      }
    } else {
      throw const DraftStorageException('草稿附件目录不可用');
    }
    return {'digest': digest, 'name': name, 'bytes': content.length};
  }

  static Future<int> _directoryBytes(Directory directory) async {
    var bytes = 0;
    await for (final entity
        in directory.list(recursive: true, followLinks: false)) {
      if (entity is File &&
          await FileSystemEntity.type(entity.path, followLinks: false) ==
              FileSystemEntityType.file) {
        bytes += await entity.length();
      }
    }
    return bytes;
  }

  static bool _isSafeFilename(String value) =>
      value.isNotEmpty &&
      value != '.' &&
      value != '..' &&
      utf8.encode(value).length <= 240 &&
      !value.contains('/') &&
      !value.contains('\\') &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

  static String _randomToken() =>
      List<int>.generate(16, (_) => Random.secure().nextInt(256))
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
}
