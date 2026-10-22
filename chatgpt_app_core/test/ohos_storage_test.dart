import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/storage/local_media_references.dart';
import 'package:chatgpt_app_core/storage/ohos_storage_service.dart';
import 'package:chatgpt_app_core/pages/storage_management_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Directory root, dbs, docs;
  final prefs = <String, Object?>{};
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    root = await Directory.systemTemp.createTemp('ohos_storage_');
    dbs = await Directory('${root.path}/dbs').create();
    docs = await Directory('${root.path}/docs').create();
    prefs.clear();
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(OhosStorageService.channel, null);
    await root.delete(recursive: true);
  });
  LocalMediaReferences scanner({int maxBytes = 64 * 1024 * 1024}) =>
      LocalMediaReferences(
          databases: () async => dbs,
          documents: () async => [docs],
          preferences: () => prefs,
          factory: databaseFactoryFfi,
          maxBytes: maxBytes);
  StorageCandidate image(int n) => StorageCandidate(
      '/files/chatai_picked_images/image_1700000000000_$n.jpg',
      'image_1700000000000_$n.jpg',
      'image',
      10,
      1700000000000);
  Future<void> database(String account, Map<String, Object?> values) async {
    final db = await databaseFactoryFfi.openDatabase('${dbs.path}/$account.db');
    try {
      await db.execute(
          'create table tb_messages (images text, blocks text, avatar text)');
      await db.insert('tb_messages', values);
    } finally {
      await db.close();
    }
  }

  Map<String, Object?> inventory(List<StorageCandidate> entries) => {
        'token': 'snapshot',
        'fileBytes': 100,
        'imageBytes': 20,
        'entries': [
          for (final e in entries)
            {
              'path': e.path,
              'name': e.name,
              'kind': e.kind,
              'bytes': e.bytes,
              'created': e.created
            }
        ]
      };

  test('全部账号 SQLite、转义 JSON、设置和草稿引用均保护，数据库不迁移或写入', () async {
    final candidates = List.generate(5, image);
    await database('account_a', {
      'images': jsonEncode([candidates[0].path])
          .replaceAll('/', r'\/')
          .replaceAll('_', r'\u005f')
    });
    await database('account_b', {'avatar': candidates[1].name});
    prefs['settings_other_account'] =
        jsonEncode({'avatar': candidates[2].path});
    final draft = await Directory(
            '${docs.path}/conversation_drafts/accounts/other/conversation')
        .create(recursive: true);
    await File('${draft.path}/draft.json').writeAsString(jsonEncode({
      'version': 2,
      'text': '',
      'images': [candidates[3].path],
      'files': []
    }));
    expect(await scanner().collect(candidates),
        candidates.take(4).map((e) => e.name).toSet());
    final db =
        await databaseFactoryFfi.openDatabase('${dbs.path}/account_a.db');
    expect((await db.query('tb_messages')).length, 1);
    await db.close();
    final names = await dbs.list().map((e) => e.path.split('/').last).toList();
    expect(names.where((n) => n.endsWith('.db')), hasLength(2));
  });
  test('损坏数据库、损坏草稿、链接和预算耗尽均不能签发删除证明', () async {
    final bad = await File('${dbs.path}/bad.db').writeAsString('not sqlite');
    await expectLater(scanner().collect([image(0)]), throwsA(anything));
    await bad.delete();
    await database('broken_record', {'blocks': '{broken'});
    await expectLater(scanner().collect([image(0)]), throwsA(anything));
    await File('${dbs.path}/broken_record.db').delete();
    final dir = await Directory('${docs.path}/conversation_drafts').create();
    final draft = await File('${dir.path}/draft.json').writeAsString('{broken');
    await expectLater(scanner().collect([image(0)]), throwsA(anything));
    await draft.delete();
    final link = await Link('${docs.path}/link').create(root.path);
    await expectLater(scanner().collect([image(0)]), throwsA(anything));
    await link.delete();
    prefs['large'] = 'x' * 100;
    await expectLater(
        scanner(maxBytes: 10).collect([image(0)]), throwsA(isA<StateError>()));
  });
  test('其它账号仅引用文件批次中的一份文件也保留整批', () async {
    const item = StorageCandidate('/cache/chatai_file_picker/1700000000000_3',
        '1700000000000_3', 'file', 5, 1700000000000);
    await database('other', {
      'blocks': jsonEncode([
        {'path': '${item.path}/0_资料.txt'}
      ])
    });
    expect(await scanner().collect([item]), {item.name});
  });
  test('服务传精确快照及保护名称，账号变化或核对失败不调用原生删除', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(OhosStorageService.channel,
        (call) async {
      calls.add(call);
      if (call.method == 'storageInventory') return inventory([image(0)]);
      expect(call.arguments['token'], 'snapshot');
      expect(call.arguments['referenced'], [image(0).name]);
      return {'removed': 0, 'bytes': 0, 'retained': 1};
    });
    prefs['avatar'] = image(0).path;
    final service = OhosStorageService(references: scanner());
    expect((await service.clean(manual: true)).retained, 1);
    calls.clear();
    await expectLater(service.clean(isCurrent: () => false), throwsStateError);
    expect(calls.map((e) => e.method), ['storageInventory']);
    await File('${dbs.path}/bad.db').writeAsString('bad');
    calls.clear();
    await service.prepareSelection();
    expect(calls.map((e) => e.method), ['storageInventory']);
  });
  test('近期候选不读取账号数据，无效通道结果不能成为删除请求', () async {
    await File('${dbs.path}/bad.db').writeAsString('bad');
    final fresh = StorageCandidate(image(0).path, image(0).name, 'image', 1,
        DateTime.now().millisecondsSinceEpoch);
    messenger.setMockMethodCallHandler(OhosStorageService.channel,
        (call) async {
      expect(call.method, 'storageInventory');
      return inventory([fresh]);
    });
    expect(
        (await OhosStorageService(references: scanner()).clean()).removed, 0);
    for (final value in [
      null,
      {
        'token': 'x',
        'fileBytes': 0,
        'imageBytes': 0,
        'entries': [
          {
            'path': '/outside/../a',
            'name': 'a',
            'kind': 'image',
            'bytes': 1,
            'created': 1
          }
        ]
      }
    ]) {
      messenger.setMockMethodCallHandler(
          OhosStorageService.channel, (_) async => value);
      await expectLater(OhosStorageService(references: scanner()).clean(),
          throwsFormatException);
    }
  });
  testWidgets('页面显示统计和清理结果，错误不展示路径或正文', (tester) async {
    var fail = false, cleaned = false;
    messenger.setMockMethodCallHandler(OhosStorageService.channel,
        (call) async {
      if (fail) {
        throw PlatformException(
            code: 'bad', message: '/private/account.db secret-body');
      }
      if (call.method == 'storageInventory') return inventory([image(0)]);
      cleaned = true;
      return {'removed': 1, 'bytes': 1048576, 'retained': 0};
    });
    await tester.pumpWidget(MaterialApp(
        home: StorageManagementPage(
            service: OhosStorageService(references: scanner()))));
    await tester.pumpAndSettle();
    expect(find.text('图片副本'), findsOneWidget);
    await tester.tap(find.text('清理无引用副本'));
    for (var i = 0; i < 100 && !cleaned; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
    expect(cleaned, true);
    expect(find.textContaining('已释放 1.0 MiB'), findsOneWidget);
    fail = true;
    await tester.tap(find.text('清理无引用副本'));
    await tester.pumpAndSettle();
    expect(find.textContaining('secret-body'), findsNothing);
    expect(find.textContaining('/private'), findsNothing);
    expect(find.textContaining('未处理的文件已保留'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
