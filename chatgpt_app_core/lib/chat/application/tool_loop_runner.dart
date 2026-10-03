import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

/// 工具调用执行回路（阶段六）。对应源项目
/// `messageStreaming/callbacks/toolCallbacks.ts` 的「调用 → 执行 → 回灌 → 续写」：
///
/// 1. 流式请求带 tools，模型可能发起 toolCall（流结束前以完整事件到达）；
/// 2. 客户端执行工具，把 assistant(tool_calls) + role:tool 结果追加进 messages；
/// 3. 再次请求，模型基于工具结果继续输出正文；
/// 4. 重复直到模型不再调用工具，或达到 [maxRounds]（最后一轮不带 tools，
///    强制模型直接作答，防止无限调用）。
///
/// 所有事件（toolCall / toolResult / text / reasoning / citation）原样向上 yield，
/// 由 StreamDispatcher 落块 —— 验收：ToolBlock 出现后正文继续。
class ToolLoopRunner {
  /// 工具调用轮次上限（防无限循环）。
  static const int maxRounds = 5;
  static const _uncertainResult = '此工具在中断前可能已执行，结果未保存。请用户核对；禁止自动重复此操作。';

  final ChatService chatService;
  final ToolRegistry registry;

  ToolLoopRunner({required this.chatService, required this.registry});

  Stream<StreamEvent> run({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    Future<void>? abortTrigger,
    ChatSendProgressCallback? onProgress,
    List<Map<String, dynamic>> Function(
      List<Map<String, dynamic>> extraMessages,
      List<Map<String, dynamic>>? declarations,
    )? historyForRound,

    /// 每个工具结果保存后、最终回答结束时提供当前协议快照，供断点落库。
    /// 多工具轮执行途中可能尚未配对完成，消息历史的调用方需过滤或补齐。
    /// 列表不会随下一轮追加变化；包含最终 assistant 的 reasoning_content。
    FutureOr<void> Function(List<Map<String, dynamic>> messages)?
        onProtocolMessages,
    AgentTaskSession? task,
  }) async* {
    var cancelled = false;
    unawaited(abortTrigger?.then<void>((_) {
      cancelled = true;
    }, onError: (Object _, StackTrace __) {
      cancelled = true;
    }));
    void ensureRunning() {
      if (cancelled) {
        throw const ChatTransportException(
            safeCode: 'cancelled', safeMessage: '请求已取消');
      }
    }

    // 已完成的取消信号也应阻止首轮请求；无信号时保留原有执行时序。
    if (abortTrigger != null) await Future<void>.value();
    // 工具回灌消息（assistant tool_calls + role:tool），追加在当前轮 user 之后。
    final extraMessages = <Map<String, dynamic>>[...?(task?.messages)];
    // 汇总各轮联网搜索来源（按 URL 去重），收尾发一次 citation 事件。
    final citations = <WebSearchResult>[];
    final seenUrls = <String>{};
    final taskGeneration = task?.generation;
    final uncertainOperations = <String>{};

    // 恢复时声明/结果必须配对。已完成结果直接复用；执行中崩溃的调用不重放。
    if (extraMessages.isNotEmpty) {
      final interruptedToolId = task?.executingToolId;
      final declarations =
          extraMessages.where((m) => m['tool_calls'] is List).toList();
      final completed = extraMessages
          .where((m) => m['role'] == 'tool')
          .map((m) => m['tool_call_id'])
          .toSet();
      for (final declaration in declarations) {
        for (final raw in declaration['tool_calls'] as List) {
          ensureRunning();
          final call = (raw as Map).cast<String, dynamic>();
          final id = call['id'] as String;
          final function = call['function'] as Map;
          final name = function['name'] as String;
          final args = (jsonDecode(function['arguments'] as String) as Map)
              .cast<String, dynamic>();
          final savedResults = extraMessages
              .where((m) => m['role'] == 'tool' && m['tool_call_id'] == id);
          if (id == interruptedToolId ||
              savedResults.any((m) => m['content'] == _uncertainResult)) {
            uncertainOperations.add(_operationKey(name, args));
          }
          yield StreamEvent.toolCall(toolId: id, name: name, arguments: args);
          if (!completed.contains(id)) {
            final unknown = interruptedToolId == id;
            await task?.checkpoint(extraMessages, task.nextRound,
                executing: id, expectedGeneration: taskGeneration);
            final content = unknown ||
                    uncertainOperations.contains(_operationKey(name, args))
                ? _uncertainResult
                : (await registry.execute(name, args)).content;
            extraMessages
                .add({'role': 'tool', 'tool_call_id': id, 'content': content});
            await task?.checkpoint(extraMessages, task.nextRound,
                expectedGeneration: taskGeneration);
          }
          final result = extraMessages.firstWhere(
              (m) => m['role'] == 'tool' && m['tool_call_id'] == id);
          yield StreamEvent.toolResult(toolId: id, content: result['content']);
        }
      }
      await onProtocolMessages?.call(_protocolSnapshot(extraMessages));
      final finalMessage = extraMessages.last;
      if (finalMessage['role'] == 'assistant' &&
          finalMessage['tool_calls'] == null &&
          task?.needsContinuation != true) {
        // 最终回答已保存、完成标记尚未落库时，直接重播而不再请求模型。
        ensureRunning();
        final reasoning = finalMessage['reasoning_content'] as String? ?? '';
        final text = finalMessage['content'] as String? ?? '';
        if (reasoning.isNotEmpty) yield StreamEvent.reasoning(reasoning);
        if (text.isNotEmpty) yield StreamEvent.text(text);
        return;
      }
    }

    for (var round = task?.nextRound ?? 0;; round++) {
      ensureRunning();
      final calls = <StreamEvent>[];
      // 本轮正文缓存：回灌 assistant 消息时带上（模型边说边调用的场景）。
      final textBuf = StringBuffer();
      // DeepSeek 思考模式工具调用要求逐轮原样回传 reasoning_content。
      final reasoningBuf = StringBuffer();
      // 最后一轮不带 tools：模型只能直接作答，回路必然终止。
      final declarations = round < maxRounds ? registry.declarations : null;
      final roundHistory =
          historyForRound?.call(extraMessages, declarations) ?? history;
      onProgress?.call(const ChatSendProgress('等待回答'));
      final events = abortTrigger == null && onProgress == null
          ? chatService.chatStreamEvents(
              prompt: prompt,
              history: roundHistory,
              attachments: attachments,
              tools: declarations,
              extraMessages: extraMessages,
            )
          : chatService.chatStreamEventsWithOptions(
              prompt: prompt,
              history: roundHistory,
              attachments: attachments,
              tools: declarations,
              extraMessages: extraMessages,
              options: ChatRequestOptions(
                  abortTrigger: abortTrigger, onProgress: onProgress),
            );
      await for (final e in events) {
        ensureRunning();
        if (e.type == StreamEventType.toolCall) {
          calls.add(e);
        } else if (e.type == StreamEventType.text) {
          textBuf.write(e.delta);
        } else if (e.type == StreamEventType.reasoning) {
          reasoningBuf.write(e.delta);
        }
        yield e; // toolCall 也原样上抛 -> UI 立即出现 processing 态 ToolBlock
      }
      ensureRunning();
      if (calls.isEmpty) {
        extraMessages.add({
          'role': 'assistant',
          'content': textBuf.toString(),
          'reasoning_content': reasoningBuf.toString(),
        });
        await onProtocolMessages?.call(_protocolSnapshot(extraMessages));
        await task?.checkpoint(extraMessages, round,
            expectedGeneration: taskGeneration);
        break; // 模型不再调用工具，正文已输出完毕
      }
      // 硬性保护：已到无 tools 的收尾轮仍收到调用（上游异常），直接终止。
      if (round >= maxRounds) break;

      AILogger.log('tool round $round: ${calls.length} call(s)');
      extraMessages.add({
        'role': 'assistant',
        'content': textBuf.toString(),
        'reasoning_content': reasoningBuf.toString(),
        'tool_calls': [
          for (final c in calls)
            {
              'id': c.toolId,
              'type': 'function',
              'function': {
                'name': c.toolName,
                'arguments': jsonEncode(c.toolArguments ?? const {}),
              },
            },
        ],
      });
      await task?.checkpoint(extraMessages, round + 1,
          expectedGeneration: taskGeneration);
      for (final c in calls) {
        ensureRunning();
        onProgress?.call(ChatSendProgress('执行工具', fileName: c.toolName));
        await task?.checkpoint(extraMessages, round + 1,
            executing: c.toolId, expectedGeneration: taskGeneration);
        final outcome = uncertainOperations.contains(
                _operationKey(c.toolName ?? '', c.toolArguments ?? const {}))
            ? const ToolOutcome(content: _uncertainResult)
            : await registry.execute(
                c.toolName ?? '', c.toolArguments ?? const {});
        extraMessages.add({
          'role': 'tool',
          'tool_call_id': c.toolId,
          'content': outcome.content,
        });
        // 先提交结果再处理取消，停止后恢复不会重做已经执行完的写操作。
        await task?.checkpoint(extraMessages, round + 1,
            expectedGeneration: taskGeneration);
        await onProtocolMessages?.call(_protocolSnapshot(extraMessages));
        ensureRunning();
        for (final r in outcome.webResults) {
          if (r.url.isNotEmpty && seenUrls.add(r.url)) citations.add(r);
        }
        yield StreamEvent.toolResult(
            toolId: c.toolId ?? '', content: outcome.content);
      }
    }

    if (citations.isNotEmpty) yield StreamEvent.citation(citations);
  }

  static List<Map<String, dynamic>> _protocolSnapshot(
          List<Map<String, dynamic>> messages) =>
      List.unmodifiable(messages.map(Map<String, dynamic>.unmodifiable));

  static String _operationKey(String name, Map<String, dynamic> arguments) {
    Object? canonical(Object? value) {
      if (value is Map) {
        final keys = value.keys.map((key) => key.toString()).toList()..sort();
        return {for (final key in keys) key: canonical(value[key])};
      }
      if (value is List) return value.map(canonical).toList();
      return value;
    }

    return '$name:${jsonEncode(canonical(arguments))}';
  }
}
