import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('角色卡导出格式文案区分完整格式和 Tavern 兼容格式', () {
    expect(AssistantRoleCardService.fullExportLabel, '完整角色卡');
    expect(AssistantRoleCardService.fullExportDescription, contains('同款 App'));
    expect(AssistantRoleCardService.tavernExportLabel, 'Tavern V2 兼容');
    expect(AssistantRoleCardService.tavernExportDescription,
        contains('SillyTavern'));
    expect(AssistantRoleCardService.tavernPngExportLabel, 'Tavern V2 PNG');
    expect(
        AssistantRoleCardService.tavernPngExportDescription, contains('酒馆常用'));
  });

  test('导出角色卡只包含可分享字段，不携带数据库身份', () {
    final assistant = AssistantModel(
      id: 99,
      name: '艾琳',
      emoji: '🕯️',
      description: '浮岛钟表师',
      prompt: '保持克制而温柔',
      openingMessage: '你听见钟声了吗？',
      exampleDialogs: '用户：你好\n助手：夜色很安静。',
      memoryBook: '钟声 => 钟声代表浮岛潮汐',
      defaultVoiceStyle: 'female',
      providerId: 'openai',
      model: 'gpt-4o',
      useTools: false,
      toolIds: ['knowledge_search'],
      createdAt: 1,
      updatedAt: 2,
    );

    final json = AssistantRoleCardService.exportJson(
      assistant,
      exportedAt: DateTime.utc(2026, 7, 4),
    );
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    expect(decoded['format'], AssistantRoleCardService.format);
    expect(decoded['version'], AssistantRoleCardService.version);
    expect(decoded['exportedAt'], '2026-07-04T00:00:00.000Z');

    final payload = decoded['assistant'] as Map<String, dynamic>;
    expect(payload['name'], '艾琳');
    expect(payload['memoryBook'], '钟声 => 钟声代表浮岛潮汐');
    expect(payload['toolIds'], ['knowledge_search']);
    expect(payload.containsKey('id'), isFalse);
    expect(payload.containsKey('createdAt'), isFalse);
    expect(payload.containsKey('updatedAt'), isFalse);
  });

  test('可导出 SillyTavern V2 兼容 JSON 并保留世界书结构', () {
    final assistant = AssistantModel(
      name: '艾琳',
      emoji: '🕯️',
      description: '浮岛钟表师，适合慢节奏角色扮演',
      prompt: '''
[系统提示]
保持沉浸，不要跳出角色。

[角色设定]
艾琳 是浮岛钟表师，习惯在雨夜修表。

[性格]
克制、温柔、少解释。

[场景]
用户 和 艾琳 在旧书店重逢。

[后续指令]
延续上一幕情绪。
''',
      openingMessage: '你听见钟声了吗？',
      exampleDialogs: '''
用户：你好
助手：夜色很安静。

[备选开场白]
雨声盖住了脚步声。
''',
      memoryBook: '[sec=潮汐|浮岛] [p=12] 钟声 => 钟声代表艾琳记忆里的浮岛潮汐。\n'
          '[off] [re] 第[一二三]幕 || Act\\s+\\d+ => 按幕次切换叙事节奏。\n'
          '城市由七座浮岛组成。',
      defaultVoiceStyle: 'female',
      providerId: 'openai',
      model: 'gpt-4o',
      toolIds: ['knowledge_search'],
    );

    final json = AssistantRoleCardService.exportTavernV2Json(
      assistant,
      exportedAt: DateTime.utc(2026, 7, 5),
    );
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    expect(decoded['spec'], 'chara_card_v2');
    expect(decoded['spec_version'], '2.0');
    final data = decoded['data'] as Map<String, dynamic>;
    expect(data['name'], '艾琳');
    expect(data['description'], '艾琳 是浮岛钟表师，习惯在雨夜修表。');
    expect(data['personality'], '克制、温柔、少解释。');
    expect(data['scenario'], '用户 和 艾琳 在旧书店重逢。');
    expect(data['system_prompt'], '保持沉浸，不要跳出角色。');
    expect(data['post_history_instructions'], '延续上一幕情绪。');
    expect(data['first_mes'], '你听见钟声了吗？');
    expect(data['mes_example'], '用户：你好\n助手：夜色很安静。');
    expect(data['alternate_greetings'], ['雨声盖住了脚步声。']);
    expect(data['creator_notes'], '浮岛钟表师，适合慢节奏角色扮演');
    expect(data['tags'], ['有默认音色', '世界书', '工具']);

    final book = data['character_book'] as Map<String, dynamic>;
    final entries = book['entries'] as List;
    expect(entries, hasLength(3));
    expect(entries.first, {
      'content': '钟声代表艾琳记忆里的浮岛潮汐。',
      'enabled': true,
      'keys': ['钟声'],
      'selective': true,
      'secondary_keys': ['潮汐', '浮岛'],
      'priority': 12,
    });
    expect(entries[1], {
      'content': '按幕次切换叙事节奏。',
      'enabled': false,
      'keys': [r'第[一二三]幕', r'Act\s+\d+'],
      'regex': true,
    });
    expect(entries[2], {
      'content': '城市由七座浮岛组成。',
      'enabled': true,
      'constant': true,
    });
    final extensions = data['extensions'] as Map<String, dynamic>;
    final appMeta = extensions['chatai_deep'] as Map<String, dynamic>;
    expect(appMeta['exportedAt'], '2026-07-05T00:00:00.000Z');
    expect(appMeta['defaultVoiceStyle'], 'female');
    expect(appMeta['providerId'], 'openai');
    expect(appMeta['model'], 'gpt-4o');
    expect(appMeta['toolIds'], ['knowledge_search']);

    final imported = AssistantRoleCardService.importJson(json);
    expect(imported.name, '艾琳');
    expect(imported.description, '浮岛钟表师，适合慢节奏角色扮演\n标签：有默认音色、世界书、工具');
    expect(imported.prompt, contains('[系统提示]\n保持沉浸，不要跳出角色。'));
    expect(imported.prompt, contains('[角色设定]\n艾琳 是浮岛钟表师，习惯在雨夜修表。'));
    expect(imported.memoryBook, contains('[sec=潮汐|浮岛] [p=12] 钟声 =>'));
    expect(
        imported.memoryBook, contains('[off] [re] 第[一二三]幕 || Act\\s+\\d+ =>'));
    expect(imported.memoryBook, contains('城市由七座浮岛组成。'));
    expect(imported.defaultVoiceStyle, 'female');
    expect(imported.providerId, 'openai');
    expect(imported.model, 'gpt-4o');
    expect(imported.useTools, isTrue);
    expect(imported.toolIds, ['knowledge_search']);

    final sanitized = AssistantRoleCardService.sanitizeForImport(imported);
    expect(sanitized.defaultVoiceStyle, isEmpty);
    expect(sanitized.providerId, isEmpty);
    expect(sanitized.model, isEmpty);
    expect(sanitized.toolIds, isNull);
  });

  test('可导出 SillyTavern 常用 PNG 角色卡并从 PNG 元数据导回', () {
    final assistant = AssistantModel(
      name: 'Fuka Shikuzaki',
      emoji: '📘',
      description: '日本女学生',
      prompt: '''
[角色设定]
志久崎 风香是一名不太擅长主动说话的学生。

[性格]
害羞、观察细致。
''',
      openingMessage: '啊...嗯，我会的。',
      exampleDialogs: '用户：你好\n助手：啊...你好。',
      memoryBook: '黑板擦 => 风香会紧张',
    );

    final pngBytes = AssistantRoleCardService.exportTavernV2Png(
      assistant,
      exportedAt: DateTime.utc(2026, 7, 6),
    );

    expect(pngBytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(AssistantRoleCardService.tavernPngFilenameFor(assistant),
        'tavern_Fuka_Shikuzaki.png');

    final imported = AssistantRoleCardService.importBytes(
      pngBytes,
      filename: 'fuka.png',
    );
    expect(imported.name, 'Fuka Shikuzaki');
    expect(imported.description, contains('日本女学生'));
    expect(imported.prompt, contains('[角色设定]'));
    expect(imported.prompt, contains('志久崎 风香'));
    expect(imported.openingMessage, '啊...嗯，我会的。');
    expect(imported.exampleDialogs, '用户：你好\n助手：啊...你好。');
    expect(imported.memoryBook, contains('黑板擦 => 风香会紧张'));

    final rawPng = String.fromCharCodes(pngBytes);
    expect(rawPng, contains('chara'));
    expect(rawPng, isNot(contains('chara_card_v2')));
  });

  test('导入角色卡作为新助手，保留角色卡字段和工具绑定', () {
    final imported = AssistantRoleCardService.importJson('''
{
  "format": "chatai_deep_assistant_card",
  "version": 1,
  "assistant": {
    "id": 99,
    "name": "艾琳",
    "emoji": "🕯️",
    "description": "浮岛钟表师",
    "prompt": "保持克制而温柔",
    "openingMessage": "你听见钟声了吗？",
    "exampleDialogs": "用户：你好\\n助手：夜色很安静。",
    "memoryBook": "钟声 => 钟声代表浮岛潮汐",
    "defaultVoiceStyle": "female",
    "providerId": "openai",
    "model": "gpt-4o",
    "useTools": false,
    "toolIds": ["knowledge_search"],
    "createdAt": 1,
    "updatedAt": 2
  }
}
''');

    expect(imported.id, isNull);
    expect(imported.createdAt, 0);
    expect(imported.updatedAt, 0);
    expect(imported.name, '艾琳');
    expect(imported.description, '浮岛钟表师');
    expect(imported.memoryBook, '钟声 => 钟声代表浮岛潮汐');
    expect(imported.useTools, isFalse);
    expect(imported.toolIds, ['knowledge_search']);
  });

  test('导入清洗默认丢弃工具绑定、模型覆盖和默认语音', () {
    final original = AssistantModel(
      name: '艾琳',
      defaultVoiceStyle: 'custom_sherpa:voice_a',
      providerId: 'openai',
      model: 'gpt-4o',
      useTools: false,
      toolIds: ['web_search'],
    );

    final sanitized = AssistantRoleCardService.sanitizeForImport(original);

    expect(sanitized.name, '艾琳');
    expect(sanitized.defaultVoiceStyle, isEmpty);
    expect(sanitized.providerId, isEmpty);
    expect(sanitized.model, isEmpty);
    expect(sanitized.useTools, isTrue);
    expect(sanitized.toolIds, isNull);
  });

  test('导入清洗可按用户选择保留高影响字段', () {
    final original = AssistantModel(
      name: '艾琳',
      defaultVoiceStyle: 'custom_sherpa:voice_a',
      providerId: 'openai',
      model: 'gpt-4o',
      useTools: false,
      toolIds: ['web_search'],
    );

    final sanitized = AssistantRoleCardService.sanitizeForImport(
      original,
      keepTools: true,
      keepModelOverride: true,
      keepDefaultVoice: true,
    );

    expect(sanitized.defaultVoiceStyle, 'custom_sherpa:voice_a');
    expect(sanitized.providerId, 'openai');
    expect(sanitized.model, 'gpt-4o');
    expect(sanitized.useTools, isFalse);
    expect(sanitized.toolIds, ['web_search']);
  });

  test('导入预览摘要展示开场、世界书结构和高影响配置', () {
    final assistant = AssistantModel(
      name: '艾琳',
      prompt: '保持沉浸',
      openingMessage: '你听见钟声了吗？',
      exampleDialogs: '''
用户：你好
助手：夜色很安静。

[备选开场白]
雨声盖住了脚步声。
''',
      memoryBook: '钟声 => 钟声代表浮岛潮汐\n'
          '[off] 雨夜 => 雨夜会触发旧书店记忆\n'
          '城市由七座浮岛组成。',
      defaultVoiceStyle: 'female',
      providerId: 'openai',
      model: 'gpt-4o',
      useTools: false,
      toolIds: ['knowledge_search', 'web_search'],
    );

    final summary = AssistantRoleCardService.importPreviewSummaryText(
      assistant,
      hasAvatar: true,
    );

    expect(summary, contains('提示词 4 字'));
    expect(summary, contains('开场 8 字'));
    expect(summary, contains('示例 2 行'));
    expect(summary, contains('备选开场 1'));
    expect(summary, contains('世界书 3 条（常驻 1 / 关键词 2 / 禁用 1）'));
    expect(summary, contains('工具关闭 / 工具 2 / 模型覆盖 / 默认语音'));
    expect(summary, contains('含头像'));
  });

  test('导入预览摘要在缺少开场时给出明确提示', () {
    final assistant = AssistantModel(
      name: '空白角色',
      prompt: '',
      openingMessage: '',
    );

    expect(
      AssistantRoleCardService.importPreviewSummaryText(assistant),
      '提示词 0 字 · 无开场',
    );
  });

  test('覆盖导入默认保留本地高影响配置，可按用户选择改用外部卡配置', () {
    final existing = AssistantModel(
      name: '艾琳',
      defaultVoiceStyle: 'custom_sherpa:local_voice',
      providerId: 'deepseek',
      model: 'deepseek-chat',
      useTools: false,
      toolIds: ['knowledge_search'],
    );
    final imported = AssistantModel(
      name: '艾琳',
      defaultVoiceStyle: 'custom_sherpa:incoming_voice',
      providerId: 'openai',
      model: 'gpt-4o',
      useTools: true,
      toolIds: ['web_search'],
    );

    final keepLocal = AssistantRoleCardService.sanitizeForImport(
      imported,
      keepTools: true,
      keepModelOverride: true,
      keepDefaultVoice: true,
    );
    AssistantRoleCardService.preserveLocalOverwriteSettings(
      keepLocal,
      existing,
    );

    expect(keepLocal.defaultVoiceStyle, 'custom_sherpa:local_voice');
    expect(keepLocal.providerId, 'deepseek');
    expect(keepLocal.model, 'deepseek-chat');
    expect(keepLocal.useTools, isFalse);
    expect(keepLocal.toolIds, ['knowledge_search']);

    final keepIncoming = AssistantRoleCardService.sanitizeForImport(
      imported,
      keepTools: true,
      keepModelOverride: true,
      keepDefaultVoice: true,
    );
    AssistantRoleCardService.preserveLocalOverwriteSettings(
      keepIncoming,
      existing,
      keepIncomingTools: true,
      keepIncomingModelOverride: true,
      keepIncomingDefaultVoice: true,
    );

    expect(keepIncoming.defaultVoiceStyle, 'custom_sherpa:incoming_voice');
    expect(keepIncoming.providerId, 'openai');
    expect(keepIncoming.model, 'gpt-4o');
    expect(keepIncoming.useTools, isTrue);
    expect(keepIncoming.toolIds, ['web_search']);
  });

  test('角色卡导入结果文案区分新增、更新和跳过', () {
    expect(
      AssistantRoleCardService.importResultText(
        createdCount: 2,
        updatedCount: 0,
      ),
      '角色卡已保存：新增 2 张',
    );
    expect(
      AssistantRoleCardService.importResultText(
        createdCount: 0,
        updatedCount: 3,
        skippedCount: 1,
      ),
      '角色卡已保存：更新 3 张，跳过 1 个文件',
    );
    expect(
      AssistantRoleCardService.importResultText(
        createdCount: 1,
        updatedCount: 2,
        skippedCount: 4,
      ),
      '角色卡已保存：新增 1 张，更新 2 张，跳过 4 个文件',
    );
    expect(
      AssistantRoleCardService.importResultText(
        createdCount: 0,
        updatedCount: 0,
      ),
      '未保存角色卡',
    );
  });

  test('格式化并追加世界书条目，关键词留空时作为常驻设定', () {
    final line = AssistantRoleCardService.formatMemoryBookEntry(
      keywords: ' 钟声， 潮汐 /浮岛 ',
      content: ' 钟声代表\n浮岛潮汐 ',
      priority: 5,
    );

    expect(line, '[p=5] 钟声, 潮汐, 浮岛 => 钟声代表 浮岛潮汐');

    final alwaysOn = AssistantRoleCardService.formatMemoryBookEntry(
      keywords: '',
      content: ' 城市由七座浮岛组成 ',
      enabled: false,
    );

    expect(alwaysOn, '[off] 城市由七座浮岛组成');

    final merged = AssistantRoleCardService.appendMemoryBookEntry(
      '旧设定 => 旧内容\n\n',
      keywords: '银钥匙',
      content: '银钥匙属于失踪船长',
    );

    expect(merged, '旧设定 => 旧内容\n银钥匙 => 银钥匙属于失踪船长');
  });

  test('世界书内容去重忽略空白和关键词差异', () {
    const raw = '''
钟声 => 钟声代表 浮岛潮汐
城市由七座浮岛组成。
''';

    expect(
      AssistantRoleCardService.hasDuplicateMemoryContent(raw, '钟声代表\n浮岛潮汐'),
      isTrue,
    );
    expect(
      AssistantRoleCardService.hasDuplicateMemoryContent(raw, '不存在的新设定'),
      isFalse,
    );
  });

  test('合并世界书会保留旧条目并追加新卡未重复条目', () {
    const current = '''
钟声 => 钟声代表 浮岛潮汐
[off] 城市由七座浮岛组成。
''';
    const incoming = '''
潮汐 => 钟声代表  浮岛潮汐
[sec=旧书店|雨夜] [p=8] 银钥匙 => 银钥匙属于失踪船长
# 注释不会导入
''';

    final preview =
        AssistantRoleCardService.mergeMemoryBookPreview(current, incoming);
    final merged = AssistantRoleCardService.mergeMemoryBooks(current, incoming);

    expect(
      merged,
      '钟声 => 钟声代表 浮岛潮汐\n'
      '[off] 城市由七座浮岛组成。\n'
      '[sec=旧书店|雨夜] [p=8] 银钥匙 => 银钥匙属于失踪船长',
    );
    expect(preview.mergedText, merged);
    expect(preview.existingCount, 2);
    expect(preview.incomingCount, 2);
    expect(preview.appendedCount, 1);
    expect(preview.skippedDuplicateCount, 1);
    expect(preview.skippedInvalidCount, 0);
    expect(preview.mergedCount, 3);
    expect(preview.compactSummary, '保留旧 2 / 追加新 1 / 跳过重复 1');
    expect(preview.appendedLines, [
      '[sec=旧书店|雨夜] [p=8] 银钥匙 => 银钥匙属于失踪船长',
    ]);
    expect(preview.appendedPreviewLines(), [
      '[sec=旧书店|雨夜] [p=8] 银钥匙 => 银钥匙属于失踪船长',
    ]);
  });

  test('格式化并追加示例对话，重复检测忽略空白', () {
    final snippet = AssistantRoleCardService.formatExampleDialogTurn(
      userMessage: '  你好\n艾琳 ',
      assistantMessage: ' 夜色 很安静。 ',
    );

    expect(snippet, '用户：你好 艾琳\n助手：夜色 很安静。');

    final merged = AssistantRoleCardService.appendExampleDialog(
      '用户：去哪？\n助手：向北。',
      snippet,
    );

    expect(
      merged,
      '用户：去哪？\n助手：向北。\n\n用户：你好 艾琳\n助手：夜色 很安静。',
    );
    expect(
      AssistantRoleCardService.hasDuplicateExampleDialog(
        merged,
        '用户：你好艾琳\n助手：夜色很安静。',
      ),
      isTrue,
    );
    expect(
      AssistantRoleCardService.hasDuplicateExampleDialog(
        merged,
        '用户：新的问题\n助手：新的回答',
      ),
      isFalse,
    );
  });

  test('追加示例对话会插入备选开场白之前，确保新样例可注入', () {
    const raw = '''
用户：你好
助手：夜色很安静。

[备选开场白]
雨声盖住了脚步声。

钟塔今晚没有准点报时。
''';
    final snippet = AssistantRoleCardService.formatExampleDialogTurn(
      userMessage: '你是谁？',
      assistantMessage: '我是守钟人艾琳。',
    );

    final appended = AssistantRoleCardService.appendExampleDialog(raw, snippet);

    expect(appended, contains('$snippet\n\n[备选开场白]'));
    expect(
      AssistantRoleCardService.exampleDialogPromptText(appended),
      contains(snippet),
    );
    expect(
      AssistantRoleCardService.alternateGreetings(appended),
      ['雨声盖住了脚步声。', '钟塔今晚没有准点报时。'],
    );
    expect(
      AssistantRoleCardService.hasDuplicateExampleDialog(appended, snippet),
      isTrue,
    );
    expect(
      AssistantRoleCardService.hasDuplicateExampleDialog(
        appended,
        '雨声盖住了脚步声。',
      ),
      isFalse,
    );
  });

  test('备选开场白支持 header 同行文本', () {
    const raw = '''
用户：你好
助手：夜色很安静。

[备选开场白] 雨声盖住了脚步声。

钟塔今晚没有准点报时。
[alternate_greetings] 雾从码头爬上来。
重复  空白
重复空白
''';
    final snippet = AssistantRoleCardService.formatExampleDialogTurn(
      userMessage: '你是谁？',
      assistantMessage: '我是守钟人艾琳。',
    );

    expect(
      AssistantRoleCardService.exampleDialogPromptText(raw),
      '用户：你好\n助手：夜色很安静。',
    );
    expect(AssistantRoleCardService.alternateGreetings(raw), [
      '雨声盖住了脚步声。',
      '钟塔今晚没有准点报时。',
      '雾从码头爬上来。',
      '重复 空白',
    ]);

    final appended = AssistantRoleCardService.appendExampleDialog(raw, snippet);
    expect(appended, contains('$snippet\n\n[备选开场白] 雨声盖住了脚步声。'));
    expect(
      AssistantRoleCardService.exampleDialogPromptText(appended),
      contains(snippet),
    );
  });

  test('从示例对话中提取备选开场白并去重', () {
    final greetings = AssistantRoleCardService.alternateGreetings('''
用户：你好
助手：夜色很安静。

[备选开场白]
雨声盖住了脚步声。

钟塔今晚没有准点报时。
雨声 盖住了 脚步声。
''');

    expect(greetings, [
      '雨声盖住了脚步声。',
      '钟塔今晚没有准点报时。',
    ]);
  });

  test('兼容直接导出的 AssistantModel JSON 和旧 tools 字段', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'name': '旧助手',
      'prompt': '旧格式',
      'tools': jsonEncode(['web_search']),
    }));

    expect(imported.name, '旧助手');
    expect(imported.prompt, '旧格式');
    expect(imported.toolIds, ['web_search']);
  });

  test('兼容 SillyTavern character_card_v2 JSON', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {
        'name': '艾琳',
        'description': '{{char}} 是浮岛钟表师，习惯在雨夜修表。',
        'personality': '克制、温柔、少解释。',
        'scenario': '{{user}} 和 {{char}} 在旧书店重逢。',
        'first_mes': '你听见钟声了吗？',
        'mes_example': '<START>\n{{user}}：你好\n{{char}}：夜色很安静。',
        'creator_notes': '适合慢节奏角色扮演',
        'system_prompt': '保持沉浸，不要跳出角色。',
        'post_history_instructions': '延续上一幕情绪。',
        'tags': ['慢热', '奇幻'],
        'alternate_greetings': [
          '雨声盖住了脚步声。',
          '钟塔今晚没有准点报时。',
        ],
        'character_book': {
          'entries': [
            {
              'keys': ['钟声', '潮汐'],
              'secondary_keys': ['{{char}}', '浮岛'],
              'content': '钟声代表 {{char}} 记忆里的浮岛潮汐。',
              'enabled': true,
              'priority': 12,
            },
            {
              'constant': true,
              'content': '城市由七座浮岛组成。',
              'enabled': true,
            },
            {
              'keys': ['废稿'],
              'content': '这条不应导入。',
              'enabled': false,
            },
          ],
        },
      },
    }));

    expect(imported.name, '艾琳');
    expect(
      imported.description,
      '艾琳 是浮岛钟表师，习惯在雨夜修表。\n适合慢节奏角色扮演\n标签：慢热、奇幻',
    );
    expect(imported.prompt, contains('[系统提示]\n保持沉浸，不要跳出角色。'));
    expect(imported.prompt, contains('[角色设定]\n艾琳 是浮岛钟表师，习惯在雨夜修表。'));
    expect(imported.prompt, contains('[性格]\n克制、温柔、少解释。'));
    expect(imported.prompt, contains('[场景]\n用户 和 艾琳 在旧书店重逢。'));
    expect(imported.prompt, contains('[后续指令]\n延续上一幕情绪。'));
    expect(imported.openingMessage, '你听见钟声了吗？');
    expect(imported.exampleDialogs, contains('用户：你好'));
    expect(imported.exampleDialogs, contains('艾琳：夜色很安静。'));
    expect(imported.exampleDialogs, contains('[备选开场白]\n雨声盖住了脚步声。'));
    expect(imported.exampleDialogs, contains('钟塔今晚没有准点报时。'));
    expect(
      imported.memoryBook,
      contains('[p=12] 钟声,潮汐,艾琳,浮岛 => 钟声代表 艾琳 记忆里的浮岛潮汐。'),
    );
    expect(imported.memoryBook, contains('城市由七座浮岛组成。'));
    expect(imported.memoryBook, contains('[off] 废稿 => 这条不应导入。'));
    expect(imported.prompt, isNot(contains('{{char}}')));
    expect(imported.prompt, isNot(contains('{{user}}')));
    expect(imported.exampleDialogs, isNot(contains('{{char}}')));
    expect(imported.memoryBook, isNot(contains('{{char}}')));
  });

  test('SillyTavern creator comment 别名可作为角色简介', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '备注角色',
        'description': '角色设定正文。',
        'creatorcomment': '作者备注来自旧字段。',
        'tags': '测试/兼容',
        'first_mes': '你好。',
      },
    }));

    expect(imported.description, '角色设定正文。\n作者备注来自旧字段。\n标签：测试、兼容');
    expect(imported.prompt, contains('[角色设定]\n角色设定正文。'));
  });

  test('SillyTavern 多语言 creator notes 优先取中文并替换占位符', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '多语角色',
        'description': '角色设定正文。',
        'creator_notes_multilingual': {
          'en': 'English note for <BOT>.',
          'zh-CN': '中文备注给 {{char}} 和 {{user}}。',
        },
        'tags': ['多语'],
        'first_mes': '你好。',
      },
    }));

    expect(imported.description, '角色设定正文。\n中文备注给 多语角色 和 用户。\n标签：多语');
    expect(imported.prompt, contains('[角色设定]\n角色设定正文。'));
  });

  test('SillyTavern 多语言核心角色字段优先取中文', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '多语正文',
        'description': {
          'en': 'English description for <BOT>.',
          'zh-CN': '中文设定给 {{char}}。',
        },
        'personality': {
          'en': 'Calm.',
          'zh': '克制。',
        },
        'scenario': {
          'default': '<USER> 和 <BOT> 在旧书店。',
        },
        'system_prompt': {
          'en': 'Stay in character.',
          'zh-Hans': '保持入戏。',
        },
        'post_history_instructions': {
          'default': '延续温柔语气。',
        },
        'first_mes': {
          'en': 'Can you hear the bell?',
          'zh-CN': '你听见钟声了吗？',
        },
        'mes_example': {
          'en': '<START>\n{{user}}: hi\n{{char}}: night is quiet.',
          'zh-CN': '<START>\n{{user}}：你好\n{{char}}：夜色很安静。',
        },
      },
    }));

    expect(imported.prompt, contains('[系统提示]\n保持入戏。'));
    expect(imported.prompt, contains('[角色设定]\n中文设定给 多语正文。'));
    expect(imported.prompt, contains('[性格]\n克制。'));
    expect(imported.prompt, contains('[场景]\n用户 和 多语正文 在旧书店。'));
    expect(imported.prompt, contains('[后续指令]\n延续温柔语气。'));
    expect(imported.openingMessage, '你听见钟声了吗？');
    expect(imported.exampleDialogs, '<START>\n用户：你好\n多语正文：夜色很安静。');
    expect(imported.description, '中文设定给 多语正文。');
  });

  test('SillyTavern 备选开场白兼容字符串和换行格式', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '开场角色',
        'description': '角色设定正文。',
        'first_mes': '你好。',
        'alternate_greetings': '''
雨声盖住了 {{char}} 的脚步声。

<BOT> 把伞递给 <USER>。
雨声盖住了 开场角色 的脚步声。
''',
      },
    }));

    expect(imported.exampleDialogs, contains('[备选开场白]'));
    expect(
        AssistantRoleCardService.alternateGreetings(imported.exampleDialogs), [
      '雨声盖住了 开场角色 的脚步声。',
      '开场角色 把伞递给 用户。',
    ]);
    expect(
        AssistantRoleCardService.exampleDialogPromptText(
            imported.exampleDialogs),
        isEmpty);
  });

  test('SillyTavern 备选开场白兼容多语言对象', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '多语开场',
        'description': '角色设定正文。',
        'first_mes': '你好。',
        'alternate_greetings': {
          'en': ['English greeting.'],
          'zh-CN': [
            '雨声盖住了 {{char}} 的脚步声。',
            '<BOT> 把伞递给 <USER>。',
          ],
        },
      },
    }));

    expect(
      AssistantRoleCardService.alternateGreetings(imported.exampleDialogs),
      [
        '雨声盖住了 多语开场 的脚步声。',
        '多语开场 把伞递给 用户。',
      ],
    );
    expect(imported.exampleDialogs, isNot(contains('English greeting')));
  });

  test('SillyTavern 正则世界书条目会保留为可匹配的角色记忆', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '正则角色',
        'description': '角色设定正文。',
        'first_mes': '你好。',
        'character_book': {
          'entries': [
            {
              'keys': [r'第[一二三]幕', r'Act\s+\d+'],
              'content': '按幕次切换叙事节奏。',
              'regex': true,
              'priority': 4,
            },
          ],
        },
      },
    }));

    expect(
      imported.memoryBook,
      r'[re] [p=4] 第[一二三]幕 || Act\s+\d+ => 按幕次切换叙事节奏。',
    );
    final hits = AssistantRoleCardService.matchMemoryEntries(
      imported.memoryBook,
      '现在进入第二幕。',
    );
    expect(hits, hasLength(1));
    expect(hits.single.regex, isTrue);
    expect(hits.single.label, r'正则：第[一二三]幕 / Act\s+\d+ · p=4');
    expect(hits.single.content, '按幕次切换叙事节奏。');
  });

  test('SillyTavern selective 世界书条目会保留二级触发条件', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '选择性角色',
        'description': '角色设定正文。',
        'first_mes': '你好。',
        'character_book': {
          'entries': [
            {
              'keys': ['钟声'],
              'secondary_keys': ['潮汐', '浮岛'],
              'content': '只有钟声和潮汐同场时才注入。',
              'selective': true,
              'priority': 6,
            },
          ],
        },
      },
    }));

    expect(
      imported.memoryBook,
      '[sec=潮汐|浮岛] [p=6] 钟声 => 只有钟声和潮汐同场时才注入。',
    );
    expect(
      AssistantRoleCardService.matchMemoryEntries(imported.memoryBook, '钟声响了'),
      isEmpty,
    );
    final hits = AssistantRoleCardService.matchMemoryEntries(
      imported.memoryBook,
      '钟声响起，潮汐也开始变化。',
    );
    expect(hits, hasLength(1));
    expect(hits.single.secondaryKeywords, ['潮汐', '浮岛']);
    expect(hits.single.label, '钟声 + 二级：潮汐 / 浮岛 · p=6');
  });

  test('SillyTavern 世界书 keysecondary 字段会作为二级触发条件', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '原生字段角色',
        'description': '角色设定正文。',
        'first_mes': '你好。',
        'character_book': {
          'entries': [
            {
              'key': ['钟声'],
              'keysecondary': ['地下', '雨夜'],
              'content': '原生二级关键词被保留。',
              'selective': true,
            },
          ],
        },
      },
    }));

    expect(
      imported.memoryBook,
      '[sec=地下|雨夜] 钟声 => 原生二级关键词被保留。',
    );
    expect(
      AssistantRoleCardService.matchMemoryEntries(imported.memoryBook, '钟声响了'),
      isEmpty,
    );
    final hits = AssistantRoleCardService.matchMemoryEntries(
      imported.memoryBook,
      '地下传来钟声',
    );
    expect(hits.single.secondaryKeywords, ['地下', '雨夜']);
    expect(hits.single.content, '原生二级关键词被保留。');
  });

  test('SillyTavern 世界书排除关键词会保留并参与匹配', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '排除角色',
        'description': '角色设定正文。',
        'first_mes': '你好。',
        'character_book': {
          'entries': [
            {
              'keys': ['钟楼'],
              'exclude_keys': ['白天', '庆典'],
              'content': '钟楼只在安静场景触发。',
              'priority': 5,
            },
          ],
        },
      },
    }));

    expect(
      imported.memoryBook,
      '[exclude=白天|庆典] [p=5] 钟楼 => 钟楼只在安静场景触发。',
    );
    expect(
      AssistantRoleCardService.matchMemoryEntries(
        imported.memoryBook,
        '白天经过钟楼',
      ),
      isEmpty,
    );
    final hits = AssistantRoleCardService.matchMemoryEntries(
      imported.memoryBook,
      '深夜经过钟楼',
    );
    expect(hits.single.excludeKeywords, ['白天', '庆典']);
    expect(hits.single.label, '钟楼 · 排除：白天 / 庆典 · p=5');
  });

  test('SillyTavern 世界书大小写敏感和整词匹配开关会保留', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '开关角色',
        'description': '角色设定正文。',
        'first_mes': '你好。',
        'character_book': {
          'entries': [
            {
              'keys': ['Alice'],
              'content': '只在精确提到 Alice 时注入。',
              'case_sensitive': true,
              'match_whole_words': true,
            },
          ],
        },
      },
    }));

    expect(imported.memoryBook, '[cs] [ww] Alice => 只在精确提到 Alice 时注入。');
    expect(
      AssistantRoleCardService.matchMemoryEntries(
          imported.memoryBook, 'alice 来了'),
      isEmpty,
    );
    expect(
      AssistantRoleCardService.matchMemoryEntries(
          imported.memoryBook, 'Alicehood'),
      isEmpty,
    );
    final hits = AssistantRoleCardService.matchMemoryEntries(
      imported.memoryBook,
      'Alice 来了',
    );
    expect(hits, hasLength(1));
    expect(hits.single.caseSensitive, isTrue);
    expect(hits.single.wholeWords, isTrue);
    expect(hits.single.label, 'Alice · 区分大小写 · 整词');
  });

  test('SillyTavern 世界书 entries 对象映射也可导入', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '映射角色',
        'description': '角色设定正文。',
        'first_mes': '你好。',
        'character_book': {
          'entries': {
            '20': {
              'keys': ['镜子'],
              'secondary_keys': ['夜晚'],
              'content': '镜子只在夜晚回应。',
              'selective': true,
              'priority': 8,
            },
            '10': {
              'constant': true,
              'content': '城市由七座浮岛组成。',
            },
            '30': {
              'keys': [r'第[一二三]幕'],
              'content': '按幕次切换叙事节奏。',
              'regex': true,
              'enabled': false,
            },
          },
        },
      },
    }));

    expect(
      imported.memoryBook,
      [
        '城市由七座浮岛组成。',
        '[sec=夜晚] [p=8] 镜子 => 镜子只在夜晚回应。',
        '[off] [re] 第[一二三]幕 => 按幕次切换叙事节奏。',
      ].join('\n'),
    );
    final hits = AssistantRoleCardService.matchMemoryEntries(
      imported.memoryBook,
      '夜晚的镜子亮了',
    );
    expect(hits.map((item) => item.content), [
      '镜子只在夜晚回应。',
      '城市由七座浮岛组成。',
    ]);
  });

  test('SillyTavern 世界书 entries 对象映射按数字 key 排序', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '数字排序角色',
        'description': '角色设定正文。',
        'first_mes': '你好。',
        'character_book': {
          'entries': {
            '10': {
              'keys': ['十号'],
              'content': '第十条。',
            },
            '2': {
              'keys': ['二号'],
              'content': '第二条。',
            },
            '1': {
              'keys': ['一号'],
              'content': '第一条。',
            },
          },
        },
      },
    }));

    expect(
      imported.memoryBook,
      [
        '一号 => 第一条。',
        '二号 => 第二条。',
        '十号 => 第十条。',
      ].join('\n'),
    );
  });

  test('SillyTavern 世界书布尔字段兼容字符串和数字', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '布尔字段角色',
        'description': '角色设定正文。',
        'first_mes': '你好。',
        'character_book': {
          'entries': [
            {
              'constant': '1',
              'content': '常驻设定。',
            },
            {
              'keys': ['禁用词'],
              'content': '这条不应该触发。',
              'enabled': 'false',
            },
            {
              'keys': ['暗门'],
              'secondary_keys': ['地下'],
              'content': '暗门只在地下回应。',
              'selective': 'yes',
              'regex': 1,
              'case_sensitive': 'on',
              'match_whole_words': 1,
            },
            {
              'keys': ['概率'],
              'content': '概率字段启用。',
              'probability': '20',
              'useProbability': 'true',
            },
          ],
        },
      },
    }));

    expect(
      imported.memoryBook,
      [
        '常驻设定。',
        '[off] 禁用词 => 这条不应该触发。',
        '[re] [cs] [ww] [sec=地下] 暗门 => 暗门只在地下回应。',
        '[prob=20] 概率 => 概率字段启用。',
      ].join('\n'),
    );
    final hits = AssistantRoleCardService.matchMemoryEntries(
      imported.memoryBook,
      '禁用词',
    );
    expect(hits.map((item) => item.content), ['常驻设定。']);
  });

  test('SillyTavern 世界书防递归字段会保留', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '防递归角色',
        'description': '角色设定正文。',
        'first_mes': '你好。',
        'character_book': {
          'entries': [
            {
              'keys': ['镜子'],
              'content': '镜子背后藏着暗门。',
              'excludeRecursion': true,
            },
            {
              'keys': ['暗门'],
              'content': '暗门后通向地下书库。',
              'extensions': {
                'prevent_recursion': 'yes',
              },
            },
          ],
        },
      },
    }));

    expect(
      imported.memoryBook,
      [
        '[norec] 镜子 => 镜子背后藏着暗门。',
        '[norec] 暗门 => 暗门后通向地下书库。',
      ].join('\n'),
    );
    final hits = AssistantRoleCardService.matchMemoryEntries(
      imported.memoryBook,
      '我看见了镜子。',
    );
    expect(hits.single.excludeFromRecursion, isTrue);
    expect(hits.single.label, '镜子 · 不参与递归');
  });

  test('SillyTavern 世界书 order 字段可兜底为移动端优先级', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '排序角色',
        'description': '角色设定正文。',
        'first_mes': '你好。',
        'character_book': {
          'entries': [
            {
              'keys': ['铃声'],
              'content': '铃声优先级来自 order。',
              'order': 30,
            },
            {
              'keys': ['钟声'],
              'content': 'priority 明确存在时优先使用。',
              'priority': 12,
              'order': 99,
            },
            {
              'keys': ['潮汐'],
              'content': '兼容蛇形 insertion_order。',
              'insertion_order': 7,
            },
          ],
        },
      },
    }));

    expect(
      imported.memoryBook,
      [
        '[p=30] 铃声 => 铃声优先级来自 order。',
        '[p=12] 钟声 => priority 明确存在时优先使用。',
        '[p=7] 潮汐 => 兼容蛇形 insertion_order。',
      ].join('\n'),
    );
    final hits = AssistantRoleCardService.matchMemoryEntries(
      imported.memoryBook,
      '钟声、铃声和潮汐同时出现',
      maxEntries: 3,
    );
    expect(hits.map((item) => item.content), [
      '铃声优先级来自 order。',
      'priority 明确存在时优先使用。',
      '兼容蛇形 insertion_order。',
    ]);
  });

  test('SillyTavern 世界书位置、深度和概率元信息会保留', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '元信息角色',
        'description': '角色设定正文。',
        'first_mes': '你好。',
        'character_book': {
          'entries': [
            {
              'keys': ['钟楼'],
              'content': '钟楼会在第四层扫描时触发。',
              'position': 'before_char',
              'probability': 100,
              'useProbability': true,
              'extensions': {
                'depth': 4,
              },
            },
            {
              'keys': ['暗门'],
              'content': '概率为零的条目不应注入。',
              'probability': 0,
              'useProbability': true,
            },
          ],
        },
      },
    }));

    expect(
      imported.memoryBook,
      [
        '[pos=before_char] [depth=4] [prob=100] 钟楼 => 钟楼会在第四层扫描时触发。',
        '[prob=0] 暗门 => 概率为零的条目不应注入。',
      ].join('\n'),
    );
    final hit = AssistantRoleCardService.matchMemoryEntries(
      imported.memoryBook,
      '钟楼敲响了，暗门也打开了。',
    ).single;
    expect(hit.position, 'before_char');
    expect(hit.depth, 4);
    expect(hit.probability, 100);
    expect(hit.label, '钟楼 · pos=before_char · depth=4 · prob=100');
    expect(hit.content, isNot(contains('概率为零')));
  });

  test('SillyTavern 世界书禁用别名会保留为 off 条目', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '禁用角色',
        'description': '角色设定正文。',
        'first_mes': '你好。',
        'character_book': {
          'entries': [
            {
              'keys': ['废稿一'],
              'content': 'disable 布尔禁用。',
              'disable': true,
            },
            {
              'keys': ['废稿二'],
              'content': 'disabled 布尔禁用。',
              'disabled': true,
            },
            {
              'keys': ['废稿三'],
              'content': 'extensions 中禁用。',
              'extensions': {'disabled': true},
            },
          ],
        },
      },
    }));

    expect(
      imported.memoryBook,
      [
        '[off] 废稿一 => disable 布尔禁用。',
        '[off] 废稿二 => disabled 布尔禁用。',
        '[off] 废稿三 => extensions 中禁用。',
      ].join('\n'),
    );
    expect(
      AssistantRoleCardService.matchMemoryEntries(
        imported.memoryBook,
        '废稿一 废稿二 废稿三',
      ),
      isEmpty,
    );
    final summary = AssistantRoleCardService.summarize(imported);
    expect(summary.disabledMemoryCount, 3);
  });

  test('SillyTavern 世界书备注会保留为注释且不参与命中', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '备注世界书',
        'description': '角色设定正文。',
        'first_mes': '你好。',
        'character_book': {
          'entries': [
            {
              'keys': ['镜子'],
              'content': '镜子背后藏着暗门。',
              'comment': '这个条目用于镜厅谜题。',
            },
          ],
        },
      },
    }));

    expect(
      imported.memoryBook,
      '# 这个条目用于镜厅谜题。\n镜子 => 镜子背后藏着暗门。',
    );
    final entries = AssistantRoleCardService.parseMemoryEntries(
      imported.memoryBook,
    );
    expect(entries, hasLength(1));
    expect(entries.single.content, '镜子背后藏着暗门。');
  });

  test('兼容 PNG tEXt chara 元数据中的 base64 角色卡', () {
    final cardJson = jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': '图片角色',
        'description': '藏在 PNG 里的角色。',
        'first_mes': '我在图片里。',
        'character_book': {
          'entries': [
            {
              'keys': ['图片'],
              'content': '图片角色知道自己来自 PNG。',
              'enabled': true,
            },
          ],
        },
      },
    });
    final png =
        _pngWithTextChunk('chara', base64.encode(utf8.encode(cardJson)));

    final imported = AssistantRoleCardService.importBytes(png);

    expect(imported.name, '图片角色');
    expect(imported.prompt, contains('[角色设定]\n藏在 PNG 里的角色。'));
    expect(imported.openingMessage, '我在图片里。');
    expect(imported.memoryBook, '图片 => 图片角色知道自己来自 PNG。');
  });

  test('PNG 中没有角色卡元数据时拒绝', () {
    final png = _pngWithTextChunk('comment', 'not a role card');

    expect(
      () => AssistantRoleCardService.importBytes(png),
      throwsFormatException,
    );
  });

  test('兼容 ZIP 角色卡包中的 JSON 文件', () {
    final zip = _zipOf({
      'README.txt': 'not a role card',
      'characters/airin.json': jsonEncode({
        'spec': 'chara_card_v2',
        'data': {
          'name': '压缩包角色',
          'description': '从 ZIP 导入。',
          'first_mes': '我在压缩包里。',
        },
      }),
    });

    final imported =
        AssistantRoleCardService.importBytes(zip, filename: 'role.zip');

    expect(imported.name, '压缩包角色');
    expect(imported.prompt, contains('[角色设定]\n从 ZIP 导入。'));
    expect(imported.openingMessage, '我在压缩包里。');
    final result =
        AssistantRoleCardService.importPackageBytes(zip, filename: 'role.zip');
    expect(result.assistant.name, '压缩包角色');
    expect(result.avatarPngBytes, isNull);
    expect(result.sourceName, 'characters/airin.json');
  });

  test('ZIP 内 PNG 角色卡会带回可保存头像 bytes', () {
    final png = _pngWithTextChunk(
        'chara',
        base64.encode(utf8.encode(jsonEncode({
          'spec': 'chara_card_v2',
          'data': {
            'name': '压缩图片角色',
            'description': '从 ZIP 里的 PNG 导入。',
            'first_mes': '我是压缩图片角色。',
          },
        }))));
    final zip = _zipBytesOf({
      'notes/readme.txt': utf8.encode('not a role card'),
      'characters/airin.png': png,
    });

    final result =
        AssistantRoleCardService.importPackageBytes(zip, filename: 'role.zip');

    expect(result.assistant.name, '压缩图片角色');
    expect(result.assistant.prompt, contains('[角色设定]\n从 ZIP 里的 PNG 导入。'));
    expect(result.assistant.openingMessage, '我是压缩图片角色。');
    expect(result.avatarPngBytes, png);
    expect(result.sourceName, 'characters/airin.png');
  });

  test('ZIP 多角色卡可批量解析，旧单卡接口保持取第一张', () {
    final png = _pngWithTextChunk(
        'chara',
        base64.encode(utf8.encode(jsonEncode({
          'spec': 'chara_card_v2',
          'data': {
            'name': '第二角色',
            'description': '来自 PNG。',
            'first_mes': '第二张卡。',
          },
        }))));
    final zip = _zipBytesOf({
      'cards/first.json': utf8.encode(jsonEncode({
        'name': '第一角色',
        'description': '来自 JSON。',
        'first_mes': '第一张卡。',
      })),
      'cards/second.png': png,
    });

    final all = AssistantRoleCardService.importPackageBytesList(
      zip,
      filename: 'many.zip',
    );
    final first =
        AssistantRoleCardService.importBytes(zip, filename: 'many.zip');

    expect(all.map((result) => result.assistant.name), ['第一角色', '第二角色']);
    expect(all.first.avatarPngBytes, isNull);
    expect(all.last.avatarPngBytes, png);
    expect(all.map((result) => result.sourceName), [
      'cards/first.json',
      'cards/second.png',
    ]);
    expect(first.name, '第一角色');
  });

  test('ZIP 批量解析会保留跳过文件明细', () {
    final zip = _zipBytesOf({
      'cards/good.json': utf8.encode(jsonEncode({
        'name': '好角色',
        'description': '可导入。',
        'first_mes': '你好。',
      })),
      'cards/bad.json': utf8.encode('{"assistant": {}}'),
    });

    final batch = AssistantRoleCardService.importPackageBatchBytes(
      zip,
      filename: 'mixed.zip',
    );

    expect(batch.results.map((result) => result.assistant.name), ['好角色']);
    expect(batch.skipped, hasLength(1));
    expect(batch.skipped.single.name, 'cards/bad.json');
    expect(batch.skipped.single.reason, contains('角色卡缺少助手名称'));
    expect(batch.summaryText, '已解析 1 张角色卡，1 个文件跳过');
    expect(batch.skippedDetailText, contains('cards/bad.json：角色卡缺少助手名称'));
  });

  test('ZIP 中没有可导入角色卡时拒绝', () {
    final zip = _zipOf({'README.txt': 'not a role card'});

    expect(
      () => AssistantRoleCardService.importBytes(zip, filename: 'empty.zip'),
      throwsFormatException,
    );
  });

  test('PNG 角色卡头像 bytes 可保存到托管头像目录', () async {
    final tmp = await Directory.systemTemp.createTemp('assistant_avatar_test_');
    AvatarAssetService.debugDocumentsDirectoryResolver = () async => tmp;
    addTearDown(() async {
      AvatarAssetService.debugDocumentsDirectoryResolver = null;
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final png = _pngWithTextChunk(
        'chara',
        base64.encode(utf8.encode(jsonEncode({
          'name': '头像角色',
          'first_mes': '你好',
        }))));

    final path = await AvatarAssetService.saveAssistantAvatarBytes(
      bytes: png,
      assistantName: '头像角色',
      accountHash: 'test',
    );

    expect(path, contains('/chat_avatar/test/assistant_'));
    expect(path, endsWith('.png'));
    expect(await File(path).exists(), isTrue);
  });

  test('助手头像源文件可复制到托管目录并删除', () async {
    final tmp =
        await Directory.systemTemp.createTemp('assistant_avatar_pick_test_');
    AvatarAssetService.debugDocumentsDirectoryResolver = () async => tmp;
    addTearDown(() async {
      AvatarAssetService.debugDocumentsDirectoryResolver = null;
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final source = File('${tmp.path}/source.png');
    await source.writeAsBytes(_pngWithTextChunk('comment', 'avatar'));

    final path = await AvatarAssetService.saveAssistantAvatar(
      sourcePath: source.path,
      assistantName: '头像角色',
      accountHash: 'test',
    );

    expect(path, contains('/chat_avatar/test/assistant_'));
    expect(path, isNot(source.path));
    expect(await File(path).exists(), isTrue);

    await AvatarAssetService.deleteAssistantAvatar(path);
    expect(await File(path).exists(), isFalse);
  });

  test('兼容 Tavern 直出角色字段', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode({
      'name': '旧馆角色',
      'description': '一个来自旧格式的角色。',
      'personality': '直率',
      'scenario': '深夜车站',
      'first_mes': '车快来了。',
      'mes_example': '用户：去哪？\n助手：向北。',
    }));

    expect(imported.name, '旧馆角色');
    expect(imported.description, '一个来自旧格式的角色。');
    expect(imported.prompt, contains('[角色设定]\n一个来自旧格式的角色。'));
    expect(imported.prompt, contains('[性格]\n直率'));
    expect(imported.prompt, contains('[场景]\n深夜车站'));
    expect(imported.openingMessage, '车快来了。');
    expect(imported.exampleDialogs, '用户：去哪？\n助手：向北。');
  });

  test('世界书条目解析区分常驻设定与关键词设定', () {
    final entries = AssistantRoleCardService.parseMemoryEntries('''
# comment
城市由七座浮岛组成
艾琳,钟声 => 艾琳听到钟声会想起潮汐
[re] 第[一二三]幕 || Act\\s+\\d+ => 按幕次切换叙事节奏
[sec=镜子|夜晚] [exclude=白天|广场] 反派 => 反派只在夜晚通过镜子交流
[cs] [ww] [pos=before_char] [depth=4] [prob=80] Alice => 只在精确提到 Alice 时注入
无效 =>
=> 无关键词
''');

    expect(entries, hasLength(5));
    expect(entries.first.alwaysOn, isTrue);
    expect(entries.first.label, '常驻');
    expect(entries.first.content, '城市由七座浮岛组成');
    expect(entries[1].alwaysOn, isFalse);
    expect(entries[1].keywords, ['艾琳', '钟声']);
    expect(entries[1].label, '艾琳 / 钟声');
    expect(entries[1].content, '艾琳听到钟声会想起潮汐');
    expect(entries[2].regex, isTrue);
    expect(entries[2].keywords, [r'第[一二三]幕', r'Act\s+\d+']);
    expect(entries[2].label, r'正则：第[一二三]幕 / Act\s+\d+');
    expect(entries[3].keywords, ['反派']);
    expect(entries[3].secondaryKeywords, ['镜子', '夜晚']);
    expect(entries[3].excludeKeywords, ['白天', '广场']);
    expect(entries[3].label, '反派 + 二级：镜子 / 夜晚 · 排除：白天 / 广场');
    expect(entries.last.keywords, ['Alice']);
    expect(entries.last.caseSensitive, isTrue);
    expect(entries.last.wholeWords, isTrue);
    expect(entries.last.position, 'before_char');
    expect(entries.last.depth, 4);
    expect(entries.last.probability, 80);
    expect(entries.last.label,
        'Alice · 区分大小写 · 整词 · pos=before_char · depth=4 · prob=80');

    final disabled = AssistantRoleCardService.parseMemoryEntries(
      '[off] [p=8] 反派 => 反派设定',
    ).single;
    expect(disabled.enabled, isFalse);
    expect(disabled.priority, 8);
    expect(disabled.label, '反派 · p=8 · 已禁用');
  });

  test('世界书命中结果包含常驻设定和当前输入关键词条目，并去重限量', () {
    final hits = AssistantRoleCardService.matchMemoryEntries(
      '''
城市由七座浮岛组成
艾琳,钟声 => 艾琳听到钟声会想起潮汐
反派 => 反派只能通过镜子交流
钟声 => 艾琳听到钟声会想起潮汐
''',
      '艾琳听到了钟声',
      maxEntries: 3,
    );

    expect(hits.map((e) => e.label).toList(), ['常驻', '艾琳 / 钟声']);
    expect(hits.map((e) => e.content).toList(), [
      '城市由七座浮岛组成',
      '艾琳听到钟声会想起潮汐',
    ]);
    expect(
      AssistantRoleCardService.memoryHitSummary(hits),
      '命中角色记忆 2 条（常驻 1 / 关键词 1）',
    );
    expect(
      AssistantRoleCardService.memoryHitPreviewLine(hits.first),
      '常驻：城市由七座浮岛组成',
    );
    expect(
      AssistantRoleCardService.memoryHitPreviewLine(hits.last),
      '艾琳 / 钟声：艾琳听到钟声会想起潮汐',
    );
    expect(
      AssistantRoleCardService.memoryHitCopyText(hits),
      [
        '命中角色记忆 2 条（常驻 1 / 关键词 1）',
        '- 常驻：城市由七座浮岛组成',
        '- 艾琳 / 钟声：艾琳听到钟声会想起潮汐',
      ].join('\n'),
    );
  });

  test('世界书排除关键词命中时跳过该条设定', () {
    final hits = AssistantRoleCardService.matchMemoryEntries(
      '''
钟楼 => 钟楼会触发夜巡设定
[exclude=白天|庆典] 钟楼 => 只在非白天非庆典时注入
''',
      '白天的钟楼正在举行庆典',
    );

    expect(hits.map((item) => item.content), ['钟楼会触发夜巡设定']);
    final allowed = AssistantRoleCardService.matchMemoryEntries(
      '''
[exclude=白天|庆典] 钟楼 => 只在非白天非庆典时注入
''',
      '深夜经过钟楼',
    );
    expect(allowed.single.excludeKeywords, ['白天', '庆典']);
    expect(allowed.single.label, '钟楼 · 排除：白天 / 庆典');
  });

  test('世界书扫描深度会限制最近消息匹配范围', () {
    const raw = '''
[depth=1] 旧钟声 => 只扫描最近一条消息
[depth=2] 古井 => 可以扫描最近两条消息
''';
    final hits = AssistantRoleCardService.matchMemoryEntries(
      raw,
      '现在看起来很平静',
      recentTexts: const [
        '三轮前提到了旧钟声',
        '上一轮有人说起古井',
      ],
    );

    expect(hits.map((item) => item.content), ['可以扫描最近两条消息']);
    expect(hits.single.depth, 2);
  });

  test('世界书命中预览会压缩空白并截断长内容', () {
    const longText =
        '第一行设定\n第二行设定会被压成一行，abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz';
    const entry = AssistantMemoryEntryPreview(
      keywords: ['长文'],
      content: longText,
      alwaysOn: false,
    );
    final line = AssistantRoleCardService.memoryHitPreviewLine(entry);

    expect(line, startsWith('长文：第一行设定 第二行设定会被压成一行'));
    expect(line, endsWith('...'));
    expect(line.length, lessThan(longText.length));

    final copy = AssistantRoleCardService.memoryHitCopyText([entry]);
    expect(copy, contains('第一行设定 第二行设定会被压成一行'));
    expect(
        copy, contains('abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz'));
    expect(copy, isNot(contains('...')));
  });

  test('世界书命中预览按优先级排序并跳过禁用条目', () {
    final hits = AssistantRoleCardService.matchMemoryEntries(
      '''
低优先常驻
[off] 艾琳 => 禁用设定
[p=20] 艾琳 => 高优先设定
[p=5] 艾琳 => 中优先设定
''',
      '艾琳',
      maxEntries: 2,
    );

    expect(hits.map((e) => e.content).toList(), [
      '高优先设定',
      '中优先设定',
    ]);
  });

  test('示例对话预览会拆出备选开场并限制数量', () {
    final snippets = AssistantRoleCardService.examplePreviewSnippets(
      '''
<START>
用户：你好
艾琳：夜色很安静。

[备选开场白]
雨声盖住了脚步声。

钟塔今晚没有准点报时。
''',
      maxItems: 2,
    );

    expect(snippets, [
      '<START>\n用户：你好\n艾琳：夜色很安静。',
      '备选开场：雨声盖住了脚步声。',
    ]);
  });

  test('示例对话正文会过滤备选开场白', () {
    const text = '''
用户：你好
助手：夜色很安静。

[备选开场白]
雨声盖住了脚步声。

钟塔今晚没有准点报时。
''';

    expect(
      AssistantRoleCardService.exampleDialogPromptText(text),
      '用户：你好\n助手：夜色很安静。',
    );
    expect(AssistantRoleCardService.examplePreviewSnippets(text, maxItems: 3), [
      '用户：你好\n助手：夜色很安静。',
      '备选开场：雨声盖住了脚步声。',
      '备选开场：钟塔今晚没有准点报时。',
    ]);
  });

  test('角色卡摘要统计提示词、开场白、示例对话、世界书和配置状态', () {
    final summary = AssistantRoleCardService.summarize(AssistantModel(
      name: '艾琳',
      prompt: '保持克制而温柔',
      openingMessage: '你听见钟声了吗？',
      exampleDialogs: '''
用户：你好
助手：夜色很安静。

[备选开场白]
雨声盖住了脚步声。

钟塔今晚没有准点报时。
''',
      memoryBook: '城市由七座浮岛组成\n钟声 => 钟声代表浮岛潮汐\n[off] 废稿 => 不启用',
      defaultVoiceStyle: 'female',
      providerId: 'openai',
      model: 'gpt-4o',
      toolIds: ['knowledge_search', 'web_search'],
    ));

    expect(summary.promptChars, 7);
    expect(summary.openingChars, 8);
    expect(summary.exampleDialogLines, 2);
    expect(summary.alternateGreetingCount, 2);
    expect(summary.memoryCount, 3);
    expect(summary.alwaysOnMemoryCount, 1);
    expect(summary.keywordMemoryCount, 2);
    expect(summary.disabledMemoryCount, 1);
    expect(summary.toolCount, 2);
    expect(summary.hasDefaultVoice, isTrue);
    expect(summary.hasModelOverride, isTrue);
  });

  test('不支持的格式、过新版本和缺少名称会拒绝', () {
    expect(
      () =>
          AssistantRoleCardService.importJson('{"format":"x","assistant":{}}'),
      throwsFormatException,
    );
    expect(
      () => AssistantRoleCardService.importJson(
          '{"format":"chatai_deep_assistant_card","version":99,"assistant":{}}'),
      throwsFormatException,
    );
    expect(
      () => AssistantRoleCardService.importJson(
          '{"format":"chatai_deep_assistant_card","version":1,"assistant":{}}'),
      throwsFormatException,
    );
  });

  test('文件名会清理不适合路径的字符', () {
    expect(
      AssistantRoleCardService.filenameFor(AssistantModel(name: 'A/B C')),
      'assistant_A_B_C.json',
    );
  });

  test('导入角色卡重名时会生成唯一名称', () {
    final usedNames = <String>{'艾琳', '艾琳 (2)', '  ALICE   ROLE '};

    expect(
      AssistantRoleCardService.uniqueImportName('艾琳', usedNames),
      '艾琳 (3)',
    );
    expect(
      AssistantRoleCardService.uniqueImportName('Alice Role', usedNames),
      'Alice Role (2)',
    );
    expect(
      AssistantRoleCardService.uniqueImportName('', usedNames),
      '未命名角色',
    );

    final batchNames = <String>{'旅人'};
    final first = AssistantRoleCardService.uniqueImportName('旅人', batchNames);
    batchNames.add(first);
    final second = AssistantRoleCardService.uniqueImportName('旅人', batchNames);
    expect([first, second], ['旅人 (2)', '旅人 (3)']);
  });
}

List<int> _zipOf(Map<String, String> files) {
  return _zipBytesOf(
      files.map((key, value) => MapEntry(key, utf8.encode(value))));
}

List<int> _zipBytesOf(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

List<int> _pngWithTextChunk(String keyword, String text) {
  final bytes = <int>[
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    ..._pngChunk(
        'tEXt', [...latin1.encode(keyword), 0, ...latin1.encode(text)]),
    ..._pngChunk('IEND', const []),
  ];
  return bytes;
}

List<int> _pngChunk(String type, List<int> data) {
  return [
    ..._uint32(data.length),
    ...ascii.encode(type),
    ...data,
    0,
    0,
    0,
    0,
  ];
}

List<int> _uint32(int value) => [
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ];
