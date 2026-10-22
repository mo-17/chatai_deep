import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'owned_test_directory.dart';

final pairA = BackendSelection.pair(
    providerCode: 'A/code',
    modelId: 'same/model',
    accountHash: 'account-A',
    origin: 'https://a.example:8443');
final pairB = BackendSelection.pair(
    providerCode: 'B',
    modelId: 'same/model',
    accountHash: 'account-B',
    origin: 'https://b.example');
const transferTables = {
  'project': 'tb_project',
  'conversation': 'tb_conversation_list',
  'assistant': 'tb_assistant',
  'story_room': 'tb_story_room',
  'story_participant': 'tb_story_participant',
};
const archiveFiles = {
  'project': 'projects.json',
  'conversation': 'conversations.json',
  'assistant': 'assistants.json',
  'story_room': 'story_rooms.json',
  'story_participant': 'story_participants.json',
};

class TransferFixture {
  final _owned = OwnedTestDirectory(
    rootKey: 'R2D_SQLITE_ROOT',
    nonceKey: 'R2D_SQLITE_NONCE',
    legacyPrefix: '/tmp/chatai-r2d-sqlite-',
  );
  late Directory root;
  final List<HiDBManager> opened = [];
  int closed = 0;
  late HttpOverrides? previous;
  late NoTransferNetwork network;
  Future<void> init() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    root = _owned.directory;
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await Directory('${root.path}/images').create();
    await Directory('${root.path}/cards').create();
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${root.path}/attachments');
    BackupService.debugGeneratedImageDirectoryResolver =
        () async => Directory('${root.path}/images');
    BackupService.debugRoleCardAssetsDirectoryResolver =
        () async => Directory('${root.path}/cards');
    previous = HttpOverrides.current;
    network = NoTransferNetwork();
    HttpOverrides.global = network;
  }

  Future<HiDBManager> db() async {
    final value = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        '${root.path}/owned-${opened.length}.db',
        options: OpenDatabaseOptions(singleInstance: false)));
    await value.db.execute('PRAGMA user_version = 2');
    opened.add(value);
    return value;
  }

  Future<void> seed(HiDBManager value, {String? selection}) async {
    await BackupService(value)
        .exportArchive(settings: AISettings.defaults(), accountHash: 'fixture');
    final s = selection ?? pairA.toSqlText();
    await value.db.insert('tb_assistant', {
      'id': 1,
      'name': 'source-assistant',
      'prompt': 'prompt',
      'avatarType': 'emoji',
      'avatarValue': '😀',
      'createdAt': 10,
      'updatedAt': 10,
      'backendSelection': s
    });
    await value.db.insert('tb_project', {
      'id': 1,
      'name': 'source-project',
      'createdAt': 10,
      'updatedAt': 10,
      'defaultAssistantId': 1,
      'backendSelection': s
    });
    await value.db.insert('tb_conversation_list', {
      'id': 1,
      'cid': 71,
      'title': 'source-conversation',
      'icon': '',
      'stickTime': 0,
      'updateAt': 10,
      'assistantId': 1,
      'projectId': 1,
      'backendSelection': s
    });
    await value.db.insert('tb_story_room', {
      'id': 1,
      'title': 'source-room',
      'mode': 'creation',
      'replyMode': 'autoSingle',
      'createdAt': 10,
      'updatedAt': 10,
      'backendSelection': s,
      'tavernChatMetadataJson': '{"original":"header"}',
      'promptConfigJson': '{"original":"prompt"}'
    });
    await value.db.insert('tb_story_participant', {
      'id': 1,
      'roomId': 1,
      'name': 'source-participant',
      'role': 'assistant',
      'participantKey': 'p',
      'enabled': 1,
      'sortOrder': 0,
      'createdAt': 10,
      'updatedAt': 10,
      'backendSelection': s
    });
  }

  Future<void> finish() async {
    for (final db in opened) {
      if (db.db.isOpen) {
        await db.db.close();
        closed++;
      }
    }
    ManagedAttachmentStore.debugRootDirectory = null;
    BackupService.debugGeneratedImageDirectoryResolver = null;
    BackupService.debugRoleCardAssetsDirectoryResolver = null;
    HttpOverrides.global = previous;
    expect(network.calls, 0);
    await File('${root.path}/cleanup.json').writeAsString(jsonEncode({
      'opened': opened.length,
      'closed': closed,
      'allClosed': opened.every((s) => !s.db.isOpen),
      'httpAttempts': network.calls,
      'schemaVersion': 2
    }));
  }
}

class NoTransferNetwork extends HttpOverrides {
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    calls++;
    throw StateError('network forbidden in transfer fixture');
  }
}
