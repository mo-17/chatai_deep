import 'package:chatgpt_app_core/chat/application/assistant_card_persistence.dart';
import 'package:chatgpt_app_core/chat/application/assistant_operation_scope.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';

/// 编辑入口捕获原账号/恢复代次和真实原行；用户确认后不重新认领最新行。
class AssistantManagementSession {
  final AssistantOperationScope scope;
  final AssistantDao? dao;
  AssistantRowSnapshot? snapshot;
  AssistantManagementSession._(this.scope, this.dao, this.snapshot);

  static Future<AssistantManagementSession> open({
    required AssistantModel? source,
    required AssistantOperationScope scope,
    bool injectedPersistence = false,
  }) async {
    scope.verify();
    if (injectedPersistence) {
      return AssistantManagementSession._(scope, null, null);
    }
    final db = await HiDBManager.instance(dbName: scope.accountHash);
    scope.verify();
    final dao = await AssistantDao.create(db);
    scope.verify();
    AssistantRowSnapshot? snapshot;
    if (source?.id != null) {
      snapshot = await dao.snapshot(source!.id!);
      scope.verify();
      if (snapshot == null || !snapshot.matchesModel(source)) {
        throw const AssistantMutationStale();
      }
    }
    return AssistantManagementSession._(scope, dao, snapshot);
  }

  Future<AssistantModel> save(
    AssistantModel source, {
    Future<void> Function(AssistantModel)? override,
  }) async {
    scope.verify();
    final copy = AssistantModel.fromJson(source.toJson());
    if (override != null) {
      await override(copy);
      scope.verify();
      return copy;
    }
    final result = await AssistantCardPersistence(dao: dao!, scope: scope)
        .save(copy, expected: snapshot);
    snapshot = result.committed.snapshot;
    return result.committed.assistant;
  }
}

/// 只在持久化成功并且页面身份仍有效后调用。
void acceptSavedAssistant(AssistantModel target, AssistantModel saved) {
  target
    ..id = saved.id
    ..name = saved.name
    ..emoji = saved.emoji
    ..avatarType = saved.avatarType
    ..avatarValue = saved.avatarValue
    ..prompt = saved.prompt
    ..description = saved.description
    ..openingMessage = saved.openingMessage
    ..exampleDialogs = saved.exampleDialogs
    ..memoryBook = saved.memoryBook
    ..worldBookJson = saved.worldBookJson
    ..roleCardAssets = saved.roleCardAssets
    ..defaultVoiceStyle = saved.defaultVoiceStyle
    ..providerId = saved.providerId
    ..model = saved.model
    ..useTools = saved.useTools
    ..toolIds = saved.toolIds == null ? null : [...saved.toolIds!]
    ..createdAt = saved.createdAt
    ..updatedAt = saved.updatedAt;
}
