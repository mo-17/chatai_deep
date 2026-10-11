import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:login_sdk/dao/login_dao.dart';

/// 在选择器/弹窗前捕获，所有 await 后验证；不会把旧页面对象带入新账号。
class AssistantOperationScope {
  static int _accountEpoch = 0;
  static bool _hooksRegistered = false;
  static int _captureEpoch() {
    if (!_hooksRegistered) {
      _hooksRegistered = true;
      LoginDao.addLoginHook(() => _accountEpoch++);
      LoginDao.addLogoutHook(() => _accountEpoch++);
    }
    return _accountEpoch;
  }

  final int accountEpoch;
  final String accountHash;
  final int restoreRevision;
  final String? Function() currentAccount;
  final int Function() currentRestoreRevision;
  final bool Function()? pageIsCurrent;

  AssistantOperationScope({
    required this.accountHash,
    required this.restoreRevision,
    String? Function()? currentAccount,
    int Function()? currentRestoreRevision,
    this.pageIsCurrent,
  })  : accountEpoch = _captureEpoch(),
        currentAccount = currentAccount ?? LoginDao.getAccountHash,
        currentRestoreRevision =
            currentRestoreRevision ?? (() => BackupService.restoreTick.value);

  factory AssistantOperationScope.capture({bool Function()? pageIsCurrent}) {
    final account = LoginDao.getAccountHash();
    if (account == null || account.trim().isEmpty) {
      throw const LoginAccountChangedException();
    }
    return AssistantOperationScope(
        accountHash: account,
        restoreRevision: BackupService.restoreTick.value,
        pageIsCurrent: pageIsCurrent);
  }

  AssistantOperationScope forPage(bool Function() current) =>
      AssistantOperationScope(
          accountHash: accountHash,
          restoreRevision: restoreRevision,
          currentAccount: currentAccount,
          currentRestoreRevision: currentRestoreRevision,
          pageIsCurrent: () => isCurrent && current());

  bool get isCurrent =>
      accountEpoch == _accountEpoch &&
      currentAccount() == accountHash &&
      currentRestoreRevision() == restoreRevision &&
      (pageIsCurrent?.call() ?? true);
  void verify() {
    if (!isCurrent) throw const AssistantOperationExpired();
  }

  Future<T> runStable<T>(Future<T> Function() action) {
    verify();
    return LoginDao.runWithStableAccount(
        expectedAccountHash: accountHash,
        action: () async {
          verify();
          final result = await action();
          verify();
          return result;
        });
  }
}

class AssistantOperationExpired implements Exception {
  const AssistantOperationExpired();
  @override
  String toString() => '账号、页面或恢复状态已变化，请重新进入角色管理后重试';
}
