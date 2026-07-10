import 'dart:io';

import 'package:chatgpt_app_core/chat/application/story_template_background_scheduler.dart';
import 'package:chatgpt_app_core/chat/application/story_template_background_worker.dart';
import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

const String storyTemplateTranslationTaskName = 'story_template_translation';
const String storyTemplateTranslationUniqueName =
    'com.example.chatgpt_flutter.story-template-translation';

/// Workmanager 的入口必须是顶层函数，并保留给 release tree-shaking。
@pragma('vm:entry-point')
void storyTemplateBackgroundCallback() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != storyTemplateTranslationTaskName &&
        taskName != storyTemplateTranslationUniqueName) {
      return true;
    }

    final accountHash = inputData?['accountHash'] as String?;
    if (accountHash == null || accountHash.isEmpty) {
      return true;
    }

    try {
      final completed = await runStoryTemplateTranslationBackgroundWork(
        accountHash: accountHash,
      );
      if (!completed && Platform.isIOS) {
        await scheduleStoryTemplateTranslationBackgroundWork(accountHash);
      }
      return completed;
    } catch (error, stackTrace) {
      debugPrint(
        'story template background work failed: $error\n$stackTrace',
      );
      return false;
    }
  });
}

Future<void> installStoryTemplateBackgroundWorkmanager() async {
  if (!Platform.isAndroid && !Platform.isIOS) return;

  await Workmanager().initialize(storyTemplateBackgroundCallback);
  StoryTemplateBackgroundScheduler.install(
    schedule: scheduleStoryTemplateTranslationBackgroundWork,
    cancel: cancelStoryTemplateTranslationBackgroundWork,
  );
}

Future<void> scheduleStoryTemplateTranslationBackgroundWork(
  String accountHash,
) async {
  if (!Platform.isAndroid && !Platform.isIOS) return;

  final inputData = <String, dynamic>{'accountHash': accountHash};
  final workmanager = Workmanager();

  if (Platform.isIOS) {
    await workmanager.registerProcessingTask(
      storyTemplateTranslationUniqueName,
      storyTemplateTranslationTaskName,
      initialDelay: const Duration(minutes: 6),
      inputData: inputData,
      constraints: Constraints(networkType: NetworkType.connected),
    );
    return;
  }

  await workmanager.registerOneOffTask(
    storyTemplateTranslationUniqueName,
    storyTemplateTranslationTaskName,
    initialDelay: const Duration(minutes: 6),
    inputData: inputData,
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.replace,
    backoffPolicy: BackoffPolicy.exponential,
    backoffPolicyDelay: const Duration(minutes: 1),
  );
}

Future<void> cancelStoryTemplateTranslationBackgroundWork(
  String accountHash,
) async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  if (accountHash.trim().isEmpty) return;
  await Workmanager().cancelByUniqueName(storyTemplateTranslationUniqueName);
}
