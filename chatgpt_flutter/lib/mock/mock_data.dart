import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_flutter/db/conversation_dao.dart';
import 'package:chatgpt_flutter/db/hi_db_manager.dart';
import 'package:chatgpt_flutter/db/message_dao.dart';
import 'package:chatgpt_flutter/model/conversation_model.dart';
import 'package:flutter/cupertino.dart';
import 'package:login_sdk/dao/login_dao.dart';

const title =
    '这是ChatGPT，一个由OpenAI训练的大型语言模型。我可以提供许多不同类型的信息，回答问题，提供解释，提供意见，讲故事，写诗等等';
const title2 =
    'Flutter 是一个由 Google 开发的开源移动应用开发框架。它可以被用来创建在 Android 和 iOS 平台上运行的高性能、高保真的应用。Flutter 同时还可以用于开发全功能的 Web 应用和桌面应用（尽管这两项功能在 2021 年仍在早期开发阶段）。自 2017 年以来，Flutter 已经逐渐获得了开发者社区的关注和接纳。';

mockConversation() async {
  var storage =
      await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
  var conversationListDao = ConversationListDao(storage);
  var cid = DateTime.now().millisecondsSinceEpoch;
  var userInfo = LoginDao.getUserInfo();
  var avatar = userInfo!['avatar'];
  ConversationModel conversationModel = ConversationModel(
      cid: cid,
      icon: avatar,
      title: '$cid $title',
      updateAt: cid,
      lastMessage: title);
  await conversationListDao.saveConversation(conversationModel);
  //模拟产生5万条对话，共10万条数据
  for (var i = 0; i < 5 * 10000; i++) {
    MessageDao messageDao = MessageDao(storage, cid: cid);
    messageDao.saveMessage(MessageModel(
      ownerType: OwnerType.receiver,
      content: '$title:$i',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    messageDao.saveMessage(MessageModel(
      ownerType: OwnerType.sender,
      content: '$title2:$i',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    debugPrint('save content：$i success.');
  }
}
