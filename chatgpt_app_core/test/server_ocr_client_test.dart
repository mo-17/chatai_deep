import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:chatgpt_app_core/chat/application/server_ocr_client.dart';
import 'package:chatgpt_app_core/chat/application/import_operation.dart';
import 'package:chatgpt_app_core/chat/application/knowledge_import_error.dart';

void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('server_ocr_test_');
    file =
        await File('${directory.path}/scan.pdf').writeAsString('%PDF-fixture');
  });
  tearDown(() => directory.delete(recursive: true));
  http.Response response(Map<String, dynamic> data) =>
      http.Response(jsonEncode({'code': 0, 'data': data}), 200);
  ServerOcrClient make(http.Client client, {bool Function()? current}) =>
      ServerOcrClient(
          base: Uri.parse('https://original.example/uapi/ocr/'),
          headers: {'Authorization': 'Bearer captured-token'},
          isCurrent: current ?? () => true,
          clientFactory: () => client,
          pollInterval: Duration.zero);

  test(
      'selects missing pages, preserves original positions and removes remote result',
      () async {
    final calls = <http.Request>[];
    var polls = 0;
    final client = make(MockClient((request) async {
      calls.add(request);
      final id = request.url.pathSegments.last;
      if (request.method == 'DELETE') {
        return response({'id': id, 'state': 'cancelled'});
      }
      if (request.method == 'POST') {
        expect(request.url.queryParameters, {'kind': 'pdf', 'pages': '2,4'});
        expect(request.body, '%PDF-fixture');
        return response({'id': id, 'state': 'queued'});
      }
      polls++;
      return response({
        'id': id,
        'state': 'completed',
        'result': {
          'totalPages': 5,
          'pages': [
            {'page': 2, 'text': 'second'},
            {'page': 4, 'text': 'fourth'}
          ]
        }
      });
    }));
    final result =
        await client.recognize(file.path, pdf: true, pageNumbers: [2, 4]);
    expect(result.pages, ['', 'second', '', 'fourth', '']);
    expect(polls, 1);
    expect(calls.last.method, 'DELETE');
    expect(
        calls.every(
            (c) => c.headers['Authorization'] == 'Bearer captured-token'),
        true);
    expect(calls.every((c) => !c.followRedirects), true);
  });

  test('cancel during upload deletes known job id and rejects late completion',
      () async {
    final operation = ImportCancellation();
    String? uploaded, deleted;
    final client = make(MockClient((request) async {
      final id = request.url.pathSegments.last;
      if (request.method == 'DELETE') {
        deleted = id;
        return response({'id': id, 'state': 'cancelled'});
      }
      uploaded = id;
      operation.cancel();
      return response({
        'id': id,
        'state': 'completed',
        'result': {
          'totalPages': 1,
          'pages': [
            {'page': 1, 'text': 'must not save'}
          ]
        }
      });
    }));
    await expectLater(
        client.recognize(file.path, pdf: true, cancellation: operation),
        throwsA(isA<ImportCancelled>()));
    expect(deleted, uploaded);
  });

  test('account/backend change uses captured endpoint only for cleanup',
      () async {
    var current = true;
    final calls = <http.Request>[];
    final client = make(MockClient((request) async {
      calls.add(request);
      final id = request.url.pathSegments.last;
      current = false;
      return response({'id': id, 'state': 'queued'});
    }), current: () => current);
    await expectLater(client.recognize(file.path, pdf: true),
        throwsA(isA<ImportCancelled>()));
    expect(calls.map((c) => c.method), ['POST', 'DELETE']);
    expect(calls.every((c) => c.url.host == 'original.example'), true);
  });

  test('oversized local file never uploads', () async {
    await file.writeAsBytes(List.filled(ServerOcrClient.maxBytes + 1, 0));
    var calls = 0;
    final client = make(MockClient((_) async {
      calls++;
      return response({});
    }));
    await expectLater(client.recognize(file.path, pdf: true),
        throwsA(isA<FormatException>()));
    expect(calls, 0);
  });

  test(
      'omitted selected page is rejected without silently importing a partial PDF',
      () async {
    var deleted = false;
    final client = make(MockClient((request) async {
      final id = request.url.pathSegments.last;
      if (request.method == 'DELETE') {
        deleted = true;
        return response({'id': id});
      }
      return response({
        'id': id,
        'state': 'completed',
        'result': {
          'totalPages': 3,
          'pages': [
            {'page': 2, 'text': 'only one'}
          ]
        }
      });
    }));
    await expectLater(
        client.recognize(file.path, pdf: true, pageNumbers: [2, 3]),
        throwsA(isA<KnowledgeImportFailure>()));
    expect(deleted, true);
  });

  test(
      'queue failures are safely classified and cancelled without leaking upstream errors',
      () async {
    var deleted = false;
    final client = make(MockClient((request) async {
      if (request.method == 'DELETE') {
        deleted = true;
        return response({});
      }
      return http.Response('private upstream error /root/file', 429);
    }));
    await expectLater(
        client.recognize(file.path, pdf: true),
        throwsA(isA<KnowledgeImportFailure>()
            .having((e) => e.kind, 'kind', KnowledgeImportErrorKind.busy)
            .having((e) => e.message.contains('private'), 'safe', false)));
    expect(deleted, true);
  });
}
