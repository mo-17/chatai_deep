import 'dart:async';

/// 会话执行身份独立于页面；普通聊天并行上限不改变 Agent 的串行通道。
enum ConversationExecutionKind { ordinary, agent }

final class ConversationExecutionTicket {
  final String account;
  final int cid;
  final Object owner;
  final Object? storageKey;
  final ConversationExecutionKind kind;
  final Future<void> Function(String reason) stop;
  final Future<void> Function(String reason)? retire;
  bool _released = false;
  ConversationExecutionTicket._(this.account, this.cid, this.owner,
      this.storageKey, this.kind, this.stop, this.retire);
  bool get released => _released;
}

class ConversationExecutionRegistry {
  static final instance = ConversationExecutionRegistry();
  final _tickets = <String, ConversationExecutionTicket>{};
  final _maintenance = <Object, int>{};
  final _conversationMaintenance = <Object, Map<int, int>>{};
  static String key(String account, int cid) => '$account:$cid';
  ConversationExecutionTicket? lookup(String account, int cid) =>
      _tickets[key(account, cid)];

  ConversationExecutionTicket claim({
    required String account,
    required int cid,
    required Object owner,
    required ConversationExecutionKind kind,
    required Future<void> Function(String) stop,
    Object? storageKey,
    Future<void> Function(String)? retire,
  }) {
    if (storageKey != null &&
        ((_maintenance[storageKey] ?? 0) > 0 ||
            (_conversationMaintenance[storageKey]?[cid] ?? 0) > 0)) {
      throw StateError('账号资料维护期间不能发送');
    }
    if (lookup(account, cid) != null) {
      throw StateError('该对话已有执行中的请求');
    }
    if (kind == ConversationExecutionKind.ordinary &&
        _tickets.values
                .where((t) =>
                    t.account == account &&
                    t.kind == ConversationExecutionKind.ordinary)
                .length >=
            2) {
      throw StateError('已有两个会话正在执行，请等待或停止后再发送');
    }
    final ticket = ConversationExecutionTicket._(
        account, cid, owner, storageKey, kind, stop, retire);
    _tickets[key(account, cid)] = ticket;
    return ticket;
  }

  bool owns(ConversationExecutionTicket ticket) =>
      !ticket._released &&
      identical(lookup(ticket.account, ticket.cid), ticket);
  void release(ConversationExecutionTicket ticket) {
    if (owns(ticket)) {
      _tickets.remove(key(ticket.account, ticket.cid));
    }
    ticket._released = true;
  }

  /// 管理操作选择当前真实票据；迟到的运行回调只能释放自己的身份。
  Future<void> stopStorage(Object storage, String reason,
      {int? cid, bool retire = false}) async {
    for (final ticket in _tickets.values
        .where((t) =>
            identical(t.storageKey, storage) && (cid == null || t.cid == cid))
        .toList()) {
      if (owns(ticket)) {
        await (retire ? ticket.retire ?? ticket.stop : ticket.stop)(reason);
      }
    }
  }

  Future<T> maintainStorage<T>(Object storage, Future<T> Function() action,
      {int? cid, String reason = '资料正在恢复，原请求已停止'}) async {
    if (cid == null) {
      _maintenance.update(storage, (n) => n + 1, ifAbsent: () => 1);
    } else {
      (_conversationMaintenance[storage] ??= {})
          .update(cid, (n) => n + 1, ifAbsent: () => 1);
    }
    try {
      await stopStorage(storage, reason, cid: cid, retire: true);
      return await action();
    } finally {
      final counts =
          cid == null ? _maintenance : _conversationMaintenance[storage]!;
      final Object key = cid ?? storage;
      final n = counts[key]! - 1;
      if (n == 0) {
        counts.remove(key);
      } else {
        counts[key] = n;
      }
      if (cid != null && counts.isEmpty) {
        _conversationMaintenance.remove(storage);
      }
    }
  }
}
