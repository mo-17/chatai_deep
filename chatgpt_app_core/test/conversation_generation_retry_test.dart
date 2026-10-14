import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_profile.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/application/conversation_retry_preparation.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/conversation_generation.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/conversation_generation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'conversation_generation_test.dart' as support;

class _Chat
    implements
        ChatService,
        AttemptAwareChatService,
        OptionsAwareChatService,
        OptionsAwareNonStreamingChatService {
  int requests = 0;
  ChatAttachments? received;
  @override
  ModelCapabilities get capabilities => const ModelCapabilities(pdf: true);
  Future<void> request(String prompt, List<Map<String, dynamic>> history,
      ChatAttachments? attachments, ChatRequestOptions options) async {
    await options.resolveAttemptMessages([
      ...history,
      {'role': 'user', 'content': prompt}
    ]);
    received = attachments;
    requests++;
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
    yield StreamEvent.text('new reply');
    yield StreamEvent.usage(promptTokens: 2, completionTokens: 3);
  }

  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      required ChatRequestOptions options}) async {
    await request(prompt, history, attachments, options);
    return const ChatCompletionResult(
        content: 'new reply', promptTokens: 2, completionTokens: 3);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HiDBManager storage;
  late ConversationGenerationDao dao;
  late ConversationGenerationService service;
  late Directory root;
  late _Chat chat;
  late int conversationId;
  late List<MessageBlock> blocks;
  late Map<String, Object?> source, reply;
  late List<int> bytes;
  late File file;
  setUp(() async {
    LoginDao.resetHooksForTest();
    support.GenerationTestAuth().install();
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('chatai_run_retry_');
    ManagedAttachmentStore.debugRootDirectory = root;
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    conversationId = (await (await ConversationListDao.create(storage))
        .saveConversation(
            ConversationModel(cid: 1, title: 'synthetic', icon: '')))!;
    dao = await ConversationGenerationDao.create(storage);
    chat = _Chat();
    service = ConversationGenerationService(
        createChat: (_) => chat, createMemory: (_) async => null);
    final pdf = PdfDocument();
    pdf.pages.add().graphics.drawString(
        'synthetic original', PdfStandardFont(PdfFontFamily.helvetica, 12));
    bytes = await pdf.save();
    pdf.dispose();
    final dir = Directory(
        '${root.path}/accounts/${AccountResourceScope.tokenFor('a')}/generations/'
        '12345678-1234-4234-8234-123456789abc/${sha256.convert(bytes)}');
    await dir.create(recursive: true);
    file = await File('${dir.path}/original.pdf').writeAsBytes(bytes);
    blocks = [
      FileBlock(
          id: 'file',
          messageId: 'chat_10',
          createdAt: 10,
          status: MessageBlockStatus.success,
          file: FileMetadata(
              name: 'original.pdf',
              path: file.path,
              mime: 'application/pdf',
              size: bytes.length)),
      const MainTextBlock(
          id: 'main',
          messageId: 'chat_10',
          createdAt: 10,
          status: MessageBlockStatus.success,
          content: 'same question')
    ];
    final messages = await MessageDao.create(storage, cid: 1);
    await messages.saveMessageWithBlocks(
        MessageModel(
            ownerType: OwnerType.sender,
            content: 'same question',
            createdAt: 10),
        blocksJson: MessageBlock.encodeList(blocks));
    await messages.saveMessageWithBlocks(MessageModel(
        ownerType: OwnerType.receiver, content: 'old reply', createdAt: 20));
    source = (await storage.db.query('tb_messages',
            where: 'ownerType=?', whereArgs: [OwnerType.sender.toString()]))
        .single;
    reply = (await storage.db.query('tb_messages',
            where: 'ownerType=?', whereArgs: [OwnerType.receiver.toString()]))
        .single;
  });
  tearDown(() async {
    for (final run in service.runs.where((r) => r.busy)) {
      await run.retire('test cleanup');
    }
    service.dispose();
    await storage.db.close();
    ManagedAttachmentStore.debugRootDirectory = null;
    await root.delete(recursive: true);
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
  });
  ConversationGenerationRun start(bool stream) => service.start(
      scope: ConversationGenerationScope(account: 'a'),
      dao: dao,
      profile: ConversationGenerationProfile(support.generationSettings(), 'a',
          loadSettings: () async => support.generationSettings()),
      input: ConversationGenerationInput(
          cid: 1,
          conversationRowId: conversationId,
          user: MessageModel.fromJson(source),
          stream: stream,
          existingUserRowId: source['id'] as int,
          existingSourceId: source['memorySourceId'] as String,
          existingSourceRowHash: generationSourceRowHash(source),
          retryReplyRowId: reply['id'] as int,
          retryReplyHash: generationSourceRowHash(reply)),
      preparation: RetryGenerationPreparation(
          persisted:
              const ChatAttachments(extraText: 'saved history reference'),
          userBlocks: blocks));
  for (final stream in [false, true]) {
    test(
        'retry prepares account generation PDF and reuses one source through stream=$stream',
        () async {
      final run = start(stream);
      await run.finished;
      expect(run.stage, ConversationGenerationStage.complete);
      expect(chat.requests, 1);
      expect(chat.received!.extraText, 'saved history reference');
      expect(chat.received!.nativeFiles.single.filename, 'original.pdf');
      expect(
          base64Decode(
              chat.received!.nativeFiles.single.dataUri.split(',').last),
          bytes);
      final users = await storage.db.query('tb_messages',
          where: 'ownerType=?', whereArgs: [OwnerType.sender.toString()]);
      expect(users, [source]);
      final replies = await storage.db.query('tb_messages',
          where: 'ownerType=?', whereArgs: [OwnerType.receiver.toString()]);
      expect(replies, hasLength(1));
      expect(replies.single['content'], 'new reply');
      expect(await storage.db.query('tb_usage'), hasLength(1));
      expect(await file.readAsBytes(), bytes);
    });
  }
  test(
      'failed generation digest keeps previous reply and emits zero model requests',
      () async {
    await file.writeAsBytes([...bytes, 0]);
    final run = start(true);
    await run.finished;
    expect(chat.requests, 0);
    expect(await storage.db.query('tb_usage'), isEmpty);
    expect(
        (await storage.db
                .query('tb_messages', where: 'id=?', whereArgs: [reply['id']]))
            .single,
        reply);
    expect(
        (await storage.db
                .query('tb_messages', where: 'id=?', whereArgs: [source['id']]))
            .single,
        source);
  });
}
