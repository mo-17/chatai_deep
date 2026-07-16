import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hi_download/hi_download.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
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
    expect(await File('${tempDirectory.path}/ChatGPT.apk.part').exists(), isFalse);
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

  test('future resolves only after all bytes are flushed and renamed', () async {
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
    expect(await File('${tempDirectory.path}/ChatGPT.apk.part').exists(), isFalse);
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
