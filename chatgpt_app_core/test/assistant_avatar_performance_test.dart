import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('助手图片头像限制解码尺寸且读取失败回落 emoji', (tester) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeFactory.anime(),
        home: const Scaffold(
          body: AssistantAvatar.raw(
            emoji: '🙂',
            avatarType: AvatarAssetService.imageType,
            avatarValue: '/tmp/avatar-that-does-not-exist.png',
            radius: 20,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image));
    final resized = image.image as ResizeImage;
    expect(resized.width, 80);
    expect(resized.height, 80);
    expect(image.errorBuilder, isNotNull);
    final fallback = image.errorBuilder!(
      tester.element(find.byType(Image)),
      StateError('模拟头像解码失败'),
      StackTrace.empty,
    ) as CircleAvatar;
    expect((fallback.child! as Text).data, '🙂');
    expect(tester.takeException(), isNull);
  });
}
