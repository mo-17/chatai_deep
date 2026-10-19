import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/backup/backup_integrity.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/backend_transfer_test_support.dart';

Map<String, List<int>> files(List<int> bytes) => {
      for (final f in ZipDecoder().decodeBytes(bytes))
        if (f.isFile) f.name: List<int>.from(f.content as List)
    };
Object? read(Map<String, List<int>> f, String key) =>
    jsonDecode(utf8.decode(f[key]!));
List<int> amend(List<int> bytes, String file, void Function(dynamic) edit) {
  final f = files(bytes);
  final data = read(f, file);
  edit(data);
  f[file] = utf8.encode(jsonEncode(data));
  final manifest = read(f, 'manifest.json') as Map<String, dynamic>;
  manifest['entries'] = {
    for (final e in digestEntries(f).entries) e.key: e.value.toJson()
  };
  f['manifest.json'] = utf8.encode(jsonEncode(manifest));
  final archive = Archive();
  for (final e in f.entries) {
    archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  return ZipEncoder().encode(archive);
}

const v1 =
    '{ "version":1, "mode":"backend", "providerId":null, "modelId":"same/model", "reasoningPolicy":"providerDefault", "reasoningControlSuppressed":false }';
String v2() => jsonEncode({
      'version': 2,
      'mode': 'backend',
      'providerId': null,
      'modelId': 'same/model',
      'reasoningPolicy': 'providerDefault',
      'reasoningControlSuppressed': false,
      'backendSelection': pairA.toSafeJson()
    });
void main() {
  final fx = TransferFixture();
  setUpAll(fx.init);
  tearDownAll(fx.finish);
  test(
      'archive13 all five foreign selections and v1/v2 profiles survive overwrite/merge without scope restamp',
      () async {
    final source = await fx.db();
    await fx.seed(source);
    final tasks = await StoryTemplateTranslationTaskDao.create(source);
    for (final profile in [v1, v2()]) {
      await tasks.saveTask(StoryTemplateTranslationTaskModel(
          sourceTitle: 'profile',
          sourcePayload: '{}',
          requestProfile: profile,
          attempts: 2,
          status: StoryTemplateTranslationTaskStatus.running,
          leaseOwner: 'old',
          leaseUntil: 99));
    }
    final settings = AISettings.defaults()..backendSelection = pairA;
    final bytes = await BackupService(source)
        .exportArchive(settings: settings, accountHash: 'account-A');
    final f = files(bytes);
    expect((read(f, 'manifest.json') as Map)['formatVersion'], 13);
    final exported = read(f, 'story_template_translation_tasks.json') as List;
    expect(exported[0]['requestProfile'], v1);
    expect(exported[1]['requestProfile'], v2());
    for (final mode in [
      BackupImportMode.overwriteAll,
      BackupImportMode.mergeAppend
    ]) {
      final dest = await fx.db();
      await fx.seed(dest, selection: pairB.toSqlText());
      final result = await BackupService(dest)
          .importArchive(bytes, accountHash: 'account-B', mode: mode);
      for (final e in transferTables.entries) {
        final rows = await dest.db.query(e.value);
        expect(rows.map((r) => r['backendSelection']),
            contains(pairA.toSqlText()));
        if (mode == BackupImportMode.mergeAppend) {
          expect(rows.map((r) => r['backendSelection']),
              contains(pairB.toSqlText()));
        }
      }
      final restored =
          await dest.db.query('tb_story_template_translation_task');
      final rooms = await dest.db.query('tb_story_room');
      expect(rooms.last['tavernChatMetadataJson'], '{"original":"header"}');
      expect(rooms.last['promptConfigJson'], '{"original":"prompt"}');
      expect(restored.map((r) => r['requestProfile']), containsAll([v1, v2()]));
      expect(
          restored.every((r) =>
              r['attempts'] == 2 &&
              r['leaseOwner'] == null &&
              r['status'] == 'retryable'),
          isTrue);
      if (mode == BackupImportMode.overwriteAll) {
        expect(result.settings!.backendSelection!.toSafeJson(),
            pairA.toSafeJson());
        expect(
            result.settings!.backendSelection!.matchesScope(
                accountHash: 'account-B', origin: 'https://b.example'),
            isFalse);
      } else {
        expect(result.settings, isNull);
      }
      expect(
          (await dest.db.rawQuery('PRAGMA user_version')).single.values.single,
          2);
    }
  });
  for (final e in archiveFiles.entries) {
    test(
        'invalid ${e.key} export rejects rather than leaking extra secret or converting to legacy',
        () async {
      final source = await fx.db();
      await fx.seed(source);
      final raw =
          jsonEncode({...pairA.toSafeJson(), 'secret': 'synthetic-secret'});
      await source.db.update(transferTables[e.key]!, {'backendSelection': raw});
      await expectLater(
          BackupService(source)
              .exportArchive(settings: AISettings.defaults(), accountHash: 'a'),
          throwsFormatException);
      expect(
          (await source.db.query(transferTables[e.key]!))
              .single['backendSelection'],
          raw);
    });
  }
  test('five follow choices remain explicit after archive restore', () async {
    final source = await fx.db();
    final follow = BackendSelection.follow().toSqlText();
    await fx.seed(source, selection: follow);
    final bytes = await BackupService(source)
        .exportArchive(settings: AISettings.defaults(), accountHash: 'a');
    final dest = await fx.db();
    await BackupService(dest).importArchive(bytes, accountHash: 'b');
    for (final table in transferTables.values) {
      expect((await dest.db.query(table)).single['backendSelection'], follow);
    }
  });
  for (final malformed in [
    '["version",2]',
    '{"version":9}',
    '{"version":1,"secret":"synthetic"}'
  ]) {
    test('malformed profile export refuses $malformed without rewriting row',
        () async {
      final source = await fx.db();
      await fx.seed(source);
      final dao = await StoryTemplateTranslationTaskDao.create(source);
      await dao.saveTask(StoryTemplateTranslationTaskModel(
          sourceTitle: 'bad', sourcePayload: '{}', requestProfile: malformed));
      await expectLater(
          BackupService(source)
              .exportArchive(settings: AISettings.defaults(), accountHash: 'a'),
          throwsFormatException);
      expect(
          (await source.db.query('tb_story_template_translation_task'))
              .single['requestProfile'],
          malformed);
    });
  }
  test(
      'known legacy credential extras are scrubbed, without writing original profile',
      () async {
    final source = await fx.db();
    await fx.seed(source);
    final raw = jsonEncode({
      ...jsonDecode(v1) as Map<String, dynamic>,
      'apiKey': 'synthetic-secret'
    });
    await (await StoryTemplateTranslationTaskDao.create(source)).saveTask(
        StoryTemplateTranslationTaskModel(
            sourceTitle: 'old', sourcePayload: '{}', requestProfile: raw));
    final bytes = await BackupService(source)
        .exportArchive(settings: AISettings.defaults(), accountHash: 'a');
    final profile =
        (read(files(bytes), 'story_template_translation_tasks.json') as List)
            .single['requestProfile'] as String;
    expect(profile, isNot(contains('synthetic-secret')));
    expect((jsonDecode(profile) as Map)['version'], 1);
    expect(
        (await source.db.query('tb_story_template_translation_task'))
            .single['requestProfile'],
        raw);
  });
  for (final mode in BackupImportMode.values) {
    test(
        '${mode.name}: validates only consumed selection rows/settings/profile',
        () async {
      final source = await fx.db();
      await fx.seed(source);
      await (await StoryTemplateTranslationTaskDao.create(source)).saveTask(
          StoryTemplateTranslationTaskModel(
              sourceTitle: 'x', sourcePayload: '{}', requestProfile: v2()));
      final bytes = await BackupService(source)
          .exportArchive(settings: AISettings.defaults(), accountHash: 'a');
      final all = mode == BackupImportMode.overwriteAll ||
          mode == BackupImportMode.mergeAppend;
      final consumed = {
        if (all || mode == BackupImportMode.projectConversationsOnly) 'project',
        if (all || mode == BackupImportMode.projectConversationsOnly)
          'conversation',
        if (all || mode == BackupImportMode.assistantsOnly) 'assistant',
        if (all) 'story_room',
        if (all) 'story_participant'
      };
      for (final e in archiveFiles.entries) {
        final malformed = amend(bytes, e.value, (dynamic data) {
          data[0]['backendSelection'] = '{"version":99,"secret":"synthetic"}';
        });
        final dest = await fx.db();
        await fx.seed(dest, selection: pairB.toSqlText());
        final before = {
          for (final table in transferTables.values)
            table: await dest.db.query(table)
        };
        final revision = BackupService.agentExecutionRevision;
        final action = BackupService(dest)
            .importArchive(malformed, accountHash: 'b', mode: mode);
        if (consumed.contains(e.key)) {
          await expectLater(action, throwsFormatException);
          for (final table in transferTables.values) {
            expect(await dest.db.query(table), before[table]);
          }
          // 旧恢复失效代次在事务外；不把失败夸称所有副作用回滚。
          expect(BackupService.agentExecutionRevision, revision + 1);
        } else {
          await action;
        }
      }
      for (final file in [
        'settings.json',
        'story_template_translation_tasks.json'
      ]) {
        final malformed = amend(bytes, file, (dynamic data) {
          if (file == 'settings.json') {
            data['backendSelection'] = {'version': 1, 'mode': 'follow'};
          } else {
            data[0]['requestProfile'] = '[{"version":2}]';
          }
        });
        final dest = await fx.db();
        await fx.seed(dest, selection: pairB.toSqlText());
        final action = BackupService(dest)
            .importArchive(malformed, accountHash: 'b', mode: mode);
        if (file == 'settings.json'
            ? mode == BackupImportMode.overwriteAll
            : all) {
          await expectLater(action, throwsFormatException);
        } else {
          expect((await action).settings, isNull);
        }
      }
    });
  }
  test(
      'knowledge-only preserves all existing selections; old absent/NULL rows stay legacy',
      () async {
    final source = await fx.db();
    await fx.seed(source);
    List<int> bytes = await BackupService(source)
        .exportArchive(settings: AISettings.defaults(), accountHash: 'a');
    for (final e in archiveFiles.entries) {
      bytes = amend(bytes, e.value, (dynamic rows) {
        rows[0].remove('backendSelection');
      });
    }
    final dest = await fx.db();
    await fx.seed(dest, selection: pairB.toSqlText());
    await BackupService(dest).importArchive(bytes,
        accountHash: 'b', mode: BackupImportMode.knowledgeBaseOnly);
    for (final table in transferTables.values) {
      expect((await dest.db.query(table)).single['backendSelection'],
          pairB.toSqlText());
    }
    await BackupService(dest).importArchive(bytes, accountHash: 'b');
    for (final table in transferTables.values) {
      expect((await dest.db.query(table)).single['backendSelection'], isNull);
    }
  });
  test('invalid top-level follow export fails even when includeApiKeys is true',
      () async {
    final source = await fx.db();
    await fx.seed(source);
    final settings = AISettings.defaults()
      ..backendSelection = BackendSelection.follow();
    await expectLater(
        BackupService(source).exportArchive(
            settings: settings, accountHash: 'a', includeApiKeys: true),
        throwsFormatException);
  });
}
