import 'dart:convert';

import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/conversation_page.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/util/navigator_util.dart';

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

  ///跳转到对话详情待更新的model
  ConversationModel? pendingModel;

  get _dataCount => conversationList.length + stickConversationList.length;

  get _listView => ListView.builder(
      itemCount: _dataCount,
      itemBuilder: (BuildContext context, int index) =>
          _conversationWidget(index));

  @override
  void initState() {
    super.initState();
    _doInit();
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

  ///创建新的会话
  void _createConversation() {
    int cid = DateTime.now().millisecondsSinceEpoch;
    final avatar = AiCatalogDao.avatarUrl();
    _jumpToConversation(ConversationModel(
        cid: cid, icon: avatar));
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
    conversationListDao = ConversationListDao(storage);
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
    debugPrint('count:${list.length}');
    debugPrint(jsonEncode(list));
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
    pendingModel = model;
    NavigatorUtil.push(
            context,
            ConversationPage(
                conversationModel: model,
                conversationUpdate: (model) => _doUpdate(model.cid)))
        .then((value) => {
              //从对话详情页返回
              Future.delayed(
                  const Duration(milliseconds: 500), () => _doUpdate(model.cid))
            });
  }

  _doUpdate(int cid) async {
    //fix 新建会话，没有聊天消息也会保存的问题
    if (pendingModel == null || pendingModel?.title == null) {
      return;
    }
    var messageDao = MessageDao(conversationListDao.storage, cid: cid);
    var count = await messageDao.getMessageCount();
    //fix 置顶消息从对话框返回重复添加的问题
    if (pendingModel!.stickTime > 0) {
      if (!stickConversationList.contains(pendingModel)) {
        stickConversationList.add(pendingModel!);
      }
    } else {
      if (!conversationList.contains(pendingModel)) {
        conversationList.add(pendingModel!);
      }
    }
    //触发刷新
    setState(() {
      pendingModel?.messageCount = count;
    });
    conversationListDao.saveConversation(pendingModel!);
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
