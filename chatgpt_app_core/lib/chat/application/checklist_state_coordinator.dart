import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:flutter/foundation.dart';
import 'package:login_sdk/dao/login_dao.dart';

/// 页面提供代次/账号/会话/消息有效性检查；账号短租约只覆盖定向事务。
class ChecklistStateCoordinator {
  final MessageDao dao;
  final String accountHash;
  final bool Function() isCurrent;
  final Set<String> _pending = {};

  ChecklistStateCoordinator(
      {required this.dao, required this.accountHash, required this.isCurrent});

  /// 保留真实 DAO 路径，测试可在其事务返回后延迟交付结果。
  @protected
  Future<ChecklistWriteResult> write({
    required int createdAt,
    required String blockId,
    required String expectedContent,
    required String cardKey,
    required String itemId,
    required bool checked,
    required int expectedRowId,
  }) =>
      dao.setChecklistItemChecked(
          createdAt: createdAt,
          blockId: blockId,
          expectedContent: expectedContent,
          cardKey: cardKey,
          itemId: itemId,
          checked: checked,
          expectedRowId: expectedRowId);

  Future<ChecklistWriteResult> setChecked({
    required int createdAt,
    required String blockId,
    required String expectedContent,
    required String cardKey,
    required String itemId,
    required bool checked,
    required int expectedRowId,
    required bool Function() messageIsCurrent,
  }) async {
    final identity = '$createdAt:$blockId:$cardKey';
    bool current() =>
        isCurrent() &&
        messageIsCurrent() &&
        LoginDao.getAccountHash() == accountHash;
    if (!current() || !_pending.add(identity)) {
      return const ChecklistWriteResult(ChecklistWriteStatus.stale);
    }
    try {
      final result = await LoginDao.runWithStableAccount<ChecklistWriteResult>(
        expectedAccountHash: accountHash,
        action: () async {
          if (!current()) {
            return const ChecklistWriteResult(ChecklistWriteStatus.stale);
          }
          return await write(
              createdAt: createdAt,
              blockId: blockId,
              expectedContent: expectedContent,
              cardKey: cardKey,
              itemId: itemId,
              checked: checked,
              expectedRowId: expectedRowId);
        },
      );
      return current()
          ? result
          : const ChecklistWriteResult(ChecklistWriteStatus.stale);
    } catch (_) {
      return const ChecklistWriteResult(ChecklistWriteStatus.failed);
    } finally {
      _pending.remove(identity);
    }
  }
}
