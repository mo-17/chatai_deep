import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/domain/chat_failure_diagnosis.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final balance = ChatFailureDiagnosis.from(const ChatTransportException(
      safeCode: 'insufficient_balance',
      safeMessage: 'SECRET response body',
      statusCode: 402,
      failureStage: ChatFailureStage.response,
      failureKind: ChatFailureKind.httpStatus));

  test('诊断仅保存安全元数据，忽略存档中的文案和按钮动作', () {
    final json = balance.toJson();
    expect(json.keys.toSet(),
        {'version', 'code', 'statusCode', 'failureStage', 'failureKind'});
    final restored = ChatFailureDiagnosis.fromJson({
      ...json,
      'message': 'SECRET response body',
      'suggestion': 'SECRET key instructions',
      'action': 'none',
    })!;
    expect(restored.code, 'insufficient_balance');
    expect(restored.message, balance.message);
    expect(restored.suggestion, balance.suggestion);
    expect(restored.action, ChatFailureAction.checkBalance);
    expect(restored.statusCode, 402);
    expect(restored.diagnosticReference, 'response/httpStatus');
    expect(jsonEncode(restored.toJson()), isNot(contains('SECRET')));
  });

  test('未知版本、代码、状态与枚举只丢弃诊断', () {
    for (final raw in [
      null,
      [],
      'SECRET',
      {'version': 2, 'code': 'network_error'},
      {'version': 1, 'code': 'SECRET'},
      {...balance.toJson(), 'statusCode': '402'},
      {...balance.toJson(), 'statusCode': 999},
      {...balance.toJson(), 'failureStage': 'SECRET'},
      {...balance.toJson(), 'failureKind': []},
    ]) {
      expect(ChatFailureDiagnosis.fromJson(raw), isNull);
    }
  });

  test('公开构造器的未知代码和任意文案也不会写入存档', () {
    const untrusted = ChatFailureDiagnosis('SECRET code', 'SECRET body',
        'SECRET suggestion', ChatFailureAction.none,
        statusCode: 999);
    final json = untrusted.toJson();
    expect(jsonEncode(json), isNot(contains('SECRET')));
    expect(json['statusCode'], isNull);
    final restored = ChatFailureDiagnosis.fromJson(json)!;
    expect(restored.code, 'request_failed');
    expect(restored.action, ChatFailureAction.retry);
  });

  test('代理504超时往返后保留timeout分类，不误变为服务故障', () {
    final timeout = ChatFailureDiagnosis.from(const ChatTransportException(
        safeCode: 'total_timeout', safeMessage: '', statusCode: 504));
    final restored = ChatFailureDiagnosis.fromJson(timeout.toJson())!;
    expect(restored.code, 'timeout');
    expect(restored.statusCode, 504);
    expect(restored.message, timeout.message);
  });

  group('任务诊断快照', () {
    late _Store store;
    late AgentTaskSession task;
    final protocol = <Map<String, dynamic>>[
      {
        'role': 'assistant',
        'tool_calls': [
          {
            'id': 'read-1',
            'type': 'function',
            'function': {'name': 'read_file', 'arguments': '{}'},
          },
        ],
      },
      {'role': 'tool', 'tool_call_id': 'read-1', 'content': '已经读取的资料'},
    ];

    setUp(() async {
      store = _Store();
      task = AgentTaskSession(cid: 7, store: store);
      await task.setEnabled(true);
      await task.begin(userAt: 101, input: '继续生成报告');
      await task.checkpoint(protocol, 2, executing: 'pending-write');
    });
    tearDown(() => task.dispose());

    test('失败暂停保存诊断，重载仍保留已执行协议和工具断点', () async {
      await task.pause('余额不足', diagnosis: balance);
      final reopened = AgentTaskSession(cid: 7, store: store);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.failureDiagnosis!.code, 'insufficient_balance');
      expect(reopened.canResume, isTrue);
      expect(reopened.messages, protocol);
      expect(reopened.nextRound, 2);
      expect(reopened.executingToolId, 'pending-write');
      expect(jsonEncode(store.value), isNot(contains('SECRET')));
    });

    test('坏诊断或旧快照无诊断不损坏其余恢复数据', () async {
      await task.pause('原任务已暂停');
      for (final diagnosis in [
        null,
        'SECRET',
        {'version': 1, 'code': 'unknown'},
        {...balance.toJson(), 'failureKind': []},
      ]) {
        store.value = {...task.toJson(), 'failureDiagnosis': diagnosis};
        final reopened = AgentTaskSession(cid: 7, store: store);
        await reopened.load();
        expect(reopened.failureDiagnosis, isNull);
        expect(reopened.canResume, isTrue);
        expect(reopened.prompt, '继续生成报告');
        expect(reopened.messages, protocol);
        expect(reopened.executingToolId, 'pending-write');
        reopened.dispose();
      }
      store.value = Map.of(task.toJson())..remove('failureDiagnosis');
      final legacy = AgentTaskSession(cid: 7, store: store);
      addTearDown(legacy.dispose);
      await legacy.load();
      expect(legacy.failureDiagnosis, isNull);
      expect(legacy.messages, protocol);
    });

    test('显式恢复清除旧诊断但保留协议，旧generation错误不能污染新任务', () async {
      final previous = task.generation;
      await task.pause('余额不足', diagnosis: balance);
      await task.begin(userAt: 101, input: '继续生成报告', resume: true);
      expect(task.failureDiagnosis, isNull);
      expect(task.messages, protocol);
      expect(store.value!['failureDiagnosis'], isNull);
      await task.pause('迟到的旧错误',
          expectedGeneration: previous, diagnosis: balance);
      expect(task.status, 'running');
      expect(task.failureDiagnosis, isNull);
      await task.pause('用户已停止');
      expect(store.value!['failureDiagnosis'], isNull);
      expect(task.pauseReason, '用户已停止');
    });

    test('成功完成清空诊断和失败原因', () async {
      await task.pause('余额不足', diagnosis: balance);
      await task.finish(complete: true);
      expect(task.status, 'complete');
      expect(task.failureDiagnosis, isNull);
      expect(task.pauseReason, isNull);
      expect(store.value!['failureDiagnosis'], isNull);
    });
  });
}

class _Store implements IAgentTaskStore {
  Map<String, dynamic>? value;
  @override
  Future<Map<String, dynamic>?> read(int cid) async => value;
  @override
  Future<void> write(int cid, Map<String, dynamic> snapshot) async {
    value = (jsonDecode(jsonEncode(snapshot)) as Map).cast<String, dynamic>();
  }
}
