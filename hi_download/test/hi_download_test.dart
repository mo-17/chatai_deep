import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hi_download/hi_download.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  resumeTests();
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('hi_download_test_');
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('rejects a non-success HTTP response without creating an APK', () async {
    final client = MockClient((_) async => http.Response('missing', 404));

    await expectLater(
      HiDownLoad().download(
        downLoadUrl: 'https://example.com/app.apk',
        fileName: 'ChatGPT.apk',
        listener: (_, __, ___) {},
        client: client,
        directoryProvider: () async => tempDirectory,
      ),
      throwsA(isA<DownloadException>()),
    );

    expect(await File('${tempDirectory.path}/ChatGPT.apk').exists(), isFalse);
    expect(
        await File('${tempDirectory.path}/ChatGPT.apk.part').exists(), isFalse);
  });

  test('rejects a URL without a host before starting a request', () async {
    var requestCount = 0;
    final client = MockClient((_) async {
      requestCount += 1;
      return http.Response('unexpected', 200);
    });

    await expectLater(
      HiDownLoad().download(
        downLoadUrl: 'https:///app.apk',
        fileName: 'ChatGPT.apk',
        listener: (_, __, ___) {},
        client: client,
        directoryProvider: () async => tempDirectory,
      ),
      throwsA(isA<DownloadException>()),
    );

    expect(requestCount, 0);
  });

  test('rejects a malformed SHA-256 before downloading', () async {
    var requestCount = 0;
    final client = MockClient((_) async {
      requestCount += 1;
      return http.Response.bytes(const [1, 2, 3], 200);
    });

    await expectLater(
      HiDownLoad().download(
        downLoadUrl: 'https://example.com/app.apk',
        fileName: 'ChatGPT.apk',
        listener: (_, __, ___) {},
        expectedSha256: 'not-a-sha256',
        client: client,
        directoryProvider: () async => tempDirectory,
      ),
      throwsA(isA<DownloadException>()),
    );

    expect(requestCount, 0);
  });

  test('future resolves only after all bytes are flushed and renamed',
      () async {
    final bytes = List<int>.generate(4096, (index) => index % 251);
    final client = MockClient((_) async => http.Response.bytes(bytes, 200));
    var completed = false;
    var finalReceived = 0;

    final path = await HiDownLoad().download(
      downLoadUrl: 'https://example.com/app.apk',
      fileName: 'ChatGPT.apk',
      listener: (_, received, done) {
        finalReceived = received;
        if (done) completed = true;
      },
      client: client,
      directoryProvider: () async => tempDirectory,
    );

    expect(completed, isTrue);
    expect(finalReceived, bytes.length);
    expect(await File(path).readAsBytes(), bytes);
    expect(await File('$path.part').exists(), isFalse);
  });

  test('rejects a truncated response declared with a larger length', () async {
    final client = _StreamedClient(
      () => http.StreamedResponse(
        Stream.value(const [1, 2, 3]),
        200,
        contentLength: 10,
      ),
    );

    await expectLater(
      HiDownLoad().download(
        downLoadUrl: 'https://example.com/app.apk',
        fileName: 'ChatGPT.apk',
        listener: (_, __, ___) {},
        client: client,
        directoryProvider: () async => tempDirectory,
      ),
      throwsA(isA<DownloadException>()),
    );

    expect(await File('${tempDirectory.path}/ChatGPT.apk').exists(), isFalse);
  });

  test('deletes partial data when SHA-256 does not match', () async {
    const bytes = [1, 2, 3, 4];
    final client = MockClient((_) async => http.Response.bytes(bytes, 200));
    final wrongHash = sha256.convert(const [9, 9, 9]).toString();

    await expectLater(
      HiDownLoad().download(
        downLoadUrl: 'https://example.com/app.apk',
        fileName: 'ChatGPT.apk',
        listener: (_, __, ___) {},
        expectedSha256: wrongHash,
        client: client,
        directoryProvider: () async => tempDirectory,
      ),
      throwsA(isA<DownloadException>()),
    );

    expect(await File('${tempDirectory.path}/ChatGPT.apk').exists(), isFalse);
    expect(
        await File('${tempDirectory.path}/ChatGPT.apk.part').exists(), isFalse);
  });

  test('accepts a matching SHA-256', () async {
    const bytes = [1, 2, 3, 4];
    final client = MockClient((_) async => http.Response.bytes(bytes, 200));

    final path = await HiDownLoad().download(
      downLoadUrl: 'https://example.com/app.apk',
      fileName: 'ChatGPT.apk',
      listener: (_, __, ___) {},
      expectedSha256: sha256.convert(bytes).toString(),
      client: client,
      directoryProvider: () async => tempDirectory,
    );

    expect(await File(path).readAsBytes(), bytes);
  });
}

class _StreamedClient extends http.BaseClient {
  final http.StreamedResponse Function() responseBuilder;

  _StreamedClient(this.responseBuilder);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      responseBuilder();
}

// 两次请求共用磁盘分片，覆盖弱网中断后续传与版本变更。
void resumeTests() {
  test('resumes only matching resource and validates complete hash', () async {
    final dir = await Directory.systemTemp.createTemp('resume_');
    addTearDown(() => dir.delete(recursive: true));
    const bytes = [1, 2, 3, 4, 5, 6];
    final digest = sha256.convert(bytes).toString();
    final client = _RequestClient((request) async {
      if (request.headers['Range'] == null) {
        return http.StreamedResponse(Stream.value(bytes.take(3).toList()), 200,
            contentLength: 6, headers: {'etag': '"v1"'});
      }
      expect(request.headers['Range'], 'bytes=3-');
      expect(request.headers['If-Range'], '"v1"');
      return http.StreamedResponse(Stream.value(bytes.skip(3).toList()), 206,
          contentLength: 3,
          headers: {'content-range': 'bytes 3-5/6', 'etag': '"v1"'});
    });
    Future<String> download() => HiDownLoad().download(
        downLoadUrl: 'https://example.com/a.apk',
        fileName: 'a.apk',
        expectedSha256: digest,
        client: client,
        listener: (_, __, ___) {},
        directoryProvider: () async => dir);
    await expectLater(download(), throwsA(isA<DownloadException>()));
    expect(await File('${dir.path}/a.apk.part').length(), 3);
    final path = await download();
    expect(await File(path).readAsBytes(), bytes);
    expect(await File('$path.part.json').exists(), false);
  });

  test('pause interrupts stalled stream and keeps hashed partial', () async {
    final dir = await Directory.systemTemp.createTemp('pause_');
    addTearDown(() => dir.delete(recursive: true));
    final token = DownloadCancellationToken();
    final stream = StreamController<List<int>>();
    addTearDown(stream.close);
    final client = _StreamedClient(
        () => http.StreamedResponse(stream.stream, 200, contentLength: 6));
    final pending = HiDownLoad().download(
        downLoadUrl: 'https://example.com/a.apk',
        fileName: 'a.apk',
        expectedSha256: sha256.convert([1, 2, 3, 4, 5, 6]).toString(),
        client: client,
        cancellationToken: token,
        listener: (_, __, ___) => token.cancel(),
        directoryProvider: () async => dir);
    stream.add([1, 2, 3]);
    await expectLater(pending, throwsA(isA<DownloadCancelled>()));
    expect(await File('${dir.path}/a.apk.part').length(), 3);
  });

  test('rejects a wrong range and deletes unsafe partial', () async {
    final dir = await Directory.systemTemp.createTemp('range_');
    addTearDown(() => dir.delete(recursive: true));
    final digest = sha256.convert([1, 2, 3]).toString();
    await File('${dir.path}/a.apk.part').writeAsBytes([1]);
    await File('${dir.path}/a.apk.part.json').writeAsString(
        jsonEncode({'url': 'https://example.com/a.apk', 'sha256': digest}));
    await expectLater(
        HiDownLoad().download(
            downLoadUrl: 'https://example.com/a.apk',
            fileName: 'a.apk',
            expectedSha256: digest,
            client: _StreamedClient(() => http.StreamedResponse(
                Stream.value([2, 3]), 206,
                headers: {'content-range': 'bytes 0-1/3'})),
            listener: (_, __, ___) {},
            directoryProvider: () async => dir),
        throwsA(isA<DownloadException>()));
    expect(await File('${dir.path}/a.apk.part').exists(), false);
  });
}

class _RequestClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  _RequestClient(this.handler);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}
