import 'dart:async';
import 'dart:io';
import 'package:chatgpt_app_core/chat/application/import_operation.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/pages/knowledge_base_page.dart';
import 'package:chatgpt_app_core/widget/knowledge_import_progress_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late HiDBManager storage;
  late Directory directory;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    LoginSdkConfig.install(
        LoginSdkConfig.instance.copyWith(storage: HiCacheTokenStorage()));
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    directory = await Directory.systemTemp.createTemp('knowledge_ui_');
  });
  tearDown(() async {
    await storage.db.close();
    await directory.delete(recursive: true);
    LoginSdkConfig.reset();
  });
  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 100 && !ready(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(ready(), true);
  }

  Future<void> choose(WidgetTester tester) async {
    await tester.tap(find.byTooltip('导入文档'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择文件（可多选）'));
    await tester.pump();
  }

  testWidgets('服务器 OCR 默认关闭，游客可阅读上传说明但不能启用', (tester) async {
    await tester
        .pumpWidget(MaterialApp(home: KnowledgeBasePage(storage: storage)));
    await waitFor(tester, () => find.text('搜索标题、文件夹或标签').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('导入文档'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OCR：仅本地识别'));
    await tester.pumpAndSettle();
    expect(find.textContaining('需要 OCR 的整份 PDF 会上传'), findsOneWidget);
    final button = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '使用服务器 OCR'));
    expect(button.onPressed, isNull);
    await tester.tap(find.text('仅本地识别'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('选择器等待期间作用域变化，普通文件不再入库', (tester) async {
    var current = true;
    final picked = Completer<List<String>>();
    final file = await tester.runAsync(() =>
        File('${directory.path}/private.txt').writeAsString('private content'));
    await tester.pumpWidget(MaterialApp(
        home: KnowledgeBasePage(
            storage: storage,
            isCurrent: () => current,
            selectFiles: () => picked.future)));
    await waitFor(tester, () => find.text('搜索标题、文件夹或标签').evaluate().isNotEmpty);
    await choose(tester);
    current = false;
    picked.complete([file!.path]);
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
    final rows = await tester.runAsync(() => storage.db.query('tb_kb_doc'));
    expect(rows, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('失败明细可仅重试失败项，成功文档不重复导入', (tester) async {
    final a = await tester.runAsync(
        () => File('${directory.path}/good.txt').writeAsString('good content'));
    final b = await tester
        .runAsync(() => File('${directory.path}/empty.txt').writeAsString(''));
    await tester.pumpWidget(MaterialApp(
        home: KnowledgeBasePage(
            storage: storage, selectFiles: () async => [a!.path, b!.path])));
    await waitFor(tester, () => find.text('搜索标题、文件夹或标签').evaluate().isNotEmpty);
    await choose(tester);
    await waitFor(tester, () => find.text('重试未完成文件').evaluate().isNotEmpty);
    await tester.runAsync(() => b!.writeAsString('fixed content'));
    await tester.tap(find.text('重试未完成文件'));
    await waitFor(tester, () => find.text('empty').evaluate().isNotEmpty);
    final rows = await tester.runAsync(() => storage.db.query('tb_kb_doc'));
    expect(rows, hasLength(2));
    expect(find.textContaining('无需重复导入'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('取消按钮等待资源释放，任务结束不会关闭后来打开的页面', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final gate = Completer<void>();
    final operation = ImportCancellation();
    final progress = ValueNotifier(const KnowledgeImportProgress(
        completed: 1, total: 3, filename: '扫描件.pdf', page: 2, pages: 6));
    late BuildContext host;
    await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        home: Builder(builder: (context) {
          host = context;
          return const Scaffold(body: Text('列表'));
        })));
    final task = withKnowledgeImportProgress(host,
        progress: progress, cancellation: operation, task: () => gate.future);
    await tester.pumpAndSettle();
    expect(find.textContaining('2/6'), findsOneWidget);
    await tester.tap(find.text('取消导入'));
    await tester.pump();
    expect(operation.isCancelled, true);
    expect(find.text('正在等待当前任务释放资源…'), findsOneWidget);
    navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('新页面'))));
    await tester.pumpAndSettle();
    gate.complete();
    await tester.pumpAndSettle();
    await task;
    expect(find.text('新页面'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
