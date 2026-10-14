import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:login_sdk/dao/login_dao.dart';

typedef WorkflowStableOperation = Future<void> Function(
    Future<void> Function() action);

/// 同 isolate 的账号短租约只包 SQLite 读写，不包模型、原生申请或确认弹窗。
class AgentWorkflowScope {
  static int _loginEpoch = 0;
  static bool _registered = false;
  static int _epoch() {
    if (!_registered) {
      _registered = true;
      LoginDao.addLoginHook(() => _loginEpoch++);
      LoginDao.addLogoutHook(() => _loginEpoch++);
    }
    return _loginEpoch;
  }

  final String accountHash;
  final int loginEpoch, restoreRevision;
  final String? Function() currentAccount;
  final int Function() currentLoginEpoch, currentRestoreRevision;
  final WorkflowStableOperation? _stable;
  final _pendingOperations = LoginOperationCancellation();
  bool _cancelled = false;
  AgentWorkflowScope({
    required this.accountHash,
    String? Function()? currentAccount,
    int Function()? currentLoginEpoch,
    int Function()? currentRestoreRevision,
    WorkflowStableOperation? stableOperation,
  })  : currentAccount = currentAccount ?? LoginDao.getAccountHash,
        currentLoginEpoch = currentLoginEpoch ?? _epoch,
        currentRestoreRevision = currentRestoreRevision ??
            (() =>
                BackupService.restoreTick.value +
                BackupService.agentExecutionRevision),
        loginEpoch = (currentLoginEpoch ?? _epoch)(),
        restoreRevision = (currentRestoreRevision ??
            (() =>
                BackupService.restoreTick.value +
                BackupService.agentExecutionRevision))(),
        _stable = stableOperation;
  bool get identityCurrent =>
      currentAccount() == accountHash &&
      currentLoginEpoch() == loginEpoch &&
      currentRestoreRevision() == restoreRevision;
  bool get isCurrent => !_cancelled && identityCurrent;
  void verify() {
    if (!isCurrent) throw const WorkflowStale('账号、登录或恢复状态已变化，任务已停止');
  }

  void cancel() {
    _cancelled = true;
    _pendingOperations.cancel();
  }

  AgentWorkflowScope fork() => AgentWorkflowScope(
      accountHash: accountHash,
      currentAccount: currentAccount,
      currentLoginEpoch: currentLoginEpoch,
      currentRestoreRevision: currentRestoreRevision,
      stableOperation: _stable);
  Future<T> stable<T>(Future<T> Function() action) async {
    verify();
    late T result;
    Future<void> checked() async {
      verify();
      result = await action();
      verify();
    }

    try {
      if (_stable != null) {
        await _stable!(checked);
      } else {
        await LoginDao.runWithStableAccount(
            expectedAccountHash: accountHash,
            cancellation: _pendingOperations,
            action: checked);
      }
    } on LoginOperationCancelledException {
      throw const WorkflowStale('等待账号许可的任务已撤销');
    }
    verify();
    return result;
  }
}
