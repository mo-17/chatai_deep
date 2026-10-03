import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
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
    final extraMessages = <Map<String, dynamic>>[];
    // 汇总各轮联网搜索来源（按 URL 去重），收尾发一次 citation 事件。
    final citations = <WebSearchResult>[];
    final seenUrls = <String>{};

    for (var round = 0;; round++) {
      ensureRunning();
      final calls = <StreamEvent>[];
      // 本轮正文缓存：回灌 assistant 消息时带上（模型边说边调用的场景）。
      final textBuf = StringBuffer();
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
        }
        yield e; // toolCall 也原样上抛 -> UI 立即出现 processing 态 ToolBlock
      }
      ensureRunning();
      if (calls.isEmpty) break; // 模型不再调用工具，正文已输出完毕
      // 硬性保护：已到无 tools 的收尾轮仍收到调用（上游异常），直接终止。
      if (round >= maxRounds) break;

      AILogger.log('tool round $round: ${calls.length} call(s)');
      extraMessages.add({
        'role': 'assistant',
        'content': textBuf.isEmpty ? null : textBuf.toString(),
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
      for (final c in calls) {
        ensureRunning();
        onProgress?.call(ChatSendProgress('执行工具', fileName: c.toolName));
        final outcome = await registry.execute(
            c.toolName ?? '', c.toolArguments ?? const {});
        ensureRunning();
        extraMessages.add({
          'role': 'tool',
          'tool_call_id': c.toolId,
          'content': outcome.content,
        });
        for (final r in outcome.webResults) {
          if (r.url.isNotEmpty && seenUrls.add(r.url)) citations.add(r);
        }
        yield StreamEvent.toolResult(
            toolId: c.toolId ?? '', content: outcome.content);
      }
    }

    if (citations.isNotEmpty) yield StreamEvent.citation(citations);
  }
}
