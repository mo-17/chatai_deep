import 'package:login_sdk/platform/app_file_image.dart';
import 'package:login_sdk/platform/app_io.dart';

import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:flutter/material.dart';

class AssistantAvatar extends StatelessWidget {
  static final Map<String, Future<String?>> _managedPathFutures = {};

  final AssistantModel? assistant;
  final String emoji;
  final String? avatarType;
  final String? avatarValue;
  final double radius;

  const AssistantAvatar({
    super.key,
    required this.assistant,
    this.radius = 20,
  })  : emoji = '',
        avatarType = null,
        avatarValue = null;

  const AssistantAvatar.raw({
    super.key,
    required this.emoji,
    this.avatarType,
    this.avatarValue,
    this.radius = 20,
  }) : assistant = null;

  @override
  Widget build(BuildContext context) {
    final type = avatarType ?? assistant?.avatarType;
    final value = (avatarValue ?? assistant?.avatarValue)?.trim() ?? '';
    if (type == AvatarAssetService.imageType && value.isNotEmpty) {
      if (AvatarAssetService.isManagedPath(value)) {
        return FutureBuilder<String?>(
          future: _managedPathFutures.putIfAbsent(
            value,
            () => AvatarAssetService.resolveManagedPath(value),
          ),
          builder: (context, snapshot) {
            final resolved = snapshot.data?.trim() ?? '';
            return resolved.isEmpty
                ? _emojiAvatar(context)
                : _imageAvatar(context, appFile(resolved));
          },
        );
      }
      return _imageAvatar(context, appFile(value));
    }
    final visual = AppVisualTheme.of(context);
    if (visual.isAnime && type == AvatarAssetService.assetType) {
      final asset = StarcoreIconAssets.assistantAssetFor(value);
      if (asset != null) return _assetAvatar(context, asset);
    }
    return _emojiAvatar(context);
  }

  Widget _imageAvatar(BuildContext context, File file) {
    final decodeSize =
        (radius * 2 * MediaQuery.devicePixelRatioOf(context)).round();
    return _animeFrame(
      context,
      ClipOval(
        child: SizedBox.square(
          dimension: radius * 2,
          child: appFileImage(
            file,
            fit: BoxFit.cover,
            cacheWidth: decodeSize,
            cacheHeight: decodeSize,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _emojiCircle(context),
          ),
        ),
      ),
    );
  }

  Widget _assetAvatar(BuildContext context, String asset) {
    final decodeSize =
        (radius * 2 * MediaQuery.devicePixelRatioOf(context)).round();
    return _animeFrame(
      context,
      ClipOval(
        child: SizedBox.square(
          dimension: radius * 2,
          child: Image.asset(
            asset,
            package: StarcoreIconAssets.packageName,
            fit: BoxFit.cover,
            cacheWidth: decodeSize,
            cacheHeight: decodeSize,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _assetFallback(context),
          ),
        ),
      ),
    );
  }

  Widget _assetFallback(BuildContext context) {
    final visual = AppVisualTheme.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final fallback =
        (emoji.isNotEmpty ? emoji : (assistant?.emoji ?? '')).trim();
    return CircleAvatar(
      radius: radius,
      backgroundColor: visual.isAnime ? colorScheme.secondaryContainer : null,
      child: fallback.isNotEmpty
          ? Text(
              fallback,
              style: TextStyle(
                fontSize: radius,
                color: visual.isAnime ? colorScheme.onSecondaryContainer : null,
              ),
            )
          : Icon(
              Icons.smart_toy,
              size: radius,
              color: visual.isAnime ? colorScheme.onSecondaryContainer : null,
            ),
    );
  }

  Widget _emojiAvatar(BuildContext context) =>
      _animeFrame(context, _emojiCircle(context));

  Widget _emojiCircle(BuildContext context) {
    final visual = AppVisualTheme.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final fallback = emoji.isNotEmpty ? emoji : (assistant?.emoji ?? '🤖');
    return CircleAvatar(
      radius: radius,
      backgroundColor: visual.isAnime ? colorScheme.secondaryContainer : null,
      child: Text(
        fallback.trim().isEmpty ? '🤖' : fallback.trim(),
        style: TextStyle(
          fontSize: radius,
          color: visual.isAnime ? colorScheme.onSecondaryContainer : null,
        ),
      ),
    );
  }

  Widget _animeFrame(BuildContext context, Widget avatar) {
    final visual = AppVisualTheme.of(context);
    if (!visual.isAnime) return avatar;
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: const ValueKey('anime_assistant_avatar'),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [colorScheme.primary, colorScheme.secondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: visual.glowPrimary,
            blurRadius: 12,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: avatar,
      ),
    );
  }
}
