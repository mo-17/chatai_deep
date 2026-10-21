import 'package:chatgpt_app_core/widget/desktop_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets('$platform 缩放保留内容状态，导航支持键盘', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var selected = 0;
      await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
            builder: (_, setState) => DesktopHomeLayout(
                  selectedIndex: selected,
                  onSelected: (index) => setState(() => selected = index),
                  bottomNavigationBar: const Text('底部导航'),
                  body: const _Counter(),
                )),
      ));
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.text('底部导航'), findsNothing);
      await tester.tap(find.text('计数 0'));
      await tester.pump();
      final modifier = platform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();
      expect(selected, 2);
      tester.view.physicalSize = const Size(800, 600);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('底部导航'), findsOneWidget);
      expect(find.text('计数 1'), findsOneWidget);
      tester.view.physicalSize = const Size(1440, 350);
      await tester.pumpAndSettle();
      expect(find.text('计数 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));

    testWidgets('$platform 会话双栏缩小时不重建详情', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(
        home: DesktopConversationLayout(
          master: Text('会话列表'),
          detail: _Counter(),
        ),
      ));
      expect(find.text('会话列表'), findsOneWidget);
      await tester.tap(find.text('计数 0'));
      await tester.pump();
      tester.view.physicalSize = const Size(800, 600);
      await tester.pumpAndSettle();
      expect(find.text('会话列表'), findsNothing);
      expect(find.text('计数 1'), findsOneWidget);
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpAndSettle();
      expect(find.text('计数 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
  }

  testWidgets('宽屏 Android 保留移动导航', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: DesktopHomeLayout(
      body: const Text('内容'),
      bottomNavigationBar: const Text('底部导航'),
      selectedIndex: 0,
      onSelected: (_) {},
    )));
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.text('底部导航'), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));
}

class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  var count = 0;
  @override
  Widget build(BuildContext context) => Center(
          child: TextButton(
        onPressed: () => setState(() => count++),
        child: Text('计数 $count'),
      ));
}
