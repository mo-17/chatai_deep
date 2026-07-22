import 'dart:io';

import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/widget/starcore_svg_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runtime package assets exactly match the eight approved masters', () {
    const approvedAssetPaths = <String>[
      StarcoreIconAssets.navChatDefault,
      StarcoreIconAssets.navChatSelected,
      StarcoreIconAssets.navCreateDefault,
      StarcoreIconAssets.navCreateSelected,
      StarcoreIconAssets.toolWebSearch,
      StarcoreIconAssets.toolKnowledgeSearch,
      StarcoreIconAssets.assistantExplorer,
      StarcoreIconAssets.assistantCreator,
    ];

    for (final runtimePath in approvedAssetPaths) {
      final fileName = runtimePath.split('/').last;
      final runtimeFile = File(runtimePath);
      final approvedMaster = File(
        '../docs/design-assets/starcore-guide/$fileName',
      );
      expect(
        runtimeFile.existsSync(),
        isTrue,
        reason: 'Missing runtime package asset: ${runtimeFile.path}',
      );
      expect(
        approvedMaster.existsSync(),
        isTrue,
        reason: 'Missing approved Starcore master: ${approvedMaster.path}',
      );
      expect(
        runtimeFile.readAsBytesSync(),
        orderedEquals(approvedMaster.readAsBytesSync()),
        reason: '$fileName differs from its approved Starcore master',
      );
    }
  });

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
    expect(StarcoreIconAssets.parseMessageAvatar('asset:unknown'), isNull);
  });

  test('Starcore message avatars encode only approved assistant ids', () {
    expect(
      StarcoreIconAssets.messageAvatarFor(
        StarcoreIconAssets.assistantExplorerId,
      ),
      'asset:starcore_explorer',
    );
    expect(
      StarcoreIconAssets.messageAvatarFor(
        StarcoreIconAssets.assistantCreatorId,
      ),
      'asset:starcore_creator',
    );
    expect(StarcoreIconAssets.messageAvatarFor('unknown'), isNull);
    expect(StarcoreIconAssets.messageAvatarFor(''), isNull);
    expect(StarcoreIconAssets.messageAvatarFor('   '), isNull);
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
