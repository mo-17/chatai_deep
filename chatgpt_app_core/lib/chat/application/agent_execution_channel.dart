import 'dart:async';
import 'dart:collection';
import 'package:chatgpt_app_core/chat/application/conversation_execution_registry.dart';

class AgentQueueCancelled implements Exception {
  const AgentQueueCancelled();
}

/// 每个运行实例一个身份，只有成功注册后能取消自己的票据，且不能复用。
final class AgentExecutionOwner {
  bool _used = false;
  ConversationExecutionTicket? _conversation;
}

class _Ticket<T> {
  final String id, account;
  final AgentExecutionOwner owner;
  final Future<T> Function() action;
  final Future<void> Function(String) pause;
  final bool Function() background;
  final done = Completer<T>();
  _Ticket(this.id, this.account, this.owner, this.action, this.pause,
      this.background);
  Future<void> execute() async {
    try {
      done.complete(await action());
    } catch (error, stack) {
      done.completeError(error, stack);
    }
  }
}

/// 普通单Agent与协作父任务共用一个通道；许可覆盖整个父任务，不按节点重置。
class AgentExecutionChannel {
  static final instance = AgentExecutionChannel();
  final ConversationExecutionRegistry ownership;
  AgentExecutionChannel({ConversationExecutionRegistry? ownership})
      : ownership = ownership ?? ConversationExecutionRegistry.instance;
  final _queue = Queue<_Ticket<dynamic>>();
  final Map<String, _Ticket<dynamic>> _jobs = {};
  _Ticket<dynamic>? _active;
  final Map<String, int> _maintenanceAccounts = {};
  int _stoppingAll = 0;
  bool accountAvailable(String account) =>
      _stoppingAll == 0 && (_maintenanceAccounts[account] ?? 0) == 0;
  void holdAccount(String account) => _maintenanceAccounts
      .update(account, (value) => value + 1, ifAbsent: () => 1);
  void releaseAccount(String account) {
    final remaining = (_maintenanceAccounts[account] ?? 1) - 1;
    if (remaining == 0) {
      _maintenanceAccounts.remove(account);
    } else {
      _maintenanceAccounts[account] = remaining;
    }
  }

  void holdAll() => _stoppingAll++;
  void releaseAll() => _stoppingAll--;
  static String key(String account, int cid) => '$account:$cid';

  /// legacy enqueue 在首次 await 前占会话；正式执行仍走唯一 FIFO 通道。
  void admit(
      {required String account,
      required int cid,
      required AgentExecutionOwner owner,
      required Future<void> Function(String) pause,
      Object? storageKey,
      Future<void> Function(String)? registryStop}) {
    if (!accountAvailable(account) ||
        owner._used ||
        owner._conversation != null) {
      throw StateError('账号维护或运行身份已失效');
    }
    owner._conversation = ownership.claim(
        account: account,
        cid: cid,
        owner: owner,
        kind: ConversationExecutionKind.agent,
        stop: registryStop ?? pause,
        storageKey: storageKey);
  }

  void releaseAdmission(AgentExecutionOwner owner) {
    final ticket = owner._conversation;
    if (ticket != null) ownership.release(ticket);
  }

  Future<T> run<T>(
      {required String accountHash,
      required int cid,
      required Future<T> Function() action,
      required Future<void> Function(String) pause,
      AgentExecutionOwner? owner,
      Object? storageKey,
      Future<void> Function(String)? registryStop,
      bool Function()? canContinueInBackground}) {
    final id = key(accountHash, cid);
    if (!accountAvailable(accountHash)) {
      return Future.error(StateError('账号维护期间不能启动任务'));
    }
    if (_jobs.containsKey(id)) {
      return Future.error(StateError('该对话已有执行中的任务'));
    }
    final identity = owner ?? AgentExecutionOwner();
    if (identity._used) return Future.error(StateError('运行票据身份不可复用'));
    try {
      if (identity._conversation == null) {
        admit(
            account: accountHash,
            cid: cid,
            owner: identity,
            pause: pause,
            storageKey: storageKey,
            registryStop: registryStop);
      } else if (!ownership.owns(identity._conversation!) ||
          identity._conversation!.account != accountHash ||
          identity._conversation!.cid != cid ||
          (storageKey != null &&
              !identical(identity._conversation!.storageKey, storageKey))) {
        throw StateError('会话执行票据已过期');
      }
    } catch (error) {
      return Future.error(error);
    }
    identity._used = true;
    final ticket = _Ticket<T>(id, accountHash, identity, action, pause,
        canContinueInBackground ?? () => false);
    _jobs[id] = ticket;
    _queue.add(ticket);
    _drain();
    return ticket.done.future;
  }

  void _drain() {
    if (_active != null || _queue.isEmpty) return;
    final ticket = _queue.removeFirst();
    _active = ticket;
    unawaited(() async {
      try {
        if (!accountAvailable(ticket.account)) {
          await ticket.pause('账号维护期间已停止排队');
          ticket.done.completeError(const AgentQueueCancelled());
        } else {
          await ticket.execute();
        }
      } finally {
        if (identical(_jobs[ticket.id], ticket)) _jobs.remove(ticket.id);
        releaseAdmission(ticket.owner);
        _active = null;
        _drain();
      }
    }());
  }

  /// 仅摘除待通道票据，后继仍须等待活跃前驱；不会形成并发执行。
  bool owns(String account, int cid, AgentExecutionOwner owner) =>
      identical(_jobs[key(account, cid)]?.owner, owner);
  bool cancelQueued(String account, int cid,
      {required AgentExecutionOwner owner}) {
    final ticket = _jobs[key(account, cid)];
    if (ticket == null ||
        !identical(ticket.owner, owner) ||
        identical(_active, ticket)) {
      return false;
    }
    _queue.remove(ticket);
    _jobs.remove(ticket.id);
    releaseAdmission(ticket.owner);
    ticket.done.completeError(const AgentQueueCancelled());
    return true;
  }

  Future<void> _pause(_Ticket<dynamic> ticket, String reason) async {
    if (!identical(_jobs[ticket.id], ticket)) return;
    if (!identical(_active, ticket)) {
      _queue.remove(ticket);
      // 管理入口绑定实际票据回调；回调仍能核对自己的注册身份。
      try {
        await ticket.pause(reason);
      } finally {
        if (identical(_jobs[ticket.id], ticket)) _jobs.remove(ticket.id);
        releaseAdmission(ticket.owner);
        if (!ticket.done.isCompleted) {
          ticket.done.completeError(const AgentQueueCancelled());
        }
      }
    } else {
      await ticket.pause(reason);
    }
  }

  Future<void> pauseAccount(String account, String reason) async {
    for (final ticket
        in _jobs.values.where((t) => t.account == account).toList()) {
      await _pause(ticket, reason);
    }
  }

  Future<void> pauseConversation(String account, int cid, String reason) async {
    final ticket = _jobs[key(account, cid)];
    if (ticket != null) await _pause(ticket, reason);
  }

  Future<void> pauseAll(String reason) async {
    for (final ticket in _jobs.values.toList()) {
      await _pause(ticket, reason);
    }
  }

  Future<void> enteredBackground({bool detached = false}) async {
    for (final ticket in _jobs.values.toList()) {
      if (detached || !ticket.background()) {
        await _pause(ticket, '应用在后台且没有有效许可，已保存并暂停');
      }
    }
  }
}
