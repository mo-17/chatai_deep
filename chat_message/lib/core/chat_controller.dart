import 'dart:async';

import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/default_message_widget.dart';
import 'package:flutter/widgets.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

// 让 chat_message 的使用方无需直接依赖 scrollable_positioned_list 即可拿到这些类型。
export 'package:scrollable_positioned_list/scrollable_positioned_list.dart'
    show ItemScrollController, ItemPositionsListener, ItemPosition;

class ChatController implements IChatController {
  ///初始化数据
  final List<MessageModel> initialMessageList;

  ///按 index 跳转的控制器（支持「对话目录」精确跳到某条消息）。
  final ItemScrollController itemScrollController;

  ///列表项可见性监听（分页加载更多、置顶/置底按钮可见性都基于它）。
  final ItemPositionsListener itemPositionsListener;

  ///Provide MessageWidgetBuilder to customize your bubble style.
  final MessageWidgetBuilder? messageWidgetBuilder;

  ///只定制气泡「内部内容」（保留头像/气泡外壳/时间/长按）。
  ///返回 null 时回退到默认的文本/图片渲染。用于块化消息渲染。
  final MessageContentBuilder? messageContentBuilder;

  ///展示时间的间隔，单位秒
  final int timePellet;
  List<int> pelletShow = [];

  ChatController(
      {required this.initialMessageList,
      required this.itemScrollController,
      required this.itemPositionsListener,
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
  /// 注：ItemScrollController / ItemPositionsListener 无需手动 dispose。
  void dispose() {
    messageStreamController.close();
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
    final idx =
        initialMessageList.indexWhere((m) => m.createdAt == model.createdAt);
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

  bool _scrollScheduled = false;

  void scrollToLastMessage() {
    // 用户消息和 AI 占位常在同一帧插入，只安排一次滚动。
    if (_scrollScheduled || messageStreamController.isClosed) return;
    _scrollScheduled = true;
    // 延后到下一帧再滚：addMessage 里 sink.add 触发的列表重建是异步的，
    // 若此刻同步 scrollTo，SPL 仍按旧 itemCount（新建会话时为 0）定位，
    // 锚点 positionedIndex 落到 -1，列表滚到空白、首条消息不渲染
    // （要靠目录跳转 / 退出重进才恢复）。等新数据完成布局后再滚，
    // index 0（最新，reverse:true 下在最底部）才是有效锚点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      //fix controller not attached to any scroll views.
      if (messageStreamController.isClosed ||
          !itemScrollController.isAttached ||
          initialMessageList.isEmpty) {
        return;
      }
      // 首次布局的位置通知也在帧尾发布，可能晚于当前回调。
      // 此时直接定位，避免 SPL 启动双列表过渡并重复挂载气泡的 GlobalKey。
      if (itemPositionsListener.itemPositions.value.isEmpty) {
        itemScrollController.jumpTo(index: 0);
        return;
      }
      itemScrollController.scrollTo(
          index: 0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeIn);
    });
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
