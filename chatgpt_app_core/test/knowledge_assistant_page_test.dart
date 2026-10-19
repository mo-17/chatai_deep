import 'dart:async';
import 'dart:convert';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_assistant.dart';
import 'package:chatgpt_app_core/knowledge/knowledge_repository.dart';
import 'package:chatgpt_app_core/pages/knowledge_assistant_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/fake_voice_input.dart';

void main() {
  late HiDBManager db;
  late KnowledgeRepository repo;
  late KnowledgeAssistant assistant;
  late KnowledgeCompletion complete;
  late int calls;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    LoginSdkConfig.install(
        LoginSdkConfig.instance.copyWith(storage: HiCacheTokenStorage()));
    db = HiDBManager.test(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
    repo = await KnowledgeRepository.create(db);
    await repo.knowledge.addDocument('退款政策', '7 天内可申请退款。运费由买家承担。');
    calls = 0;
    complete = (
        {required prompt,
        required abort,
        required isCurrent,
        required beforeDispatch}) async {
      calls++;
      await beforeDispatch();
      final key = jsonDecode(prompt)['sources'][0]['id'];
      return KnowledgeModelResult(
          'fixture-model',
          ChatCompletionResult(
              content: jsonEncode({
            'status': 'supported',
            'claims': [
              {
                'text': '退款期限为7天。',
                'evidence': [
                  {'source': key, 'quote': '7 天内可申请退款。'}
                ]
              }
            ]
          })));
    };
    assistant = KnowledgeAssistant(
        repository: repo,
        isCurrent: () => true,
        complete: (
                {required prompt,
                required abort,
                required isCurrent,
                required beforeDispatch}) =>
            complete(
                prompt: prompt,
                abort: abort,
                isCurrent: isCurrent,
                beforeDispatch: beforeDispatch));
  });
  tearDown(() async {
    await db.db.close();
    LoginSdkConfig.reset();
  });

  Future<void> io(WidgetTester t) async {
    await t
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await t.pump();
  }

  Future<void> until(WidgetTester t, bool Function() ready) async {
    for (var i = 0; i < 80 && !ready(); i++) {
      await io(t);
    }
    expect(ready(), isTrue);
  }

  Future<void> mount(WidgetTester t) async {
    await t.pumpWidget(
        MaterialApp(home: KnowledgeAssistantPage(assistant: assistant)));
    await until(
        t,
        () => find
            .byKey(const ValueKey('knowledge_question'))
            .evaluate()
            .isNotEmpty);
  }

  Future<void> ask(WidgetTester t) async {
    await t.ensureVisible(find.byKey(const ValueKey('knowledge_question')));
    await t.enterText(
        find.byKey(const ValueKey('knowledge_question')), '退款期限是什么');
    await t.ensureVisible(find.text('检索并回答'));
    await t.tap(find.text('检索并回答'));
    await io(t);
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox.shrink());
    await io(t);
  }

  testWidgets('没有自动请求；提问后逐条结论可打开高亮原文', (t) async {
    await mount(t);
    expect(calls, 0);
    await ask(t);
    await until(t, () => find.text('1. 退款期限为7天。').evaluate().isNotEmpty);
    expect(calls, 1);
    final source = find.text('退款政策 · 片段 1');
    await t.ensureVisible(source);
    await t.tap(source);
    await t.pumpAndSettle();
    await until(t, () => find.text('当前原文与问答快照一致').evaluate().isNotEmpty);
    expect(find.text('当前原文与问答快照一致'), findsOneWidget);
    expect(find.textContaining('快照 SHA-256'), findsOneWidget);
    final old = BackendConfig.host;
    BackendConfig.host = 'changed-source.invalid';
    await t.pumpAndSettle();
    expect(find.text('来源环境已变化，请关闭并重新打开'), findsOneWidget);
    expect(find.textContaining('快照 SHA-256'), findsNothing);
    expect(t.takeException(), isNull);
    await close(t);
    BackendConfig.host = old;
  });
  testWidgets('资料语音提问沿用选定范围，核验后才播报并保留引用', (t) async {
    final speech = FakeVoiceInput(), voice = FakeVoiceOutput();
    await t.pumpWidget(MaterialApp(
        home: KnowledgeAssistantPage(
            assistant: assistant, speechInput: speech, voiceOutput: voice)));
    await until(
        t,
        () => find
            .byKey(const ValueKey('knowledge_question'))
            .evaluate()
            .isNotEmpty);
    await t.tap(find.byTooltip('资料语音问答'));
    await t.pump();
    await t.ensureVisible(find.text('开始语音对话'));
    await t.tap(find.text('开始语音对话'));
    await until(t, () => speech.results.isNotEmpty);
    speech.finish('退款期限是什么');
    await until(t, () => voice.requests.isNotEmpty);
    expect(voice.requests.single.text, contains('退款期限为7天'));
    expect(
        (await t.runAsync(() => repo.history()))!
            .single
            .claims
            .single
            .evidence
            .single
            .quote,
        '7 天内可申请退款。');
    await close(t);
  });
  testWidgets('资料语音的无引用模型正文被拦截，不进入朗读', (t) async {
    complete = (
            {required prompt,
            required abort,
            required isCurrent,
            required beforeDispatch}) async =>
        const KnowledgeModelResult(
            'fixture', ChatCompletionResult(content: '无引用的模型正文'));
    final speech = FakeVoiceInput(), voice = FakeVoiceOutput();
    await t.pumpWidget(MaterialApp(
        home: KnowledgeAssistantPage(
            assistant: assistant, speechInput: speech, voiceOutput: voice)));
    await until(
        t,
        () => find
            .byKey(const ValueKey('knowledge_question'))
            .evaluate()
            .isNotEmpty);
    await t.tap(find.byTooltip('资料语音问答'));
    await t.pump();
    await t.ensureVisible(find.text('开始语音对话'));
    await t.tap(find.text('开始语音对话'));
    await until(t, () => speech.results.isNotEmpty);
    speech.finish('退款期限是什么');
    await until(
        t, () => find.textContaining('本轮没有通过引用核验').evaluate().isNotEmpty);
    expect(voice.requests, isEmpty);
    expect(find.text('无引用的模型正文'), findsNothing);
    await close(t);
  });
  testWidgets('模型胡编内容被拦截，不在页面显示', (t) async {
    complete = (
            {required prompt,
            required abort,
            required isCurrent,
            required beforeDispatch}) async =>
        const KnowledgeModelResult(
            'fixture',
            ChatCompletionResult(
                content:
                    '{"status":"supported","claims":[{"text":"UNVERIFIED_SECRET","evidence":[]}]}'));
    await mount(t);
    await ask(t);
    await until(t, () => find.text('回答未通过引用核验，已拦截正文').evaluate().isNotEmpty);
    expect(find.textContaining('UNVERIFIED_SECRET'), findsNothing);
    await close(t);
  });
  testWidgets('取消并清空选择后禁用发送，不回退到全部资料', (t) async {
    await mount(t);
    await t.tap(find.text('选择资料 · 已选 1/1 篇'));
    await t.pumpAndSettle();
    await t.tap(find.byType(CheckboxListTile));
    await t.pump();
    await t.tap(find.text('使用所选资料'));
    await t.pumpAndSettle();
    final button = t.widget<FilledButton>(find.ancestor(
        of: find.text('检索并回答'),
        matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(button.onPressed, isNull);
    expect(calls, 0);
    await close(t);
  });
  testWidgets('退后台停止请求，迟到回答不显示或保存，也不自动继续', (t) async {
    final pending = Completer<KnowledgeModelResult>();
    complete = (
        {required prompt,
        required abort,
        required isCurrent,
        required beforeDispatch}) async {
      calls++;
      return pending.future;
    };
    await mount(t);
    await ask(t);
    await until(t, () => calls == 1);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await io(t);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await io(t);
    pending.complete(const KnowledgeModelResult(
        'late', ChatCompletionResult(content: 'LATE_ANSWER')));
    await io(t);
    expect(find.textContaining('LATE_ANSWER'), findsNothing);
    expect((await t.runAsync(repo.history))!, isEmpty);
    expect(calls, 1);
    await close(t);
  });
  testWidgets('后端来源改变时隐藏旧问答，不能在新来源继续展示', (t) async {
    await mount(t);
    await ask(t);
    await until(t, () => find.text('1. 退款期限为7天。').evaluate().isNotEmpty);
    final old = BackendConfig.host;
    BackendConfig.host = 'scope-change.invalid';
    await t.pump();
    expect(find.text('账号或资料环境已变化，请返回并重新打开'), findsOneWidget);
    expect(find.text('1. 退款期限为7天。'), findsNothing);
    await close(t);
    BackendConfig.host = old;
  });
  testWidgets('320px 大字体可滚动提问及查看回答，无布局溢出', (t) async {
    t.view.physicalSize = const Size(320, 600);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await mount(t);
    await ask(t);
    await until(t, () => find.text('1. 退款期限为7天。').evaluate().isNotEmpty);
    await t.ensureVisible(find.text('退款政策 · 片段 1'));
    expect(t.takeException(), isNull);
    await close(t);
  });
}
