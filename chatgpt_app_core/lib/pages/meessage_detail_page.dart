import 'package:chat_message/util/wechat_date_format.dart';
import 'package:chatgpt_app_core/model/favorite_model.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/hi_selection_area.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:flutter/material.dart';

///展示精彩内容详情
class MessageDetailPage extends StatefulWidget {
  final FavoriteModel model;

  const MessageDetailPage({super.key, required this.model});

  @override
  State<MessageDetailPage> createState() => _MessageDetailPageState();
}

class _MessageDetailPageState extends State<MessageDetailPage> {
  Widget get _titleView {
    final isAnime = AppVisualTheme.of(context).isAnime;
    if (isAnime) return const Text('详情');
    return Column(
      children: [
        const Text(
          '详情',
          style: TextStyle(fontSize: 16),
        ),
        Text(
          '来自 ${widget.model.ownerName} ${WechatDateFormat.formatYMd(widget.model.createdAt!)}',
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  Widget get _listView {
    final isAnime = AppVisualTheme.of(context).isAnime;
    final scheme = Theme.of(context).colorScheme;
    final Widget body = isAnime
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '来自 ${widget.model.ownerName} ${WechatDateFormat.formatYMd(widget.model.createdAt!)}',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 10),
              const Divider(),
              const SizedBox(height: 12),
              _content,
            ],
          )
        : _content;
    return ListView(
      padding: const EdgeInsets.only(top: 20, bottom: 20, left: 15, right: 15),
      children: [
        AppVisualSurface(
          animeKey: const ValueKey('favorite_detail_surface'),
          child: body,
        ),
      ],
    );
  }

  Widget get _content => HiSelectionArea.wrap(Text(
        widget.model.content,
        style: const TextStyle(fontSize: 18),
      ));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _titleView,
      ),
      body: _listView,
    );
  }
}
