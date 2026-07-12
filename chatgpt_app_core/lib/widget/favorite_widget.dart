import 'package:chat_message/util/wechat_date_format.dart';
import 'package:chatgpt_app_core/model/favorite_model.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/util/padding_extension.dart';

typedef OnFavoriteClick = void Function(
    FavoriteModel model, BuildContext ancestor);

///收藏widget
class FavoriteWidget extends StatelessWidget {
  final FavoriteModel model;
  final OnFavoriteClick onLongPress;
  final OnFavoriteClick onTap;

  const FavoriteWidget({
    super.key,
    required this.model,
    required this.onLongPress,
    required this.onTap,
  });

  get _titleView => Text(
        model.content,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
      );

  Widget _bottomLayout(BuildContext context) {
    final visual = AppVisualTheme.of(context);
    final muted = visual.isAnime
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : Colors.grey;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            model.ownerName ?? "",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: muted, fontSize: 12),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          WechatDateFormat.format(model.createdAt!),
          maxLines: 1,
          style: TextStyle(color: muted, fontSize: 12),
        )
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final visual = AppVisualTheme.of(context);
    final content = Padding(
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [_titleView, 20.paddingHeight, _bottomLayout(context)],
      ),
    );
    if (!visual.isAnime) {
      return InkWell(
        onLongPress: () => onLongPress(model, context),
        onTap: () => onTap(model, context),
        child: Card(
          margin: const EdgeInsets.only(left: 10, right: 10, bottom: 5, top: 5),
          child: content,
        ),
      );
    }
    return Semantics(
      button: true,
      label: '收藏内容：${model.content}',
      excludeSemantics: true,
      onTap: () => onTap(model, context),
      onLongPress: () => onLongPress(model, context),
      child: Card(
        margin: const EdgeInsets.only(left: 10, right: 10, bottom: 5, top: 5),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(visual.cardRadius),
          onLongPress: () => onLongPress(model, context),
          onTap: () => onTap(model, context),
          child: content,
        ),
      ),
    );
  }
}
