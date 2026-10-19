import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatgpt_app_core/chat/application/downloadable_tts_models.dart';
import 'package:chatgpt_app_core/chat/application/sherpa_onnx_tts_assets.dart';
import 'package:chatgpt_app_core/chat/application/sherpa_onnx_read_aloud_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('published on-demand voice package downloads with SHA and installs without bundled weights',() async {
    final previous=HttpOverrides.current;
    final directory=await Directory.systemTemp.createTemp('chatai-live-voice-');
    HttpOverrides.global=null;
    try {
      final store=DownloadableTtsModelStore(baseDir:()async=>directory);
      final catalog=await store.catalog();
      expect(catalog.single.url,startsWith('https://kushui.shop/'));
      expect(catalog.single.bytes,greaterThan(100000000));
      var complete=false;
      await store.install(catalog.single,listener:(_,__,done){if(done)complete=true;});
      expect(complete,true);
      final model=await store.resolve(BundledSherpaOnnxTtsModel.matchaZhBaker.id);
      expect(model?.manifest.locale,'zh-CN');
      expect(await File(model!.resolve(model.manifest.acousticModel)).length(),greaterThan(1000000));
      final compatible=await BundledSherpaOnnxAssetInstaller(baseDir:()async=>directory).ensureInstalled(BundledSherpaOnnxTtsModel.matchaZhBaker);
      expect(compatible.rootDir.path,model.rootDir.path);
    } finally {HttpOverrides.global=previous;await directory.delete(recursive:true);}
  },skip:Platform.environment['CHATAI_LIVE_MODEL']!='1',timeout:const Timeout(Duration(minutes:5)));
}
