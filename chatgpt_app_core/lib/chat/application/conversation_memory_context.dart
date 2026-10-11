import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'package:login_sdk/dao/login_dao.dart';

/// 正式请求的作用域快照。没有页面缓存，也不让后台任务读取个人记忆。
class ConversationMemoryContext {
  final HiDBManager storage;
  final String accountHash;
  final int cid;
  final int? assistantId;
  final bool taskMode;
  final PersonalMemoryDao personal;
  final AssistantMemoryDao assistant;

  const ConversationMemoryContext(
      {required this.storage,
      required this.accountHash,
      required this.cid,
      required this.assistantId,
      required this.taskMode,
      required this.personal,
      required this.assistant});

  Future<String> resolve(bool allowPersonal) async {
    final scope = await LoginDao.runWithStableAccount(
      expectedAccountHash: accountHash,
      action: () => storage.db.query('tb_conversation_list',
          columns: ['assistantId'], where: 'cid=?', whereArgs: [cid]),
    );
    if (scope.length != 1 || scope.single['assistantId'] != assistantId) {
      throw const PersonalMemoryConflict('原对话已删除或助手绑定已变化');
    }
    if (assistantId != null) {
      return LoginDao.runWithStableAccount(
          expectedAccountHash: accountHash,
          action: () async => AssistantMemoryDao.buildSystemContext(
              await assistant.getActiveMemories(assistantId!, limit: 8)));
    }
    if (!allowPersonal || taskMode) return '';
    return personal.requestContext(
        cid: cid, assistantId: assistantId, taskMode: taskMode);
  }
}
