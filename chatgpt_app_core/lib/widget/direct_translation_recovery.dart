import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/direct_failure_recovery.dart';
import 'package:chatgpt_app_core/chat/application/story_template_translation_tasks.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_eligibility.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/widget/direct_failure_dialog.dart';
import 'package:provider/provider.dart';

/// 返回true表示直连分支已处理；后台选择仍走原恢复合同。
Future<bool> showDirectTranslationRecovery(
    BuildContext context,
    StoryTemplateTranslationTaskModel task,
    StoryTemplateTranslationCoordinator coordinator,
    TranslationExecutorResolver Function(AISettings) resolver) async {
  final TranslationRequestProfile originalProfile;
  try {
    final decoded = jsonDecode(task.requestProfile);
    if (decoded is! Map) throw const FormatException();
    originalProfile =
        TranslationRequestProfile.fromJson(Map<String, dynamic>.from(decoded));
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('原任务模型声明无法确认，请保留记录并重新创建任务')));
    }
    return true;
  }
  if (originalProfile.mode != TranslationExecutionMode.local) return false;
  final account = coordinator.ownerAccountFor(task);
  final ownerEpoch = coordinator.ownerEpochFor(task);
  if (account == null || ownerEpoch == null) return true;
  final source = task.sourcePayload, profile = task.requestProfile;
  final identity = AiCatalogIdentity.capture();
  var handedOff = false;
  final original = context.read<AISettingsProvider>().settings.clone()
    ..mode = AIMode.local
    ..activeProviderId = originalProfile.providerId!;
  original.setLocalModelOverride(originalProfile.modelId);
  final scope = ConversationGenerationScope(account: account);
  final recovery = DirectFailureRecovery(
      original: original,
      scope: scope,
      currentSettings: () => context.read<AISettingsProvider>().settings,
      sourceCurrent: () =>
          context.mounted &&
          identity.current &&
          coordinator.ownerContextCurrent(account, ownerEpoch) &&
          (handedOff || coordinator.ownerAccountFor(task) == account) &&
          task.sourcePayload == source &&
          task.requestProfile == profile,
      requiredInput: const ModelCapabilities.none(),
      mayHaveBeenProcessed: true,
      failureCode: task.error);
  final permit = await showDirectFailureDialog(context, recovery);
  if (!context.mounted || permit == null || !permit.current) return true;
  final selected = permit.claim();
  if (selected == null) return true;
  handedOff = true;
  final nextProfile = TranslationRequestProfile(
      mode: TranslationExecutionMode.local,
      providerId: selected.activeProvider.id,
      modelId: selected.effectiveModel,
      reasoningPolicy: originalProfile.reasoningPolicy,
      reasoningControlSuppressed: originalProfile.reasoningControlSuppressed);
  final environment = TranslationEligibilityEnvironment.current();
  const evaluator = TranslationModelEligibilityEvaluator();
  TranslationEligibilityResult eligible(TranslationRequestProfile p) {
    permit.verify();
    return evaluator.evaluateProfile(
        settings: selected, profile: p, environment: environment);
  }

  if (nextProfile.providerId == originalProfile.providerId &&
      nextProfile.modelId == originalProfile.modelId) {
    await coordinator.retry(task,
        directPermit: permit,
        checkEligibility: eligible,
        resolveExecutor: resolver(selected));
  } else {
    await coordinator.startConfirmedDirectCopy(task,
        requestProfile: nextProfile,
        directPermit: permit,
        checkEligibility: eligible,
        resolveExecutor: resolver(selected));
  }
  return true;
}
