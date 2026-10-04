import 'dart:async';

import 'package:chatgpt_app_core/chat/application/agent_background_execution.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/agent_background');
  late PlatformAgentBackgroundExecution execution;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) native;
  late List<String> interrupted;

  setUp(() {
    calls = [];
    interrupted = [];
    native = (call) async {
      if (call.method == 'getCapabilities') {
        return {'supported': true, 'mode': 'androidForegroundService'};
      }
      if (call.method == 'start') {
        return {'active': true, 'mode': 'androidForegroundService'};
      }
      return true;
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return native(call);
    });
    execution = PlatformAgentBackgroundExecution(
        channel: channel, operatingSystem: 'android');
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<AgentBackgroundStartResult> start(String runId) => execution.start(
      runId: runId,
      cid: 73,
      title: '读取资料任务',
      onInterrupted: (reason) async => interrupted.add(reason));

  Future<void> interrupt(String runId, String reason) async {
    final done = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(MethodCall(
                'onInterrupted', {'runId': runId, 'reason': reason})),
            (_) => done.complete());
    await done.future;
    await Future<void>.delayed(Duration.zero);
  }

  test('支持的平台能力及 start/update/stop 契约，进度不传对话正文和 API key', () async {
    final capabilities = await execution.capabilities();
    expect(capabilities.supported, isTrue);
    expect((await start('run-1')).active, isTrue);
    expect(execution.isActive('run-1'), isTrue);
    await execution.update(
        runId: 'run-1', completed: 2, total: 5, status: 'reading');
    await execution.stop(runId: 'run-1', success: true);
    expect(execution.isActive('run-1'), isFalse);
    final started = calls.singleWhere((call) => call.method == 'start');
    expect(started.arguments, containsPair('runId', 'run-1'));
    expect(started.arguments, containsPair('cid', 73));
    expect(started.arguments, containsPair('title', '读取资料任务'));
    final updated = calls.singleWhere((call) => call.method == 'update');
    expect(updated.arguments, containsPair('completed', 2));
    expect(updated.arguments, containsPair('total', 5));
    expect(updated.arguments, containsPair('status', 'reading'));
    final stopped = calls.singleWhere((call) => call.method == 'stop');
    expect(stopped.arguments, containsPair('success', true));
    for (final call in calls.where((call) => call.arguments is Map)) {
      expect(
          (call.arguments as Map).keys,
          isNot(anyOf(
              contains('apiKey'),
              contains('messages'),
              contains('prompt'),
              contains('accountHash'),
              contains('attachments'))));
    }
  });

  test('平台不支持时不申请后台许可', () async {
    execution = PlatformAgentBackgroundExecution(
        channel: channel, operatingSystem: 'ohos');
    expect((await execution.capabilities()).supported, isFalse);
    expect((await start('unsupported')).active, isFalse);
    expect(execution.isActive('unsupported'), isFalse);
    expect(calls.where((call) => call.method == 'start'), isEmpty);
  });

  test('缺少插件或权限拒绝安全回退，不标记为正在后台执行', () async {
    native = (call) async => throw MissingPluginException();
    expect((await execution.capabilities()).supported, isFalse);
    expect((await start('no-plugin')).active, isFalse);
    expect(execution.isActive('no-plugin'), isFalse);

    native = (call) async {
      if (call.method == 'getCapabilities') {
        return {'supported': true, 'mode': 'androidForegroundService'};
      }
      if (call.method == 'start') {
        return {'active': false, 'reason': 'notification_permission_denied'};
      }
      return true;
    };
    execution = PlatformAgentBackgroundExecution(
        channel: channel, operatingSystem: 'android');
    final denied = await start('denied');
    expect(denied.active, isFalse);
    expect(execution.isActive('denied'), isFalse);
    expect(interrupted, isEmpty);
  });

  test('同 run 的启动等待只申请一次，不同 run 不抢占已有许可', () async {
    final pending = Completer<Object?>();
    final entered = Completer<void>();
    native = (call) async {
      if (call.method == 'getCapabilities') return {'supported': true};
      if (call.method == 'start') {
        if (!entered.isCompleted) entered.complete();
        return pending.future;
      }
      return true;
    };
    final first = start('first');
    await entered.future;
    final sameRun = start('first');
    final different = await start('second');
    expect(different.active, isFalse);
    expect(calls.where((call) => call.method == 'start'), hasLength(1));
    pending.complete({'active': true});
    expect((await first).active, isTrue);
    expect((await sameRun).active, isTrue);
    expect(execution.isActive('first'), isTrue);
    expect(execution.isActive('second'), isFalse);
    await execution.stop(runId: 'first');
  });

  test('start 未返回就 stop，迟到成功必须释放且不能复活', () async {
    final pending = Completer<Object?>();
    final entered = Completer<void>();
    native = (call) async {
      if (call.method == 'getCapabilities') return {'supported': true};
      if (call.method == 'start') {
        entered.complete();
        return pending.future;
      }
      return true;
    };
    final starting = start('cancelled');
    await entered.future;
    await execution.stop(runId: 'cancelled');
    pending.complete({'active': true});
    expect((await starting).active, isFalse);
    expect(execution.isActive('cancelled'), isFalse);
    expect(calls.where((call) => call.method == 'stop'), isNotEmpty);
    expect(interrupted, isEmpty);
  });

  test('旧 run 的迟到中断和停止不能终止新 run', () async {
    expect((await start('old')).active, isTrue);
    await execution.stop(runId: 'old');
    expect((await start('current')).active, isTrue);
    await interrupt('old', 'expired');
    await execution.stop(runId: 'old');
    expect(execution.isActive('current'), isTrue);
    expect(interrupted, isEmpty);
    await interrupt('current', 'expired');
    expect(execution.isActive('current'), isFalse);
    expect(interrupted, hasLength(1));
    await interrupt('current', 'expired');
    expect(interrupted, hasLength(1), reason: '重复中断只通知页面一次');
  });

  test('启动等待期间收到原生中断，迟到启动不能复活该许可', () async {
    final pending = Completer<Object?>();
    final entered = Completer<void>();
    native = (call) async {
      if (call.method == 'getCapabilities') return {'supported': true};
      if (call.method == 'start') {
        entered.complete();
        return pending.future;
      }
      return true;
    };
    final starting = start('interrupt-during-start');
    await entered.future;
    await interrupt('interrupt-during-start', 'stopped_by_user');
    pending.complete({'active': true});
    expect((await starting).active, isFalse);
    expect(execution.isActive('interrupt-during-start'), isFalse);
    expect(interrupted, hasLength(1));
    expect(calls.where((call) => call.method == 'stop'), isNotEmpty);
  });

  test('原生 stop 失败仍清空本地许可，重复 stop 不通知其他任务', () async {
    expect((await start('stop-failure')).active, isTrue);
    native = (call) async => throw PlatformException(code: 'channel_closed');
    await execution.stop(runId: 'stop-failure');
    expect(execution.isActive('stop-failure'), isFalse);
    await execution.stop(runId: 'stop-failure');
    expect(interrupted, isEmpty);
  });

  test('update 失去原生许可时通知暂停而非继续假后台执行', () async {
    expect((await start('update-failure')).active, isTrue);
    native = (call) async {
      if (call.method == 'update') {
        throw PlatformException(code: 'service_stopped');
      }
      return true;
    };
    await execution.update(
        runId: 'update-failure', completed: 1, total: 4, status: 'reading');
    expect(execution.isActive('update-failure'), isFalse);
    expect(interrupted, hasLength(1));
  });

  test('启动超时返回失败，迟到结果不能把过期 run 标成活跃', () async {
    final pending = Completer<Object?>();
    native = (call) async {
      if (call.method == 'getCapabilities') return {'supported': true};
      if (call.method == 'start') return pending.future;
      return true;
    };
    execution = PlatformAgentBackgroundExecution(
        channel: channel,
        operatingSystem: 'android',
        requestTimeout: const Duration(milliseconds: 10));
    final result = await start('timeout');
    expect(result.active, isFalse);
    expect(execution.isActive('timeout'), isFalse);
    pending.complete({'active': true});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(execution.isActive('timeout'), isFalse);
    expect(calls.where((call) => call.method == 'stop'), isNotEmpty);
  });

  test('后台执行选择默认开启，旧快照保留默认；关闭设置持久化且恢复沿用', () async {
    final store = _MemoryStore();
    final task = AgentTaskSession(cid: 73, store: store);
    addTearDown(task.dispose);
    expect(task.backgroundEnabled, isTrue);
    await task.setEnabled(true);
    await task.setBackgroundEnabled(false);
    await task.begin(userAt: 101, input: '读取任务');
    await task.pause('中断');
    expect(store.snapshot!['backgroundEnabled'], isFalse);
    final reopened = AgentTaskSession(cid: 73, store: store);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.backgroundEnabled, isFalse);
    await reopened.begin(userAt: 101, input: '读取任务', resume: true);
    expect(reopened.backgroundEnabled, isFalse);
    store.snapshot!.remove('backgroundEnabled');
    final legacy = AgentTaskSession(cid: 73, store: store);
    addTearDown(legacy.dispose);
    await legacy.load();
    expect(legacy.backgroundEnabled, isTrue);
  });
}

class _MemoryStore implements IAgentTaskStore {
  Map<String, dynamic>? snapshot;
  @override
  Future<Map<String, dynamic>?> read(int cid) async => snapshot;
  @override
  Future<void> write(int cid, Map<String, dynamic> value) async =>
      snapshot = Map<String, dynamic>.of(value);
}
