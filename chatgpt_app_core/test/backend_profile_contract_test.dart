import 'support/owned_test_directory.dart';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/agent_workflow_models.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_preference_store.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, dynamic> selection(
        [String provider = 'a', String origin = 'http://127.0.0.1:39991']) =>
    {
      'version': 1,
      'mode': 'pair',
      'providerCode': provider,
      'modelId': ' same/model ',
      'scope': {'accountHash': 'account-a', 'origin': origin},
    };
Map<String, dynamic> profileJson({int version = 2}) => {
      'version': version,
      'mode': 'backend',
      'providerId': null,
      'modelId': ' same/model ',
      'reasoningPolicy': 'offIfSupported',
      'reasoningControlSuppressed': false,
      if (version == 2) 'backendSelection': selection(),
    };
Map<String, dynamic> preferenceJson() => {
      'version': 2,
      'mode': 'backend',
      'modelId': ' same/model ',
      'reasoningPolicy': 'offIfSupported',
      'backendSelection': selection(),
    };

void main() {
  final ownedFixture = OwnedTestDirectory(
    rootKey: 'R2C_SQLITE_ROOT',
    nonceKey: 'R2C_SQLITE_NONCE',
    legacyPrefix: '/tmp/chatai-r2c-sqlite-',
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  final connections = <Database>[];
  final resources = <Map<String, Object?>>[];
  late Directory root;
  setUpAll(() {
    sqfliteFfiInit();
    root = ownedFixture.directory;
  });
  tearDownAll(() async {
    for (final db in connections) {
      if (db.isOpen) await db.close();
    }
    for (final item in resources) {
      item['closed'] = true;
    }
    File('${root.path}/cleanup.json')
        .writeAsStringSync(jsonEncode({'databases': resources}));
  });
  Future<StoryTemplateTranslationTaskDao> dao() async {
    final path = '${root.path}/contract-${connections.length}.db';
    final db = await databaseFactoryFfi.openDatabase(path);
    connections.add(db);
    resources.add({'path': path, 'closed': false});
    return StoryTemplateTranslationTaskDao.create(HiDBManager.test(db));
  }

  test('v1 translation backend remains exact original bytes/version', () {
    final raw = jsonEncode(profileJson(version: 1));
    final profile = TranslationRequestProfile.fromJson(jsonDecode(raw));
    expect(jsonEncode(profile.toJson()), raw);
    expect(profile.toJson()['version'], 1);
    expect(profile.toJson().containsKey('backendSelection'), isFalse);
  });
  test('modern translation profile keeps exact pair and suppression version',
      () {
    final p = TranslationRequestProfile.fromJson(profileJson());
    expect(p.toJson(), profileJson());
    expect(p.suppressReasoningControl().toJson(),
        {...profileJson(), 'reasoningControlSuppressed': true});
  });
  test('foreign scope modern profile serializes without re-signing', () {
    final value = {
      ...profileJson(),
      'backendSelection': selection('b', 'https://foreign.invalid')
    };
    final p = TranslationRequestProfile.fromJson(value);
    expect(p.toJson(), value);
  });
  test('modern translation preference preserves pair in persisted JSON', () {
    final p = TranslationModelPreference.fromJson(preferenceJson());
    expect(p.toJson(), preferenceJson());
  });
  for (final mutation in ['modelMismatch', 'follow', 'extra']) {
    test('modern preference rejects $mutation', () {
      final value = preferenceJson();
      if (mutation == 'modelMismatch') value['modelId'] = 'different';
      if (mutation == 'follow') {
        value['backendSelection'] = {'version': 1, 'mode': 'follow'};
      }
      if (mutation == 'extra') value['token'] = 'synthetic-never-export';
      expect(() => TranslationModelPreference.fromJson(value),
          throwsFormatException);
    });
  }
  test('legacy workflow sentinel and local encoding/hash remain exact', () {
    for (final mode in ['backend', 'local']) {
      final raw = jsonEncode({
        'mode': mode,
        'providerId': mode == 'backend' ? 'backend' : 'local-id',
        'modelId': ' same/model '
      });
      final p = WorkflowModelProfile.fromJson(jsonDecode(raw));
      expect(jsonEncode(p.toJson()), raw);
      expect(workflowHash(jsonEncode(p.toJson())), workflowHash(raw));
    }
  });
  test(
      'modern workflow profile keeps tuple, same-name providers have distinct keys',
      () {
    final a = WorkflowModelProfile.fromJson({
      'version': 1,
      'mode': 'backend',
      'backendSelection': selection('a/b')
    });
    final b = WorkflowModelProfile.fromJson(
        {'version': 1, 'mode': 'backend', 'backendSelection': selection('a')});
    expect(a.toJson()['backendSelection'], selection('a/b'));
    expect(WorkflowModelChoice(a, 'a').key,
        isNot(WorkflowModelChoice(b, 'b').key));
  });
  test('modern workflow additional fields are rejected', () {
    expect(
        () => WorkflowModelProfile.fromJson({
              'version': 1,
              'mode': 'backend',
              'backendSelection': selection(),
              'apiKey': 'synthetic'
            }),
        throwsFormatException);
  });
  for (final raw in [
    jsonEncode({...preferenceJson(), 'version': 9}),
    jsonEncode({
      ...preferenceJson(),
      'backendSelection': {'version': 9}
    }),
    '{"version":2,'
  ]) {
    test(
        'explicit damaged modern preference is unavailable and raw unchanged: ${raw.length}',
        () {
      final kv = _Memory()
        ..values[TranslationModelPreferenceStore.keyFor('account-a')] = raw;
      final store = TranslationModelPreferenceStore(
          storage: kv, currentAccountHash: () => 'account-a');
      final p = store.read('account-a');
      expect(p.mode, TranslationModelPreferenceMode.backend);
      expect(() => p.toJson(), throwsFormatException);
      expect(kv.values.values.single, raw);
    });
  }
  test('modern preference save/reopen foreign scope keeps original pair',
      () async {
    final kv = _Memory();
    final value = {
      ...preferenceJson(),
      'backendSelection': selection('b', 'https://foreign.invalid')
    };
    final store = TranslationModelPreferenceStore(
        storage: kv, currentAccountHash: () => 'account-a');
    await store.save(TranslationModelPreference.fromJson(value),
        expectedAccountHash: 'account-a');
    expect(
        TranslationModelPreferenceStore(
            storage: kv,
            currentAccountHash: () => 'account-a').read('account-a').toJson(),
        value);
  });
  test(
      'old translation model-only consumer rejects modern profile before service',
      () {
    final p = TranslationRequestProfile.fromJson(profileJson());
    expect(() => TranslationModelResolver.apply(AISettings.defaults(), p),
        throwsA(isA<TranslationModelUnavailableException>()));
    final preference = TranslationModelPreference.fromJson(preferenceJson());
    expect(
        () => TranslationModelResolver.snapshot(
            AISettings.defaults(), preference),
        throwsA(isA<TranslationModelUnavailableException>()));
  });
  test('old workflow model-only consumer rejects modern pair', () {
    final p = WorkflowModelProfile.fromJson(
        {'version': 1, 'mode': 'backend', 'backendSelection': selection()});
    expect(() => AgentWorkflowModels.forProfile(AISettings.defaults(), p),
        throwsA(anything));
  });
  for (final raw in [
    jsonEncode(profileJson()),
    jsonEncode({...profileJson(), 'version': 9}),
    '{"version":2,"backendSelection":'
  ]) {
    test(
        'plain claim refuses modern/unknown explicit profile with zero row writes: ${raw.length}',
        () async {
      final store = await dao();
      final task = StoryTemplateTranslationTaskModel(
          sourceTitle: 'fixture',
          sourcePayload: '{}',
          requestProfile: raw,
          updatedAt: 100);
      await store.saveTask(task);
      final before = (await store.storage.db.query(store.tableName)).single;
      expect(
          await store.claimTask(task.id!,
              leaseOwner: 'synthetic',
              leaseDuration: const Duration(seconds: 5)),
          isFalse);
      expect((await store.storage.db.query(store.tableName)).single, before);
    });
  }
  test('legacy backend/local claim semantics remain available', () async {
    final store = await dao();
    for (final value in [
      profileJson(version: 1),
      {...profileJson(version: 1), 'mode': 'local', 'providerId': 'local-a'}
    ]) {
      final task = StoryTemplateTranslationTaskModel(
          sourceTitle: 'fixture',
          sourcePayload: '{}',
          requestProfile: jsonEncode(value));
      await store.saveTask(task);
      expect(
          await store.claimTask(task.id!,
              leaseOwner: 'synthetic',
              leaseDuration: const Duration(seconds: 5)),
          isTrue);
      expect((await store.getTask(task.id!))!.attempts, 1);
    }
  });
  test(
      'codec source identity is structural and foreign scope remains unavailable',
      () {
    final p = BackendSelection.fromStorage(selection('a/b'))!;
    expect(p.isPair, isTrue);
    expect(
        p.matchesScope(accountHash: 'other', origin: 'http://127.0.0.1:39991'),
        isFalse);
  });
}

class _Memory implements TranslationPreferenceKeyValueStore {
  final values = <String, Object?>{};
  @override
  Object? read(String key) => values[key];
  @override
  Future<bool> writeString(String key, String value) async {
    values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }
}
