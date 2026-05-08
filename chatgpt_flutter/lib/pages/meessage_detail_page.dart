import 'package:chat_message/util/wechat_date_format.dart';
import 'package:chatgpt_flutter/model/favorite_model.dart';
import 'package:chatgpt_flutter/util/hi_selection_area.dart';
import 'package:chatgpt_flutter/util/hi_utils.dart';
import 'package:flutter/material.dart';

///展示精彩内容详情
class MessageDetailPage extends StatefulWidget {
  final FavoriteModel model;

  const MessageDetailPage({Key? key, required this.model}) : super(key: key);

  @override
  State<MessageDetailPage> createState() => _MessageDetailPageState();
}

class _MessageDetailPageState extends State<MessageDetailPage> {
  TapDownDetails? details;

  get _titleView => Column(
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

  get _listView => ListView(
        padding:
            const EdgeInsets.only(top: 20, bottom: 20, left: 15, right: 15),
        children: [_content],
      );

  get _content => HiSelectionArea.wrap(Text(
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

  ///让弹框的位置跟随手势
  void _onLongPress() {
    //根据点击的位置计算出弹框的位置
    var offsetY = details?.localPosition.dy ?? 0;
    var offsetX = details?.localPosition.dx ?? 0;
    final RelativeRect position =
        RelativeRect.fromLTRB(offsetX, offsetY + 120, offsetX, 0);
    showMenu(context: context, position: position, items: [
      PopupMenuItem(
          onTap: () => HiUtils.copyMessage(widget.model.content, context),
          child: const Text('复制'))
    ]);
  }

  void _onTapDown(TapDownDetails details) {
    this.details = details;
  }
}
