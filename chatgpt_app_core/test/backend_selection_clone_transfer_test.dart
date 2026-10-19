import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/assistant_conversation_factory.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/migration/guest_migration_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'support/backend_transfer_test_support.dart';
import 'support/personal_memory_test_support.dart';

class TransferAccount extends PersonalMemoryTestAccount {
  TransferAccount(super.account);
  @override
  String? readTokenSync() => 'synthetic-token';
}

class TransferSecrets implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

ConversationModel seedProject(ProjectModel project) {
  final args = <Symbol, dynamic>{
    #cid: 99,
    #icon: '',
    #projectId: project.id,
    #modelProviderId: project.defaultProviderId,
    #modelId: project.defaultModelId,
    #backendSelection: project.backendSelection
  };
  try {
    return Function.apply(AssistantConversationFactory.create, const [], args)
        as ConversationModel;
  } on NoSuchMethodError {
    args.remove(#backendSelection);
    return Function.apply(AssistantConversationFactory.create, const [], args)
        as ConversationModel;
  }
}

void main() {
  final fx = TransferFixture();
  setUpAll(fx.init);
  tearDownAll(fx.finish);
  setUp(() async {
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
    AISettingsDao.resetSecureStateForTest();
    await HiCache.getInstance().prefs?.clear();
    AISettingsDao.configureSecretStore(TransferSecrets());
  });
  tearDown(() {
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
    AISettingsDao.resetSecureStateForTest();
  });
  for (final selection in [
    pairA,
    BackendSelection.follow(),
    BackendSelection.fromStorage('{"version":99,"future":"keep"}')!
  ]) {
    test(
        'clone and project seed preserve ${selection.kind.name} without overwriting local fields',
        () async {
      final project = ProjectModel(
          id: 1,
          name: 'p',
          defaultProviderId: 'local-A',
          defaultModelId: 'local-model',
          backendSelection: selection);
      final seeded = seedProject(project);
      expect(seeded.backendSelection?.toSqlValue(), selection.toSqlValue());
      expect(seeded.modelProviderId, 'local-A');
      expect(seeded.modelId, 'local-model');
      project.backendSelection = pairB;
      expect(seeded.backendSelection?.toSqlValue(), selection.toSqlValue());
      final assistant =
          AssistantModel(name: 'a', prompt: 'p', backendSelection: selection);
      final cloned = AssistantModel.fromJson(assistant.toJson());
      expect(cloned.backendSelection?.toSqlValue(), selection.toSqlValue());
      final room = StoryRoomModel(title: 'r', backendSelection: selection);
      expect(room.copyWith(title: 'clone').backendSelection?.toSqlValue(),
          selection.toSqlValue());
      expect(
          ProjectModel.fromJson(project.toJson())
              .backendSelection
              ?.toSafeJson(),
          pairB.toSafeJson());
    });
  }
  test(
      'third-party Tavern payload keeps prompt and excludes account backend selection',
      () {
    final assistant = AssistantModel(
        name: 'a', prompt: 'original-prompt', backendSelection: pairA);
    final exported = AssistantRoleCardService.exportTavernV2Json(assistant);
    expect(exported, isNot(contains('backendSelection')));
    expect(exported, isNot(contains('account-A')));
    expect(exported, contains('original-prompt'));
  });
  test(
      'guest raw append keeps pair/follow/unknown and remaps cid without overwriting destination',
      () async {
    final guest = await fx.db();
    await fx.seed(guest);
    final dest = await fx.db();
    await fx.seed(dest, selection: pairB.toSqlText());
    await guest.db.update('tb_project',
        {'backendSelection': BackendSelection.follow().toSqlText()});
    const raw = '{"version":99,"future":"unchanged"}';
    await guest.db.update('tb_assistant', {'backendSelection': raw});
    await GuestMigrationService.mergeGuestData(from: guest, to: dest);
    for (final e in {
      'tb_project': BackendSelection.follow().toSqlText(),
      'tb_assistant': raw,
      'tb_conversation_list': pairA.toSqlText()
    }.entries) {
      final rows = await dest.db.query(e.key);
      expect(rows.length, 2);
      expect(rows.map((r) => r['backendSelection']),
          containsAll([e.value, pairB.toSqlText()]));
    }
    final conversations = await dest.db.query('tb_conversation_list');
    expect(conversations.map((r) => r['cid']).toSet().length, 2);
    expect(
        (await dest.db.query('tb_story_room')).length, 1); // 原游客搬运范围不增故事/运行任务。
  });
  for (final existing in [false, true]) {
    test('guest settings if-absent keeps original scope, existing=$existing',
        () async {
      TransferAccount('account-B').install();
      final guest = await fx.db();
      await fx.seed(guest);
      final dest = await fx.db();
      final settings = AISettings.defaults()..backendSelection = pairA;
      await AISettingsDao.saveFor('guest', settings);
      if (existing) {
        await AISettingsDao.saveFor(
            'account-B', AISettings.defaults()..backendSelection = pairB);
      }
      final result = await GuestMigrationService.migrate(
          storageResolver: (hash) async => hash == 'guest' ? guest : dest);
      expect(result.settingsImported, !existing);
      final loaded = await AISettingsDao.loadForAsync('account-B');
      expect(loaded.backendSelection!.toSafeJson(),
          (existing ? pairB : pairA).toSafeJson());
      if (!existing) {
        expect(
            loaded.backendSelection!.matchesScope(
                accountHash: 'account-B', origin: 'https://b.example'),
            isFalse);
      }
      expect(jsonEncode(loaded.toJson()), contains('same/model'));
    });
  }
}
