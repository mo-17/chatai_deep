import 'dart:async';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:sqflite/sqflite.dart';

/// 由一个运行持有的能力边界；不能使用当前页面/当前账号重新取得许可。
abstract class ToolExecutionScope {
  Future<void> get abortTrigger;
  void verify();
  Future<void> beforeRequest();

  /// 实际 HTTP 调用前同步复核本次异步授权，期间不能再插入 await。
  void verifyRequest() => verify();
  Future<T> commit<T>(Future<T> Function(Transaction tx) action);

  Future<T> wait<T>(Future<T> value) => Future.any([
        value,
        abortTrigger.then<T>((_) => throw const ChatTransportException(
            safeCode: 'cancelled',
            safeMessage: '工具操作已停止',
            failureKind: ChatFailureKind.cancelled)),
      ]);
}
