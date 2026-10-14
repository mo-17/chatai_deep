import 'dart:async';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:login_sdk/dao/login_dao.dart';

class ConversationGenerationStale implements Exception {
  final String reason;
  const ConversationGenerationStale([this.reason = '账号、会话或来源已变化，请重新发送']);
  @override
  String toString() => reason;
}

class ConversationRetirementStale extends ConversationGenerationStale {
  const ConversationRetirementStale() : super('退役生成记录已变化，请重新核对当前会话');
}

/// 捕获登录代次，不把同账号重新登录视为同一个执行许可。
class ConversationGenerationScope {
  static int _epoch = 0;
  static bool _registered = false;
  static int epoch() {
    if (!_registered) {
      _registered = true;
      LoginDao.addLoginHook(() => _epoch++);
      LoginDao.addLogoutHook(() => _epoch++);
    }
    return _epoch;
  }

  final String account;
  final int loginEpoch, restoreRevision;
  final String? Function() currentAccount;
  final int Function() currentEpoch, currentRestore;
  final Future<void> Function(Future<void> Function())? stableOperation;
  final _pending = LoginOperationCancellation();
  bool _cancelled = false;
  ConversationGenerationScope({
    required this.account,
    String? Function()? currentAccount,
    int Function()? currentEpoch,
    int Function()? currentRestore,
    this.stableOperation,
  })  : currentAccount = currentAccount ?? LoginDao.getAccountHash,
        currentEpoch = currentEpoch ?? epoch,
        currentRestore = currentRestore ?? _restore,
        loginEpoch = (currentEpoch ?? epoch)(),
        restoreRevision = (currentRestore ?? _restore)();
  ConversationGenerationScope._(ConversationGenerationScope source)
      : account = source.account,
        loginEpoch = source.loginEpoch,
        restoreRevision = source.restoreRevision,
        currentAccount = source.currentAccount,
        currentEpoch = source.currentEpoch,
        currentRestore = source.currentRestore,
        stableOperation = source.stableOperation;
  static int _restore() =>
      BackupService.restoreTick.value + BackupService.agentExecutionRevision;
  bool get identityCurrent =>
      currentAccount() == account &&
      currentEpoch() == loginEpoch &&
      currentRestore() == restoreRevision;
  bool get isCurrent => !_cancelled && identityCurrent;
  void verify() {
    if (!isCurrent) {
      throw const ConversationGenerationStale();
    }
  }

  Future<void> get whenCancelled => _pending.whenCancelled;

  void cancel() {
    _cancelled = true;
    _pending.cancel();
  }

  // 终结只能沿原身份写回；不能通过重新 capture 认领恢复后的同号会话。
  ConversationGenerationScope finalWriteScope() =>
      ConversationGenerationScope._(this);
  Future<T> stable<T>(Future<T> Function() action) async {
    verify();
    late T result;
    Future<void> checked() async {
      verify();
      result = await action();
      verify();
    }

    try {
      if (stableOperation != null) {
        await stableOperation!(checked);
      } else {
        await LoginDao.runWithStableAccount(
            expectedAccountHash: account,
            cancellation: _pending,
            action: checked);
      }
    } on LoginOperationCancelledException {
      throw const ConversationGenerationStale('等待账号许可的请求已停止');
    }
    verify();
    return result;
  }

  Future<T> wait<T>(Future<T> value, Future<void> abort) => Future.any([
        value,
        abort.then<T>((_) => throw const ChatTransportException(
            safeCode: 'cancelled',
            safeMessage: '请求已停止',
            failureKind: ChatFailureKind.cancelled)),
      ]);
}
