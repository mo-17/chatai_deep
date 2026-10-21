import 'dart:async';
import 'dart:convert';
import 'package:login_sdk/platform/app_io.dart';
import 'dart:math';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/chat/domain/composer_reference.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:chatgpt_app_core/util/bounded_file_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:chatgpt_app_core/platform/app_paths.dart';

typedef DraftDirectoryResolver = Future<Directory> Function();

/// 只能由原草稿签发；正文相同的新 save 也不能被旧发送清除。
final class DraftManifestToken {
  final String _queueKey, _digest;
  final Object _stamp;
  DraftManifestToken._(this._queueKey, this._digest, this._stamp);
}

/// 缺失也是明确捕获的槽位；被替代和读失败不会签发这个 token。
final class DraftSubmissionToken {
  final String _queueKey;
  final String? _digest;
  final Object _stamp;
  DraftSubmissionToken._(this._queueKey, this._digest, this._stamp);
}

/// 草稿与消息历史独立；旧会话不需要迁移，也不会在读取时被改写。
class ConversationDraft {
  final String text;
  final List<String> imagePaths;
  final List<String> filePaths;
  final List<ComposerReference> references;

  /// 被系统清理、移除或校验失败的附件不会恢复成可发送的路径。
  final int missingAttachmentCount;

  const ConversationDraft({
    required this.text,
    this.imagePaths = const [],
    this.filePaths = const [],
    this.references = const [],
    this.missingAttachmentCount = 0,
  });

  bool get isEmpty =>
      text.isEmpty &&
      imagePaths.isEmpty &&
      filePaths.isEmpty &&
      references.isEmpty;
}

class DraftStorageException implements Exception {
  final String message;
  const DraftStorageException(this.message);

  @override
  String toString() => message;
}

/// 按账号和会话保存草稿。附件先复制到 documents 下的托管目录，再原子写入
/// 小型 manifest，避免重启后继续依赖照片选择器/文件提供器的临时路径。
final class DraftAttachmentPreview {
  final ConversationDraftStore _store;
  final ComposerReference reference;
  DraftAttachmentPreview._(this._store, this.reference,
      {this.limits = const AttachmentProcessingLimits(),
      bool manifestBound = true})
      : _manifestBound = manifestBound;

  Future<Uint8List> readBytes() => _store._readVerifiedAttachment(reference,
      manifestBound: _manifestBound, limits: limits);
  final AttachmentProcessingLimits limits;
  final bool _manifestBound;
  Future<String> readText() async {
    final bytes = await readBytes();
    final text = await FileProcessor.extractTextFromBytes(bytes,
        filename: reference.attachmentPath!.split(RegExp(r'[/\\]')).last,
        limits: limits);
    _store._verifyAccount();
    return text ?? '此文件类型没有文字预览。';
  }
}

/// 仅由本账号、会话的冻结操作签发；发送快照不受草稿 manifest 容量限制。
final class FrozenComposerDraft extends ConversationDraft {
  final ConversationDraftStore _store;
  final AttachmentProcessingLimits limits;
  FrozenComposerDraft._(this._store, this.limits,
      {required super.text,
      required super.imagePaths,
      required super.filePaths,
      required super.references,
      required super.missingAttachmentCount});

  DraftAttachmentPreview? previewForReference(String id) {
    final reference = references.where((r) => r.id == id).firstOrNull;
    if (reference == null ||
        !reference.available ||
        reference.kind == ComposerReferenceKind.historyMessage ||
        reference.attachmentPath == null ||
        reference.snapshotDigest.isEmpty) {
      return null;
    }
    return DraftAttachmentPreview._(_store, reference,
        limits: limits, manifestBound: false);
  }
}

/// 空间不足不能把仍可用于发送的已选来源误标为失效。
class DraftStorageCapacityException extends DraftStorageException {
  const DraftStorageCapacityException(super.message);
}

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
  static final Map<String, Object> _manifestStamps = {};

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

  Object _manifestStamp({bool replace = false}) {
    if (replace || !_manifestStamps.containsKey(_queueKey)) {
      _manifestStamps.remove(_queueKey);
      _manifestStamps[_queueKey] = Object();
      // 被淘汰的旧 token 失配后保守保留草稿，不恢复执行权。
      while (_manifestStamps.length > 256) {
        _manifestStamps.remove(_manifestStamps.keys.first);
      }
    }
    return _manifestStamps[_queueKey]!;
  }

  Future<String?> _manifestDigest({void Function()? verify}) async {
    verify?.call();
    _verifyAccount();
    final base = await _directoryResolver();
    verify?.call();
    _verifyAccount();
    final root = appDirectory('${base.path}/$directoryName');
    await AccountResourceScope.ensureNoLinks(
        root: root, relativeSegments: [..._segments, 'draft.json']);
    verify?.call();
    final file = appFile('${root.path}/${_segments.join('/')}/draft.json');
    final type = await appFileType(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw const DraftStorageException('草稿文件类型异常');
    }
    final bytes = await readFileBytesBounded(file,
        maxBytes: maxManifestBytes, label: '草稿');
    verify?.call();
    _verifyAccount();
    return sha256.convert(bytes).toString();
  }

  /// 调用时同步捕获写入代次，随后只读取该代次的 manifest。
  Future<DraftManifestToken?> captureManifest({void Function()? verify}) async {
    verify?.call();
    final stamp = _manifestStamp();
    await _tails[_queueKey];
    verify?.call();
    if (!identical(_manifestStamps[_queueKey], stamp)) return null;
    final digest = await _manifestDigest(verify: verify);
    if (digest == null || !identical(_manifestStamps[_queueKey], stamp)) {
      return null;
    }
    return DraftManifestToken._(_queueKey, digest, stamp);
  }

  Future<DraftSubmissionToken?> captureSubmission(
      {required void Function() verify}) async {
    verify();
    final stamp = _manifestStamp();
    await _tails[_queueKey];
    verify();
    if (!identical(_manifestStamps[_queueKey], stamp)) return null;
    final digest = await _manifestDigest(verify: verify);
    verify();
    if (!identical(_manifestStamps[_queueKey], stamp)) return null;
    return DraftSubmissionToken._(_queueKey, digest, stamp);
  }

  bool sameSubmission(DraftSubmissionToken a, DraftSubmissionToken b) =>
      a._queueKey == _queueKey &&
      b._queueKey == _queueKey &&
      identical(a._stamp, b._stamp) &&
      a._digest == b._digest;

  Future<bool> submissionIsCurrent(DraftSubmissionToken token,
      {required void Function() verify}) async {
    if (token._queueKey != _queueKey) return false;
    verify();
    if (!identical(_manifestStamps[_queueKey], token._stamp)) return false;
    final digest = await _manifestDigest(verify: verify);
    verify();
    return identical(_manifestStamps[_queueKey], token._stamp) &&
        digest == token._digest;
  }

  /// 未接受的提交只可填回原槽；新的同文编辑也具有更高优先级。
  Future<ConversationDraft?> preserveSubmission(DraftSubmissionToken token,
      {required String text,
      List<String> images = const [],
      List<String> files = const [],
      List<ComposerReference> references = const [],
      required void Function() verify,
      required Future<void> abortTrigger,
      required Future<void> Function(Future<void> Function()) stableMutation}) {
    verify();
    if (token._queueKey != _queueKey ||
        !identical(_manifestStamps[_queueKey], token._stamp)) {
      return Future.value(null);
    }
    return _writeSnapshot(
        text: text,
        images: images,
        files: files,
        references: references,
        submission: token,
        verify: verify,
        abortTrigger: abortTrigger,
        stableMutation: stableMutation);
  }

  /// 发送成功只清原 manifest，附件已由运行独占；新草稿和其附件不受影响。
  Future<bool> clearCapturedManifest(DraftManifestToken token,
      {required void Function() verify,
      Future<void>? abortTrigger,
      Future<void> Function(Future<void> Function())? stableMutation}) {
    if (token._queueKey != _queueKey) {
      throw const DraftStorageException('草稿清理身份不匹配');
    }
    verify();
    if (!identical(_manifestStamps[_queueKey], token._stamp)) {
      return Future.value(false);
    }
    return _mutate((isCurrent) async {
      verify();
      if (!isCurrent() ||
          await _cleanupWait(_manifestDigest(verify: verify), abortTrigger) !=
              token._digest) {
        return false;
      }
      verify();
      if (!isCurrent()) return false;
      await _removeManifest(() {
        verify();
        return isCurrent();
      }, stableMutation: stableMutation, abortTrigger: abortTrigger);
      return isCurrent();
    });
  }

  Future<ConversationDraft?> load() async {
    await _tails[_queueKey];
    _verifyAccount();
    final base = await _directoryResolver();
    _verifyAccount();
    final root = appDirectory('${base.path}/$directoryName');
    final directory = appDirectory('${root.path}/${_segments.join('/')}');
    try {
      await AccountResourceScope.ensureNoLinks(
        root: root,
        relativeSegments: [..._segments, 'draft.json'],
      );
      final file = appFile('${directory.path}/draft.json');
      if (await appFileType(file.path, followLinks: false) !=
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
          !const [1, 2].contains(json['version']) ||
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
            final owned = appFile('${directory.path}/$digest/$name');
            if (await appFileType(owned.path, followLinks: false) !=
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
      final references = <ComposerReference>[];
      if (json['version'] == 2 && json['references'] is List) {
        final ids = <String>{};
        for (final raw in json['references']) {
          try {
            final reference = ComposerReference.fromJson(
                (raw as Map).cast<String, dynamic>());
            if (!ids.add(reference.id)) throw const FormatException('重复引用');
            final paths =
                reference.kind == ComposerReferenceKind.photo ? images : files;
            references.add(
                (reference.kind == ComposerReferenceKind.historyMessage &&
                            reference.historySnapshot?.accountToken ==
                                _accountToken) ||
                        reference.attachmentPath != null &&
                            paths.contains(reference.attachmentPath) &&
                            reference.snapshotDigest ==
                                reference.attachmentPath!
                                    .split(RegExp(r'[/\\]'))
                                    .reversed
                                    .skip(1)
                                    .first
                    ? reference
                    : reference.asUnavailable());
          } catch (_) {
            references.add(ComposerReference.unavailable(
                'invalid_${references.length}', '引用无法恢复，请重新选择'));
          }
        }
      } else if (json['version'] == 2) {
        references.add(
            ComposerReference.unavailable('invalid_manifest', '引用无法恢复，请重新选择'));
      }
      // v1 草稿仍可恢复；旧附件也进入统一标签，不改变文件编码流程。
      for (final path in images) {
        if (!references.any((r) => r.attachmentPath == path)) {
          references.add(ComposerReference.attachment(path, photo: true)
              .bindAttachment(
                  path, path.split(RegExp(r'[/\\]')).reversed.skip(1).first));
        }
      }
      for (final path in files) {
        if (!references.any((r) => r.attachmentPath == path)) {
          references.add(ComposerReference.attachment(path, photo: false)
              .bindAttachment(
                  path, path.split(RegExp(r'[/\\]')).reversed.skip(1).first));
        }
      }
      if (missing > 0 && !references.any((r) => !r.available)) {
        for (var i = 0; i < missing; i++) {
          references
              .add(ComposerReference.unavailable('missing_$i', '附件已失效，请重新选择'));
        }
      }
      _verifyAccount();
      return ConversationDraft(
        text: json['text'],
        imagePaths: images,
        filePaths: files,
        references: List.unmodifiable(references),
        missingAttachmentCount: missing,
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// 只有当前账号、当前会话 manifest 中已验证的托管绑定能签发预览能力。
  Future<DraftAttachmentPreview?> previewForReference(String id) async {
    final draft = await load();
    final reference = draft?.references.where((r) => r.id == id).firstOrNull;
    if (reference == null ||
        !reference.available ||
        reference.kind == ComposerReferenceKind.historyMessage ||
        reference.snapshotDigest.isEmpty ||
        reference.attachmentPath == null) {
      return null;
    }
    return DraftAttachmentPreview._(this, reference);
  }

  Future<Uint8List> _readVerifiedAttachment(ComposerReference reference,
      {bool manifestBound = true,
      AttachmentProcessingLimits limits =
          const AttachmentProcessingLimits()}) async {
    _verifyAccount();
    final current =
        manifestBound ? await previewForReference(reference.id) : null;
    if (manifestBound &&
        (current == null ||
            current.reference.attachmentPath != reference.attachmentPath ||
            current.reference.snapshotDigest != reference.snapshotDigest ||
            current.reference.kind != reference.kind)) {
      throw const DraftStorageException('引用已变化或不可用，请重新选择');
    }
    final base = await _directoryResolver();
    final root = appDirectory('${base.path}/$directoryName');
    final name = reference.attachmentPath!.split(RegExp(r'[/\\]')).last;
    final expectedPath =
        '${root.path}/${_segments.join('/')}/${reference.snapshotDigest}/$name';
    if (reference.attachmentPath != expectedPath || !_isSafeFilename(name)) {
      throw const DraftStorageException('引用不属于当前会话');
    }
    await AccountResourceScope.ensureNoLinks(
        root: root,
        relativeSegments: [..._segments, reference.snapshotDigest, name]);
    final bytes = await readFileBytesBounded(appFile(expectedPath),
        maxBytes: reference.kind == ComposerReferenceKind.photo
            ? maxImageBytes
            : (manifestBound || name.toLowerCase().endsWith('.pdf')
                ? maxFileBytes
                : limits.normalized.maxTextFileBytes),
        label: '引用预览');
    _verifyAccount();
    if (sha256.convert(bytes).toString() != reference.snapshotDigest) {
      throw const DraftStorageException('引用快照校验失败');
    }
    return bytes;
  }

  /// 返回保存后的托管路径；较新的 save/clear 已排队时返回 null。
  Future<ConversationDraft?> save({
    required String text,
    List<String> images = const [],
    List<String> files = const [],
    List<ComposerReference> references = const [],
  }) =>
      _writeSnapshot(
          text: text, images: images, files: files, references: references);

  Future<FrozenComposerDraft?> freezeForSend({
    required String text,
    List<String> images = const [],
    List<String> files = const [],
    List<ComposerReference> references = const [],
    AttachmentProcessingLimits limits = const AttachmentProcessingLimits(),
  }) async =>
      await _writeSnapshot(
          text: text,
          images: images,
          files: files,
          references: references,
          persist: false,
          limits: limits) as FrozenComposerDraft?;

  Future<ConversationDraft?> _writeSnapshot({
    required String text,
    List<String> images = const [],
    List<String> files = const [],
    List<ComposerReference> references = const [],
    bool persist = true,
    DraftSubmissionToken? submission,
    void Function()? verify,
    Future<void>? abortTrigger,
    Future<void> Function(Future<void> Function())? stableMutation,
    AttachmentProcessingLimits limits = const AttachmentProcessingLimits(),
  }) {
    final effectiveLimits = limits.normalized;
    if (persist && text.length > maxTextCharacters) {
      return Future.error(const DraftStorageCapacityException('草稿内容超出保存上限'));
    }
    final imageSnapshot = List<String>.of(images);
    final fileSnapshot = List<String>.of(files);
    final referenceSnapshot = List<ComposerReference>.of(references);
    return _mutate((revisionCurrent) async {
      bool isCurrent() {
        verify?.call();
        return revisionCurrent();
      }

      if (!isCurrent()) return null;
      // 目录、草稿队尾和摘要读取始终在短账号许可外。
      if (submission != null &&
          await _cleanupWait(_manifestDigest(verify: verify), abortTrigger) !=
              submission._digest) {
        return null;
      }
      if (!isCurrent()) return null;
      if (text.isEmpty &&
          imageSnapshot.isEmpty &&
          fileSnapshot.isEmpty &&
          referenceSnapshot.isEmpty) {
        if (persist) {
          await _removeManifest(isCurrent,
              abortTrigger: abortTrigger, stableMutation: stableMutation);
        }
        return persist
            ? const ConversationDraft(text: '')
            : FrozenComposerDraft._(this, effectiveLimits,
                text: text,
                imagePaths: const [],
                filePaths: const [],
                references: const [],
                missingAttachmentCount: 0);
      }
      final base = await _cleanupWait(_directoryResolver(), abortTrigger);
      _verifyAccount();
      if (!isCurrent()) return null;
      return _snapshotMutation(
        stableMutation: stableMutation,
        action: () async {
          if (!isCurrent()) return null;
          final root = appDirectory('${base.path}/$directoryName');
          if (!isCurrent()) return null;
          final directory = await AccountResourceScope.createManagedDirectory(
            root: root,
            relativeSegments: _segments,
          );
          if (!isCurrent()) return null;
          var total = 0;
          var missing = 0;
          final imageEntries = <Map<String, dynamic>>[];
          final fileEntries = <Map<String, dynamic>>[];
          final bindings = <String, Map<String, dynamic>>{};
          final expectedDigests = {
            for (final reference in referenceSnapshot)
              if (reference.attachmentPath != null &&
                  reference.snapshotDigest.isNotEmpty)
                reference.attachmentPath!: reference.snapshotDigest
          };
          Future<void> importAll(List<String> paths, int limit,
              List<Map<String, dynamic>> entries) async {
            for (final path in paths) {
              if (!isCurrent()) return;
              try {
                final entry = await _importAttachment(
                  path,
                  root: root,
                  directory: directory,
                  maxBytes: !persist && path.toLowerCase().endsWith('.pdf')
                      ? FileProcessor.defaultPdfLimit
                      : limit,
                  isCurrent: isCurrent,
                  expectedDigest: expectedDigests[path],
                  enforceDraftQuota: persist,
                  beforeWrite: (digest, bytes) {
                    if (!entries.any((e) => e['digest'] == digest)) {
                      total += bytes;
                    }
                    if (total >
                        (persist
                            ? maxDraftBytes
                            : effectiveLimits.maxTotalFileBytes)) {
                      throw DraftStorageCapacityException(persist
                          ? '待发送附件合计超过草稿保存上限 128 MiB'
                          : '本轮附件总大小超过发送上限');
                    }
                  },
                );
                if (entry == null) return;
                final existing = entries
                    .where((e) => e['digest'] == entry['digest'])
                    .firstOrNull;
                if (existing == null) entries.add(entry);
                bindings[path] = existing ?? entry;
              } on DraftStorageCapacityException {
                rethrow;
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
          await importAll(
              fileSnapshot,
              persist ? maxFileBytes : effectiveLimits.maxTextFileBytes,
              fileEntries);
          if (!isCurrent()) return null;
          String pathOf(Map<String, dynamic> entry) =>
              '${directory.path}/${entry['digest']}/${entry['name']}';
          final seenReferences = <String>{};
          final savedReferences = referenceSnapshot
              .map((reference) {
                if (reference.kind == ComposerReferenceKind.historyMessage) {
                  return reference.historySnapshot?.accountToken ==
                          _accountToken
                      ? reference
                      : reference.asUnavailable();
                }
                final entry = bindings[reference.attachmentPath];
                return entry == null
                    ? reference.asUnavailable()
                    : reference.bindAttachment(
                        pathOf(entry), entry['digest'] as String);
              })
              .where((reference) =>
                  !reference.available ||
                  seenReferences.add(reference.kind ==
                          ComposerReferenceKind.historyMessage
                      ? reference.sourceIdentity
                      : '${reference.kind.name}:${reference.snapshotDigest}'))
              .toList(growable: false);
          if (!persist) {
            return FrozenComposerDraft._(this, effectiveLimits,
                text: text,
                imagePaths: List.unmodifiable(imageEntries
                    .where((e) => e['unavailable'] != true)
                    .map(pathOf)),
                filePaths: List.unmodifiable(fileEntries
                    .where((e) => e['unavailable'] != true)
                    .map(pathOf)),
                references: List.unmodifiable(savedReferences),
                missingAttachmentCount: missing);
          }
          final encoded = utf8.encode(jsonEncode({
            'version': 2,
            'text': text,
            'images': imageEntries,
            'files': fileEntries,
            'references': savedReferences.map((r) => r.toJson()).toList(),
          }));
          if (encoded.length > maxManifestBytes) {
            throw const DraftStorageCapacityException('草稿内容超出保存上限');
          }
          final target = appFile('${directory.path}/draft.json');
          await AccountResourceScope.ensureNoLinks(
            root: root,
            relativeSegments: [..._segments, 'draft.json'],
          );
          final temporary = appFile('${directory.path}/.${_randomToken()}.tmp');
          try {
            if (!isCurrent()) return null;
            await temporary.create(exclusive: true);
            if (!isCurrent()) return null;
            await temporary.writeAsBytes(encoded, flush: true);
            _verifyAccount();
            if (!isCurrent()) return null;
            await temporary.rename(target.path);
          } finally {
            if (await temporary.exists()) await temporary.delete();
          }
          return ConversationDraft(
            text: text,
            imagePaths: List.unmodifiable(imageEntries
                .where((entry) => entry['unavailable'] != true)
                .map(pathOf)),
            filePaths: List.unmodifiable(fileEntries
                .where((entry) => entry['unavailable'] != true)
                .map(pathOf)),
            missingAttachmentCount: missing,
            references: List.unmodifiable(savedReferences),
          );
        },
      );
    }, abortTrigger: abortTrigger);
  }

  Future<T> _snapshotMutation<T>(
      {required Future<T> Function() action,
      Future<void> Function(Future<void> Function())? stableMutation}) async {
    if (stableMutation == null) {
      return AccountResourceScope.runCapturedAccountMutation(
          capturedAccountHash: accountHash,
          explicitAccountHash: _explicitAccount,
          action: action);
    }
    late T value;
    await stableMutation(() async {
      value = await action();
    });
    return value;
  }

  /// 默认保留附件副本，正在发送或失败后重试的请求可能仍引用这些路径。
  /// 附件已转交消息存储，或删除会话且没有请求使用路径时，可以清理副本。
  Future<void> clear({bool discardAttachments = false}) =>
      _mutate<void>((isCurrent) async {
        await _removeManifest(isCurrent, removeAttachments: discardAttachments);
      });

  Future<void> _removeManifest(bool Function() isCurrent,
      {bool removeAttachments = false,
      Future<void>? abortTrigger,
      Future<void> Function(Future<void> Function())? stableMutation}) async {
    final base = await _cleanupWait(_directoryResolver(), abortTrigger);
    _verifyAccount();
    if (!isCurrent()) return;
    Future<void> mutation() async {
      _verifyAccount();
      if (!isCurrent()) return;
      final root = appDirectory('${base.path}/$directoryName');
      final directory = appDirectory('${root.path}/${_segments.join('/')}');
      await AccountResourceScope.ensureNoLinks(
        root: root,
        relativeSegments: [..._segments, 'draft.json'],
      );
      if (!isCurrent()) return;
      if (removeAttachments) {
        if (await appFileType(directory.path, followLinks: false) ==
            FileSystemEntityType.directory) {
          await directory.delete(recursive: true);
        }
        return;
      }
      final manifest = appFile('${directory.path}/draft.json');
      if (await appFileType(manifest.path, followLinks: false) ==
          FileSystemEntityType.file) {
        if (!isCurrent()) return;
        await manifest.delete();
      }
    }

    if (stableMutation != null) {
      await stableMutation(mutation);
    } else {
      await AccountResourceScope.runCapturedAccountMutation(
          capturedAccountHash: accountHash,
          explicitAccountHash: _explicitAccount,
          action: mutation);
    }
  }

  /// 只用于许可外的目录/只读准备。已取得许可的 mutation 必须真正结算，
  /// 不能以取消竞速放弃正在持有账号许可的删除操作。
  Future<T> _cleanupWait<T>(Future<T> value, Future<void>? abort) =>
      abort == null
          ? value
          : Future.any([
              value,
              abort.then<T>((_) => throw const DraftStorageException('草稿清理已停止'))
            ]);

  /// 等待当前账号已经排队的写入收尾，调用方可在关闭资源前明确排空。
  Future<void> whenIdle() async {
    while (_accountTails[_accountToken] != null) {
      await _accountTails[_accountToken];
    }
  }

  Future<T> _mutate<T>(Future<T> Function(bool Function()) action,
      {Future<void>? abortTrigger}) {
    final key = _queueKey;
    _manifestStamp(replace: true);
    final revision = (_revisions[key] ?? 0) + 1;
    _revisions[key] = revision;
    // 同账号的不同会话也串行落盘，空间预算不会被并发导入穿透。
    final previous = _accountTails[_accountToken] ?? Future<void>.value();
    var started = false, cancelled = false;
    final result = previous.then((_) async {
      if (cancelled) throw const DraftStorageException('草稿回存已撤销');
      started = true;
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
    if (abortTrigger == null) return result;
    return Future.any([
      result,
      abortTrigger.then<T>((_) {
        cancelled = true;
        // 已开始的短操作必须结算；取消排队者不能让后继越过仍在运行的前驱。
        if (started) return result;
        throw const DraftStorageException('草稿回存等待已撤销');
      })
    ]);
  }

  Future<Map<String, dynamic>?> _importAttachment(
    String path, {
    required Directory root,
    required Directory directory,
    required int maxBytes,
    required bool Function() isCurrent,
    String? expectedDigest,
    bool enforceDraftQuota = true,
    required void Function(String digest, int bytes) beforeWrite,
  }) async {
    final source = appFile(path);
    if (await appFileType(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const DraftStorageException('草稿附件已不可用，请重新选择');
    }
    final before = await source.stat();
    final name = path.split(RegExp(r'[/\\]')).last;
    if (!_isSafeFilename(name)) {
      throw const DraftStorageException('附件文件名不适合保存，请重新选择');
    }
    final content = await readFileBytesBounded(
      source,
      maxBytes: maxBytes,
      label: '草稿附件',
    );
    final after = await source.stat();
    if (await appFileType(path, followLinks: false) !=
            FileSystemEntityType.file ||
        before.modified != after.modified ||
        before.changed != after.changed ||
        before.size != content.length ||
        after.size != content.length) {
      throw const DraftStorageException('附件在冻结期间发生变化，请重新选择');
    }
    if (!isCurrent()) return null;
    final digest = sha256.convert(content).toString();
    if (expectedDigest != null && digest != expectedDigest) {
      throw const DraftStorageException('已冻结附件校验失败，请重新选择');
    }
    beforeWrite(digest, content.length);
    final ownedDirectory = await AccountResourceScope.createManagedDirectory(
      root: root,
      relativeSegments: [..._segments, digest],
    );
    // 在写副本和计算磁盘配额之前复用同摘要的已有文件，文件名不制造第二份副本。
    await for (final entity in ownedDirectory.list(followLinks: false)) {
      final existingName = entity.path.split(RegExp(r'[/\\]')).last;
      if (!_isSafeFilename(existingName) || existingName.startsWith('.')) {
        continue;
      }
      if (await appFileType(entity.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      final existing = await readFileBytesBounded(appFile(entity.path),
          maxBytes: maxBytes, label: '草稿附件');
      if (sha256.convert(existing).toString() != digest) {
        throw const DraftStorageException('草稿附件校验失败，请重新选择');
      }
      return {'digest': digest, 'name': existingName, 'bytes': existing.length};
    }
    final target = appFile('${ownedDirectory.path}/$name');
    await AccountResourceScope.ensureNoLinks(
      root: root,
      relativeSegments: [..._segments, digest, name],
    );
    final type = await appFileType(target.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      final conversationBytes =
          enforceDraftQuota ? await _directoryBytes(directory) : 0;
      final accountBytes =
          enforceDraftQuota ? await _directoryBytes(directory.parent) : 0;
      if (enforceDraftQuota &&
          (conversationBytes + content.length > maxConversationBytes ||
              accountBytes + content.length > maxAccountBytes)) {
        throw const DraftStorageCapacityException('草稿附件空间已满，请清理不需要的会话草稿');
      }
      if (!isCurrent()) return null;
      final temporary = appFile('${ownedDirectory.path}/.${_randomToken()}.tmp');
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
          await appFileType(entity.path, followLinks: false) ==
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
