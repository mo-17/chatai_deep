import 'dart:async';

import 'package:chatgpt_app_core/chat/application/chat_request_recovery.dart';
import 'package:chatgpt_app_core/chat/domain/chat_failure_diagnosis.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fast = ChatRequestOptions(retryBaseDelay: Duration.zero);
  ChatTransportException failure(
          {int? status,
          bool started = false,
          String code = 'network_error',
          Duration? retryAfter}) =>
      ChatTransportException(
          statusCode: status,
          responseStarted: started,
          safeCode: code,
          safeMessage: 'SECRET response',
          retryAfter: retryAfter);

  test('默认额外最多两次，不接受调用方提高到无限次数', () async {
    var requests = 0;
    await expectLater(
        recoverChatRequest(() async {
          requests++;
          throw failure(status: 503);
        },
            options: const ChatRequestOptions(
                maxAutoRetries: 999, retryBaseDelay: Duration.zero)),
        throwsA(isA<ChatTransportException>()));
    expect(requests, 3);
  });

  for (final status in [400, 401, 402, 403, 404, 422, 502, 504]) {
    test('$status 不自动重试，即使 safeCode 错误声称网络故障', () async {
      var requests = 0;
      await expectLater(
          recoverChatRequest(() async {
            requests++;
            throw failure(status: status);
          }, options: fast),
          throwsA(isA<ChatTransportException>()));
      expect(requests, 1);
    });
  }

  test('原始成功响应开始或可见事件发出后绝不重试', () async {
    var requests = 0;
    await expectLater(
        recoverChatStream<int>(() async* {
          requests++;
          throw failure(status: 500, started: true);
        }, options: fast)
            .drain<void>(),
        throwsA(isA<ChatTransportException>()));
    expect(requests, 1);
    requests = 0;
    await expectLater(
        recoverChatStream<int>(() async* {
          requests++;
          yield 1;
          throw failure();
        }, options: fast)
            .drain<void>(),
        throwsA(isA<ChatTransportException>()));
    expect(requests, 1);
  });

  test('翻译请求沿用外层恢复预算，不叠加普通请求重试', () async {
    var requests = 0;
    await expectLater(
        recoverChatRequest(() async {
          requests++;
          throw failure(status: 429);
        },
            options: const ChatRequestOptions(
                profile: ChatRequestProfile.translation)),
        throwsA(isA<ChatTransportException>()));
    expect(requests, 1);
  });

  test('退避时取消立即停止，Retry-After 有上限，回调仅含安全字段', () async {
    final abort = Completer<void>();
    final notified = Completer<ChatRequestRetry>();
    var requests = 0;
    final pending = recoverChatRequest(() async {
      requests++;
      throw failure(status: 429, retryAfter: const Duration(hours: 9));
    },
        options: ChatRequestOptions(
            abortTrigger: abort.future,
            onRetry: (retry) => notified.complete(retry)));
    final checked = expectLater(
        pending,
        throwsA(isA<ChatTransportException>()
            .having((e) => e.safeCode, 'code', 'cancelled')));
    final retry = await notified.future;
    expect(retry.delay, const Duration(seconds: 5));
    expect(retry.attempt, 1);
    abort.complete();
    await checked.timeout(const Duration(seconds: 1));
    expect(requests, 1);
  });

  test('只有取消stream subscription也立即退出退避，不开始新请求', () async {
    final notified = Completer<void>();
    var requests = 0;
    final subscription = recoverChatStream<int>(() async* {
      requests++;
      throw failure(status: 429, retryAfter: const Duration(hours: 1));
    }, options: ChatRequestOptions(onRetry: (_) => notified.complete()))
        .listen((_) {}, onError: (Object _) {});
    await notified.future;
    await subscription.cancel().timeout(const Duration(seconds: 1));
    expect(requests, 1);
  });

  test('恢复stream保留pause/resume顺序并只交付一次原始错误', () async {
    final source = StreamController<int>();
    final firstReceived = Completer<void>();
    final done = Completer<void>();
    final values = <int>[];
    final errors = <Object>[];
    final failureAfterData = failure();
    var requests = 0;
    final subscription = recoverChatStream(() {
      requests++;
      return source.stream;
    }, options: fast)
        .listen((value) {
      values.add(value);
      if (value == 1) firstReceived.complete();
    }, onError: errors.add, onDone: done.complete);
    source.add(1);
    await firstReceived.future;
    subscription.pause();
    source.add(2);
    source.addError(failureAfterData);
    unawaited(source.close());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(values, [1]);
    expect(errors, isEmpty);
    subscription.resume();
    await done.future.timeout(const Duration(seconds: 1));
    expect(values, [1, 2]);
    expect(errors, [same(failureAfterData)]);
    expect(requests, 1);
  });

  test('已取消请求不进行第一次网络尝试；未知错误不能被猜作网络故障', () async {
    var requests = 0;
    final abort = Completer<void>()..complete();
    await expectLater(
        recoverChatRequest(() async => requests++,
            options: ChatRequestOptions(abortTrigger: abort.future)),
        throwsA(isA<ChatTransportException>()));
    expect(requests, 0);
    await expectLater(
        recoverChatRequest(() async {
          requests++;
          throw StateError('SECRET API key raw response');
        }, options: fast),
        throwsStateError);
    expect(requests, 1);
  });

  test('最终响应与取消相遇时不再返回成功，也不重发请求', () async {
    final abort = Completer<void>();
    var requests = 0;
    await expectLater(
        recoverChatRequest(() async {
          requests++;
          abort.complete();
          return 'late response';
        }, options: ChatRequestOptions(abortTrigger: abort.future)),
        throwsA(isA<ChatTransportException>()
            .having((e) => e.safeCode, 'code', 'cancelled')));
    expect(requests, 1);
  });

  test('诊断按明确状态码分类，未知内容仅显示固定说明与安全枚举', () {
    for (final (status, code) in [
      (401, 'authentication_error'),
      (402, 'insufficient_balance'),
      (404, 'model_not_found'),
      (422, 'invalid_request'),
      (429, 'rate_limited'),
      (503, 'server_error')
    ]) {
      final diagnosis = ChatFailureDiagnosis.from(failure(status: status));
      expect(diagnosis.code, code);
      expect('${diagnosis.message} ${diagnosis.suggestion}',
          isNot(contains('SECRET')));
    }
    final unknown =
        ChatFailureDiagnosis.from(StateError('SECRET raw response'));
    expect(unknown.code, 'request_failed');
    expect(unknown.message, contains('暂未确定'));
    expect(
        '${unknown.message} ${unknown.suggestion}', isNot(contains('SECRET')));
    final typed = ChatFailureDiagnosis.from(const ChatTransportException(
        safeCode: 'request_failed',
        safeMessage: 'SECRET',
        failureStage: ChatFailureStage.decode,
        failureKind: ChatFailureKind.type));
    expect(typed.diagnosticReference, 'decode/type');
  });
}
