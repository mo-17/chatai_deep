import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:flutter/material.dart';

Widget? buildStarcoreMessageAvatar(
  BuildContext context,
  MessageModel message,
  double avatarSize,
) {
  if (!AppVisualTheme.of(context).isAnime ||
      message.ownerType != OwnerType.receiver) {
    return null;
  }
  final raw = message.avatar?.trim() ?? '';
  final id = raw.isEmpty
      ? StarcoreIconAssets.assistantExplorerId
      : StarcoreIconAssets.parseMessageAvatar(raw);
  final asset = StarcoreIconAssets.assistantAssetFor(id);
  if (asset == null) return null;
  return ClipOval(
    key: ValueKey('starcore-message-avatar-$id'),
    child: Image.asset(
      asset,
      package: StarcoreIconAssets.packageName,
      width: avatarSize,
      height: avatarSize,
      cacheWidth: (avatarSize * MediaQuery.devicePixelRatioOf(context)).round(),
      cacheHeight:
          (avatarSize * MediaQuery.devicePixelRatioOf(context)).round(),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => CircleAvatar(
        radius: avatarSize / 2,
        child: const Icon(Icons.smart_toy_rounded),
      ),
    ),
  );
}
