import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/application/tool_loop_runner.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';

/// 每节点独立 session；存储适配只接受受限 checkpoint，不写旧 cid 主键表。
class WorkflowToolLoop {
  final int cid, userCreatedAt;
  final WorkflowStep node;
  final List<WorkflowInputRef> inputs;
  final AgentWorkspaceTools workspace;
  final ChatService service;
  final ChatRequestOptions options;
  final Future<void> Function(String name, int? fileId) verifyTool;
  final Future<void> Function(Map<String, dynamic> value, int rounds)
      checkpoint;
  final Future<void> Function(ChatCompletionResult result) finishToolRequest;
  final void Function() guard;
  final int usedOutputCharacters;
  WorkflowToolLoop(
      {required this.cid,
      required this.userCreatedAt,
      required this.node,
      required this.inputs,
      required this.workspace,
      required this.service,
      required this.options,
      required this.verifyTool,
      required this.checkpoint,
      required this.finishToolRequest,
      this.usedOutputCharacters = 0,
      required this.guard});

  Future<ChatCompletionResult> run(
      String prompt, List<Map<String, dynamic>> history) async {
    final registry = ToolRegistry([
      for (final tool in workspace.tools)
        if (node.tools.contains(tool.name) &&
            const {'list_files', 'read_file', 'file_search'}
                .contains(tool.name))
          ChatTool(
              name: tool.name,
              description: tool.description,
              parameters: tool.parameters,
              execute: (args) async {
                final id = args['file_id'];
                if (tool.name != 'list_files' && id is! int) {
                  throw const FormatException('文件标识须为整数');
                }
                await verifyTool(tool.name, id is int ? id : null);
                guard();
                final ToolOutcome result;
                if (tool.name == 'list_files') {
                  final offset = args['offset'] ?? 0;
                  final limit = args['limit'] ?? 50;
                  if (offset is! int ||
                      limit is! int ||
                      offset < 0 ||
                      limit < 1 ||
                      limit > 50) {
                    throw const FormatException('分页范围无效');
                  }
                  final files = [];
                  for (final input in inputs.skip(offset).take(limit)) {
                    final file =
                        await workspace.workspace.getFile(input.fileId);
                    guard();
                    if (file == null || file.revision != input.revision) {
                      throw const WorkflowStale('输入版本已变化');
                    }
                    files.add({
                      'id': file.id,
                      'name': file.name,
                      'revision': file.revision,
                      'characterCount': file.characterCount
                    });
                  }
                  final next = offset + files.length;
                  result = ToolOutcome(
                      content: jsonEncode({
                    'files': files,
                    'totalFiles': inputs.length,
                    'nextOffset': next < inputs.length ? next : null
                  }));
                } else {
                  result = await tool.execute(args);
                }
                await verifyTool(tool.name, id is int ? id : null);
                return result;
              }),
    ]);
    final task = AgentTaskSession(cid: cid, store: _NodeStore(checkpoint))
      ..enabled = true
      ..status = 'running'
      ..generation = 1
      ..userCreatedAt = userCreatedAt
      ..prompt = prompt
      ..messages = [
        for (final m in node.checkpoint?['messages'] as List? ?? const [])
          (m as Map).cast<String, dynamic>()
      ]
      ..nextRound = node.checkpoint?['nextRound'] as int? ?? 0;
    final bounded = _NodeStreamingService(
        service, options, finishToolRequest, guard, usedOutputCharacters);
    await for (final _ in ToolLoopRunner(
            chatService: bounded,
            registry: registry,
            toolRoundLimit: WorkflowBudget.toolRoundsPerStep)
        .run(
            prompt: prompt,
            history: history,
            abortTrigger: options.abortTrigger,
            task: task)) {
      guard();
    }
    guard();
    return bounded.finalResult ?? (throw const FormatException('工具收尾未返回最终正文'));
  }
}

class _NodeStore implements IAgentTaskStore {
  final Future<void> Function(Map<String, dynamic>, int) save;
  _NodeStore(this.save);
  @override
  Future<Map<String, dynamic>?> read(int cid) async => null;
  @override
  Future<void> write(int cid, Map<String, dynamic> value) => save({
        'version': 1,
        'messages': value['messages'],
        'nextRound': value['nextRound'],
        'executingToolId': value['executingToolId'],
      }, value['nextRound'] as int);
}

/// 在工具动作之前保存当前请求用量；最终请求由父协调器原子提交节点结果。
class _NodeStreamingService
    implements ChatService, AttemptAwareChatService, OptionsAwareChatService {
  final ChatService inner;
  final ChatRequestOptions budgetOptions;
  final Future<void> Function(ChatCompletionResult) finishToolRequest;
  final void Function() guard;
  ChatCompletionResult? finalResult;
  int usedCharacters;
  _NodeStreamingService(this.inner, this.budgetOptions, this.finishToolRequest,
      this.guard, this.usedCharacters);
  @override
  ModelCapabilities get capabilities => inner.capabilities;
  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    guard();
    var calls = 0;
    final text = StringBuffer();
    int? input, output;
    await for (final event in inner.chatStreamEventsWithOptions(
        prompt: prompt,
        history: history,
        attachments: attachments,
        tools: tools,
        extraMessages: extraMessages,
        options: budgetOptions)) {
      guard();
      if (event.type == StreamEventType.text) {
        text.write(event.delta);
        if (usedCharacters + text.length > WorkflowBudget.outputCharacters) {
          throw const FormatException('节点输出超限');
        }
      }
      if (event.type == StreamEventType.toolCall && ++calls > 4) {
        throw const FormatException('单轮工具调用超过4项');
      }
      if (event.type == StreamEventType.usage) {
        input = event.promptTokens;
        output = event.completionTokens;
      }
      yield event;
    }
    guard();
    final result = ChatCompletionResult(
        content: text.toString(),
        promptTokens: input,
        completionTokens: output);
    usedCharacters += text.length;
    if (calls > 0) {
      if (tools == null || tools.isEmpty) {
        throw const FormatException('工具额度已用尽，不能接受新调用');
      }
      await finishToolRequest(result);
    } else {
      finalResult = result;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
