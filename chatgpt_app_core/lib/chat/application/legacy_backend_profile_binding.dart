import 'dart:convert';
import 'dart:async';

import 'package:chatgpt_app_core/chat/application/backend_selection_probe.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';

/// 仅为确定尚未发出的旧任务准备完整请求快照。没有 runner/UI 自动接线。
/// 任何 probe 失败不写；全部 GET 结束才进入一次短事务，旧结果不重签。
class LegacyBackendProfileBinding {
  final LegacyBackendSelectionProbe probe;
  final Duration probeTimeout;
  LegacyBackendProfileBinding(
      {required this.probe, this.probeTimeout = const Duration(seconds: 8)});
  Future<BackendSelection> _resolve(
          BackendSelectionBindingScope scope, String modelId) =>
      probe(scope, modelId).timeout(probeTimeout,
          onTimeout: () => throw const BackendSelectionProbeFailure('timeout'));

  Future<AgentWorkflow> workflow(AgentWorkflowDao dao,
      BackendSelectionBindingScope scope, String parentId) async {
    scope.verify();
    if (dao.accountHash != scope.accountHash) {
      throw const WorkflowStale('任务数据库账号不匹配');
    }
    final parent = await dao.read(parentId);
    final steps = await dao.steps(parentId);
    scope.verify();
    if (parent == null ||
        !AgentWorkflowDao.unstartedForBackendBinding(parent, steps) ||
        (await dao.attemptHistory(parentId)).isNotEmpty) {
      throw const WorkflowStale('任务不能证明尚未执行，请人工处理');
    }
    scope.verify();
    final resolved = <String, BackendSelection>{};
    for (final step in steps) {
      final profile = step.profile;
      if (profile.mode != 'backend') continue;
      if (profile.backendSelection != null) {
        scope.verifyPair(profile.backendSelection!, profile.modelId);
        continue;
      }
      if (profile.providerId != 'backend') {
        throw const WorkflowStale('旧后端配置不是可识别哨兵');
      }
      scope.verify();
      final pair = await _resolve(scope, profile.modelId);
      scope.verifyPair(pair, profile.modelId);
      resolved[step.id] = pair;
    }
    scope.verify();
    return dao.bindLegacyBackendProfiles(scope,
        expected: parent, expectedSteps: steps, resolved: resolved);
  }

  Future<StoryTemplateTranslationTaskModel> translation(
      StoryTemplateTranslationTaskDao dao,
      BackendSelectionBindingScope scope,
      int taskId,
      {DateTime? now}) async {
    dao.verifyBackendBindingScope(scope);
    final row = await dao.backendBindingSnapshot(taskId);
    scope.verify();
    if (row == null ||
        !StoryTemplateTranslationTaskDao.unstartedForBackendBinding(row)) {
      throw const WorkflowStale('翻译任务不能证明尚未执行，请人工处理');
    }
    final decoded = jsonDecode(row['requestProfile'] as String);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('旧翻译快照无效');
    }
    final profile = TranslationRequestProfile.fromJson(decoded);
    if (profile.mode != TranslationExecutionMode.backend ||
        profile.version != 1 ||
        profile.backendSelection != null) {
      throw const WorkflowStale('不是待绑定的旧后端快照');
    }
    final pair = await _resolve(scope, profile.modelId);
    scope.verifyPair(pair, profile.modelId);
    return dao.bindLegacyBackendProfile(scope,
        expected: row, selection: pair, now: now);
  }
}
