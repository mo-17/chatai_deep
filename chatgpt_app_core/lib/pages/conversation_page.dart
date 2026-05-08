import 'dart:async';
import 'dart:convert';

import 'package:chat_message/core/chat_controller.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/chat_list.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/favorite_model.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/util/hi_utils.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:provider/provider.dart';

typedef OnConversationUpdate = void Function(
    ConversationModel conversationModel);

///聊天对话框页面
class ConversationPage extends StatefulWidget {
  final ConversationModel conversationModel;
  final OnConversationUpdate? conversationUpdate;

  const ConversationPage(
      {Key? key, required this.conversationModel, this.conversationUpdate})
      : super(key: key);

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  ///若为新建的对话框，则_pendingUpdate为true
  bool get _pendingUpdate => widget.conversationModel.title == null;

  ///是否有通知聊天列表页更新当前会话
  bool _hadUpdate = false;
  late Map<String, dynamic> userInfo;
  String _inputMessage = "";
  bool _sendBtnEnable = true;
  late MessageDao messageDao;
  late FavoriteDao favoriteDao;
  late ChatController chatController;
  late CompletionDao completionDao;
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<String>? _activeStreamSub;

  get _chatList => Expanded(
          child: Padding(
        padding: const EdgeInsets.only(left: 10, right: 10),
        child: ChatList(
          chatController: chatController,
          onBubbleLongPress: _onBubbleLongPress,
        ),
      ));

  get _appBar => AppBar(
        title: Text(_title),
      );

  late String _aiName;

  String get _title => _sendBtnEnable ? '与$_aiName的会话' : '对方正在输入...';

  _inputWidget() {
    return MessageInputWidget(
      '请输入',
      enable: _sendBtnEnable,
      onChanged: (text) => _inputMessage = text,
      onSend: () => _onSend(_inputMessage),
    );
  }

  @override
  void initState() {
    super.initState();
    _doInit();
  }

  @override
  void dispose() {
    _activeStreamSub?.cancel();
    _updateConversation();
    super.dispose();
    //fix A ScrollController was used after being disposed.
    // chatController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _appBar,
      body: Column(
        children: [_chatList, _inputWidget()],
      ),
    );
  }

  ///不用_inputMessage是因为在结果回来之前_inputMessage可能会变
  void _onSend(final String inputMessage) async {
    widget.conversationModel.hadChanged = true;
    _addMessage(
        _genMessageModel(ownerType: OwnerType.sender, message: inputMessage));
    setState(() {
      _sendBtnEnable = false;
    });

    // 确保使用最新设置（含 API key、provider、mode），避免 CompletionDao 持有旧 ChatService
    final settings = context.read<AISettingsProvider>().settings;
    completionDao = CompletionDao(settings: settings, messages: completionDao.currentMessages);
    if (settings.streamEnabled) {
      await _onSendStream(inputMessage);
    } else {
      await _onSendNonStream(inputMessage);
    }
  }

  Future<void> _onSendNonStream(String inputMessage) async {
    String? response = "";
    try {
      response = await completionDao.createCompletions(prompt: inputMessage);
      debugPrint(response);
    } catch (e) {
      response = e.toString();
      debugPrint(e.toString());
    }
    response ??= 'no response';
    _addMessage(
        _genMessageModel(ownerType: OwnerType.receiver, message: response));
    setState(() {
      _sendBtnEnable = true;
    });
  }

  Future<void> _onSendStream(String inputMessage) async {
    // 创建空内容的 AI 气泡，只加入 UI，不存 DB
    final receiverModel =
        _genMessageModel(ownerType: OwnerType.receiver, message: '');
    chatController.addMessage(receiverModel);

    final buffer = StringBuffer();
    MessageModel? finalModel;
    try {
      final stream = completionDao.streamCompletions(prompt: inputMessage);
      _activeStreamSub = stream.listen(
        (chunk) {
          buffer.write(chunk);
          if (!mounted) return;
          finalModel = receiverModel.copyWith(content: buffer.toString());
          chatController.updateMessage(finalModel!);
        },
        onError: (e) {
          debugPrint('stream error: $e');
        },
        cancelOnError: false,
      );
      await _activeStreamSub!.asFuture<void>();
      // 流正常结束
      final content = buffer.toString();
      final effective = content.isNotEmpty ? content : 'no response';
      finalModel = receiverModel.copyWith(content: effective);
      messageDao.saveMessage(finalModel!);
      _notifyConversationListUpdate();
    } catch (e) {
      debugPrint('stream exception: $e');
      // 错误兜底：保存已接收的内容
      final content = buffer.toString();
      if (content.isNotEmpty) {
        finalModel = receiverModel.copyWith(
            content: '$content\n\n[错误: $e]');
      } else {
        finalModel = receiverModel.copyWith(content: '请求失败: $e');
      }
      messageDao.saveMessage(finalModel!);
      _notifyConversationListUpdate();
    } finally {
      _activeStreamSub = null;
      if (mounted) {
        setState(() {
          _sendBtnEnable = true;
        });
      }
    }
  }

  ///通知聊天列表页更新当前会话
  _notifyConversationListUpdate() {
    if (!_hadUpdate && _pendingUpdate && widget.conversationUpdate != null) {
      _hadUpdate = true;
      _updateConversation();
      widget.conversationUpdate!(widget.conversationModel);
    }
  }

  @override
  void setState(VoidCallback fn) {
    //页面关闭后不再处理消息更新
    if (!mounted) {
      return;
    }
    super.setState(fn);
  }

  MessageModel _genMessageModel(
      {required OwnerType ownerType, required String message}) {
    String avatar, ownerName;
    if (ownerType == OwnerType.sender) {
      avatar = (userInfo['avatar'] as String?)?.isNotEmpty == true
          ? userInfo['avatar']
          : '';
      ownerName = userInfo['userName'];
    } else {
      avatar = '';
      ownerName = _aiName;
    }
    return MessageModel(
        ownerType: ownerType,
        content: message,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        avatar: avatar,
        ownerName: ownerName);
  }

  void _doInit() async {
    userInfo = LoginDao.getUserInfo()!;
    chatController = ChatController(
        initialMessageList: [],
        scrollController: _scrollController,
        timePellet: 60);
    //下拉触发加载更多
    _scrollController.addListener(() {
      if (_scrollController.position.pixels ==
          _scrollController.position.maxScrollExtent) {
        _loadData(loadMore: true);
      }
    });
    final settings = context.read<AISettingsProvider>().settings;
    _aiName = settings.aiDisplayName;
    var dbManager =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    messageDao = MessageDao(dbManager, cid: widget.conversationModel.cid);
    favoriteDao = FavoriteDao(dbManager);
    var list = await _loadData();
    chatController.loadMoreData(list);
    completionDao = CompletionDao(settings: settings, messages: list);
  }

  void _addMessage(MessageModel model) {
    chatController.addMessage(model);
    messageDao.saveMessage(model);
    _notifyConversationListUpdate();
  }

  int pageIndex = 1;

  ///从数据库加载历史聊天记录
  Future<List<MessageModel>> _loadData({loadMore = false}) async {
    if (loadMore) {
      pageIndex++;
    } else {
      pageIndex = 1;
    }
    var list = await messageDao.getMessages(pageIndex: pageIndex);
    AILogger.log('count:${list.length}');
    AILogger.log(jsonEncode(list));
    if (loadMore) {
      if (list.isNotEmpty) {
        chatController.loadMoreData(list);
      } else {
        //如果没有更多的数据，则pageIndex不增加
        pageIndex--;
      }
    }
    return list;
  }

  void _updateConversation() {
    //更新会话信息
    if (chatController.initialMessageList.isNotEmpty) {
      var model = chatController.initialMessageList.first;
      widget.conversationModel.lastMessage = model.content;
      widget.conversationModel.updateAt = model.createdAt;
      widget.conversationModel.title ??=
          chatController.initialMessageList.last.content;
    }
  }

  void _onBubbleLongPress(MessageModel message, BuildContext ancestor) {
    bool left = message.ownerType == OwnerType.receiver ? true : false;
    double offsetX = left ? -100 : 50;
    HiDialog.showPopMenu(ancestor, offsetX: offsetX, items: [
      PopupMenuItem(
        child: const Text('设为精彩'),
        onTap: () {
          _addFavorite(message);
        },
      ),
      PopupMenuItem(
        child: const Text('复制'),
        onTap: () {
          _copyMessage(message);
        },
      ),
      PopupMenuItem(
        child: const Text('删除'),
        onTap: () => _deleteMessage(message),
      ),
      PopupMenuItem(
        child: const Text('转发'),
        onTap: () {
          //todo
        },
      )
    ]);
  }

  void _addFavorite(MessageModel message) async {
    var result = await favoriteDao.addFavorite(FavoriteModel(
        ownerName: message.ownerName,
        createdAt: message.createdAt,
        content: message.content));
    var showText = '';
    if (result != null && result > 0) {
      showText = '收藏成功';
    } else {
      showText = '收藏失败';
    }
    if (!mounted) return;
    HiDialog.showSnackBar(context, showText);
  }

  void _copyMessage(MessageModel message) async {
    HiUtils.copyMessage(message.content, context);
  }

  _deleteMessage(MessageModel message) async {
    try {
      var result = await messageDao.deleteMessage(message.id!);
      if (result > 0) {
        chatController.deleteMessage(message);
        _notifyConversationListUpdate();
        debugPrint('删除成功');
      }
    } catch (e) {
      debugPrint(e.toString());
    }
  }
}
