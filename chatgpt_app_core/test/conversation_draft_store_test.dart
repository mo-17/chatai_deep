import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:login_sdk/dao/login_dao.dart';

void main() {
  late Directory base;
  late Directory picker;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('chatai_draft_test_');
    picker = await Directory.systemTemp.createTemp('chatai_draft_picker_');
  });
  tearDown(() async {
    LoginSdkConfig.reset();
    await base.delete(recursive: true);
    await picker.delete(recursive: true);
  });

  ConversationDraftStore store(
          {String cid = 'old-cid', String account = 'a'}) =>
      ConversationDraftStore(
        conversationId: cid,
        accountHash: account,
        directoryResolver: () async => base,
      );

  Future<File> pick(String name, List<int> bytes) async {
    final file = File('${picker.path}/$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<File> manifest() async => (await base
          .list(recursive: true)
          .where((item) => item is File && item.path.endsWith('/draft.json'))
          .toList())
      .single as File;

  test('旧会话没有草稿时返回空，不创建目录或改写旧历史', () async {
    final history = File('${base.path}/old_conversations.json');
    const original = '[{"cid":"old-cid","title":"旧对话","messages":[]}]';
    await history.writeAsString(original);
    expect(await store().load(), isNull);
    expect(await history.readAsString(), original);
    expect(await base.list().length, 1);
  });

  test('文字草稿在新实例与重启后恢复，保留换行和空白', () async {
    const text = '  未发出的问题\n下一行🙂  ';
    final saved = await store().save(text: text);
    expect(saved!.text, text);
    expect((await store().load())!.text, text);
  });

  test('账号与会话双重隔离，路径不包含明文账号或会话号', () async {
    await store(account: 'private@example.com', cid: 'private-cid')
        .save(text: '账号 A');
    expect(await store(account: 'b', cid: 'private-cid').load(), isNull);
    expect(await store(account: 'private@example.com', cid: 'other').load(),
        isNull);
    final file = await manifest();
    expect(file.path, isNot(contains('private@example.com')));
    expect(file.path, isNot(contains('private-cid')));
    await store(account: 'b', cid: 'private-cid').save(text: '账号 B');
    expect(
        (await store(account: 'private@example.com', cid: 'private-cid')
                .load())!
            .text,
        '账号 A');
    expect(
        (await store(account: 'b', cid: 'private-cid').load())!.text, '账号 B');
  });

  test('图片和文件复制到持久目录，选择器临时文件删除后仍可恢复', () async {
    final image = await pick('旅行照片.png', [1, 2, 3]);
    final file = await pick('预算.txt', utf8.encode('文件正文'));
    final saved = await store().save(
      text: '看看附件',
      images: [image.path],
      files: [file.path],
    );
    expect(saved!.imagePaths.single, startsWith(base.path));
    expect(saved.imagePaths.single, endsWith('/旅行照片.png'));
    expect(saved.filePaths.single, endsWith('/预算.txt'));
    await image.delete();
    await file.delete();
    final restored = await store().load();
    expect(restored!.imagePaths, saved.imagePaths);
    expect(await File(restored.filePaths.single).readAsString(), '文件正文');
    expect(restored.missingAttachmentCount, 0);
  });

  test('不同内容的同名附件不覆盖；已经托管的路径可以继续保存', () async {
    final first = await pick('same.txt', [1]);
    final saved = await store().save(text: '一', files: [first.path]);
    final oldPath = saved!.filePaths.single;
    await first.writeAsBytes([2]);
    final next = await store().save(text: '二', files: [oldPath, first.path]);
    expect(next!.filePaths.toSet().length, 2);
    expect(next.filePaths.every((path) => path.endsWith('/same.txt')), isTrue);
    expect(await File(next.filePaths.first).readAsBytes(), [1]);
    expect(await File(next.filePaths.last).readAsBytes(), [2]);
  });

  test('恢复时丢失附件仍保留文字，并报告需要重新选择', () async {
    final file = await pick('gone.txt', [1]);
    final saved = await store().save(text: '不要丢这段文字', files: [file.path]);
    await File(saved!.filePaths.single).delete();
    final restored = await store().load();
    expect(restored!.text, '不要丢这段文字');
    expect(restored.filePaths, isEmpty);
    expect(restored.missingAttachmentCount, 1);
  });

  test('附件导入失败也保存最新文字，重启后报告不可用附件', () async {
    final saved =
        await store().save(text: '最新编辑', files: ['${picker.path}/gone.txt']);
    expect(saved!.text, '最新编辑');
    expect(saved.missingAttachmentCount, 1);
    final restored = await store().load();
    expect(restored!.text, '最新编辑');
    expect(restored.filePaths, isEmpty);
    expect(restored.missingAttachmentCount, 1);
  });

  test('被改写的附件不会作为原始内容恢复', () async {
    final file = await pick('tampered.txt', [1, 2]);
    final saved = await store().save(text: '保留文字', files: [file.path]);
    await File(saved!.filePaths.single).writeAsBytes([3, 4]);
    final restored = await store().load();
    expect(restored!.text, '保留文字');
    expect(restored.filePaths, isEmpty);
    expect(restored.missingAttachmentCount, 1);
  });

  test('不支持的版本与损坏 JSON 安全忽略，不擦除文件', () async {
    await store().save(text: '草稿');
    final file = await manifest();
    await file.writeAsString('{broken');
    expect(await store().load(), isNull);
    expect(await file.readAsString(), '{broken');
    await file.writeAsString(jsonEncode({
      'version': 2,
      'text': '未来版本',
      'images': [],
      'files': [],
    }));
    expect(await store().load(), isNull);
    expect((jsonDecode(await file.readAsString()) as Map)['version'], 2);
  });

  test('恶意路径 metadata 不获得外部文件读取能力', () async {
    final outside = await pick('private.txt', [1, 2, 3]);
    await store().save(text: '安全草稿');
    final file = await manifest();
    await file.writeAsString(jsonEncode({
      'version': 1,
      'text': '安全草稿',
      'images': [],
      'files': [
        {
          'digest': '../../..',
          'name': outside.path,
          'bytes': 3,
        }
      ],
    }));
    final restored = await store().load();
    expect(restored!.text, '安全草稿');
    expect(restored.filePaths, isEmpty);
    expect(restored.missingAttachmentCount, 1);
    expect(await outside.readAsBytes(), [1, 2, 3]);
  });

  test('后排队的 clear 阻止尚在准备中的保存复活已发送草稿', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final slow = ConversationDraftStore(
      conversationId: 'old-cid',
      accountHash: 'a',
      directoryResolver: () async {
        entered.complete();
        await release.future;
        return base;
      },
    );
    final saving = slow.save(text: '旧输入');
    await entered.future;
    final clearing = store().clear();
    release.complete();
    expect(await saving, isNull);
    await clearing;
    expect(await store().load(), isNull);
  });

  test('连续保存只持久化最新快照，跨实例顺序同样生效', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final slow = ConversationDraftStore(
      conversationId: 'old-cid',
      accountHash: 'a',
      directoryResolver: () async {
        entered.complete();
        await release.future;
        return base;
      },
    );
    final first = slow.save(text: '旧');
    await entered.future;
    final second = store().save(text: '新');
    release.complete();
    expect(await first, isNull);
    expect((await second)!.text, '新');
    expect((await store().load())!.text, '新');
  });

  test('清除默认保留正在发送的附件，显式清理只删除当前会话', () async {
    final file = await pick('keep.txt', [1]);
    final saved = await store().save(text: '发送', files: [file.path]);
    await store(cid: 'other').save(text: '其他会话', files: [file.path]);
    await store().clear();
    expect(await store().load(), isNull);
    expect(await File(saved!.filePaths.single).exists(), isTrue);
    await store().clear(discardAttachments: true);
    expect(await File(saved.filePaths.single).exists(), isFalse);
    expect((await store(cid: 'other').load())!.text, '其他会话');
  });

  test('保存空快照相当于清除文字草稿；超限输入拒绝而不覆盖旧快照', () async {
    await store().save(text: '旧草稿');
    await expectLater(
      store().save(text: 'x' * (ConversationDraftStore.maxTextCharacters + 1)),
      throwsA(isA<DraftStorageException>()),
    );
    expect((await store().load())!.text, '旧草稿');
    await store().save(text: '');
    expect(await store().load(), isNull);
  });

  test('超大附件不会先完整读入内存，文字仍保存并报告不可用附件', () async {
    final source = File('${picker.path}/large.pdf');
    final handle = await source.open(mode: FileMode.write);
    await handle.truncate(ConversationDraftStore.maxFileBytes + 1);
    await handle.close();
    final saved = await store().save(text: '保留问题', files: [source.path]);
    expect(saved!.missingAttachmentCount, 1);
    expect(saved.filePaths, isEmpty);
    expect((await store().load())!.text, '保留问题');
    expect(
        (await base
                .list(recursive: true)
                .where((item) => item is File)
                .toList())
            .every((file) => file.path.endsWith('/draft.json')),
        isTrue);
  });

  test('异步保存期间切换账号，不写入旧账号或新账号的草稿', () async {
    final auth = await _installAccount('a');
    final guarded = ConversationDraftStore(
      conversationId: 'old-cid',
      directoryResolver: () async {
        await auth.setAccount('b');
        return base;
      },
    );
    await expectLater(
      guarded.save(text: '账号 A 的未发文字'),
      throwsA(isA<LoginAccountChangedException>()),
    );
    expect(await store().load(), isNull);
    expect(await store(account: 'b').load(), isNull);
  });

  test('捕获的账号已经变化，旧实例不能读取或清除原账号草稿', () async {
    final auth = await _installAccount('a');
    await store().save(text: '账号 A 的草稿');
    final guarded = ConversationDraftStore(
      conversationId: 'old-cid',
      directoryResolver: () async => base,
    );
    await auth.setAccount('b');
    await expectLater(
        guarded.load(), throwsA(isA<LoginAccountChangedException>()));
    await expectLater(
        guarded.clear(), throwsA(isA<LoginAccountChangedException>()));
    expect((await store().load())!.text, '账号 A 的草稿');
    expect(await store(account: 'b').load(), isNull);
  });

  if (!Platform.isWindows) {
    test('符号链接附件不复制；符号链接 manifest 不读取', () async {
      final original = await pick('original.txt', [1]);
      final linked = Link('${picker.path}/link.txt');
      await linked.create(original.path);
      final saved = await store().save(text: '文字', files: [linked.path]);
      expect(saved!.missingAttachmentCount, 1);
      final file = await manifest();
      await file.delete();
      await Link(file.path).create(original.path);
      expect(await store().load(), isNull);
      expect(await original.readAsBytes(), [1]);
    });
  }
}

Future<_MemoryTokenStorage> _installAccount(String account) async {
  final storage = _MemoryTokenStorage();
  await storage.setAccount(account);
  LoginSdkConfig.install(LoginSdkConfig(
    baseUrl: 'localhost:3000',
    headerProvider: () async => const {},
    syncHeaders: () => const {},
    routes: LoginRoutes.imooc,
    responseAdapter: ImoocResponseAdapter(),
    storage: storage,
    onLogoutNavigate: () {},
  ));
  return storage;
}

final class _MemoryTokenStorage implements TokenStorage {
  Map<String, dynamic>? _profile;

  Future<void> setAccount(String account) => writeProfile(
        token: 'token-$account',
        userName: 'user-$account',
        extras: {'accountHash': account},
      );

  @override
  Future<void> clear() async => _profile = null;
  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();
  @override
  Map<String, dynamic>? readProfileSync() => _profile;
  @override
  Future<String?> readToken() async => readTokenSync();
  @override
  String? readTokenSync() => _profile?['boardingPass'] as String?;
  @override
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras = const {},
  }) async {
    _profile = {'boardingPass': token, 'userName': userName, ...extras};
  }
}
