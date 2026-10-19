import 'dart:async';

import 'package:chatgpt_app_core/pages/cloud_sync_page.dart';
import 'package:chatgpt_app_core/sync/cloud_sync_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('展示初始状态并可手动同步成功', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: CloudSyncPage(
        lastSyncAtLoader: () async =>
            DateTime(2026, 7, 1, 9, 5).millisecondsSinceEpoch,
        syncAction: () async => const CloudSyncResult(
          pulled: 2,
          pushed: 1,
          stale: 0,
          conflicts: ['assistant:a1'],
          conflictDetails: [
            SyncConflictDetail(
              entity: 'assistant',
              entityId: 'a1',
              reason: 'same_timestamp',
            ),
          ],
          cursor: 9,
          finishedAt: 1782869400000,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('跨设备云同步'), findsOneWidget);
    expect(find.textContaining('上次同步：2026-07-01 09:05'), findsOneWidget);
    expect(find.text('立即同步'), findsOneWidget);
    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();

    expect(find.textContaining('同步完成（手动）：拉取 2 条，上传 1 条'), findsOneWidget);
    expect(find.textContaining('未自动覆盖冲突内容'), findsOneWidget);
    expect(find.textContaining('冲突：助手 a1：同时间内容不同'), findsOneWidget);
    expect(find.textContaining('上次同步：2026-07-01'), findsOneWidget);
  });

  testWidgets('同步结果展示友好的冲突摘要并限制明细数量', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: CloudSyncPage(
        lastSyncAtLoader: () async => 0,
        syncAction: () async => const CloudSyncResult(
          pulled: 4,
          pushed: 0,
          stale: 1,
          conflicts: [
            'conversation:c1',
            'message:m1',
            'knowledge_doc:7',
            'project_knowledge:2:7',
          ],
          conflictDetails: [
            SyncConflictDetail(
              entity: 'conversation',
              entityId: 'c1',
              reason: 'remote_newer',
            ),
            SyncConflictDetail(
              entity: 'message',
              entityId: 'm1',
              reason: 'local_same_timestamp',
            ),
            SyncConflictDetail(
              entity: 'knowledge_doc',
              entityId: '7',
              reason: 'same_timestamp',
            ),
            SyncConflictDetail(
              entity: 'project_knowledge',
              entityId: '2:7',
              reason: 'unknown',
            ),
          ],
          cursor: 22,
          finishedAt: 1782869400000,
          auto: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();

    expect(find.textContaining('同步完成（自动）：拉取 4 条'), findsOneWidget);
    expect(find.textContaining('冲突 4 条'), findsOneWidget);
    expect(find.textContaining('会话 c1：远端更新，本机已跳过'), findsOneWidget);
    expect(find.textContaining('消息 m1：本地同时间内容不同'), findsOneWidget);
    expect(find.textContaining('知识库文档 7：同时间内容不同 等'), findsOneWidget);
    expect(find.textContaining('项目知识库绑定 2:7'), findsNothing);
  });

  testWidgets('同步失败时展示错误', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: CloudSyncPage(
        lastSyncAtLoader: () async => 0,
        syncAction: () async => throw const CloudSyncException('网络不可用'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('尚未同步'), findsOneWidget);

    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();

    expect(find.textContaining('同步失败：网络不可用'), findsOneWidget);
  });

  testWidgets('同步进行中禁用按钮，避免重复提交', (tester) async {
    final completer = Completer<CloudSyncResult>();
    await tester.pumpWidget(MaterialApp(
      home: CloudSyncPage(
        lastSyncAtLoader: () async => 0,
        syncAction: () => completer.future,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即同步'));
    await tester.pump();

    final button = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('同步中...'),
        matching: find.byWidgetPredicate((widget) => widget is ElevatedButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(find.text('同步中...'), findsOneWidget);

    completer.complete(const CloudSyncResult(
      pulled: 0,
      pushed: 0,
      stale: 0,
      conflicts: [],
      cursor: 0,
      finishedAt: 1782869400000,
    ));
    await tester.pumpAndSettle();

    expect(find.text('立即同步'), findsOneWidget);
  });
}
