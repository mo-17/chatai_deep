import 'package:flutter/foundation.dart';

typedef StoryTemplateBackgroundSchedule = Future<void> Function(
  String accountHash,
);
typedef StoryTemplateBackgroundCancel = Future<void> Function(
  String accountHash,
);

/// 由 Android/iOS 壳层注入的系统后台调度桥。
///
/// Core 不直接依赖 WorkManager 或 BGTaskScheduler，OHOS/桌面端未安装处理器时
/// 保持无操作；调度失败也不能影响前台翻译任务本身。
class StoryTemplateBackgroundScheduler {
  const StoryTemplateBackgroundScheduler._();

  static StoryTemplateBackgroundSchedule? _schedule;
  static StoryTemplateBackgroundCancel? _cancel;

  static void install({
    required StoryTemplateBackgroundSchedule schedule,
    required StoryTemplateBackgroundCancel cancel,
  }) {
    _schedule = schedule;
    _cancel = cancel;
  }

  static Future<void> schedule(String accountHash) async {
    final handler = _schedule;
    if (handler == null || accountHash.trim().isEmpty) return;
    try {
      await handler(accountHash);
    } catch (error, stackTrace) {
      debugPrint('schedule story translation background work failed: '
          '$error\n$stackTrace');
    }
  }

  static Future<void> cancel(String accountHash) async {
    final handler = _cancel;
    if (handler == null || accountHash.trim().isEmpty) return;
    try {
      await handler(accountHash);
    } catch (error, stackTrace) {
      debugPrint('cancel story translation background work failed: '
          '$error\n$stackTrace');
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _schedule = null;
    _cancel = null;
  }
}
