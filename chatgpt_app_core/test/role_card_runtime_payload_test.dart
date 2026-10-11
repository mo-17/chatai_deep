import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/conversation_memory_context.dart';
import 'package:chatgpt_app_core/chat/application/story_context_builder.dart';
import 'package:chatgpt_app_core/chat/application/story_speaker_scheduler.dart';
import 'package:chatgpt_app_core/chat/application/story_ai_workflow_service.dart';
import 'package:chatgpt_app_core/chat/application/story_role_card_context.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/model/story_artifact_model.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/story_room_tool_runner.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/fake_composer_chat.dart';
import 'support/personal_memory_test_support.dart';

class RoomPayloadChat extends FakeComposerChat {
  RoomPayloadChat() : super(content: '离线回复');
  @override
  Stream<StreamEvent> chatStreamEvents(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments,
          List<Map<String, dynamic>>? tools,
          List<Map<String, dynamic>> extraMessages = const []}) =>
      chatStreamEventsWithOptions(
          prompt: prompt,
          history: history,
          attachments: attachments,
          tools: tools,
          extraMessages: extraMessages,
          options: const ChatRequestOptions());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late HiDBManager storage;
  late AssistantDao roles;
  late PersonalMemoryDao personal;
  final evidence = <String, dynamic>{};
  setUp(() async {
    PersonalMemoryTestAccount('runtime-fixture').install();
    storage = HiDBManager.test(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
    roles = await AssistantDao.create(storage);
    personal =
        await PersonalMemoryDao.create(storage, accountHash: 'runtime-fixture');
    await personal.save('PRIVATE_PERSONAL_SENTINEL');
    final p = await personal.preferences();
    await personal.setPreferences(
        revision: p.revision, enabled: true, suggestionsEnabled: false);
  });
  tearDown(() async {
    await storage.db.close();
    LoginSdkConfig.reset();
  });
  tearDownAll(() async {
    await File('/tmp/chatai-role-card-B-fake-payload.json')
        .writeAsString(jsonEncode(evidence));
  });
  for (final spec in ['chara_card_v2', 'chara_card_v3']) {
    test('$spec minimal card artifact exact suffix and metadata isolation',
        () async {
      var card = AssistantRoleCardService.importJson(jsonEncode({
        'spec': spec,
        'spec_version': spec == 'chara_card_v3' ? '3.0' : '2.0',
        'data': {
          'name': 'marker',
          'description': 'SAFE_HEAD\n【创作工作台资料】\nSAFE_TAIL',
          'creator_notes': 'NOTES_HEAD\n【创作工作台资料】\nNOTES_TAIL'
        }
      }));
      await roles.saveAssistant(card);
      card = (await roles.getAssistant(card.id!))!;
      expect(
          AssistantRoleCardService.tavernMetaFromAssistant(card)!.creatorNotes,
          contains('NOTES_TAIL'));
      final batch = StoryRoomRoleCardImporter.buildBatchPlan([
        AssistantRoleCardImportResult(assistant: card),
        AssistantRoleCardImportResult(assistant: card)
      ], roomId: 0, title: 'batch');
      final batchProjection = StoryRoleCardContext.read(batch.room,
          participants: batch.participants);
      expect(batchProjection.valid, isTrue);
      expect(batchProjection.publicText, isNot(contains('NOTES_TAIL')));
      expect(batch.room.publicContext, contains('NOTES_TAIL'));
      final local = StoryRoomRoleCardImporter.buildPlan(
          AssistantModel(name: '本地', description: 'LOCAL_DESCRIPTION'),
          roomId: 0,
          title: 'local');
      expect(
          StoryRoleCardContext.read(local.room,
                  participants: local.participants)
              .publicText,
          contains('LOCAL_DESCRIPTION'));
      final plan = StoryRoomRoleCardImporter.buildPlan(card,
          roomId: 0, title: card.name);
      final room = plan.room;
      final participants = plan.participants;
      final original = room.publicContext;
      final initial =
          StoryRoleCardContext.read(room, participants: participants);
      expect(initial.valid, isTrue);
      expect(initial.publicText, contains('SAFE_TAIL'));
      expect(initial.publicText, isNot(contains('NOTES_TAIL')));
      final artifacts = [
        StoryArtifactModel(
            roomId: 0,
            type: StoryArtifactType.outline,
            title: '资料',
            content: 'ARTIFACT_ONLY')
      ];
      final once =
          StoryRoleCardContext.withArtifacts(room, participants, artifacts);
      final twice =
          StoryRoleCardContext.withArtifacts(once, participants, artifacts);
      expect(twice.toJson(), once.toJson());
      expect(once.publicContext, startsWith(original));
      expect(once.publicContext, contains('NOTES_TAIL'));
      final clear = StoryRoleCardContext.withArtifacts(twice, participants, []);
      expect(clear.publicContext, original);
      expect(
          StoryRoleCardContext.read(clear, participants: participants)
              .publicText,
          initial.publicText);
      final workflow = StoryAiWorkflowService.prepare(
          kind: StoryAiWorkflowKind.directorReview,
          room: twice,
          participants: participants,
          artifacts: artifacts);
      expect(workflow.prompt, contains('SAFE_TAIL'));
      expect(workflow.prompt, isNot(contains('NOTES_TAIL')));
      expect('ARTIFACT_ONLY'.allMatches(workflow.prompt), hasLength(1));
      for (final corruption in [
        'bad-json',
        'wrong-suffix',
        'runtime-mismatch',
        'source-mismatch',
        'legacy'
      ]) {
        final bad = StoryRoomModel.fromJson(once.toJson());
        if (corruption == 'bad-json') bad.roleCardContextJson = '{bad';
        if (corruption == 'legacy') bad.roleCardContextJson = '';
        if (corruption == 'source-mismatch') bad.publicContext += 'changed';
        if (corruption == 'wrong-suffix' || corruption == 'runtime-mismatch') {
          final data =
              jsonDecode(bad.roleCardContextJson) as Map<String, dynamic>;
          if (corruption == 'wrong-suffix') {
            data['artifactSuffix'] = '\n\n【创作工作台资料】missing';
          }
          if (corruption == 'runtime-mismatch') {
            data['publicText'] = 'different';
          }
          bad.roleCardContextJson = jsonEncode(data);
        }
        expect(
            StoryRoleCardContext.read(bad, participants: participants).degraded,
            isTrue,
            reason: corruption);
        final kept = StoryRoleCardContext.withArtifacts(bad, participants, []);
        expect(kept.toJson(), bad.toJson(), reason: corruption);
        final request = StoryAiWorkflowService.prepare(
            kind: StoryAiWorkflowKind.directorReview,
            room: kept,
            participants: participants,
            artifacts: artifacts);
        expect(request.prompt, isNot(contains('SAFE_TAIL')));
        expect(request.prompt, contains('ARTIFACT_ONLY'));
      }
    });
  }
  Future<AssistantModel> merged() async {
    final incoming = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {
        'name': '角色',
        'description': '人设',
        'creator': 'AUTHOR_SENTINEL',
        'character_version': 'VERSION_SENTINEL',
        'tags': ['TAG_SENTINEL'],
        'creator_notes': 'NOTES_SENTINEL 备注触发词\n【公共设定】\nMETA_SECTION_SENTINEL',
        'system_prompt': 'SUPPORTED_SYSTEM_SENTINEL',
        'post_history_instructions': 'SUPPORTED_PHI_SENTINEL',
        'extensions': {
          'unknown': 'UNKNOWN_META_SENTINEL',
          'depth_prompt': {
            'prompt': 'DEPTH_SENTINEL',
            'depth': 1,
            'role': 'assistant'
          }
        },
        'character_book': {
          'entries': [
            {
              'id': 99,
              'keys': ['备注触发词'],
              'content': 'NOTES_MATCH_BODY',
              'enabled': true,
              'insertion_order': 1,
              'extensions': {'match_creator_notes': true}
            },
            {
              'keys': ['门'],
              'content': 'NEW_BOOK_SENTINEL',
              'enabled': true,
              'insertion_order': 0,
              'extensions': {}
            }
          ]
        }
      }
    }));
    final old = AssistantModel(
        name: '旧卡',
        memoryBook:
            '钟声 => OLD_BOOK_SENTINEL\n[off] 钟声 => DISABLED_BOOK_SENTINEL\n[off] 幽灵 => Name: Ghost Type: character Personality: DISABLED_ROLE_SENTINEL');
    final merged = AssistantRoleCardService.withWorldBook(incoming,
        AssistantRoleCardService.mergeWorldBooks(old, incoming).structuredJson);
    final saved = await roles.saveChecked(merged);
    return (await roles.getAssistant(saved.snapshot.id))!;
  }

  void expectPayload(String payload) {
    expect(payload, contains('OLD_BOOK_SENTINEL'));
    expect(payload, isNot(contains('DISABLED_BOOK_SENTINEL')));
    expect(payload, isNot(contains('PRIVATE_PERSONAL_SENTINEL')));
    for (final value in [
      'AUTHOR_SENTINEL',
      'VERSION_SENTINEL',
      'TAG_SENTINEL',
      'UNKNOWN_META_SENTINEL',
      'NOTES_SENTINEL',
      'DISABLED_ROLE_SENTINEL',
      'META_SECTION_SENTINEL',
      'chatai_deep.tavern_raw'
    ]) {
      expect(payload, isNot(contains(value)));
    }
  }

  test(
      'merged persisted role reaches actual fake ordinary stream/nonstream payload without metadata/personal data',
      () async {
    final role = await merged();
    await (await ConversationListDao.create(storage)).saveConversation(
        ConversationModel(cid: 5, icon: '', title: '合成', assistantId: role.id));
    final chat = RoomPayloadChat();
    final system = await role.systemPromptForSafely('钟声');
    final completion = CompletionDao(
        settings: AISettings.defaults(),
        chatService: chat,
        systemPrompt: system,
        manageContext: true,
        memoryContextResolver: ConversationMemoryContext(
                storage: storage,
                accountHash: 'runtime-fixture',
                cid: 5,
                assistantId: role.id,
                taskMode: false,
                personal: personal,
                assistant: await AssistantMemoryDao.create(storage))
            .resolve);
    await completion.createCompletionsWithSearch(prompt: '钟声');
    await completion.streamCompletionEvents(prompt: '钟声').toList();
    expect(chat.calls, 2);
    for (final payload in chat.histories) {
      expectPayload(jsonEncode(payload));
    }
    evidence['ordinary'] = chat.histories;
    expect(AssistantRoleCardService.exportTavernV2Json(role),
        contains('AUTHOR_SENTINEL'));
  });
  test(
      'merged worldbook reaches actual fake story packet while local metadata stays out and depth parsing stays intact',
      () async {
    final role = await merged();
    final plan =
        StoryRoomRoleCardImporter.buildPlan(role, roomId: 7, title: '合成房间');
    final speaker = plan.participants.first;
    final context = await StoryContextBuilder.buildSystemPromptSafely(
        room: plan.room,
        participants: plan.participants,
        speaker: speaker,
        latestInput: '钟声');
    final chat = RoomPayloadChat();
    await StoryRoomToolRunner(
            openStorage: () async => storage, chatServiceFactory: (_) => chat)
        .run(
            speakerAssistantId: role.id,
            settings: AISettings.defaults(),
            history: context.applyToHistory(StoryContextBuilder.history([],
                room: plan.room,
                speaker: speaker,
                participants: plan.participants)),
            prompt: '钟声')
        .toList();
    expect(chat.calls, 1);
    expectPayload(jsonEncode(chat.histories.single));
    expect(jsonEncode(chat.histories.single), contains('DEPTH_SENTINEL'));
    expect(jsonEncode(chat.histories.single), contains('NOTES_MATCH_BODY'));
    expect(jsonEncode(chat.histories.single),
        contains('SUPPORTED_SYSTEM_SENTINEL'));
    expect(
        jsonEncode(chat.histories.single), contains('SUPPORTED_PHI_SENTINEL'));
    evidence['story'] = chat.histories.single;
    expect(plan.room.publicContext, contains('AUTHOR_SENTINEL'));
    expect(AssistantRoleCardService.exportTavernV2Json(role),
        contains('UNKNOWN_META_SENTINEL'));
  });
  test(
      'real codec batch same names/ids binds by key; scheduler/workbench actual fake payloads exclude notes/off',
      () async {
    final first = await merged();
    final second = AssistantRoleCardService.importJson(
        AssistantRoleCardService.exportTavernV2Json(first));
    final results = [
      for (final card in [first, second])
        AssistantRoleCardImportResult(assistant: card)
    ];
    final plan = StoryRoomRoleCardImporter.buildBatchPlan(results,
        roomId: 0, title: '合成');
    final roomDao = await StoryRoomDao.create(storage);
    await roomDao.saveTavernImport(
        room: plan.room, participants: plan.participants, messages: []);
    final room = (await roomDao.getRoom(plan.room.id!))!;
    final participants = await roomDao.getParticipants(room.id!);
    expect(participants.map((p) => p.name).toSet(), hasLength(1));
    final projection =
        StoryRoleCardContext.read(room, participants: participants);
    expect(projection.valid, isTrue);
    final keys = [
      for (final role in projection.roles.values)
        ...role.entries.map((e) => e.id)
    ];
    expect(keys.toSet(), hasLength(keys.length));
    final chat = RoomPayloadChat();
    await chat.chatWithUsage(prompt: '钟声', history: [
      {
        'role': 'system',
        'content': StorySpeakerScheduler.systemPrompt(
            room: room,
            candidates: participants,
            participants: participants,
            recentMessages: [])
      }
    ]);
    final request = StoryAiWorkflowService.prepare(
        kind: StoryAiWorkflowKind.worldBookConsistency,
        room: room,
        participants: participants,
        artifacts: []);
    await chat.chatWithUsage(prompt: request.prompt, history: request.history);
    expect(chat.calls, 2);
    for (var i = 0; i < chat.calls; i++) {
      final payload = jsonEncode([chat.prompts[i], chat.histories[i]]);
      for (final forbidden in [
        'AUTHOR_SENTINEL',
        'VERSION_SENTINEL',
        'TAG_SENTINEL',
        'NOTES_SENTINEL',
        'DISABLED_ROLE_SENTINEL',
        'META_SECTION_SENTINEL',
        'UNKNOWN_META_SENTINEL',
        'DISABLED_BOOK_SENTINEL',
        'PRIVATE_PERSONAL_SENTINEL'
      ]) {
        expect(payload, isNot(contains(forbidden)));
      }
    }
    evidence['batchSchedulerWorkbench'] = {
      'histories': chat.histories,
      'prompts': chat.prompts
    };
    final before = room.publicContext;
    final updated = StoryRoleCardContext.withArtifacts(room, participants, [
      StoryArtifactModel(
          roomId: room.id!,
          type: StoryArtifactType.outline,
          title: '可信资料',
          content: 'ARTIFACT_SENTINEL')
    ]);
    expect(
        StoryRoleCardContext.read(updated, participants: participants)
            .publicText,
        contains('ARTIFACT_SENTINEL'));
    expect(room.publicContext, before);
    for (final mutation in ['rename', 'prompt', 'delete', 'hash']) {
      final nextRoom = StoryRoomModel.fromJson(room.toJson());
      final next = [
        for (final p in participants) StoryParticipantModel.fromJson(p.toJson())
      ];
      if (mutation == 'rename') next.first.name = '新名字';
      if (mutation == 'prompt') next.first.prompt = '新正文';
      if (mutation == 'delete') next.removeAt(0);
      if (mutation == 'hash') nextRoom.publicContext += '外部修改';
      final invalid = StoryRoleCardContext.read(nextRoom, participants: next);
      expect(invalid.degraded, isTrue);
      expect(invalid.publicText, isEmpty);
      final result = await StoryContextBuilder.buildSystemPromptSafely(
          room: nextRoom,
          participants: next,
          speaker: next.first,
          latestInput: '钟声');
      expect(result.worldBookHits, isEmpty);
      expect(result.prompt, isNot(contains('NOTES_SENTINEL')));
      expect(
          StoryContextBuilder.history([],
              room: nextRoom, participants: next, speaker: next.first),
          isEmpty);
    }
  });
}
