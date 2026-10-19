import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hi_download/hi_download.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manifestPath=Platform.environment['CHATAI_RELEASE_MANIFEST'];
  test('published ARM64 APK pauses, resumes through HTTPS and verifies full SHA',() async {
    final manifest=jsonDecode(await File(manifestPath!).readAsString()) as Map;
    expect(manifest['versionCode'],16);
    final artifact=(manifest['artifacts'] as Map)['arm64-v8a'] as Map;
    final uri=Uri.parse(artifact['url']);expect(uri.scheme,'https');expect(uri.host,'kushui.shop');
    final directory=await Directory.systemTemp.createTemp('aipu-release16-resume-');
    final previous=HttpOverrides.current;HttpOverrides.global=null;
    try {
      final pause=DownloadCancellationToken();
      await expectLater(HiDownLoad().download(downLoadUrl:artifact['url'],fileName:'aipu16.apk',expectedSha256:artifact['sha256'],directoryProvider:()async=>directory,cancellationToken:pause,listener:(_,received,__){if(received>=1024*1024)pause.cancel();}),throwsA(isA<DownloadCancelled>()));
      final offset=await File('${directory.path}/aipu16.apk.part').length();expect(offset,greaterThanOrEqualTo(1024*1024));
      int? firstReceived;var done=false;
      final path=await HiDownLoad().download(downLoadUrl:artifact['url'],fileName:'aipu16.apk',expectedSha256:artifact['sha256'],directoryProvider:()async=>directory,listener:(_,received,completed){firstReceived??=received;done=completed;});
      expect(firstReceived,greaterThan(offset));expect(done,true);expect(await File(path).length(),artifact['bytes']);
      expect(await File('$path.part').exists(),false);
    } finally {HttpOverrides.global=previous;await directory.delete(recursive:true);}
  },skip:manifestPath==null,timeout:const Timeout(Duration(minutes:5)));
}
