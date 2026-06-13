import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/conversation_page.dart';
import 'package:chatgpt_app_core/widget/assistant_picker.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/util/navigator_util.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

import '../db/hi_db_manager.dart';
import '../widget/conversation_widget.dart';

class ConversationListPage extends StatefulWidget {
  const ConversationListPage({Key? key}) : super(key: key);

  @override
  State<ConversationListPage> createState() => _ConversationListPageState();
}

class _ConversationListPageState extends State<ConversationListPage>
    with AutomaticKeepAliveClientMixin {
  List<ConversationModel> conversationList = [];
  List<ConversationModel> stickConversationList = [];
  late ConversationListDao conversationListDao;

  get _dataCount => conversationList.length + stickConversationList.length;

  get _listView => ListView.builder(
      itemCount: _dataCount,
      itemBuilder: (BuildContext context, int index) =>
          _conversationWidget(index));

  @override
  void initState() {
    super.initState();
    _doInit();
    // 备份导入后重新加载（页面 keepAlive 常驻，不会再走 initState）。
    BackupService.restoreTick.addListener(_onRestore);
  }

  @override
  void dispose() {
    BackupService.restoreTick.removeListener(_onRestore);
    super.dispose();
  }

  void _onRestore() {
    _loadStickData();
    _loadData();
  }

  @override
  void setState(VoidCallback fn) {
    if (!mounted) {
      //fix 热重启/热加载 build被连续执行两次，_doInit执行setState时页面已经销毁的问题
      return;
    }
    super.setState(fn);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('ChatGPT'),
        centerTitle: true,
      ),
      body: _listView,
      floatingActionButton: FloatingActionButton(
        onPressed: _createConversation,
        tooltip: '新建会话',
        child: const Icon(Icons.add),
      ),
    );
  }

  ///创建新的会话。先选助手（阶段七）：没有任何助手时选择器零打扰直接放行。
  void _createConversation() async {
    final pick = await showAssistantPicker(context);
    if (pick == null || !mounted) return; // 用户取消
    int cid = DateTime.now().millisecondsSinceEpoch;
    final avatar = AiCatalogDao.avatarUrl();
    _jumpToConversation(ConversationModel(
        cid: cid, icon: avatar, assistantId: pick.assistant?.id));
  }

  _conversationWidget(int pos) {
    ConversationModel model;
    if (pos < stickConversationList.length) {
      model = stickConversationList[pos];
    } else {
      model = conversationList[pos - stickConversationList.length];
    }
    return ConversationWidget(
      model: model,
      onPressed: _jumpToConversation,
      onDelete: _onDelete,
      onStick: _onStick,
    );
  }

  void _doInit() async {
    var storage =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    conversationListDao = await ConversationListDao.create(storage);
    _loadStickData();
    _loadData();
  }

  int pageIndex = 1;

  Future<List<ConversationModel>> _loadStickData() async {
    var list = await conversationListDao.getStickConversationList();
    setState(() {
      stickConversationList = list;
    });
    return list;
  }

  Future<List<ConversationModel>> _loadData({loadMore = false}) async {
    if (loadMore) {
      pageIndex++;
    } else {
      pageIndex = 1;
    }
    var list =
        await conversationListDao.getConversationList(pageIndex: pageIndex);
    AILogger.log('conversation list count:${list.length}');
    if (loadMore) {
      setState(() {
        conversationList.addAll(list);
      });
    } else {
      setState(() {
        conversationList = list;
      });
    }
    return list;
  }

  void _jumpToConversation(ConversationModel model) {
    NavigatorUtil.push(
            context,
            ConversationPage(
                conversationModel: model,
                conversationUpdate: (updated) => _doUpdate(updated)))
        .then((_) {
      // 从对话详情页返回后立即更新，DB 操作已通过 async factory 保证表就绪
      _doUpdate(model);
    });
  }

  _doUpdate(ConversationModel model) async {
    //fix 新建会话，没有聊天消息也会保存的问题
    if (model.title == null) {
      return;
    }
    var messageDao = await MessageDao.create(conversationListDao.storage, cid: model.cid);
    var count = await messageDao.getMessageCount();
    //fix 置顶消息从对话框返回重复添加的问题
    if (model.stickTime > 0) {
      if (!stickConversationList.contains(model)) {
        stickConversationList.add(model);
      }
    } else {
      if (!conversationList.contains(model)) {
        conversationList.add(model);
      }
    }
    //触发刷新
    setState(() {
      model.messageCount = count;
    });
    conversationListDao.saveConversation(model);
  }

  @override
  bool get wantKeepAlive => true;

  _onDelete(ConversationModel model) {
    conversationListDao.deleteConversation(model);
    conversationList.remove(model);
    //fix 置顶消息无法删除问题
    stickConversationList.remove(model);
    setState(() {});
  }

  _onStick(ConversationModel model, {required bool isStick}) async {
    var result =
        await conversationListDao.updateStickTime(model, isStick: isStick);
    //操作失败
    if (result <= 0) {
      return;
    }
    if (isStick) {
      //从之前的列表中移除
      conversationList.remove(model);
      if (!stickConversationList.contains(model)) {
        //加入到新的列表
        stickConversationList.insert(0, model);
      }
    } else {
      stickConversationList.remove(model);
      if (!conversationList.contains(model)) {
        conversationList.insert(0, model); //也可根据需要，根据条件model插入到其他位置
      }
    }
    //刷新
    setState(() {});
  }
}
