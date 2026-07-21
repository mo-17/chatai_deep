import 'package:chat_message/widget/default_message_widget.dart';
import 'package:chat_message/widget/message_avatar_builder.dart';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../core/chat_controller.dart';
import '../models/message_model.dart';

class ChatList extends StatefulWidget {
  ///ChatList的控制器
  final ChatController chatController;
  // ScrollablePositionedList 的 padding 要求 EdgeInsets（非 Geometry）。
  final EdgeInsets? padding;
  final OnBubbleClick? onBubbleTap;
  final OnBubbleClick? onBubbleLongPress;
  final MessageAvatarBuilder? avatarBuilder;
  final Color? receiverBackgroundColor;
  final Color? senderBackgroundColor;
  final Color? receiverAvatarBackgroundColor;
  final Color? senderAvatarBackgroundColor;
  final Color? textColor;
  final Radius? bubbleRadius;

  const ChatList({
    super.key,
    required this.chatController,
    this.padding,
    this.onBubbleTap,
    this.onBubbleLongPress,
    this.avatarBuilder,
    this.receiverBackgroundColor,
    this.senderBackgroundColor,
    this.receiverAvatarBackgroundColor,
    this.senderAvatarBackgroundColor,
    this.textColor,
    this.bubbleRadius,
  });

  @override
  State<ChatList> createState() => _ChatListState();
}

class _ChatListState extends State<ChatList> {
  ChatController get chatController => widget.chatController;

  MessageWidgetBuilder? get messageWidgetBuilder =>
      chatController.messageWidgetBuilder;

  MessageContentBuilder? get messageContentBuilder =>
      chatController.messageContentBuilder;

  ItemScrollController get itemScrollController =>
      chatController.itemScrollController;

  ItemPositionsListener get itemPositionsListener =>
      chatController.itemPositionsListener;

  Widget get _chatStreamBuilder => StreamBuilder<List<MessageModel>>(
      stream: chatController.messageStreamController.stream,
      builder:
          (BuildContext context, AsyncSnapshot<List<MessageModel>> snapshot) {
        return snapshot.connectionState == ConnectionState.active
            ? ScrollablePositionedList.builder(
                shrinkWrap: true,
                reverse: true,
                padding: widget.padding,
                itemScrollController: itemScrollController,
                itemPositionsListener: itemPositionsListener,
                itemCount: snapshot.data?.length ?? 0,
                itemBuilder: (BuildContext context, int index) {
                  // ScrollablePositionedList 以内部 positionedIndex 为锚把列表拆成
                  // 三段 sliver；动画 scrollTo 期间（尤其列表刚从 0→1 条、reverse
                  // 下）锚点可能瞬时为 -1，使 itemBuilder 收到越界 index。
                  // 不防护会 data![-1] 抛 RangeError 红屏，故越界时渲染空盒。
                  final data = snapshot.data;
                  if (data == null || index < 0 || index >= data.length) {
                    return const SizedBox.shrink();
                  }
                  final model = data[index];
                  return DefaultMessageWidget(
                    key: model.key,
                    message: model,
                    messageWidget: messageWidgetBuilder,
                    contentBuilder: messageContentBuilder,
                    avatarBuilder: widget.avatarBuilder,
                    onBubbleTap: widget.onBubbleTap,
                    onBubbleLongPress: widget.onBubbleLongPress,
                    receiverBackgroundColor: widget.receiverBackgroundColor,
                    senderBackgroundColor: widget.senderBackgroundColor,
                    receiverAvatarBackgroundColor:
                        widget.receiverAvatarBackgroundColor,
                    senderAvatarBackgroundColor:
                        widget.senderAvatarBackgroundColor,
                    textColor: widget.textColor,
                    bubbleRadius: widget.bubbleRadius,
                  );
                })
            : const Center(
                child: CircularProgressIndicator(),
              );
      });

  @override
  Widget build(BuildContext context) {
    //配合shrinkWrap: true使用，解决数据少的时候数据底部对齐的问题
    return Align(
      alignment: Alignment.topCenter,
      child: _chatStreamBuilder,
    );
  }

  @override
  void initState() {
    super.initState();
    chatController.widgetReady();
  }

  @override
  void dispose() {
    chatController.dispose();
    super.dispose();
  }
}
