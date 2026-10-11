import 'dart:typed_data';

import 'package:chatgpt_app_core/backup/backup_archive_limits.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/pages/backup_restore_page.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('备份选择器在读取 path 前拒绝声明超限文件，并保留合法内存输入', () async {
    final oversized = PlatformFile(
      name: 'crafted.zip',
      size: BackupArchiveLimits.standard.maxCompressedBytes + 1,
      path: '/path-must-not-be-read/crafted.zip',
    );
    final legal = PlatformFile(
      name: 'legal.zip',
      size: 4,
      bytes: Uint8List.fromList([0x50, 0x4b, 0x05, 0x06]),
    );

    await expectLater(
      readBackupImportFile(oversized),
      throwsA(isA<FormatException>()),
    );
    expect(await readBackupImportFile(legal), legal.bytes);
  });

  Future<void> useLargeSurface(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  BackupPreview preview({bool includeApiKeys = false}) => BackupPreview(
        formatVersion: BackupService.formatVersion,
        exportedAt: 1719820800000,
        accountHash: 'backup-account',
        includeApiKeys: includeApiKeys,
        conversations: 3,
        messages: 9,
        assistants: 2,
        assistantMemories: 3,
        favorites: 1,
        projects: 1,
        knowledgeDocs: 4,
        knowledgeChunks: 12,
        projectKnowledge: 2,
        avatarAssets: 1,
        fileAssets: 2,
        generatedImageAssets: 3,
        hasSettings: true,
        integrityVerified: true,
        warnings: const ['备份来自其他账号，导入会写入当前账号'],
        conflictSummary: const BackupConflictSummary(
          localRows: 5,
          replacingRows: 1,
          localOnlyRows: 2,
          backupOnlyRows: 3,
          changedRows: 1,
          tableConflicts: [
            BackupTableConflict(
              table: 'tb_conversation_list',
              localRows: 2,
              backupRows: 3,
              replacingRows: 1,
              localOnlyRows: 1,
              backupOnlyRows: 2,
              changedRows: 1,
            ),
            BackupTableConflict(
              table: 'tb_messages',
              localRows: 3,
              backupRows: 9,
              replacingRows: 0,
              localOnlyRows: 3,
              backupOnlyRows: 9,
              changedRows: 0,
            ),
            BackupTableConflict(
              table: 'tb_assistant',
              localRows: 2,
              backupRows: 2,
              replacingRows: 1,
              localOnlyRows: 1,
              backupOnlyRows: 1,
              changedRows: 1,
            ),
            BackupTableConflict(
              table: 'tb_kb_doc',
              localRows: 1,
              backupRows: 4,
              replacingRows: 0,
              localOnlyRows: 1,
              backupOnlyRows: 4,
              changedRows: 0,
            ),
            BackupTableConflict(
              table: 'tb_kb_chunk',
              localRows: 2,
              backupRows: 12,
              replacingRows: 0,
              localOnlyRows: 2,
              backupOnlyRows: 12,
              changedRows: 0,
            ),
          ],
        ),
      );

  Future<BackupImportMode?> pumpDialog(WidgetTester tester) async {
    await useLargeSurface(tester);
    BackupImportMode? selected;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                selected = await showDialog<BackupImportMode>(
                  context: context,
                  builder: (_) => BackupImportPreviewDialog(preview: preview()),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    return selected;
  }

  Future<void> selectMode(WidgetTester tester, String label) async {
    await tester.tap(find.byType(DropdownButtonFormField<BackupImportMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('导入预览展示数量、告警、冲突摘要和五种导入方式', (tester) async {
    await pumpDialog(tester);

    expect(find.text('导入预览'), findsOneWidget);
    expect(find.textContaining('备份版本：v${BackupService.formatVersion}'),
        findsOneWidget);
    expect(find.textContaining('来源账号：ba…nt'), findsOneWidget);
    expect(find.textContaining('内容与清单一致（不代表来源可信）'), findsOneWidget);
    expect(find.textContaining('AI 设置：包含（不含 API Key）'), findsOneWidget);
    expect(find.textContaining('会话：3'), findsOneWidget);
    expect(find.textContaining('助手记忆：3'), findsOneWidget);
    expect(find.textContaining('个人记忆：0'), findsOneWidget);
    expect(find.textContaining('附件原始文件：2'), findsOneWidget);
    expect(find.textContaining('生成图片：3'), findsOneWidget);
    expect(find.textContaining('备份来自其他账号'), findsOneWidget);
    expect(find.textContaining('当前本地数据：5 行'), findsOneWidget);
    expect(find.textContaining('tb_conversation_list：覆盖 1'), findsOneWidget);
    expect(find.textContaining('预计影响：覆盖全部数据'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<BackupImportMode>));
    await tester.pumpAndSettle();
    expect(find.text('覆盖全部'), findsWidgets);
    expect(find.text('仅导入项目和会话'), findsWidgets);
    expect(find.text('仅导入助手'), findsWidgets);
    expect(find.text('仅导入知识库'), findsWidgets);
    expect(find.text('合并导入'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择项目和会话模式后更新警告和确认返回值', (tester) async {
    await useLargeSurface(tester);
    BackupImportMode? selected;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                selected = await showDialog<BackupImportMode>(
                  context: context,
                  builder: (_) => BackupImportPreviewDialog(preview: preview()),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('覆盖导入'), findsOneWidget);
    expect(find.textContaining('覆盖全部不可撤销'), findsOneWidget);

    await selectMode(tester, '仅导入项目和会话');
    expect(find.textContaining('会替换项目、会话和消息'), findsOneWidget);
    expect(find.textContaining('预计影响：仅项目、会话和消息'), findsOneWidget);
    expect(find.textContaining('新增 11 行'), findsOneWidget);
    expect(find.text('仅导入项目和会话'), findsWidgets);

    await tester.tap(find.widgetWithText(TextButton, '仅导入项目和会话'));
    await tester.pumpAndSettle();
    expect(selected, BackupImportMode.projectConversationsOnly);
    expect(tester.takeException(), isNull);
  });

  testWidgets('助手和知识库模式有独立风险文案', (tester) async {
    await pumpDialog(tester);

    await selectMode(tester, '仅导入助手');
    expect(find.textContaining('会替换助手列表'), findsOneWidget);
    expect(find.textContaining('助手引用'), findsOneWidget);
    expect(find.textContaining('预计影响：仅助手'), findsOneWidget);
    expect(find.textContaining('仅本地助手将删除 1 行'), findsOneWidget);

    await selectMode(tester, '仅导入知识库');
    expect(find.textContaining('不会修改会话、消息、助手、收藏、项目和 AI 设置'), findsOneWidget);
    expect(find.textContaining('预计影响：仅知识库'), findsOneWidget);
    expect(find.textContaining('新增 16 行'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('合并导入模式说明追加重映射且不删除本地数据', (tester) async {
    await pumpDialog(tester);

    await selectMode(tester, '合并导入');
    expect(find.textContaining('追加为新数据'), findsOneWidget);
    expect(find.textContaining('不覆盖本地数据和 AI 设置'), findsOneWidget);
    expect(find.textContaining('预计影响：合并导入'), findsOneWidget);
    expect(find.textContaining('同 ID/cid 会重映射'), findsOneWidget);
    expect(find.textContaining('仅本地数据将保留'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '合并导入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('跨账号导入隐藏完整账号且需额外确认', (tester) async {
    await useLargeSurface(tester);
    BackupImportMode? selected;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              selected = await showDialog<BackupImportMode>(
                context: context,
                builder: (_) => BackupImportPreviewDialog(
                  preview: preview(),
                  targetAccountHash: 'current-account',
                ),
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.textContaining('ba…nt → cu…nt'), findsOneWidget);
    expect(find.text('backup-account'), findsNothing);
    expect(find.text('current-account'), findsNothing);
    final confirmBefore = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '覆盖导入'),
    );
    expect(confirmBefore.onPressed, isNull);

    await tester.tap(find.text('我确认将此备份导入当前账号'));
    await tester.pump();
    final confirmAfter = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '覆盖导入'),
    );
    expect(confirmAfter.onPressed, isNotNull);
    await tester.tap(find.widgetWithText(TextButton, '覆盖导入'));
    await tester.pumpAndSettle();
    expect(selected, BackupImportMode.overwriteAll);
  });

  testWidgets('包含 API/MCP 凭据的明文 ZIP 必须单独确认来源风险', (tester) async {
    await useLargeSurface(tester);
    BackupImportMode? selected;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              selected = await showDialog<BackupImportMode>(
                context: context,
                builder: (_) => BackupImportPreviewDialog(
                  preview: preview(includeApiKeys: true),
                  targetAccountHash: 'backup-account',
                ),
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.textContaining('ZIP 未加密'), findsWidgets);
    expect(find.textContaining('API Key 或 MCP 鉴权信息'), findsOneWidget);
    final confirmBefore = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '覆盖导入'),
    );
    expect(confirmBefore.onPressed, isNull);

    await tester.tap(find.text('我确认备份来自可信来源，并接受凭据泄露风险'));
    await tester.pump();
    final confirmAfter = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '覆盖导入'),
    );
    expect(confirmAfter.onPressed, isNotNull);
    await tester.tap(find.widgetWithText(TextButton, '覆盖导入'));
    await tester.pumpAndSettle();
    expect(selected, BackupImportMode.overwriteAll);
  });
}
