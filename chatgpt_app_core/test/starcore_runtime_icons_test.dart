import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/widget/starcore_svg_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Starcore assistant ids map only to approved package assets', () {
    expect(
      StarcoreIconAssets.assistantAssetFor(
        StarcoreIconAssets.assistantExplorerId,
      ),
      StarcoreIconAssets.assistantExplorer,
    );
    expect(
      StarcoreIconAssets.assistantAssetFor(
        StarcoreIconAssets.assistantCreatorId,
      ),
      StarcoreIconAssets.assistantCreator,
    );
    expect(StarcoreIconAssets.assistantAssetFor('unknown'), isNull);
    expect(
      StarcoreIconAssets.parseMessageAvatar('asset:starcore_explorer'),
      StarcoreIconAssets.assistantExplorerId,
    );
  });

  testWidgets('approved SVG resolves from the shared-core package',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StarcoreSvgIcon(
            assetName: StarcoreIconAssets.navChatDefault,
            fallback: Icon(Icons.chat_bubble_outline),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('starcore-svg-nav-chat-default')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing SVG renders the supplied Material fallback',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: StarcoreSvgIcon(
          assetName: 'assets/icons/starcore/missing.svg',
          fallback: Icon(Icons.extension_off, key: ValueKey('svg-fallback')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('svg-fallback')), findsOneWidget);
  });
}
