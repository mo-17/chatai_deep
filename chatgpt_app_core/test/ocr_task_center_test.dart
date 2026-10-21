import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:chatgpt_app_core/chat/application/import_operation.dart';
import 'package:chatgpt_app_core/chat/application/ocr_task_center.dart';
import 'package:chatgpt_app_core/chat/application/pdf_ocr_result.dart';
import 'package:chatgpt_app_core/chat/application/server_ocr_client.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/ocr_task_dao.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late OcrTaskDao dao;
  late bool current;
  late OcrTaskCenter service;
  final uploaded = <List<int>>[];
  final methods = <String>[];
  late Future<http.Response> Function(http.Request) respond;
  http.Response completed(http.Request request, [String text = 'recognized']) =>
      http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'id': request.url.pathSegments.last,
              'state': 'completed',
              'result': {
                'totalPages': 1,
                'pages': [
                  {
                    'page': 1,
                    'text': text,
                    'width': 100,
                    'height': 200,
                    'lines': [
                      {
                        'text': text,
                        'confidence': .72,
                        'box': [
                          [1, 2],
                          [90, 2],
                          [90, 20],
                          [1, 20]
                        ]
                      }
                    ]
                  }
                ]
              }
            }
          }),
          200);
  setUp(() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(db.close);
    dao = await OcrTaskDao.create(HiDBManager.test(db));
    current = true;
    uploaded.clear();
    methods.clear();
    respond = (request) async => request.method == 'DELETE'
        ? http.Response('{"code":0,"data":{"state":"cancelled"}}', 200)
        : completed(request);
    service = OcrTaskCenter(
        dao: dao,
        origin: 'https://backend.example',
        isCurrent: () => current,
        createClient: () => ServerOcrClient(
            base: Uri.parse('https://backend.example/uapi/ocr/'),
            headers: const {'Authorization': 'Bearer test'},
            isCurrent: () => current,
            pollInterval: Duration.zero,
            clientFactory: () => MockClient((request) async {
                  methods.add(request.method);
                  if (request.method == 'POST') {
                    expect(request.url.queryParameters['preview'], 'true');
                    uploaded.add(List<int>.from(request.bodyBytes));
                  }
                  return respond(request);
                })));
    addTearDown(service.retire);
    await service.recover();
  });
  Future<String> add([int value = 1]) =>
      service.add('scan$value.png', Uint8List.fromList([value, 2, 3]));

  test('添加只保存冻结副本，用户开始前没有网络请求', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final id = await service.add('scan.png', bytes);
    bytes[0] = 9;
    expect((await service.load(id))!.bytes, [1, 2, 3]);
    expect((await service.list()).single.state, OcrTaskState.waiting);
    expect(uploaded, isEmpty);
  });
  test('批量按顺序识别，保存坐标/置信度并清理服务器结果', () async {
    final first = await add(1), second = await add(2);
    await service.start([first, second]);
    await service.settled;
    expect(uploaded, [
      [1, 2, 3],
      [2, 2, 3]
    ]);
    expect(methods, ['POST', 'DELETE', 'POST', 'DELETE']);
    expect((await service.list()).map((r) => r.state),
        [OcrTaskState.review, OcrTaskState.review]);
    final result = (await service.load(first))!.result!;
    expect(result.details.single.lines.single.needsReview, true);
    expect(result.details.single.lines.single.box.last, [1, 20]);
    await service.saveCorrection(first, result.corrected(['手工校对文字']));
    expect((await service.load(first))!.task.state, OcrTaskState.completed);
    expect((await service.load(first))!.result!.text, '手工校对文字');
    expect(
        (await service.load(first))!.result!.details.single.lines.single.text,
        'recognized');
  });
  test('某文件失败不阻断后续文件，可手动重试失败项', () async {
    var failed = false;
    respond = (request) async {
      if (request.method == 'POST' && request.bodyBytes.first == 1 && !failed) {
        failed = true;
        return http.Response('unavailable', 503);
      }
      return request.method == 'DELETE'
          ? http.Response('{"code":0,"data":{}}', 200)
          : completed(request);
    };
    final first = await add(1), second = await add(2);
    await service.start([first, second]);
    await service.settled;
    expect((await service.load(first))!.task.state, OcrTaskState.failed);
    expect((await service.load(second))!.task.state, OcrTaskState.review);
    await service.start([first]);
    await service.settled;
    expect((await service.load(first))!.task.state, OcrTaskState.review);
    expect(uploaded.length, 3);
  });
  test('取消运行任务后迟到响应不能覆盖状态，后续文件继续', () async {
    final entered = Completer<void>(), release = Completer<void>();
    respond = (request) async {
      if (request.method == 'POST' && request.bodyBytes.first == 1) {
        entered.complete();
        await release.future;
      }
      return request.method == 'DELETE'
          ? http.Response('{"code":0,"data":{}}', 200)
          : completed(request);
    };
    final first = await add(1), second = await add(2);
    await service.start([first, second]);
    await entered.future;
    await service.cancel(first);
    release.complete();
    await service.settled;
    expect((await service.load(first))!.task.state, OcrTaskState.cancelled);
    expect((await service.load(first))!.result, isNull);
    expect((await service.load(second))!.task.state, OcrTaskState.review);
  });
  test('账号变化后迟到响应不写结果也不上传后续文件', () async {
    final entered = Completer<void>(), release = Completer<void>();
    respond = (request) async {
      if (request.method == 'POST') {
        entered.complete();
        await release.future;
      }
      return request.method == 'DELETE'
          ? http.Response('{"code":0,"data":{}}', 200)
          : completed(request);
    };
    final first = await add(1), second = await add(2);
    await service.start([first, second]);
    await entered.future;
    current = false;
    release.complete();
    await service.settled;
    expect((await dao.load(first))!.result, isNull);
    expect((await dao.load(second))!.task.state, OcrTaskState.queued);
    expect(uploaded.length, 1);
    expect(methods.last, 'DELETE');
    await expectLater(service.list(), throwsA(isA<ImportCancelled>()));
  });
  test('重建服务将未完成任务标为中断，保留副本且不自动上传', () async {
    final id = await add();
    await dao.transition(id, {OcrTaskState.waiting}, OcrTaskState.running,
        verify: service.verify);
    service.retire();
    final recreated = OcrTaskCenter(
        dao: dao,
        origin: 'https://backend.example',
        isCurrent: () => current,
        createClient: () => throw StateError('must not upload'));
    addTearDown(recreated.retire);
    await recreated.recover();
    expect((await recreated.load(id))!.task.state, OcrTaskState.interrupted);
    expect((await recreated.load(id))!.bytes, [1, 2, 3]);
    expect(uploaded, isEmpty);
  });
  test('任务删除释放副本和结果，不可读取已删除任务', () async {
    final id = await add();
    await service.start([id]);
    await service.settled;
    await service.delete(id);
    expect(await service.load(id), isNull);
    expect(await service.list(), isEmpty);
  });
  test('只有保存校对后才能导入知识库，删除任务不会删除已导入资料', () async {
    final id = await add();
    await service.start([id]); await service.settled;
    await expectLater(service.importKnowledge(id), throwsFormatException);
    final result = (await service.load(id))!.result!;
    await service.saveCorrection(id, result.corrected(['经过校对的知识正文']));
    await service.importKnowledge(id);
    final knowledge = await KnowledgeDao.create(dao.storage);
    expect((await knowledge.search('校对')).single.content, contains('经过校对的知识正文'));
    await service.delete(id);
    expect((await knowledge.getDocuments()).length, 1);
  });
  test('原件总大小超过 40 MiB 前拒绝新任务', () async {
    final bytes = Uint8List(8 * 1024 * 1024);
    for (var i = 0; i < 5; i++) { await service.add('large$i.png', bytes); }
    await expectLater(service.add('overflow.png', Uint8List.fromList([1])), throwsFormatException);
    expect((await service.list()).length, 5);
  });
  test('拒绝超大文件、过多任务和被篡改的原件', () async {
    await expectLater(service.add('huge.png', Uint8List(8 * 1024 * 1024 + 1)),
        throwsFormatException);
    for (var i = 0; i < OcrTaskDao.maxTasks; i++) {
      await add(i);
    }
    await expectLater(add(21), throwsFormatException);
    final first = (await service.list()).first;
    await dao.storage.db.update(
        dao.tableName,
        {
          'source': Uint8List.fromList([9, 9, 9])
        },
        where: 'id=?',
        whereArgs: [first.id]);
    await expectLater(service.load(first.id), throwsFormatException);
  });
  test('后端变更不会把原任务自动上传到新后端', () async {
    final id = await add();
    final other = OcrTaskCenter(
        dao: dao,
        origin: 'https://other.example',
        isCurrent: () => true,
        createClient: () => throw StateError('must not upload'));
    addTearDown(other.retire);
    await expectLater(other.start([id]), throwsFormatException);
    expect(uploaded, isEmpty);
  });
  test('持久化结果解析拒绝越界页码、坐标、置信度和重复页', () {
    final invalid = [
      {
        'totalPages': 1,
        'pages': [
          {'page': 2, 'text': 'bad'}
        ]
      },
      {
        'totalPages': 1,
        'pages': [
          {'page': 1, 'text': 'a'},
          {'page': 1, 'text': 'b'}
        ]
      },
      {
        'totalPages': 1,
        'pages': [
          {
            'page': 1,
            'text': 'bad',
            'lines': [
              {'text': 'bad', 'confidence': 1.5}
            ]
          }
        ]
      },
      {
        'totalPages': 1,
        'pages': [
          {
            'page': 1,
            'text': 'bad',
            'lines': [
              {
                'text': 'bad',
                'box': [
                  [double.nan, 2]
                ]
              }
            ]
          }
        ]
      },
    ];
    for (final value in invalid) {
      expect(() => PdfOcrResult.fromJson(value), throwsFormatException);
    }
  });
}
