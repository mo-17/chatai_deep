import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_translation_service.dart';
import 'package:chatgpt_app_core/chat/application/role_card_translation_fields.dart';
import 'package:chatgpt_app_core/chat/application/translation_chunk_planner.dart';
import 'package:chatgpt_app_core/chat/application/translation_retry_policy.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AssistantModel sampleAssistant() => AssistantModel(
        id: 7,
        name: 'Alice',
        emoji: '🎭',
        avatarType: 'image',
        avatarValue: '/tmp/alice.png',
        description: 'A detective from London.',
        prompt: 'You are a careful detective.',
        openingMessage: 'Good evening.',
        exampleDialogs: '<START>\nUser: Hello\nAlice: I observe first.',
        memoryBook: r'[re] ^Baker Street$ => Alice lives at Baker Street.',
        defaultVoiceStyle: 'custom_sherpa:voice-1',
        providerId: 'openrouter',
        model: 'anthropic/claude-sonnet',
        useTools: false,
        toolIds: ['web_search', 'knowledge_search'],
        createdAt: 100,
        updatedAt: 200,
      );

  test('translateToSimplifiedChinese applies only translated text fields',
      () async {
    final assistant = sampleAssistant();
    var requests = 0;

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      assistant,
      complete: (_) async {
        requests += 1;
        return '''
```json
{
  "name": "爱丽丝",
  "description": "一位来自伦敦的侦探。",
  "prompt": "你是一位细心的侦探。",
  "openingMessage": "晚上好。",
  "exampleDialogs": "<START>\\nUser: 你好\\nAlice: 我先观察。",
  "memoryBook": "[re] ^Baker Street\$ => 爱丽丝住在贝克街。",
  "providerId": "should-not-apply",
  "model": "should-not-apply",
  "defaultVoiceStyle": "should-not-apply"
}
```
''';
      },
    );

    expect(requests, 1);
    expect(translated.name, '爱丽丝');
    expect(translated.description, '一位来自伦敦的侦探。');
    expect(translated.prompt, '你是一位细心的侦探。');
    expect(translated.openingMessage, '晚上好。');
    expect(translated.exampleDialogs, contains('我先观察'));
    expect(translated.memoryBook, contains('爱丽丝住在贝克街'));

    expect(translated.id, assistant.id);
    expect(translated.emoji, assistant.emoji);
    expect(translated.avatarType, assistant.avatarType);
    expect(translated.avatarValue, assistant.avatarValue);
    expect(translated.defaultVoiceStyle, assistant.defaultVoiceStyle);
    expect(translated.providerId, assistant.providerId);
    expect(translated.model, assistant.model);
    expect(translated.useTools, assistant.useTools);
    expect(translated.toolIds, assistant.toolIds);
    expect(translated.createdAt, assistant.createdAt);
    expect(translated.updatedAt, assistant.updatedAt);
  });

  test('first request respects the world-book hard limit without checkpoints',
      () async {
    final source = List.filled(2200, '界').join();
    expect(source.runes.length, 2200);
    final memoryBookSources = <String>[];

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', memoryBook: source),
      complete: (prompt) async {
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final memoryBook = payload['memoryBook'];
        if (memoryBook is String && memoryBook.isNotEmpty) {
          memoryBookSources.add(memoryBook);
        }
        return jsonEncode(payload);
      },
    );

    expect(memoryBookSources, isNotEmpty);
    expect(
      memoryBookSources.every((text) => text.runes.length <= 1200),
      isTrue,
    );
    expect(memoryBookSources.toSet(), hasLength(memoryBookSources.length));
    expect(translated.memoryBook, source);
  });

  test('applyTranslatedFields keeps original value when a field is missing',
      () {
    final assistant = sampleAssistant();

    final translated =
        AssistantRoleCardTranslationService.applyTranslatedFields(
      assistant,
      {'name': '爱丽丝'},
    );

    expect(translated.name, '爱丽丝');
    expect(translated.prompt, assistant.prompt);
    expect(translated.memoryBook, assistant.memoryBook);
  });

  test('整卡翻译超时后会降级为分字段翻译', () async {
    final assistant = sampleAssistant();
    var calls = 0;

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      assistant,
      complete: (prompt) async {
        calls++;
        if (calls == 1) throw TimeoutException('whole card timeout');
        if (prompt.contains('"name"')) return '{"name":"爱丽丝"}';
        if (prompt.contains('"description"')) {
          return '{"description":"一位来自伦敦的侦探。"}';
        }
        if (prompt.contains('"prompt"')) return '{"prompt":"你是一位细心的侦探。"}';
        if (prompt.contains('"openingMessage"')) {
          return '{"openingMessage":"晚上好。"}';
        }
        if (prompt.contains('"exampleDialogs"')) {
          return '{"exampleDialogs":"<START>\\n用户：你好\\n爱丽丝：我先观察。"}';
        }
        if (prompt.contains('"memoryBook"')) {
          return '{"memoryBook":"[re] ^Baker Street\$ => 爱丽丝住在贝克街。"}';
        }
        return '{}';
      },
    );

    expect(calls, greaterThan(1));
    expect(translated.name, '爱丽丝');
    expect(translated.description, '一位来自伦敦的侦探。');
    expect(translated.memoryBook, contains('爱丽丝住在贝克街'));
  });

  for (final failureCase in [
    (
      name: '429',
      failure: const TranslationRequestFailure(
        kind: TranslationFailureKind.rateLimited,
        retryAfter: Duration(seconds: 9),
        safeCode: 'rate_limited',
      ),
      matcher: isA<TranslationWorkDeferred>(),
    ),
    (
      name: '5xx',
      failure: const TranslationRequestFailure(
        kind: TranslationFailureKind.server,
        safeCode: 'server_error',
      ),
      matcher: isA<TranslationWorkDeferred>(),
    ),
    (
      name: 'auth',
      failure: const TranslationRequestFailure(
        kind: TranslationFailureKind.authentication,
        safeCode: 'authentication',
      ),
      matcher: isA<TranslationWorkPaused>(),
    ),
  ]) {
    test('whole-card ${failureCase.name} does not fall through to field calls',
        () async {
      var calls = 0;

      await expectLater(
        AssistantRoleCardTranslationService.translateToSimplifiedChinese(
          sampleAssistant(),
          complete: (_) {
            calls += 1;
            throw failureCase.failure;
          },
        ),
        throwsA(failureCase.matcher),
      );

      expect(calls, 1);
    });
  }

  test(
      'whole-card typed timeout degrades to fields without resending whole card',
      () async {
    final assistant = AssistantModel(
      name: 'Alice',
      description: 'A detective.',
    );
    var wholeCardCalls = 0;
    var fieldCalls = 0;

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      assistant,
      complete: (prompt) async {
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        if (payload.length > 1) {
          wholeCardCalls += 1;
          throw const TranslationRequestFailure(
            kind: TranslationFailureKind.firstEventTimeout,
            safeCode: 'first_event_timeout',
          );
        }
        fieldCalls += 1;
        final field = payload.keys.single;
        return jsonEncode({field: payload[field]});
      },
    );

    expect(wholeCardCalls, 1);
    expect(fieldCalls, 2);
    expect(translated.name, assistant.name);
    expect(translated.description, assistant.description);
  });

  test('无效 JSON 仅发送一次明确 repair prompt', () async {
    var descriptionCalls = 0;
    final checkpoints = <TranslationChunkCheckpoint>[];

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', description: 'A detective from London.'),
      onChunkCheckpoint: (field, checkpoint) async {
        if (field == 'description') checkpoints.add(checkpoint);
      },
      complete: (prompt) async {
        descriptionCalls++;
        if (descriptionCalls == 1) return '这不是 JSON';
        expect(prompt, contains('修复'));
        return '{"description":"一位来自伦敦的侦探。"}';
      },
    );

    expect(descriptionCalls, 2);
    expect(translated.description, '一位来自伦敦的侦探。');
    expect(
      checkpoints.any(
        (checkpoint) =>
            checkpoint.chunks.single.lastErrorKind ==
            TranslationFailureKind.invalidOutput,
      ),
      isTrue,
    );
    expect(checkpoints.last.chunks.single.status,
        TranslationChunkStatus.completed);
  });

  test('分字段翻译会拆分过长 memoryBook', () async {
    final assistant = AssistantModel(
      name: 'Alice',
      memoryBook: List.generate(
        80,
        (index) =>
            'key$index => Alice has a very long memory entry number $index.',
      ).join('\n'),
    );
    final memoryPrompts = <String>[];

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      assistant,
      complete: (prompt) async {
        if (prompt.contains('"name"') &&
            !prompt.contains('"memoryBook"') &&
            !prompt.contains('"description"')) {
          return '{"name":"爱丽丝"}';
        }
        if (prompt.contains('"memoryBook"')) {
          memoryPrompts.add(prompt);
          final start = prompt.indexOf('{');
          final payload = prompt.substring(start);
          return payload.replaceAll('Alice has', '爱丽丝有');
        }
        throw TimeoutException('force fallback');
      },
    );

    expect(memoryPrompts.length, greaterThan(1));
    expect(translated.memoryBook, contains('爱丽丝有'));
    expect(translated.memoryBook.split('\n'), hasLength(80));
  });

  test('大卡会直接跳过整卡翻译以减少失败成本', () async {
    final assistant = AssistantModel(
      name: 'Alice',
      description: 'A long role card.',
      memoryBook: List.generate(
        80,
        (index) =>
            'key$index => Alice keeps a detailed note about scene number $index.',
      ).join('\n'),
    );
    var wholeCardCalls = 0;
    var fieldCalls = 0;

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      assistant,
      complete: (prompt) async {
        if (prompt.contains('"description"') &&
            prompt.contains('"prompt"') &&
            prompt.contains('"memoryBook"')) {
          wholeCardCalls++;
        } else {
          fieldCalls++;
        }
        if (prompt.contains('"name"')) return '{"name":"爱丽丝"}';
        if (prompt.contains('"description"')) {
          return '{"description":"一张很长的角色卡。"}';
        }
        if (prompt.contains('"memoryBook"')) {
          final start = prompt.indexOf('{');
          final payload = prompt.substring(start);
          return payload.replaceAll('Alice keeps', '爱丽丝记录');
        }
        return '{}';
      },
    );

    expect(wholeCardCalls, 0);
    expect(fieldCalls, greaterThan(1));
    expect(translated.name, '爱丽丝');
    expect(translated.description, '一张很长的角色卡。');
    expect(translated.memoryBook, contains('爱丽丝记录'));
  });

  test('timeout 立即拆分当前块且不重发原 payload', () async {
    final source = List.generate(
      35,
      (index) =>
          'key$index => Alice keeps a detailed note about scene number $index.',
    ).join('\r\n');
    final sent = <String>[];
    final persisted = <TranslationChunkCheckpoint>[];
    var timedOut = false;

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', memoryBook: source),
      onChunkCheckpoint: (field, checkpoint) async {
        if (field == 'memoryBook') persisted.add(checkpoint);
      },
      complete: (prompt) async {
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final field = payload.keys.single;
        final value = payload[field] as String;
        expect(field, 'memoryBook');
        sent.add(value);
        if (!timedOut) {
          timedOut = true;
          throw const TranslationRequestFailure(
            kind: TranslationFailureKind.totalTimeout,
            safeCode: 'total_timeout',
          );
        }
        return jsonEncode({
          field: value.replaceAll('Alice keeps', '爱丽丝记录'),
        });
      },
    );

    expect(sent, isNotEmpty);
    expect(sent.every((value) => value.runes.length <= 1200), isTrue);
    expect(sent.where((value) => value == sent.first), hasLength(1));
    expect(sent, hasLength(greaterThanOrEqualTo(3)));
    expect(sent[1].runes.length, lessThan(sent.first.runes.length));
    expect(sent[2].runes.length, lessThan(sent.first.runes.length));
    expect(persisted.first.chunks.length, greaterThan(1));
    expect(
      persisted.any((checkpoint) => checkpoint.chunks.any(
            (state) =>
                state.lastErrorKind == TranslationFailureKind.totalTimeout,
          )),
      isFalse,
    );
    expect(translated.memoryBook, source.replaceAll('Alice keeps', '爱丽丝记录'));
  });

  test('字段检查点会跳过已完成字段并逐字段持久化', () async {
    final calledFields = <String>[];
    final checkpoints = <String, String>{};

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      sampleAssistant(),
      initialTranslatedFields: const {
        'name': '爱丽丝',
        'description': '伦敦侦探',
      },
      onFieldCheckpoint: (field, value) async {
        checkpoints[field] = value;
      },
      complete: (prompt) async {
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final field = payload.keys.single;
        final value = payload[field] as String;
        calledFields.add(field);
        return jsonEncode({field: '已翻译:$value'});
      },
    );

    expect(calledFields, [
      'prompt',
      'openingMessage',
      'exampleDialogs',
      'memoryBook',
    ]);
    expect(checkpoints.keys, calledFields);
    expect(translated.name, '爱丽丝');
    expect(translated.description, '伦敦侦探');
    expect(translated.prompt, '已翻译:${sampleAssistant().prompt}');
  });

  test('decodeTranslation rejects non json output', () {
    expect(
      () => AssistantRoleCardTranslationService.decodeTranslation('已翻译完成'),
      throwsFormatException,
    );
  });

  test('decodeTranslation errors never include raw model output', () {
    const raw = 'secret-model-output-with-private-source';

    try {
      AssistantRoleCardTranslationService.decodeTranslation(raw);
      fail('expected FormatException');
    } on FormatException catch (error) {
      expect(error.toString(), isNot(contains(raw)));
      expect(error.toString(), isNot(contains('secret-model-output')));
    }
  });

  test('buildPrompt asks model to preserve runtime configuration', () {
    final prompt =
        AssistantRoleCardTranslationService.buildPrompt(sampleAssistant());

    expect(prompt, contains('只返回一个 JSON 对象'));
    expect(prompt, contains('不要添加、删除或改写工具 ID、模型 ID、服务商 ID、语音 ID'));
    expect(prompt, contains('"name":"Alice"'));
    expect(prompt, isNot(contains('custom_sherpa:voice-1')));
    expect(prompt, isNot(contains('anthropic/claude-sonnet')));
  });

  test('chunk checkpoint mode sends bounded memoryBook chunks from the start',
      () async {
    final source = List.generate(
      80,
      (index) =>
          '[p=$index] key$index => Alice keeps a detailed note about scene $index.',
    ).join('\r\n');
    final sentChunks = <String>[];
    final checkpoints = <TranslationChunkCheckpoint>[];

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', memoryBook: source),
      onChunkCheckpoint: (field, checkpoint) async {
        if (field == 'memoryBook') checkpoints.add(checkpoint);
      },
      complete: (prompt) async {
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final field = payload.keys.single;
        final value = payload[field] as String;
        if (field == 'memoryBook') sentChunks.add(value);
        return jsonEncode({field: value.replaceAll('Alice keeps', '爱丽丝记录')});
      },
    );

    expect(sentChunks, isNotEmpty);
    expect(
      sentChunks.every((text) => text.runes.length <= 1200),
      isTrue,
    );
    expect(sentChunks.toSet(), hasLength(sentChunks.length));
    expect(checkpoints, isNotEmpty);
    expect(translated.memoryBook, source.replaceAll('Alice keeps', '爱丽丝记录'));
  });

  test('marker-only memory book never reaches the model', () async {
    const prefix = '# [chatai_deep.tavern_raw.v1] ';
    final source =
        '$prefix${List.filled(33322 - prefix.runes.length, 'A').join()}';
    var calls = 0;
    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', memoryBook: source),
      onChunkCheckpoint: (_, __) async {},
      complete: (_) async {
        calls += 1;
        throw StateError('raw marker reached model');
      },
    );
    expect(calls, 0);
    expect(translated.memoryBook, source);
  });

  test('raw marker stays outside memory book prompts', () async {
    const prefix = '# [chatai_deep.tavern_raw.v1] ';
    const base64Sentinel = 'VU5JUVVFX1JBV19CQVNFNjRfU0VOVElORUw=';
    const marker = '$prefix$base64Sentinel';
    const body = 'key => Alice keeps a visible world-book note.';
    final prompts = <String>[];

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', memoryBook: '$marker\n$body'),
      onChunkCheckpoint: (_, __) async {},
      complete: (prompt) async {
        prompts.add(prompt);
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final value = payload['memoryBook'] as String;
        return jsonEncode({
          'memoryBook': value.replaceAll(
            'Alice keeps a visible world-book note.',
            '爱丽丝保留了一条可见的世界书记录。',
          ),
        });
      },
    );

    expect(prompts, isNotEmpty);
    expect(prompts.every((prompt) => !prompt.contains(prefix)), isTrue);
    expect(prompts.every((prompt) => !prompt.contains(base64Sentinel)), isTrue);
    expect(translated.memoryBook.split('\n').first, marker);
    expect(translated.memoryBook, contains('爱丽丝保留了一条可见的世界书记录。'));
  });

  test('33322-rune world book resumes without resending completed chunks',
      () async {
    final raw = List.generate(
      1200,
      (index) =>
          '[entry=$index] key$index => Alice remembers a detailed world rule $index.',
    ).join('\n');
    final source = String.fromCharCodes(raw.runes.take(33322));
    expect(source.runes.length, 33322);

    TranslationChunkCheckpoint? interrupted;
    var memoryCalls = 0;
    final firstAttemptSent = <String>[];
    final firstAttempt =
        AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', memoryBook: source),
      onChunkCheckpoint: (field, checkpoint) async {
        if (field == 'memoryBook') interrupted = checkpoint;
      },
      complete: (prompt) async {
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final field = payload.keys.single;
        final value = payload[field] as String;
        if (field == 'memoryBook') {
          memoryCalls += 1;
          firstAttemptSent.add(value);
          if (memoryCalls == 6) {
            throw const TranslationRequestFailure(
              kind: TranslationFailureKind.cancelled,
              safeCode: 'cancelled',
            );
          }
        }
        return jsonEncode({field: value.replaceAll('Alice', '爱丽丝')});
      },
    );

    await expectLater(
      firstAttempt,
      throwsA(isA<RoleCardTranslationCancelled>()),
    );
    expect(interrupted, isNotNull);
    final completedBeforeResume = interrupted!.chunks
        .where((state) => state.status == TranslationChunkStatus.completed)
        .map((state) => state.chunk.sourceText)
        .toSet();
    expect(completedBeforeResume, isNotEmpty);

    final resumedSent = <String>[];
    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', memoryBook: source),
      initialChunkCheckpoints: {'memoryBook': interrupted!},
      onChunkCheckpoint: (field, checkpoint) async {
        if (field == 'memoryBook') interrupted = checkpoint;
      },
      complete: (prompt) async {
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final field = payload.keys.single;
        final value = payload[field] as String;
        if (field == 'memoryBook') resumedSent.add(value);
        return jsonEncode({field: value.replaceAll('Alice', '爱丽丝')});
      },
    );

    expect(firstAttemptSent.every((text) => text.runes.length <= 1200), isTrue);
    expect(resumedSent.every((text) => text.runes.length <= 1200), isTrue);
    expect(resumedSent.where(completedBeforeResume.contains), isEmpty);
    expect(resumedSent.toSet(), hasLength(resumedSent.length));
    expect(translated.memoryBook, source.replaceAll('Alice', '爱丽丝'));
    expect(
      interrupted!.chunks.every(
        (state) => state.status == TranslationChunkStatus.completed,
      ),
      isTrue,
    );
  });

  test('empty fields persist completed checkpoints without network calls',
      () async {
    final checkpoints = <String, TranslationChunkCheckpoint>{};
    final fieldCheckpoints = <String, String>{};

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: ''),
      onChunkCheckpoint: (field, checkpoint) async {
        checkpoints[field] = checkpoint;
      },
      onFieldCheckpoint: (field, value) async {
        fieldCheckpoints[field] = value;
      },
      complete: (_) => throw StateError('empty fields must not call AI'),
    );

    expect(
        checkpoints.keys,
        containsAll([
          'name',
          'description',
          'prompt',
          'openingMessage',
          'exampleDialogs',
          'memoryBook',
        ]));
    expect(
      checkpoints.values.every(
        (checkpoint) => checkpoint.chunks.every(
          (state) => state.status == TranslationChunkStatus.completed,
        ),
      ),
      isTrue,
    );
    expect(fieldCheckpoints.values.every((value) => value.isEmpty), isTrue);
    expect(translated.name, isEmpty);
  });

  test('resume skips completed and retained chunks and merges exact separators',
      () async {
    const planner = TranslationChunkPlanner();
    final source = List.generate(
      70,
      (index) => 'key$index => Alice remembers item $index.',
    ).join('\r\n');
    final planned = planner.plan(field: 'memoryBook', source: source);
    expect(planned.chunks.length, greaterThanOrEqualTo(3));
    final resumed = TranslationChunkCheckpoint(
      field: planned.field,
      sourceHash: planned.sourceHash,
      chunks: [
        TranslationChunkState(
          chunk: planned.chunks[0].chunk,
          status: TranslationChunkStatus.completed,
          translatedText:
              planned.chunks[0].chunk.sourceText.replaceAll('Alice', '爱丽丝'),
          attempts: 1,
          lastErrorKind: null,
        ),
        TranslationChunkState(
          chunk: planned.chunks[1].chunk,
          status: TranslationChunkStatus.retainedOriginal,
          translatedText: planned.chunks[1].chunk.sourceText,
          attempts: 2,
          lastErrorKind: TranslationFailureKind.invalidOutput,
        ),
        ...planned.chunks.skip(2),
      ],
    );
    final sent = <String>[];
    TranslationChunkCheckpoint? lastCheckpoint;

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', memoryBook: source),
      initialChunkCheckpoints: {'memoryBook': resumed},
      onChunkCheckpoint: (field, checkpoint) async {
        if (field == 'memoryBook') lastCheckpoint = checkpoint;
      },
      complete: (prompt) async {
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final value = payload['memoryBook'] as String;
        sent.add(value);
        return jsonEncode({'memoryBook': value.replaceAll('Alice', '爱丽丝')});
      },
    );

    expect(sent, isNot(contains(planned.chunks[0].chunk.sourceText)));
    expect(sent, isNot(contains(planned.chunks[1].chunk.sourceText)));
    final expected = planned.chunks.map((state) {
      final index = state.chunk.index;
      final text = index == 0
          ? state.chunk.sourceText.replaceAll('Alice', '爱丽丝')
          : index == 1
              ? state.chunk.sourceText
              : state.chunk.sourceText.replaceAll('Alice', '爱丽丝');
      return '$text${state.chunk.separatorAfter}';
    }).join();
    expect(translated.memoryBook, expected);
    expect(lastCheckpoint, isNotNull);
    expect(lastCheckpoint!.chunks[1].status,
        TranslationChunkStatus.retainedOriginal);
    expect(
      TranslationChunkCheckpoint.fromJson(lastCheckpoint!.toJson()).toJson(),
      lastCheckpoint!.toJson(),
    );
  });

  test('source hash mismatch discards old completed chunks', () async {
    const planner = TranslationChunkPlanner();
    final oldPlan = planner.plan(
      field: 'memoryBook',
      source: 'old => Alice',
    );
    final stale = TranslationChunkCheckpoint(
      field: oldPlan.field,
      sourceHash: oldPlan.sourceHash,
      chunks: [
        TranslationChunkState(
          chunk: oldPlan.chunks.single.chunk,
          status: TranslationChunkStatus.completed,
          translatedText: '过期译文 => 爱丽丝',
          attempts: 1,
          lastErrorKind: null,
        ),
      ],
    );
    final sent = <String>[];

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', memoryBook: 'new => Alice'),
      initialChunkCheckpoints: {'memoryBook': stale},
      complete: (prompt) async {
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final value = payload['memoryBook'] as String;
        sent.add(value);
        return jsonEncode({'memoryBook': value.replaceAll('Alice', '爱丽丝')});
      },
    );

    expect(sent, ['new => Alice']);
    expect(translated.memoryBook, 'new => 爱丽丝');
    expect(translated.memoryBook, isNot(contains('过期译文')));
  });

  test('marker corruption repairs once then pauses without retained fallback',
      () async {
    const source = '[off] [p=10] [re] [sec=plot] key => English text';
    final checkpoints = <TranslationChunkCheckpoint>[];
    var calls = 0;

    final future =
        AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', memoryBook: source),
      onChunkCheckpoint: (field, checkpoint) async {
        if (field == 'memoryBook') checkpoints.add(checkpoint);
      },
      complete: (prompt) async {
        calls += 1;
        if (calls == 2) expect(prompt, contains('修复'));
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final value = payload['memoryBook'] as String;
        return jsonEncode({'memoryBook': value.replaceAll('[re] ', '')});
      },
    );

    await expectLater(
      future,
      throwsA(
        isA<TranslationWorkPaused>().having(
          (error) => error.failure.kind,
          'kind',
          TranslationFailureKind.invalidOutput,
        ),
      ),
    );
    expect(calls, 2);
    expect(checkpoints, hasLength(2));
    expect(
      checkpoints.every((checkpoint) => checkpoint.chunks.every(
            (state) => state.status == TranslationChunkStatus.pending,
          )),
      isTrue,
    );
    expect(checkpoints.last.chunks.single.attempts, 2);
    expect(checkpoints.last.chunks.single.lastErrorKind,
        TranslationFailureKind.invalidOutput);
  });

  test('rate limit schedules without sleeping and persists failure first',
      () async {
    final checkpoints = <TranslationChunkCheckpoint>[];
    final stopwatch = Stopwatch()..start();

    final future =
        AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', description: 'Translate me'),
      onChunkCheckpoint: (field, checkpoint) async {
        if (field == 'description') checkpoints.add(checkpoint);
      },
      complete: (_) => throw const TranslationRequestFailure(
        kind: TranslationFailureKind.rateLimited,
        retryAfter: Duration(seconds: 30),
        safeCode: 'rate_limited',
      ),
    );

    await expectLater(
      future,
      throwsA(
        isA<TranslationWorkDeferred>().having(
          (error) => error.failure.kind,
          'kind',
          TranslationFailureKind.rateLimited,
        ),
      ),
    );
    stopwatch.stop();
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(checkpoints, hasLength(1));
    expect(checkpoints.single.chunks.single.lastErrorKind,
        TranslationFailureKind.rateLimited);
  });

  test('typed cancellation stops immediately without field fallback', () async {
    var calls = 0;

    final future =
        AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', description: 'Translate me'),
      onChunkCheckpoint: (_, __) async {},
      complete: (_) {
        calls += 1;
        throw const TranslationRequestFailure(
          kind: TranslationFailureKind.cancelled,
          safeCode: 'cancelled',
        );
      },
    );

    await expectLater(
      future,
      throwsA(isA<RoleCardTranslationCancelled>()),
    );
    expect(calls, 1);
  });

  test('marker crossing a hard cut is revalidated after final merge', () async {
    final source = '${List.filled(1198, 'a').join()}[re] => English';
    final checkpoints = <TranslationChunkCheckpoint>[];

    final future =
        AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', memoryBook: source),
      onChunkCheckpoint: (field, checkpoint) async {
        if (field == 'memoryBook') checkpoints.add(checkpoint);
      },
      complete: (prompt) async {
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final value = payload['memoryBook'] as String;
        return jsonEncode({
          'memoryBook':
              value.replaceAll('[r', '[x').replaceAll('English', '中文'),
        });
      },
    );

    await expectLater(
      future,
      throwsA(
        isA<TranslationWorkPaused>().having(
          (error) => error.failure.kind,
          'kind',
          TranslationFailureKind.invalidOutput,
        ),
      ),
    );
    expect(checkpoints, isNotEmpty);
    expect(
      checkpoints.last.chunks.every(
        (state) =>
            state.status == TranslationChunkStatus.pending &&
            state.translatedText.isEmpty &&
            state.lastErrorKind == TranslationFailureKind.invalidOutput,
      ),
      isTrue,
    );
  });

  test('prompt and exampleDialogs use 2400-rune chunks and exact separators',
      () async {
    final promptSource = List.generate(
      180,
      (index) => 'English prompt $index 😀',
    ).join('\r\n');
    final dialogsSource = List.generate(
      100,
      (index) => '<START>\r\nUser: English $index\r\nBot: English reply $index',
    ).join('\r\n\r\n');
    final sent = <String, List<String>>{};

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(
        name: '',
        prompt: promptSource,
        exampleDialogs: dialogsSource,
      ),
      onChunkCheckpoint: (_, __) async {},
      complete: (requestPrompt) async {
        final payload =
            jsonDecode(requestPrompt.split('\n').last) as Map<String, dynamic>;
        final field = payload.keys.single;
        final value = payload[field] as String;
        sent.putIfAbsent(field, () => []).add(value);
        return jsonEncode({field: value.replaceAll('English', '中文')});
      },
    );

    for (final field in ['prompt', 'exampleDialogs']) {
      expect(sent[field], isNotEmpty);
      expect(
        sent[field]!.every((value) => value.runes.length <= 2400),
        isTrue,
      );
      expect(sent[field]!.toSet(), hasLength(sent[field]!.length));
    }
    expect(translated.prompt, promptSource.replaceAll('English', '中文'));
    expect(
      translated.exampleDialogs,
      dialogsSource.replaceAll('English', '中文'),
    );
  });

  test('failed checkpoint is awaited before timeout split sends a child',
      () async {
    final source = List.filled(1000, '界').join();
    final checkpointEntered = Completer<void>();
    final releaseCheckpoint = Completer<void>();
    final sent = <String>[];
    final persisted = <TranslationChunkCheckpoint>[];

    final translation =
        AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', memoryBook: source),
      onChunkCheckpoint: (field, checkpoint) async {
        if (field != 'memoryBook') return;
        persisted.add(checkpoint);
        if (checkpoint.chunks.length > 1 &&
            checkpoint.chunks.every(
              (state) => state.status == TranslationChunkStatus.pending,
            )) {
          if (!checkpointEntered.isCompleted) checkpointEntered.complete();
          await releaseCheckpoint.future;
        }
      },
      complete: (requestPrompt) async {
        final payload =
            jsonDecode(requestPrompt.split('\n').last) as Map<String, dynamic>;
        final value = payload['memoryBook'] as String;
        sent.add(value);
        if (sent.length == 1) {
          throw const TranslationRequestFailure(
            kind: TranslationFailureKind.idleTimeout,
            safeCode: 'idle_timeout',
          );
        }
        return jsonEncode({'memoryBook': value});
      },
    );

    await checkpointEntered.future;
    expect(sent, [source]);
    releaseCheckpoint.complete();
    await translation;
    expect(sent.length, greaterThan(1));
    expect(sent.where((value) => value == source), hasLength(1));
    expect(
      persisted.any((checkpoint) => checkpoint.chunks.any(
            (state) =>
                state.lastErrorKind == TranslationFailureKind.idleTimeout,
          )),
      isFalse,
    );
  });

  test('resumed persisted timeout checkpoint splits before sending parent',
      () async {
    final source = List.filled(1000, '界').join();
    const planner = TranslationChunkPlanner();
    final planned = planner.plan(field: 'memoryBook', source: source);
    final interrupted = TranslationChunkCheckpoint(
      field: planned.field,
      sourceHash: planned.sourceHash,
      chunks: [
        TranslationChunkState(
          chunk: planned.chunks.single.chunk,
          status: TranslationChunkStatus.pending,
          translatedText: '',
          attempts: 1,
          lastErrorKind: TranslationFailureKind.idleTimeout,
        ),
      ],
    );
    final restored = TranslationChunkCheckpoint.fromJson(
      jsonDecode(jsonEncode(interrupted.toJson())) as Map<String, dynamic>,
    );
    final sent = <String>[];
    final persisted = <TranslationChunkCheckpoint>[];

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', memoryBook: source),
      initialChunkCheckpoints: {'memoryBook': restored},
      onChunkCheckpoint: (field, checkpoint) async {
        if (field == 'memoryBook') persisted.add(checkpoint);
      },
      complete: (requestPrompt) async {
        final payload =
            jsonDecode(requestPrompt.split('\n').last) as Map<String, dynamic>;
        final value = payload['memoryBook'] as String;
        sent.add(value);
        return jsonEncode({'memoryBook': value});
      },
    );

    expect(sent, isNotEmpty);
    expect(sent, isNot(contains(source)));
    expect(sent.every((value) => value.runes.length < source.runes.length),
        isTrue);
    expect(persisted.first.chunks.length, greaterThan(1));
    expect(translated.memoryBook, source);
  });

  test(
      'internal empty chunk completes without letting the model alter separators',
      () async {
    final source = 'a.${List.filled(2500, ' ').join()}tail';
    final sent = <String>[];
    final persisted = <TranslationChunkCheckpoint>[];

    final translated =
        await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', prompt: source),
      onChunkCheckpoint: (field, checkpoint) async {
        if (field == 'prompt') persisted.add(checkpoint);
      },
      complete: (requestPrompt) async {
        final payload =
            jsonDecode(requestPrompt.split('\n').last) as Map<String, dynamic>;
        final value = payload['prompt'] as String;
        sent.add(value);
        return jsonEncode({'prompt': value.isEmpty ? 'INJECTED' : value});
      },
    );

    expect(sent, isNot(contains('')));
    expect(translated.prompt, source);
    final emptyStates = persisted.last.chunks.where(
      (state) => state.chunk.sourceText.isEmpty,
    );
    expect(emptyStates, isNotEmpty);
    expect(
      emptyStates.every(
        (state) =>
            state.status == TranslationChunkStatus.completed &&
            state.translatedText.isEmpty,
      ),
      isTrue,
    );
  });

  test('direct success publishes chunk rune progress after checkpoint persists',
      () async {
    const source = 'Detective 😀';
    final checkpointEntered = Completer<void>();
    final releaseCheckpoint = Completer<void>();
    final progresses = <RoleCardTranslationProgress>[];

    final translation =
        AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', description: source),
      onProgress: progresses.add,
      onChunkCheckpoint: (field, checkpoint) async {
        if (field != 'description' ||
            checkpoint.chunks.single.status !=
                TranslationChunkStatus.completed) {
          return;
        }
        if (!checkpointEntered.isCompleted) checkpointEntered.complete();
        await releaseCheckpoint.future;
      },
      complete: (_) async => '{"description":"侦探"}',
    );

    await checkpointEntered.future;
    final beforePersistence = progresses
        .where((progress) => progress.field == 'description')
        .toList();
    expect(
      beforePersistence.map((progress) => progress.stage),
      contains('准备翻译字段'),
    );
    expect(
      beforePersistence.every((progress) => progress.completedRunes == 0),
      isTrue,
    );
    expect(
      beforePersistence.any((progress) => progress.stage == '分块已翻译'),
      isFalse,
    );

    releaseCheckpoint.complete();
    await translation;

    final persistedProgress = progresses.firstWhere(
      (progress) =>
          progress.field == 'description' && progress.stage == '分块已翻译',
    );
    expect(persistedProgress.completedRunes, source.runes.length);
  });

  test(
      'field translation keeps completed rune progress monotonic across fields',
      () async {
    final assistant = AssistantModel(
      name: 'Alice 😀',
      description: 'Detective from London.',
    );
    final progresses = <RoleCardTranslationProgress>[];

    await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      assistant,
      onProgress: progresses.add,
      onChunkCheckpoint: (_, __) async {},
      complete: (prompt) async {
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final field = payload.keys.single;
        return jsonEncode({field: '已翻译:${payload[field]}'});
      },
    );

    final completedRunes = progresses
        .map((progress) => progress.completedRunes)
        .whereType<int>()
        .toList();
    expect(completedRunes, isNotEmpty);
    for (var i = 1; i < completedRunes.length; i++) {
      expect(
        completedRunes[i],
        greaterThanOrEqualTo(completedRunes[i - 1]),
        reason: '字段切换时 completedRunes 不应重置',
      );
    }
    final totalSourceRunes = RoleCardTranslationFields.fromAssistant(assistant)
        .fold<int>(0, (sum, field) => sum + field.source.runes.length);
    expect(progresses.last.completedRunes, totalSourceRunes);
    expect(progresses.last.totalRunes, totalSourceRunes);
  });

  test('整卡成功以所有字段 rune 总数结束进度', () async {
    final assistant = sampleAssistant();
    final progresses = <RoleCardTranslationProgress>[];

    await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      assistant,
      onProgress: progresses.add,
      complete: (_) async => jsonEncode({
        'name': '爱丽丝',
        'description': '一位侦探。',
        'prompt': '保持谨慎。',
        'openingMessage': '晚上好。',
        'exampleDialogs': '示例对话',
        'memoryBook': '[re] ^Baker Street\$ => 爱丽丝住在贝克街。',
      }),
    );

    final completed = progresses.last;
    expect(completed.completedRunes, completed.totalRunes);
    expect(completed.totalRunes, greaterThan(0));
  });

  test('恢复分块按 source 和 separator rune 只累计一次', () async {
    const planner = TranslationChunkPlanner();
    final source = List.generate(
      70,
      (index) => 'key$index => Alice remembers item $index.',
    ).join('\r\n');
    final planned = planner.plan(field: 'memoryBook', source: source);
    expect(planned.chunks.length, greaterThanOrEqualTo(3));
    final restored = TranslationChunkCheckpoint(
      field: planned.field,
      sourceHash: planned.sourceHash,
      chunks: [
        TranslationChunkState(
          chunk: planned.chunks[0].chunk,
          status: TranslationChunkStatus.completed,
          translatedText: planned.chunks[0].chunk.sourceText,
          attempts: 1,
          lastErrorKind: null,
        ),
        TranslationChunkState(
          chunk: planned.chunks[1].chunk,
          status: TranslationChunkStatus.retainedOriginal,
          translatedText: planned.chunks[1].chunk.sourceText,
          attempts: 1,
          lastErrorKind: TranslationFailureKind.invalidOutput,
        ),
        ...planned.chunks.skip(2),
      ],
    );
    final progresses = <RoleCardTranslationProgress>[];

    await AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', memoryBook: source),
      initialChunkCheckpoints: {'memoryBook': restored},
      onProgress: progresses.add,
      complete: (prompt) async {
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final value = payload['memoryBook'] as String;
        return jsonEncode({'memoryBook': value});
      },
    );

    final restoredProgress =
        progresses.where((progress) => progress.stage == '从检查点恢复分块').toList();
    expect(restoredProgress, hasLength(2));
    expect(
      restoredProgress.last.completedRunes,
      planned.chunks.take(2).fold<int>(
          0,
          (sum, state) =>
              sum +
              state.chunk.sourceText.runes.length +
              state.chunk.separatorAfter.runes.length),
    );
    expect(progresses.last.completedRunes, source.runes.length);
    expect(progresses.last.totalRunes, source.runes.length);
  });

  test('等待持久化的 retry 和 timeout split 不会提前累计 rune', () async {
    final source = List.filled(1000, '界').join();
    final splitPersisted = Completer<void>();
    final releaseSplit = Completer<void>();
    final progresses = <RoleCardTranslationProgress>[];
    var calls = 0;

    final translation =
        AssistantRoleCardTranslationService.translateToSimplifiedChinese(
      AssistantModel(name: '', memoryBook: source),
      onProgress: progresses.add,
      onChunkCheckpoint: (field, checkpoint) async {
        if (field != 'memoryBook' || checkpoint.chunks.length == 1) return;
        if (!splitPersisted.isCompleted) splitPersisted.complete();
        await releaseSplit.future;
      },
      complete: (prompt) async {
        final payload =
            jsonDecode(prompt.split('\n').last) as Map<String, dynamic>;
        final value = payload['memoryBook'] as String;
        calls += 1;
        if (calls == 1) {
          throw const TranslationRequestFailure(
            kind: TranslationFailureKind.unsupportedReasoningControl,
            safeCode: 'unsupported_reasoning_control',
          );
        }
        if (calls == 2) {
          throw const TranslationRequestFailure(
            kind: TranslationFailureKind.totalTimeout,
            safeCode: 'total_timeout',
          );
        }
        return jsonEncode({'memoryBook': value});
      },
    );

    await splitPersisted.future;
    expect(
      progresses
          .where((progress) => progress.field == 'memoryBook')
          .every((progress) => progress.completedRunes == 0),
      isTrue,
    );
    releaseSplit.complete();
    await translation;

    expect(progresses.last.completedRunes, source.runes.length);
    expect(progresses.last.totalRunes, source.runes.length);
  });
}
