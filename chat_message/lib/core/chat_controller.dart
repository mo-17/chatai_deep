import 'dart:async';

import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/default_message_widget.dart';
import 'package:flutter/widgets.dart';

class ChatController implements IChatController {
  ///初始化数据
  final List<MessageModel> initialMessageList;
  final ScrollController scrollController;

  ///Provide MessageWidgetBuilder to customize your bubble style.
  final MessageWidgetBuilder? messageWidgetBuilder;

  ///只定制气泡「内部内容」（保留头像/气泡外壳/时间/长按）。
  ///返回 null 时回退到默认的文本/图片渲染。用于块化消息渲染。
  final MessageContentBuilder? messageContentBuilder;

  ///展示时间的间隔，单位秒
  final int timePellet;
  List<int> pelletShow = [];

  ChatController({required this.initialMessageList,
    required this.scrollController,
    required this.timePellet,
    this.messageWidgetBuilder,
    this.messageContentBuilder}) {
    for (var message in initialMessageList.reversed) {
      inflateMessage(message);
    }
  }

  StreamController<List<MessageModel>> messageStreamController =
  StreamController();

  /// Used to dispose stream.
  void dispose() {
    messageStreamController.close();
    scrollController.dispose();
  }

  ///ChatList is init ok
  void widgetReady() {
    if (!messageStreamController.isClosed) {
      messageStreamController.sink.add(initialMessageList);
    }
    if (initialMessageList.isNotEmpty) scrollToLastMessage();
  }

  @override
  void addMessage(MessageModel message) {
    //fix Bad state: Cannot add event after closing
    if (messageStreamController.isClosed) return;
    inflateMessage(message);
    //List反转后列是从底部向上展示，所以新来的消息需要插入到数据第0个位置
    initialMessageList.insert(0, message);
    messageStreamController.sink.add(initialMessageList);
    scrollToLastMessage();
  }

  @override
  void updateMessage(MessageModel model) {
    if (messageStreamController.isClosed) return;
    final idx = initialMessageList.indexWhere((m) => m.createdAt == model.createdAt);
    if (idx != -1) {
      initialMessageList[idx] = model;
      messageStreamController.sink.add(initialMessageList);
    }
  }

  @override
  void deleteMessage(MessageModel message) {
    if (messageStreamController.isClosed) return;
    initialMessageList.remove(message);
    pelletShow.clear();
    //时间的标记是从最久的消息开始标
    for (var message in initialMessageList.reversed) {
      inflateMessage(message);
    }
    messageStreamController.sink.add(initialMessageList);
  }

  @override
  void loadMoreData(List<MessageModel> messageList) {
    //List反转后列是从底部向上展示，所以消息顺序也需要进行反转
    messageList = List.from(messageList.reversed);
    List<MessageModel> tempList = [...initialMessageList, ...messageList];
    //Clear record and redo
    pelletShow.clear();
    //时间的标记是从最久的消息开始标
    for (var message in tempList.reversed) {
      inflateMessage(message);
    }
    initialMessageList.clear();
    initialMessageList.addAll(tempList);
    if (messageStreamController.isClosed) return;
    messageStreamController.sink.add(initialMessageList);
  }

  void scrollToLastMessage() {
    //fix ScrollController not attached to any scroll views.
    if (!scrollController.hasClients) {
      return;
    }
    scrollController.animateTo(0,
        duration: const Duration(milliseconds: 200), curve: Curves.easeIn);
  }

  ///设置消息的时间是否可以展示
  void inflateMessage(MessageModel message) {
    int pellet = (message.createdAt / (timePellet * 1000)).truncate();
    if (!pelletShow.contains(pellet)) {
      pelletShow.add(pellet);
      message.showCreatedTime = true;
    } else {
      message.showCreatedTime = false;
    }
  }
}

abstract class IChatController {
  void addMessage(MessageModel message);

  void updateMessage(MessageModel message);

  void loadMoreData(List<MessageModel> messageList);

  void deleteMessage(MessageModel message);
}
