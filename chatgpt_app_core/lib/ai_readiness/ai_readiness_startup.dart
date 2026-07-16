typedef AIReadinessStartupStep = Future<void> Function();
typedef GuestMigrationSettlementStep = Future<bool> Function();

/// 保证首页账号状态的启动顺序：先加载目标账号设置，再完成游客迁移决策，
/// 最后才允许读取 legacy evidence 并初始化 readiness。
///
/// 返回 false 表示页面已销毁或迁移未完成；此时 readiness 保持 loading，避免
/// 把尚未导入游客数据的旧账号误判为首次使用。
Future<bool> initializeAIReadinessAfterGuestMigration({
  required AIReadinessStartupStep loadSettings,
  required GuestMigrationSettlementStep settleGuestMigration,
  required AIReadinessStartupStep initializeReadiness,
  bool Function()? canContinue,
}) async {
  bool active() => canContinue?.call() ?? true;

  await loadSettings();
  if (!active()) return false;

  final migrationSettled = await settleGuestMigration();
  if (!migrationSettled || !active()) return false;

  await initializeReadiness();
  return active();
}
