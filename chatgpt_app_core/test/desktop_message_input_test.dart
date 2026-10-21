import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });
  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    for (final anime in [false, true]) {
      testWidgets('$platform anime=$anime 回车发送、换行及中文组词互不冲突', (tester) async {
        final provider = ThemeProvider();
        if (anime) provider.setVisualStyle(AppVisualStyle.anime);
        final controller = TextEditingController(text: '你好');
        addTearDown(controller.dispose);
        var sends = 0;
        var enabled = true;
        late StateSetter rebuild;
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
              theme: provider.getTheme(),
              home: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return Scaffold(
                      body: Align(
                    alignment: Alignment.bottomCenter,
                    child: MessageInputWidget('输入消息',
                        controller: controller,
                        enable: enabled,
                        clearOnSend: false,
                        speechInputEnabled: false,
                        onSend: () => sends++),
                  ));
                },
              )),
        ));
        await tester.tap(find.byType(TextField));
        await tester.pump();
        expect(tester.widget<TextField>(find.byType(TextField)).maxLines, 5);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(sends, 0);
        expect(controller.text, contains('\n'));
        controller.value = const TextEditingValue(
            text: 'ni',
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange(start: 0, end: 2));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(sends, 0, reason: '输入法尚在组词时不发送');
        controller.value = const TextEditingValue(
            text: '你好', selection: TextSelection.collapsed(offset: 2));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(sends, 1);
        rebuild(() => enabled = false);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(sends, 1, reason: '禁用时键盘不能绕过发送闸门');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: TargetPlatformVariant({platform}));
    }
  }
}
