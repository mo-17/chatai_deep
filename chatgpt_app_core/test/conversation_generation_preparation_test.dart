import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:chatgpt_app_core/chat/application/conversation_attachment_ocr.dart';
import 'package:chatgpt_app_core/chat/application/server_ocr_client.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/conversation_composer_preparation.dart';
import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_profile.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/composer_reference.dart';
import 'package:chatgpt_app_core/chat/domain/conversation_generation.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/conversation_generation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'conversation_generation_test.dart' as support;

class _Chat
    implements
        ChatService,
        AttemptAwareChatService,
        OptionsAwareChatService,
        OptionsAwareNonStreamingChatService {
  int requests = 0;
  final release = Completer<void>();
  ChatAttachments? attachments;
  @override
  ModelCapabilities get capabilities => const ModelCapabilities();
  Future<void> request(String prompt, List<Map<String, dynamic>> history,
      ChatAttachments? attachments, ChatRequestOptions options) async {
    await options.resolveAttemptMessages([
      ...history,
      {'role': 'user', 'content': prompt}
    ]);
    this.attachments = attachments;
    requests++;
    await Future.any([release.future, options.abortTrigger!]);
  }

  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    await request(prompt, history, attachments, options);
    yield StreamEvent.text('SYNTHETIC_REPLY');
  }

  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      required ChatRequestOptions options}) async {
    await request(prompt, history, attachments, options);
    return const ChatCompletionResult(content: 'SYNTHETIC_REPLY');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> eventually(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('IO gate');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HiDBManager storage;
  late ConversationGenerationDao dao;
  late ConversationGenerationService service;
  late AISettings settings;
  late _Chat chat;
  late Directory base, resources;
  late int conversationId;
  ConversationDraftStore draft([String account = 'a', int cid = 1]) =>
      ConversationDraftStore(
          conversationId: cid.toString(),
          accountHash: account,
          directoryResolver: () async => base);
  MessageModel user(String text) => MessageModel(
      ownerType: OwnerType.sender,
      ownerName: '合成用户',
      avatar: 'synthetic-avatar',
      content: text,
      createdAt: 10);
  ConversationGenerationRun start(ConversationTurnPreparation prep,
          {int cid = 1,
          int? rowId,
          ConversationModel? birth,
          MessageModel? source,
          int? sourceRowId,
          String? sourceId,
          String? sourceHash,
          int? replyId,
          String? replyHash}) =>
      service.start(
          scope: ConversationGenerationScope(account: 'a'),
          dao: dao,
          profile: ConversationGenerationProfile(settings, 'a',
              loadSettings: () async => settings),
          input: ConversationGenerationInput(
              cid: cid,
              conversationRowId: birth == null ? rowId ?? conversationId : null,
              newConversation: birth,
              user: source ?? user('task'),
              existingUserRowId: sourceRowId,
              existingSourceId: sourceId,
              existingSourceRowHash: sourceHash,
              retryReplyRowId: replyId,
              retryReplyHash: replyHash),
          preparation: prep);
  setUp(() async {
    LoginDao.resetHooksForTest();
    support.GenerationTestAuth().install();
    sqfliteFfiInit();
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    conversationId = (await (await ConversationListDao.create(storage))
        .saveConversation(
            ConversationModel(cid: 1, title: 'existing', icon: '')))!;
    dao = await ConversationGenerationDao.create(storage);
    settings = support.generationSettings();
    chat = _Chat();
    service = ConversationGenerationService(
        createChat: (_) => chat, createMemory: (_) async => null);
    base = await Directory.systemTemp.createTemp('chatai_l2_drafts_');
    resources = await Directory.systemTemp.createTemp('chatai_l2_resources_');
    ManagedAttachmentStore.debugRootDirectory = resources;
  });
  tearDown(() async {
    for (final run in service.runs.where((r) => r.busy)) {
      await run.retire('synthetic cleanup').timeout(const Duration(seconds: 3));
    }
    service.dispose();
    await storage.db.close();
    ManagedAttachmentStore.debugRootDirectory = null;
    await base.delete(recursive: true);
    await resources.delete(recursive: true);
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
  });
  test('OCR 上传须经 run 确认，识别文字随用户消息落库并发送模型', () async {
    final pick = await File('${base.path}/scan.png').writeAsBytes([1, 2, 3]);
    await draft().save(text: 'task', files: [pick.path]);
    final calls = <http.Request>[];
    final prep = ComposerGenerationPreparation(
        draftStore: draft(),
        text: 'task',
        files: [pick.path],
        resourceRoot: () async => resources,
        createOcr: (run) => ConversationAttachmentOcr.forRun(run,
            createClient: () => ServerOcrClient(
                base: Uri.parse('https://captured.example/uapi/ocr/'),
                headers: const {'Authorization': 'Bearer synthetic'},
                isCurrent: () => run.current,
                clientFactory: () => MockClient((request) async {
                      calls.add(request);
                      return http.Response(
                          jsonEncode({
                            'code': 0,
                            'data': {
                              'id': request.url.pathSegments.last,
                              'state': request.method == 'DELETE'
                                  ? 'cancelled'
                                  : 'completed',
                              if (request.method != 'DELETE')
                                'result': {
                                  'totalPages': 1,
                                  'pages': [
                                    {'page': 1, 'text': 'OCR SOURCE TEXT'}
                                  ]
                                },
                            }
                          }),
                          200);
                    }))));
    final run = start(prep);
    final host = Object();
    run.attachVisibleHost(host);
    await support.waitGeneration(() => run.confirmation != null);
    expect(run.confirmation!.title, '服务器 OCR 上传确认');
    expect(calls, isEmpty);
    expect(chat.requests, 0);
    expect(await storage.db.query('tb_messages'), isEmpty);
    await run.answerConfirmation(
        host: host, confirmationId: run.confirmation!.id, accepted: true);
    await support.waitGeneration(() => chat.requests == 1);
    expect(calls.map((r) => r.method), ['POST', 'DELETE']);
    expect(chat.attachments!.extraText, contains('OCR SOURCE TEXT'));
    expect(chat.attachments!.images, isEmpty);
    final rows = await storage.db
        .query('tb_messages', where: 'content=?', whereArgs: ['task']);
    final blocks = MessageBlock.decodeList(rows.single['blocks'] as String?);
    final meta = blocks.whereType<FileBlock>().single.file;
    expect(meta.extractedText, chat.attachments!.extraText);
    expect(meta.mime, 'image/png');
    expect(run.inputConsumed, true);
    chat.release.complete();
    await run.finished.timeout(const Duration(seconds: 4));
    expect(
        run.completion!.attachmentsForUserMessage(run.acceptedUser!).extraText,
        contains('OCR SOURCE TEXT'));
  });

  test('拒绝 OCR 确认不上传不请求模型，原草稿和原件保留', () async {
    final pick = await File('${base.path}/scan.png').writeAsBytes([1, 2, 3]);
    await draft().save(text: 'task', files: [pick.path]);
    var uploads = 0;
    final prep = ComposerGenerationPreparation(
        draftStore: draft(),
        text: 'task',
        files: [pick.path],
        resourceRoot: () async => resources,
        createOcr: (run) => ConversationAttachmentOcr.forRun(run,
            createClient: () => ServerOcrClient(
                base: Uri.parse('https://captured.example/uapi/ocr/'),
                headers: const {},
                isCurrent: () => run.current,
                clientFactory: () => MockClient((_) async {
                      uploads++;
                      throw StateError('must not upload');
                    }))));
    final run = start(prep);
    final host = Object();
    run.attachVisibleHost(host);
    await support.waitGeneration(() => run.confirmation != null);
    await run.answerConfirmation(
        host: host, confirmationId: run.confirmation!.id, accepted: false);
    await run.finished.timeout(const Duration(seconds: 4));
    expect(uploads, 0);
    expect(chat.requests, 0);
    expect(run.notice, contains('已取消服务器 OCR'));
    expect(run.inputConsumed, false);
    expect(await storage.db.query('tb_messages'), isEmpty);
    expect((await draft().load())!.text, 'task');
    expect(await pick.exists(), true);
  });

  test(
      'unaccepted absent slot restores text and attachment after preparation failure',
      () async {
    final pick = File('${base.path}/original.txt');
    await pick.writeAsString('ORIGINAL_BYTES');
    final run = start(ComposerGenerationPreparation(
        draftStore: draft(),
        text: 'task',
        files: [pick.path],
        resourceRoot: () => Future.error(
            const FileSystemException('synthetic preparation failure'))));
    await run.finished.timeout(const Duration(seconds: 4));
    expect(run.inputConsumed, false);
    expect(chat.requests, 0);
    expect(await storage.db.query('tb_messages'), isEmpty);
    final restored = await draft().load();
    expect(restored!.text, 'task');
    expect(restored.missingAttachmentCount, 0);
    expect(
        await File(restored.filePaths.single).readAsString(), 'ORIGINAL_BYTES');
    expect(await pick.readAsString(), 'ORIGINAL_BYTES');
    final retry = start(ComposerGenerationPreparation(
        draftStore: draft(), text: 'task', files: restored.filePaths));
    await support.waitGeneration(() => chat.requests == 1);
    chat.release.complete();
    await retry.finished;
    expect(retry.inputConsumed, true);
    expect(await draft().load(), isNull);
    final path =
        retry.acceptedUserBlocks.whereType<FileBlock>().single.file.path!;
    expect(await File(path).readAsString(), 'ORIGINAL_BYTES');
  });

  test(
      'superseded identical text slot and new attachment beat failed submission',
      () async {
    final old = File('${base.path}/old.txt')..writeAsStringSync('OLD');
    final fresh = File('${base.path}/new.txt')..writeAsStringSync('NEW');
    final entered = Completer<void>(), release = Completer<Directory>();
    final prep = ComposerGenerationPreparation(
        draftStore: draft(),
        text: 'task',
        files: [old.path],
        resourceRoot: () {
          entered.complete();
          return release.future;
        });
    final run = start(prep);
    await entered.future;
    final newer = await draft().save(text: 'task', files: [fresh.path]);
    release.completeError(const FileSystemException('failed old preparation'));
    await run.finished;
    final actual = await draft().load();
    expect(run.inputConsumed, false);
    expect(chat.requests, 0);
    expect(actual!.filePaths, newer!.filePaths);
    expect(await File(actual.filePaths.single).readAsString(), 'NEW');
    expect(await old.exists(), true);
  });

  test('capture read failure cannot claim an absent slot for fallback',
      () async {
    final pick = File('${base.path}/original.txt')
      ..writeAsStringSync('UNCHANGED');
    final broken = ConversationDraftStore(
        accountHash: 'a',
        conversationId: '1',
        directoryResolver: () =>
            Future.error(const FileSystemException('unreadable directory')));
    final run = start(ComposerGenerationPreparation(
        draftStore: broken,
        text: 'task',
        files: [pick.path],
        resourceRoot: () =>
            Future.error(const FileSystemException('preparation failure'))));
    await run.finished;
    expect(run.inputConsumed, false);
    expect(chat.requests, 0);
    expect(await draft().load(), isNull);
    expect(await pick.readAsString(), 'UNCHANGED');
    expect(run.notice, contains('无法回存'));
  });

  test('capture superseded during resolver never claims missing slot',
      () async {
    final resolver = Completer<Directory>();
    final old = ConversationDraftStore(
        accountHash: 'a',
        conversationId: '1',
        directoryResolver: () => resolver.future);
    final capture = old.captureSubmission(verify: () {});
    final newer = await draft().save(text: 'task');
    resolver.complete(base);
    expect(await capture, isNull);
    expect((await draft().load())!.text, newer!.text);
  });

  test(
      'ordinary stop settles held unaccepted fallback with no late draft write',
      () async {
    final resolver = Completer<Directory>();
    final s = ConversationDraftStore(
        accountHash: 'a',
        conversationId: '1',
        directoryResolver: () => resolver.future);
    final pick = File('${base.path}/original.txt')
      ..writeAsStringSync('ORIGINAL');
    final entered = Completer<void>(), release = Completer<Directory>();
    final run = start(ComposerGenerationPreparation(
        draftStore: s,
        text: 'task',
        files: [pick.path],
        resourceRoot: () {
          entered.complete();
          return release.future;
        }));
    await entered.future;
    await run.stop('synthetic stop').timeout(const Duration(seconds: 3));
    expect(run.ticket.released, true);
    expect(run.inputConsumed, false);
    expect(chat.requests, 0);
    await draft().save(text: 'NEW_DRAFT');
    resolver.complete(base);
    release.complete(resources);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect((await draft().load())!.text, 'NEW_DRAFT');
    expect(await pick.exists(), true);
  });
  test(
      'retire settles failed terminal while unaccepted fallback resolver is pending',
      () async {
    final resolver = Completer<Directory>();
    final s = ConversationDraftStore(
        accountHash: 'a',
        conversationId: '1',
        directoryResolver: () => resolver.future);
    final pick = File('${base.path}/original.txt')..writeAsStringSync('UNSENT');
    final run = start(ComposerGenerationPreparation(
        draftStore: s,
        text: 'task',
        files: [pick.path],
        resourceRoot: () =>
            Future.error(const FileSystemException('prepare failed'))));
    await support
        .waitGeneration(() => run.stage == ConversationGenerationStage.failed);
    await run.retire('maintenance').timeout(const Duration(seconds: 3));
    await run.finished;
    expect(run.ticket.released, true);
    expect(chat.requests, 0);
    await draft().save(text: 'NEW_IDENTITY_DRAFT');
    resolver.complete(base);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect((await draft().load())!.text, 'NEW_IDENTITY_DRAFT');
    expect(await storage.db.query('tb_messages'), isEmpty);
  });

  test('retire waits acquired fallback lease; no late draft after release',
      () async {
    final s = _OwnedFallbackGate(base);
    final pick = File('${base.path}/original.txt')..writeAsStringSync('UNSENT');
    final run = start(ComposerGenerationPreparation(
        draftStore: s,
        text: 'task',
        files: [pick.path],
        resourceRoot: () =>
            Future.error(const FileSystemException('prepare failed'))));
    await s.entered.future.timeout(const Duration(seconds: 3));
    expect(run.stage, ConversationGenerationStage.failed);
    var retired = false, probeEntered = false;
    final stopping = run.retire('maintenance').then((_) => retired = true);
    final probe = LoginDao.runWithStableAccount(
        expectedAccountHash: 'a',
        action: () async {
          probeEntered = true;
        });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(retired, false, reason: '已经取得的真实账号许可必须结算');
    expect(probeEntered, false);
    expect(run.ticket.released, false);
    s.release.complete();
    await stopping.timeout(const Duration(seconds: 3));
    await probe;
    expect(retired, true);
    expect(probeEntered, true);
    expect(run.ticket.released, true);
    expect(chat.requests, 0);
    expect(await draft().load(), isNull);
    expect(await pick.readAsString(), 'UNSENT');
    expect(await storage.db.query('tb_messages'), isEmpty);
  });
  for (final sameText in [true, false]) {
    test(
        'old manifest CAS keeps a later save including identical body=$sameText',
        () async {
      final s = draft();
      await s.save(text: 'original');
      final token = (await s.captureManifest())!;
      await draft().save(text: sameText ? 'original' : 'new draft');
      expect(await s.clearCapturedManifest(token, verify: () {}), isFalse);
      expect((await draft().load())!.text, sameText ? 'original' : 'new draft');
    });
  }
  test(
      'manifest token is account/cid bound and matching clear retains draft attachments',
      () async {
    final pick = File('${base.path}/file.txt');
    await pick.writeAsString('SYNTHETIC_FILE');
    final saved = (await draft().save(text: 'task', files: [pick.path]))!;
    final token = (await draft().captureManifest())!;
    expect(() => draft('b').clearCapturedManifest(token, verify: () {}),
        throwsA(isA<DraftStorageException>()));
    expect(await draft().clearCapturedManifest(token, verify: () {}), isTrue);
    expect(await draft().load(), isNull);
    expect(await File(saved.filePaths.single).exists(), isTrue);
  });
  test('late manifest read cannot adopt a newer draft generation', () async {
    await draft().save(text: 'original');
    final gate = Completer<Directory>();
    var entered = false;
    final old = ConversationDraftStore(
        conversationId: '1',
        accountHash: 'a',
        directoryResolver: () {
          entered = true;
          return gate.future;
        });
    final capture = old.captureManifest();
    await support.waitGeneration(() => entered);
    await draft().save(text: 'new draft');
    gate.complete(base);
    expect(await capture, isNull);
    expect((await draft().load())!.text, 'new draft');
  });
  test(
      'photo and history snapshots preserve user text, blocks and request data',
      () async {
    final photo = File('${base.path}/photo.png');
    await photo.writeAsBytes([137, 80, 78, 71]);
    final history = ComposerReference.history(HistoryMessageSnapshot(
        accountToken: AccountResourceScope.tokenFor('a'),
        conversationId: 42,
        messageId: 1,
        createdAt: 2,
        title: '合成引用',
        role: 'user',
        content: 'SYNTHETIC_HISTORY',
        selectedAt: 3));
    final run = start(ComposerGenerationPreparation(
        draftStore: draft(),
        text: 'task',
        images: [photo.path],
        references: [
          ComposerReference.attachment(photo.path, photo: true),
          history
        ],
        resourceRoot: () async => resources));
    await support.waitGeneration(() => chat.requests == 1);
    final row = (await storage.db.query('tb_messages',
            where: 'id=?', whereArgs: [run.record!.userRowId]))
        .single;
    final blocks = MessageBlock.decodeList(row['blocks'] as String);
    expect(blocks.whereType<MainTextBlock>().single.content, 'task');
    expect(
        await File(blocks.whereType<ImageBlock>().single.filePath!)
            .readAsBytes(),
        [137, 80, 78, 71]);
    expect(
        blocks
            .whereType<ReferenceBlock>()
            .single
            .reference
            .historySnapshot!
            .content,
        'SYNTHETIC_HISTORY');
    expect(
        chat.attachments!.images.single, startsWith('data:image/png;base64,'));
    expect(chat.attachments!.extraText, contains('SYNTHETIC_HISTORY'));
    chat.release.complete();
    await run.finished;
  });
  test(
      'foreign account history snapshot is rejected before user commit or request',
      () async {
    final history = ComposerReference.history(HistoryMessageSnapshot(
        accountToken: AccountResourceScope.tokenFor('b'),
        conversationId: 42,
        messageId: 1,
        createdAt: 2,
        title: '合成引用',
        role: 'user',
        content: 'FOREIGN_HISTORY',
        selectedAt: 3));
    final run = start(ComposerGenerationPreparation(
        draftStore: draft(),
        text: 'task',
        references: [history],
        resourceRoot: () async => resources));
    await run.finished;
    expect(chat.requests, 0);
    expect(await storage.db.query('tb_messages'), isEmpty);
  });
  test(
      'accepted run owns files after shared draft discard and publishes real file blocks once',
      () async {
    final pick = File('${base.path}/file.txt');
    await pick.writeAsString('SYNTHETIC_FILE');
    final saved = (await draft().save(
        text: 'task',
        files: [pick.path],
        references: [ComposerReference.attachment(pick.path, photo: false)]))!;
    final prep = ComposerGenerationPreparation(
        draftStore: draft(),
        text: 'task',
        files: saved.filePaths,
        references: saved.references,
        resourceRoot: () async => resources);
    final run = start(prep);
    await support.waitGeneration(() => chat.requests == 1);
    expect(await draft().load(), isNull);
    await draft().clear(discardAttachments: true);
    final row = (await storage.db.query('tb_messages',
            where: 'id=?', whereArgs: [run.record!.userRowId]))
        .single;
    final file = MessageBlock.decodeList(row['blocks'] as String)
        .whereType<FileBlock>()
        .single
        .file;
    expect(file.path, contains(run.runId));
    expect(await File(file.path!).readAsString(), 'SYNTHETIC_FILE');
    expect(await ManagedAttachmentStore.readManagedBytes(file.path), isNotNull);
    expect(chat.attachments!.extraText, contains('SYNTHETIC_FILE'));
    expect(row['ownerName'], '合成用户');
    expect(row['avatar'], 'synthetic-avatar');
    chat.release.complete();
    await run.finished;
    expect(run.stage, ConversationGenerationStage.complete);
    expect(await File(file.path!).exists(), isTrue);
  });
  test('new draft typed during preparation survives accepted manifest cleanup',
      () async {
    await draft().save(text: 'task');
    final rootGate = Completer<Directory>();
    final pick = File('${base.path}/file.txt');
    await pick.writeAsString('SYNTHETIC_FILE');
    final prep = ComposerGenerationPreparation(
        draftStore: draft(),
        text: 'task',
        files: [pick.path],
        resourceRoot: () => rootGate.future);
    final run = start(prep);
    await support.waitGeneration(
        () => run.record?.userRowId == null && run.record != null);
    await draft().save(text: 'new draft');
    rootGate.complete(resources);
    await support.waitGeneration(() => chat.requests == 1);
    expect((await draft().load())!.text, 'new draft');
    chat.release.complete();
    await run.finished;
  });
  test(
      'stop while resource resolver is held creates no late generation files and no user or request',
      () async {
    final pick = File('${base.path}/file.txt');
    await pick.writeAsString('SYNTHETIC_FILE');
    await draft().save(text: 'task');
    final gate = Completer<Directory>();
    var entered = false;
    final prep = ComposerGenerationPreparation(
        draftStore: draft(),
        text: 'task',
        files: [pick.path],
        resourceRoot: () {
          entered = true;
          return gate.future;
        });
    final run = start(prep);
    await support.waitGeneration(() => entered);
    await run.stop('停止准备').timeout(const Duration(seconds: 3));
    gate.complete(resources);
    await expectLater(prep.prepare(run), throwsA(anything));
    expect(await resources.list(recursive: true).length, 0);
    expect(await storage.db.query('tb_messages'), isEmpty);
    expect(chat.requests, 0);
    expect((await draft().load())!.text, 'task');
  });
  test(
      'warning confirmation uses run broker; stopping removes only unpublished resources',
      () async {
    final pick = File('${base.path}/unsupported.bin');
    await pick.writeAsString('SYNTHETIC_BINARY');
    await draft().save(text: 'task');
    final prep = ComposerGenerationPreparation(
        draftStore: draft(),
        text: 'task',
        files: [pick.path],
        resourceRoot: () async => resources);
    final run = start(prep);
    await support.waitGeneration(() => run.confirmation != null);
    expect(chat.requests, 0);
    expect(await storage.db.query('tb_messages'), isEmpty);
    final copied =
        (await resources.list(recursive: true).where((e) => e is File).toList())
            .single;
    final runDirectory = File(copied.path).parent.parent;
    await run.stop('取消说明').timeout(const Duration(seconds: 3));
    await eventually(() async =>
        await FileSystemEntity.type(runDirectory.path, followLinks: false) ==
        FileSystemEntityType.notFound);
    expect((await draft().load())!.text, 'task');
    expect(await pick.exists(), isTrue);
  });
  test(
      'sender commit failure never publishes generation and retains original manifest',
      () async {
    final pick = File('${base.path}/file.txt');
    await pick.writeAsString('SYNTHETIC_FILE');
    await draft().save(text: 'task');
    await storage.db.execute(
        "create trigger fail_sender before insert on tb_messages when NEW.ownerType='OwnerType.sender' begin select raise(abort,'synthetic disk'); end");
    final run = start(ComposerGenerationPreparation(
        draftStore: draft(),
        text: 'task',
        files: [pick.path],
        resourceRoot: () async => resources));
    await run.finished;
    expect(await storage.db.query('tb_messages'), isEmpty);
    expect(chat.requests, 0);
    expect((await draft().load())!.text, 'task');
    expect(await resources.list(recursive: true).where((e) => e is File).length,
        0);
  });
  test('new conversation birth and journal insert rollback as one transaction',
      () async {
    await storage.db.execute(
        "create trigger fail_birth before insert on tb_conversation_generation begin select raise(abort,'synthetic journal'); end");
    final failed = start(
        ReadyConversationTurn(PreparedConversationTurn(prompt: 'task')),
        cid: 77,
        birth: ConversationModel(cid: 77, title: null, icon: 'birth'));
    await failed.finished;
    expect(await storage.db.query('tb_conversation_list', where: 'cid=77'),
        isEmpty);
    expect(await storage.db.query('tb_conversation_generation'), isEmpty);
    expect(chat.requests, 0);
    await storage.db.execute('drop trigger fail_birth');
    final model = ConversationModel(cid: 77, title: null, icon: 'birth');
    final run = start(
        ReadyConversationTurn(PreparedConversationTurn(prompt: 'task')),
        cid: 77,
        birth: model);
    model.icon = 'changed';
    await support.waitGeneration(() => chat.requests == 1);
    expect(
        (await storage.db.query('tb_conversation_list', where: 'cid=77'))
            .single['icon'],
        'birth');
    expect(
        (await storage.db.query('tb_conversation_list', where: 'cid=77'))
            .single['title'],
        'task');
    chat.release.complete();
    await run.finished;
    expect(run.stage, ConversationGenerationStage.complete);
  });
  test('new conversation cannot adopt an occupied cid', () async {
    final run = start(
        ReadyConversationTurn(PreparedConversationTurn(prompt: 'task')),
        birth: ConversationModel(cid: 1, title: null, icon: 'replacement'));
    await run.finished;
    expect(chat.requests, 0);
    expect(run.record, isNull);
    expect(
        (await storage.db.query('tb_conversation_list', where: 'cid=1'))
            .single['icon'],
        '');
  });
  test(
      'legacy retry assigns source UUID by full original row CAS and keeps one user',
      () async {
    final source = user('task');
    final values = source.toJson()..remove('id');
    values['cid'] = 1;
    values['blocks'] = '[]';
    final id = await storage.db.insert('tb_messages', values);
    final raw =
        (await storage.db.query('tb_messages', where: 'id=?', whereArgs: [id]))
            .single;
    final run = start(
        ReadyConversationTurn(PreparedConversationTurn(prompt: 'task')),
        source: source,
        sourceRowId: id,
        sourceHash: generationSourceRowHash(raw));
    await support.waitGeneration(() => chat.requests == 1);
    final bound =
        (await storage.db.query('tb_messages', where: 'id=?', whereArgs: [id]))
            .single;
    expect(bound['memorySourceId'], run.record!.sourceId);
    expect(bound['memorySourceId'], isNotNull);
    chat.release.complete();
    await run.finished;
    expect(
        await storage.db.query('tb_messages',
            where: 'ownerType=?', whereArgs: [OwnerType.sender.toString()]),
        hasLength(1));
  });
  test(
      'legacy retry rejects changed images while waiting for real account lease without assigning UUID',
      () async {
    final source = user('task');
    final values = source.toJson()..remove('id');
    values['cid'] = 1;
    final id = await storage.db.insert('tb_messages', values);
    final raw =
        (await storage.db.query('tb_messages', where: 'id=?', whereArgs: [id]))
            .single;
    final entered = Completer<void>(), release = Completer<void>();
    final lease = LoginDao.runWithStableAccount(
        expectedAccountHash: 'a',
        action: () async {
          entered.complete();
          await release.future;
        });
    await entered.future;
    final run = start(
        ReadyConversationTurn(PreparedConversationTurn(prompt: 'task')),
        source: source,
        sourceRowId: id,
        sourceHash: generationSourceRowHash(raw));
    await storage.db.update('tb_messages', {'images': '["changed"]'},
        where: 'id=?', whereArgs: [id]);
    release.complete();
    await lease;
    await run.finished;
    expect(chat.requests, 0);
    expect(await storage.db.query('tb_conversation_generation'), isEmpty);
    expect(
        (await storage.db.query('tb_messages', where: 'id=?', whereArgs: [id]))
            .single['memorySourceId'],
        isNull);
  });
  test(
      'old reply fingerprint is rechecked after preparation and deletion shares acceptance transaction',
      () async {
    final source = user('task');
    final values = source.toJson()..remove('id');
    values['cid'] = 1;
    values['memorySourceId'] = 'stable-source';
    final id = await storage.db.insert('tb_messages', values);
    final replyId = await storage.db.insert('tb_messages', {
      'cid': 1,
      'createdAt': 20,
      'ownerType': OwnerType.receiver.toString(),
      'content': 'old reply',
      'memorySourceId': 'old-reply'
    });
    final raw =
        (await storage.db.query('tb_messages', where: 'id=?', whereArgs: [id]))
            .single;
    final reply = (await storage.db
            .query('tb_messages', where: 'id=?', whereArgs: [replyId]))
        .single;
    final scope = ConversationGenerationScope(account: 'a');
    final record = await dao.begin(scope,
        runId: 'synthetic-retry',
        cid: 1,
        conversationRowId: conversationId,
        assistantId: null,
        sourceId: 'stable-source',
        sourceHash: generationContentHash('task'),
        receiverId: 'new-reply',
        receiverAt: 30,
        existingUserRowId: id,
        existingSourceRowHash: generationSourceRowHash(raw),
        retryReplyRowId: replyId,
        retryReplyHash: generationSourceRowHash(reply));
    await storage.db.update('tb_messages', {'content': 'edited reply'},
        where: 'id=?', whereArgs: [replyId]);
    var published = false;
    await expectLater(
        dao.acceptUser(scope, record, source,
            onCommitted: () => published = true),
        throwsA(isA<ConversationGenerationStale>()));
    expect(published, isFalse);
    expect(
        (await storage.db
                .query('tb_messages', where: 'id=?', whereArgs: [replyId]))
            .single['content'],
        'edited reply');
    await storage.db.update('tb_messages', {'content': reply['content']},
        where: 'id=?', whereArgs: [replyId]);
    final accepted = await dao.acceptUser(scope, record, source,
        onCommitted: () => published = true);
    expect(published, isTrue);
    expect(
        await storage.db
            .query('tb_messages', where: 'id=?', whereArgs: [replyId]),
        isEmpty);
    final again = await dao.acceptUser(scope, accepted, source);
    expect(again.revision, accepted.revision);
  });
}

class _OwnedFallbackGate extends ConversationDraftStore {
  final entered = Completer<void>(), release = Completer<void>();
  _OwnedFallbackGate(Directory root)
      : super(
            accountHash: 'a',
            conversationId: '1',
            directoryResolver: () async => root);
  @override
  Future<ConversationDraft?> preserveSubmission(DraftSubmissionToken token,
          {required String text,
          List<String> images = const [],
          List<String> files = const [],
          List<ComposerReference> references = const [],
          required void Function() verify,
          required Future<void> abortTrigger,
          required Future<void> Function(Future<void> Function())
              stableMutation}) =>
      super.preserveSubmission(token,
          text: text,
          images: images,
          files: files,
          references: references,
          verify: verify,
          abortTrigger: abortTrigger,
          stableMutation: (action) => stableMutation(() async {
                entered.complete();
                await release.future;
                await action();
              }));
}
