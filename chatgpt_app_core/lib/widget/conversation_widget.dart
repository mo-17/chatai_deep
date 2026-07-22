import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:chat_message/util/wechat_date_format.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/util/padding_extension.dart';

///定义一个带有ConversationModel参数的回调

typedef ConversationCallBack = Function(ConversationModel model);
typedef ConversationStickCallBack = Function(ConversationModel model,
    {required bool isStick});

class ConversationWidget extends StatelessWidget {
  final ConversationModel model;
  final ConversationCallBack? onPressed;
  final ConversationCallBack? onDelete;
  final ConversationCallBack? onMoveProject;
  final ConversationCallBack? onAvatar;
  final ConversationStickCallBack? onStick;

  const ConversationWidget(
      {super.key,
      required this.model,
      this.onPressed,
      this.onDelete,
      this.onMoveProject,
      this.onAvatar,
      this.onStick});

  get _item => Container(
        padding: const EdgeInsets.only(left: 10, right: 10),
        color: _itemBackgroundColor,
        height: 76,
        child: Row(
          children: [_icon, 10.paddingWidth, _rightLayout],
        ),
      );

  get _itemBackgroundColor =>
      model.stickTime > 0 ? Colors.grey.withValues(alpha: 0.2) : Colors.white;

  bool get _hasValidIcon =>
      model.icon.isNotEmpty && Uri.tryParse(model.icon)?.hasScheme == true;

  /// 仅当 icon URL 与后端同源时才注入 Authorization，避免泄漏 Bearer Token 到第三方 CDN
  bool get _isSameOrigin {
    final uri = Uri.tryParse(model.icon);
    if (uri == null) return false;
    return uri.host == BackendConfig.host.split(':').first;
  }

  Widget get _aiFallback => ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Container(
          height: 50,
          width: 50,
          color: const Color(0xFF2E7D32),
          alignment: Alignment.center,
          child: const Text('AI',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
        ),
      );

  Widget _emojiAvatar(String emoji) => ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Container(
          height: 50,
          width: 50,
          color: const Color(0xFFE8F5E9),
          alignment: Alignment.center,
          child: Text(emoji, style: const TextStyle(fontSize: 28)),
        ),
      );

  Widget _localImageAvatar(String path) {
    final file = File(path);
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: Image.file(
        file,
        height: 50,
        width: 50,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _aiFallback,
      ),
    );
  }

  int _animeAvatarCacheSize(BuildContext context) {
    final physicalPixels =
        (50 * MediaQuery.devicePixelRatioOf(context)).round();
    return physicalPixels < 1 ? 1 : physicalPixels;
  }

  Widget _animeFallback(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final cacheSize = _animeAvatarCacheSize(context);
    return Container(
      height: 50,
      width: 50,
      color: colorScheme.primaryContainer,
      alignment: Alignment.center,
      child: Image.asset(
        StarcoreIconAssets.assistantExplorer,
        package: StarcoreIconAssets.packageName,
        height: 50,
        width: 50,
        cacheWidth: cacheSize,
        cacheHeight: cacheSize,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Icon(
          Icons.smart_toy_rounded,
          size: 28,
          color: colorScheme.primary,
        ),
      ),
    );
  }

  Widget _animeIcon(BuildContext context) {
    final avatarType = model.avatarType;
    final avatarValue = model.avatarValue?.trim() ?? '';
    if (avatarType == 'emoji' && avatarValue.isNotEmpty) {
      return _emojiAvatar(avatarValue);
    }
    if (avatarType == 'image' && avatarValue.isNotEmpty) {
      final file = File(avatarValue);
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Image.file(
          file,
          height: 50,
          width: 50,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _animeFallback(context),
        ),
      );
    }
    if (avatarType == AvatarAssetService.assetType) {
      final asset = StarcoreIconAssets.assistantAssetFor(avatarValue);
      if (asset != null) {
        final cacheSize = _animeAvatarCacheSize(context);
        return ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.asset(
            asset,
            package: StarcoreIconAssets.packageName,
            height: 50,
            width: 50,
            cacheWidth: cacheSize,
            cacheHeight: cacheSize,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _animeFallback(context),
          ),
        );
      }
    }
    if (!_hasValidIcon) return _animeFallback(context);
    return CachedNetworkImage(
      imageUrl: model.icon,
      height: 50,
      width: 50,
      fit: BoxFit.cover,
      httpHeaders: _isSameOrigin && LoginDao.getBoardingPass() != null
          ? {'Authorization': 'Bearer ${LoginDao.getBoardingPass()}'}
          : null,
      errorWidget: (_, __, ___) => _animeFallback(context),
      placeholder: (_, __) => _animeFallback(context),
    );
  }

  get _icon {
    final avatarType = model.avatarType;
    final avatarValue = model.avatarValue?.trim() ?? '';
    if (avatarType == 'emoji' && avatarValue.isNotEmpty) {
      return _emojiAvatar(avatarValue);
    }
    if (avatarType == 'image' && avatarValue.isNotEmpty) {
      return _localImageAvatar(avatarValue);
    }
    return _hasValidIcon
        ? ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: CachedNetworkImage(
              imageUrl: model.icon,
              height: 50,
              width: 50,
              httpHeaders: _isSameOrigin && LoginDao.getBoardingPass() != null
                  ? {'Authorization': 'Bearer ${LoginDao.getBoardingPass()}'}
                  : null,
              errorWidget: (_, __, ___) => _aiFallback,
              placeholder: (_, __) => _aiFallback,
            ),
          )
        : _aiFallback;
  }

  get _rightLayout => Expanded(
          child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              5.paddingHeight,
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                      child: Text(
                    model.title ?? "",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18),
                  )),
                  Text(
                    WechatDateFormat.format(model.updateAt ?? 0),
                    style: const TextStyle(fontSize: 13, color: Colors.grey),
                  )
                ],
              ),
              Text(
                '[${model.messageCount ?? 0}条对话] ${_previewText(model.lastMessage)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              )
            ],
          ),
          Divider(
            height: 1,
            color: Colors.grey.withValues(alpha: 0.6),
          )
        ],
      ));

  @override
  Widget build(BuildContext context) {
    if (AppVisualTheme.of(context).isAnime) {
      return _buildAnimeItem(context);
    }
    return GestureDetector(
      key: ValueKey('classic_conversation_item_${model.cid}'),
      onTap: () {
        if (onPressed != null) onPressed!(model);
      },
      onLongPress: () => _showPopMenu(context),
      child: _item,
    );
  }

  Widget _buildAnimeItem(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final pinned = model.stickTime > 0;
    return Padding(
      key: ValueKey('anime_conversation_item_${model.cid}'),
      padding: const EdgeInsets.fromLTRB(12, 5, 12, 5),
      child: Material(
        color: pinned
            ? colorScheme.primaryContainer.withValues(alpha: 0.72)
            : colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            if (onPressed != null) onPressed!(model);
          },
          onLongPress: () => _showPopMenu(context),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 84),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          colorScheme.primary,
                          colorScheme.secondary,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(17),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: _animeIcon(context),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                model.title ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              WechatDateFormat.format(model.updateAt ?? 0),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            if (pinned) ...[
                              Icon(Icons.push_pin_rounded,
                                  size: 14, color: colorScheme.primary),
                              const SizedBox(width: 4),
                            ],
                            Expanded(
                              child: Text(
                                '[${model.messageCount ?? 0}条对话] ${_previewText(model.lastMessage)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  ///在item下方弹框，难点如何找到要弹框的坐标位置
  _showPopMenu(BuildContext context) {
    final isStick = model.stickTime > 0 ? true : false;
    final showStick = isStick ? "取消置顶" : "置顶";
    HiDialog.showPopMenu(context, offsetX: -50, items: [
      PopupMenuItem(
        child: Text(showStick),
        onTap: () {
          if (onStick != null) onStick!(model, isStick: !isStick);
        },
      ),
      PopupMenuItem(
        child: const Text('移动到项目'),
        onTap: () {
          if (onMoveProject != null) onMoveProject!(model);
        },
      ),
      PopupMenuItem(
        child: const Text('设置头像'),
        onTap: () {
          if (onAvatar != null) onAvatar!(model);
        },
      ),
      PopupMenuItem(
        child: const Text('删除'),
        onTap: () {
          if (onDelete != null) onDelete!(model);
        },
      )
    ]);
  }

  String _previewText(String? value) {
    final text = value?.trim() ?? '';
    return text.toLowerCase() == 'null' ? '' : text;
  }
}
