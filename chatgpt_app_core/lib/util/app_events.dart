import 'package:flutter/foundation.dart';

/// 全局轻量事件总线（沿用 [BackupService.restoreTick] 的 ValueNotifier 约定）。
///
/// 当前仅一项：会话列表数据在「当前可见页之外」被改动时通知刷新——典型场景是
/// 「转发」把消息写入了另一个会话、或新建了会话，而会话列表页是 keepAlive 常驻、
/// 不会自动重载。各页在 initState 监听、dispose 取消。
class AppEvents {
  AppEvents._();

  /// 会话列表需要重新加载（转发写入/新建会话后自增以触发监听方刷新）。
  static final ValueNotifier<int> conversationsChanged = ValueNotifier<int>(0);

  static void notifyConversationsChanged() => conversationsChanged.value++;
}
