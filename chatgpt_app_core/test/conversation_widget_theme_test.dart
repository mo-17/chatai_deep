import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/widget/conversation_widget.dart';
import 'package:flutter/material.dart';
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

  ConversationModel model() => ConversationModel(
        cid: 1,
        title: '和星空旅人的超长对话标题，用来确认小屏不会溢出',
        icon: '',
        updateAt: DateTime(2026, 7, 12).millisecondsSinceEpoch,
        stickTime: DateTime(2026, 7, 12).millisecondsSinceEpoch,
        messageCount: 42,
        lastMessage: '今天继续完善这个世界的设定与角色关系。',
      );

  AssetImage? packageAssetProvider(ImageProvider<Object> provider) {
    final source = provider is ResizeImage ? provider.imageProvider : provider;
    return source is AssetImage ? source : null;
  }

  Finder packageAssetImage(String assetName) => find.byWidgetPredicate(
        (widget) {
          if (widget is! Image) return false;
          final provider = packageAssetProvider(widget.image);
          return provider?.assetName == assetName &&
              provider?.package == StarcoreIconAssets.packageName;
        },
      );

  testWidgets('二次元会话卡支持大字体、置顶状态和点击', (tester) async {
    tester.view.physicalSize = const Size(390, 560);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final provider = ThemeProvider()..setVisualStyle(AppVisualStyle.anime);
    var tapped = false;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: provider.getTheme(),
          themeAnimationDuration: Duration.zero,
          home: Scaffold(
            body: ListView(
              children: [
                ConversationWidget(
                  model: model(),
                  onPressed: (_) => tapped = true,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('anime_conversation_item_1')),
        findsOneWidget);
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('anime_conversation_item_1')));
    expect(tapped, isTrue);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('经典风格仍走旧会话列表渲染路径', (tester) async {
    final provider = ThemeProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: provider.getTheme(),
          home: Scaffold(body: ConversationWidget(model: model())),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('classic_conversation_item_1')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('anime_conversation_item_1')), findsNothing);
  });

  testWidgets('二次元会话卡渲染 allowlisted package asset，经典风格保持旧路径', (tester) async {
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    final provider = ThemeProvider()..setVisualStyle(AppVisualStyle.anime);
    final assetModel = model()
      ..avatarType = AvatarAssetService.assetType
      ..avatarValue = StarcoreIconAssets.assistantExplorerId;
    Widget app() => ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            theme: provider.getTheme(),
            themeAnimationDuration: Duration.zero,
            home: Scaffold(body: ConversationWidget(model: assetModel)),
          ),
        );

    await tester.pumpWidget(app());
    expect(
      packageAssetImage(StarcoreIconAssets.assistantExplorer),
      findsOneWidget,
    );
    final image = tester.widget<Image>(
      packageAssetImage(StarcoreIconAssets.assistantExplorer),
    );
    expect(image.image, isA<ResizeImage>());
    final resized = image.image as ResizeImage;
    expect(resized.width, 100);
    expect(resized.height, 100);

    provider.setVisualStyle(AppVisualStyle.classic);
    await tester.pumpWidget(app());
    expect(
      packageAssetImage(StarcoreIconAssets.assistantExplorer),
      findsNothing,
    );
    expect(find.text('AI'), findsOneWidget);
  });

  testWidgets('二次元空头像回退 explorer package asset，经典风格保持 AI 回退', (tester) async {
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    final provider = ThemeProvider()..setVisualStyle(AppVisualStyle.anime);
    final noAvatarModel = model();
    Widget app() => ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            theme: provider.getTheme(),
            themeAnimationDuration: Duration.zero,
            home: Scaffold(body: ConversationWidget(model: noAvatarModel)),
          ),
        );

    await tester.pumpWidget(app());
    expect(
      packageAssetImage(StarcoreIconAssets.assistantExplorer),
      findsOneWidget,
    );
    final image = tester.widget<Image>(
      packageAssetImage(StarcoreIconAssets.assistantExplorer),
    );
    expect(image.image, isA<ResizeImage>());
    final resized = image.image as ResizeImage;
    expect(resized.width, 100);
    expect(resized.height, 100);

    provider.setVisualStyle(AppVisualStyle.classic);
    await tester.pumpWidget(app());
    expect(
      packageAssetImage(StarcoreIconAssets.assistantExplorer),
      findsNothing,
    );
    expect(find.text('AI'), findsOneWidget);
  });
}
