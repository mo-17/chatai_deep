import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/widget/starcore_message_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AssetImage? assetImageOf(Image widget) {
    final provider = widget.image;
    if (provider is AssetImage) return provider;
    if (provider is ResizeImage && provider.imageProvider is AssetImage) {
      return provider.imageProvider as AssetImage;
    }
    return null;
  }

  Finder packageAssetImage(String assetName) => find.byWidgetPredicate(
        (widget) {
          if (widget is! Image) return false;
          final image = assetImageOf(widget);
          return image?.assetName == assetName &&
              image?.package == StarcoreIconAssets.packageName;
        },
      );

  Future<void> pumpAvatar(
    WidgetTester tester, {
    required AppVisualTheme visualTheme,
    required MessageModel message,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: [visualTheme]),
      home: Scaffold(
        body: Builder(
          builder: (context) =>
              buildStarcoreMessageAvatar(
                context,
                message,
                40,
              ) ??
              const SizedBox(key: ValueKey('legacy-avatar')),
        ),
      ),
    ));
  }

  MessageModel receiver(String avatar) => MessageModel(
        ownerType: OwnerType.receiver,
        ownerName: '向导',
        avatar: avatar,
        content: '你好',
        createdAt: 1,
      );

  testWidgets('anime receiver empty avatar defaults to explorer',
      (tester) async {
    await pumpAvatar(
      tester,
      visualTheme: AppVisualTheme.anime,
      message: receiver(''),
    );

    expect(
      packageAssetImage(StarcoreIconAssets.assistantExplorer),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey(
          'starcore-message-avatar-${StarcoreIconAssets.assistantExplorerId}')),
      findsOneWidget,
    );
  });

  testWidgets('anime receiver creator protocol renders creator asset',
      (tester) async {
    await pumpAvatar(
      tester,
      visualTheme: AppVisualTheme.anime,
      message: receiver(
        '${StarcoreIconAssets.messageAssetPrefix}'
        '${StarcoreIconAssets.assistantCreatorId}',
      ),
    );

    expect(
      packageAssetImage(StarcoreIconAssets.assistantCreator),
      findsOneWidget,
    );
  });

  testWidgets('anime emoji receiver returns null for the legacy renderer',
      (tester) async {
    await pumpAvatar(
      tester,
      visualTheme: AppVisualTheme.anime,
      message: receiver('emoji:${Uri.encodeComponent('🎭')}'),
    );

    expect(find.byKey(const ValueKey('legacy-avatar')), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('anime unknown asset protocol returns null', (tester) async {
    await pumpAvatar(
      tester,
      visualTheme: AppVisualTheme.anime,
      message: receiver('${StarcoreIconAssets.messageAssetPrefix}unknown'),
    );

    expect(find.byKey(const ValueKey('legacy-avatar')), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('anime sender returns null for the legacy renderer',
      (tester) async {
    await pumpAvatar(
      tester,
      visualTheme: AppVisualTheme.anime,
      message: MessageModel(
        ownerType: OwnerType.sender,
        ownerName: '用户',
        avatar: '',
        content: '你好',
        createdAt: 2,
      ),
    );

    expect(find.byKey(const ValueKey('legacy-avatar')), findsOneWidget);
  });

  testWidgets('classic receiver returns null for the legacy renderer',
      (tester) async {
    await pumpAvatar(
      tester,
      visualTheme: AppVisualTheme.classic,
      message: receiver(
        '${StarcoreIconAssets.messageAssetPrefix}'
        '${StarcoreIconAssets.assistantExplorerId}',
      ),
    );

    expect(find.byKey(const ValueKey('legacy-avatar')), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
