import 'package:chatgpt_app_core/platform/desktop_quick_assistant.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(DesktopQuickAssistant.channel, null));
  test('原生注册失败后清除已启用状态，避免关闭窗口后误认为仍有托盘', () async {
    final assistant = DesktopQuickAssistant();
    if (!assistant.supported) return;
    var failure = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DesktopQuickAssistant.channel, (call) async {
      if (failure) throw PlatformException(code: 'hotkey_unavailable');
      return (call.arguments as Map)['enabled'];
    });
    await assistant.configure(true);
    expect(assistant.enabled, true);
    failure = true;
    await assistant.configure(true);
    expect(assistant.enabled, false);
    expect(assistant.error, isNotNull);
    expect(HiCache.getInstance().get('desktop_quick_assistant_enabled'), false);
  });
  test('未登录或没有捕获令牌的截图不能进入任务中心', () async {
    final assistant = DesktopQuickAssistant();
    expect(await assistant.handle(const MethodCall('beginCapture')), isNull);
    expect(
        await assistant.handle(MethodCall('captured', {
          'token': 'unknown',
          'bytes': Uint8List.fromList([1, 2, 3])
        })),
        isNull);
    expect(
        await assistant
            .handle(const MethodCall('captureCancelled', {'token': 'unknown'})),
        isNull);
  });
}
