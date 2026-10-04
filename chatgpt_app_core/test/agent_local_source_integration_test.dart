import 'dart:convert';

import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/application/tool_loop_runner.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/local_source_citation.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('real file reads persist citations and replay without a new request',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final storage = HiDBManager.test(db);
    final workspace = await AgentWorkspaceService.create(storage, cid: 7);
    final file = await workspace.importText(
        name: '小说.txt', content: '第一章\n这是实际保存的原文😀。\n第二章\n新的故事。');
    final workspaceTools =
        await AgentWorkspaceTools.create(storage, cid: 7, workspace: workspace);
    await workspaceTools.beginTurn(101, [file.id]);
    final read = workspaceTools.tools.singleWhere((t) => t.name == 'read_file');
    var executions = 0;
    final registry = ToolRegistry([
      ChatTool(
        name: read.name,
        description: read.description,
        parameters: read.parameters,
        execute: (args) async {
          executions++;
          return read.execute(args);
        },
      ),
    ]);
    final store = await AgentTaskDao.create(storage);
    final task = AgentTaskSession(cid: 7, store: store);
    addTearDown(task.dispose);
    await task.setEnabled(true);
    await task.begin(userAt: 101, input: '引用原文分析');
    final service = _ReadService(file.id);
    final events = await ToolLoopRunner(
      chatService: service,
      registry: registry,
    ).run(prompt: task.prompt, history: const [], task: task).toList();
    final sources = [for (final event in events) ...?event.localSources];
    expect(executions, 2);
    expect(service.requests, 3);
    expect(sources, isNotEmpty);
    expect(sources.map((s) => s.sourceId).toSet(), hasLength(1));
    expect(sources.first.quote, contains('实际保存的原文'));
    final source = sources.first;
    expect(task.messages.last['content'], contains(source.marker));
    expect(events.indexWhere((e) => e.localSources?.isNotEmpty == true),
        lessThan(events.indexWhere((e) => e.type == StreamEventType.text)));
    await task.finish(complete: false);
    await task.flush();

    final reopened = AgentTaskSession(cid: 7, store: store);
    addTearDown(reopened.dispose);
    await reopened.load();
    await reopened.begin(userAt: 101, input: reopened.prompt, resume: true);
    final noRequests = _ReadService(file.id, rejectRequests: true);
    final replayed = await ToolLoopRunner(
      chatService: noRequests,
      registry: registry,
    ).run(prompt: reopened.prompt, history: const [], task: reopened).toList();
    expect(noRequests.requests, 0);
    expect(executions, 2);
    expect(
        [for (final event in replayed) ...?event.localSources]
            .map((s) => s.sourceId)
            .toSet(),
        {source.sourceId});
    expect(replayed.where((e) => e.type == StreamEventType.text).single.delta,
        contains(source.marker));
  });

  test(
      'backup remaps owned citations without changing markers or ordinary text',
      () {
    final source = _source();
    final message = _message(source);
    final remapped =
        BackupService.remapWorkspaceMessageReferences(message, files: const [
      {'id': 1, 'cid': 7}
    ], fileIdMap: const {
      1: 91
    }, cidMap: const {
      7: 70
    });
    final citation = _citation(remapped);
    expect(citation.cid, 70);
    expect(citation.fileId, 91);
    expect(citation.sourceId, source.sourceId);
    expect(citation.marker, source.marker);
    expect(citation.rangeHash, source.rangeHash);
    expect(citation.quote, source.quote);
    expect(citation.revision, source.revision);
    expect(citation.available, isTrue);
    expect(remapped['content'], message['content']);
  });

  test(
      'missing workspace cannot retarget a citation to a same-number local file',
      () {
    final source = _source();
    final remapped = BackupService.remapWorkspaceMessageReferences(
        _message(source),
        files: const [],
        fileIdMap: const {1: 1},
        cidMap: const {7: 7});
    final citation = _citation(remapped);
    expect(citation.available, isFalse);
    expect(citation.marker, source.marker);
    expect(citation.quote, source.quote);
  });

  test('a forged cross-conversation citation remains unavailable after import',
      () {
    final source = _source(cid: 8);
    final remapped = BackupService.remapWorkspaceMessageReferences(
        _message(source),
        files: const [
          {'id': 1, 'cid': 7}
        ],
        fileIdMap: const {
          1: 91
        },
        cidMap: const {
          7: 70,
          8: 80
        });
    expect(_citation(remapped).available, isFalse);
  });

  test('remapping does not re-enable an already unavailable citation', () {
    final source = _source().remap(cid: null, fileId: null);
    final remapped = BackupService.remapWorkspaceMessageReferences(
        _message(source),
        files: const [
          {'id': 1, 'cid': 7}
        ],
        fileIdMap: const {
          1: 91
        },
        cidMap: const {
          7: 70
        });
    expect(_citation(remapped).available, isFalse);
  });

  test('legacy blocks with no local sources stay byte-for-byte unchanged', () {
    final message = {
      'cid': 7,
      'content': '旧对话 1 7 91',
      'blocks': '[{"type":"citation","id":"old","results":[]}]',
    };
    expect(
        BackupService.remapWorkspaceMessageReferences(message,
            files: const [], fileIdMap: const {}, cidMap: const {7: 70}),
        message);
  });
}

LocalSourceCitation _source({int cid = 7}) => LocalSourceCitation.forRead(
    cid: cid,
    fileId: 1,
    revision: 2,
    fileName: '小说.txt',
    startOffset: 5,
    content: '这是需要查证的原文😀。');

Map<String, dynamic> _message(LocalSourceCitation source) => {
      'cid': 7,
      'content': '${source.marker} 原文分析与普通数字 1 7 91',
      'blocks': jsonEncode([
        {
          'id': 'sources',
          'type': 'citation',
          'results': [],
          'localSources': [source.toJson()],
        }
      ]),
    };

LocalSourceCitation _citation(Map<String, dynamic> message) {
  final blocks = jsonDecode(message['blocks'] as String) as List;
  return LocalSourceCitation.tryFromJson(blocks.single['localSources'].single)!;
}

class _ReadService implements ChatService {
  final int fileId;
  final bool rejectRequests;
  int requests = 0;
  _ReadService(this.fileId, {this.rejectRequests = false});

  @override
  ModelCapabilities get capabilities => const ModelCapabilities(tool: true);

  @override
  Stream<StreamEvent> chatStreamEvents({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
  }) async* {
    if (rejectRequests) throw StateError('cached completion must not request');
    final index = requests++;
    if (index < 2) {
      yield StreamEvent.toolCall(
          toolId: 'read-$index',
          name: 'read_file',
          arguments: {'file_id': fileId});
      return;
    }
    final saved = extraMessages.firstWhere((m) => m['role'] == 'tool');
    final source = LocalSourceCitation.fromToolResult(
        toolName: 'read_file', content: saved['content'], expectedCid: 7)!;
    yield StreamEvent.text('分析结论 ${source.marker}');
  }

  @override
  Future<String?> chat(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments,
          Duration? timeout}) async =>
      null;

  @override
  Future<ChatCompletionResult> chatWithUsage(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments}) async =>
      const ChatCompletionResult(content: null);

  @override
  Stream<String> chatStream(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments}) =>
      const Stream.empty();
}
