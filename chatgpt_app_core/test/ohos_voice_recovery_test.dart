import 'dart:async';
import 'package:chatgpt_app_core/chat/application/ohos_image_recovery.dart';
import 'package:chatgpt_app_core/chat/application/sherpa_onnx_read_aloud_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const player = MethodChannel('aipu/tts-playback');
  const picker = MethodChannel('com.hzb.flutter_ai/image_picker');
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(player, null);
    messenger.setMockMethodCallHandler(picker, null);
  });
  test('新会话按账号/助手/项目恢复，已保存会话按 cid 隔离', () {
    String scope(String account, int cid, bool persisted, int? assistant,
            int? project) =>
        OhosImageRecovery.conversationScope(
            account: account,
            cid: cid,
            persisted: persisted,
            assistantId: assistant,
            projectId: project);
    expect(scope('a', 1, false, 3, 4), scope('a', 999, false, 3, 4));
    for (final other in [
      scope('b', 1, false, 3, 4),
      scope('a', 1, false, 8, 4),
      scope('a', 1, false, 3, 9),
      scope('a', 1, true, 3, 4)
    ]) {
      expect(other, isNot(scope('a', 1, false, 3, 4)));
    }
    expect(scope('a', 1, true, null, null),
        isNot(scope('a', 2, true, null, null)));
  });
  test('恢复与确认使用同一个匿名作用域，确认绑定操作 id', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(picker, (call) async {
      calls.add(call);
      if (call.method == 'setRecoveryContext') return 'job1';
      if (call.method == 'retrieveLostData') {
        return {'id': 'job1', 'text': '原输入'};
      }
      return null;
    });
    const recovery = OhosImageRecovery();
    expect(
        await recovery.begin('account:cid', '原输入', ['/cache/a.jpg']), 'job1');
    expect((await recovery.retrieve('account:cid'))!['text'], '原输入');
    await recovery.acknowledge('account:cid', 'job1');
    expect(calls.map((c) => c.arguments['scope']).toSet(),
        {OhosImageRecovery.scopeFor('account:cid')});
    expect(calls.last.arguments['id'], 'job1');
  });
  test('鸿蒙模型播放器等待原生完成，stop 精确取消当前 id', () async {
    final done = Completer<void>(), calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(player, (call) async {
      calls.add(call);
      if (call.method == 'play') await done.future;
      if (call.method == 'stop') done.complete();
      return null;
    });
    final playback = OhosTtsAudioPlayback();
    var finished = false;
    final playing =
        playback.playFile('/cache/a.wav').then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    expect(finished, false);
    await playback.stop();
    await playing;
    expect(calls.map((c) => c.method), ['play', 'stop']);
    expect(calls[0].arguments['id'], calls[1].arguments['id']);
    await playback.stop();
    expect(calls.length, 2);
  });
  test('鸿蒙播放错误传递给朗读协调器，不能伪装成播放完成', () async {
    messenger.setMockMethodCallHandler(
        player, (_) async => throw PlatformException(code: 'playback_error'));
    await expectLater(OhosTtsAudioPlayback().playFile('/cache/a.wav'),
        throwsA(isA<PlatformException>()));
  });
  for (final existing in ['', '新输入']) {
    testWidgets('恢复需要明确确认并保留当前输入：$existing', (tester) async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(picker, (call) async {
        calls.add(call);
        if (call.method == 'retrieveLostData') {
          return {
            'id': 'job',
            'phase': 'ready',
            'text': '旧输入',
            'images': <String>[],
            'files': [
              {'path': '/cache/image.jpg'}
            ],
          };
        }
        return null;
      });
      final controller = TextEditingController(text: existing);
      addTearDown(controller.dispose);
      List<String>? picked;
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: ThemeProvider(),
          child: MaterialApp(
              home: Scaffold(
                  body: MessageInputWidget('输入',
                      controller: controller,
                      referenceScopeKey: 'account:cid',
                      imageRecovery: OhosImageRecovery(supported: () => true),
                      onImagesPicked: (value) => picked = value,
                      speechInputEnabled: false)))));
      await tester.pumpAndSettle();
      expect(find.text('恢复上次图片选择'), findsOneWidget);
      expect(picked, isNull);
      await tester.tap(find.text('恢复草稿'));
      await tester.pumpAndSettle();
      expect(controller.text, existing.isEmpty ? '旧输入' : existing);
      expect(picked, ['/cache/image.jpg']);
      expect(calls.last.method, 'ackRecovery');
      expect(calls.last.arguments['id'], 'job');
    });
  }
  testWidgets('确认期间切换账号不回填、不消费原账号记录', (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(picker, (call) async {
      calls.add(call);
      return {
        'id': 'job',
        'phase': 'pending',
        'text': '旧账号输入',
        'images': <String>[],
        'files': <Object>[]
      };
    });
    var current = true, picked = false;
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: ThemeProvider(),
        child: MaterialApp(
            home: Scaffold(
                body: MessageInputWidget('输入',
                    controller: controller,
                    referenceScopeKey: 'account:cid',
                    isReferenceScopeCurrent: () => current,
                    imageRecovery: OhosImageRecovery(supported: () => true),
                    onImagesPicked: (_) => picked = true,
                    speechInputEnabled: false)))));
    await tester.pumpAndSettle();
    current = false;
    await tester.tap(find.text('恢复草稿'));
    await tester.pumpAndSettle();
    expect(controller.text, '');
    expect(picked, false);
    expect(calls.map((call) => call.method), ['retrieveLostData']);
  });
}
