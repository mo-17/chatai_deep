// ignore_for_file: prefer_const_constructors

import 'package:chatgpt_app_core/model/world_book.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WorldBookMatchContext context({
    String input = '钟声在雨夜响起',
    List<String> recentTexts = const [],
    String characterName = '艾琳',
    int messageCount = 1,
    int generationSeed = 7,
    Map<String, WorldBookActivation> activations = const {},
    String personaDescription = '',
    String characterDescription = '',
    String characterPersonality = '',
    String characterDepthPrompt = '',
    String scenario = '',
    String creatorNotes = '',
  }) =>
      WorldBookMatchContext(
        input: input,
        recentTexts: recentTexts,
        characterName: characterName,
        messageCount: messageCount,
        generationSeed: generationSeed,
        activations: activations,
        personaDescription: personaDescription,
        characterDescription: characterDescription,
        characterPersonality: characterPersonality,
        characterDepthPrompt: characterDepthPrompt,
        scenario: scenario,
        creatorNotes: creatorNotes,
      );

  test('legacy line tags parse and round-trip unchanged', () {
    const line =
        '[off] [p=8] [re] [cs] [ww] [sec=雨夜|潮汐] [exclude=白天|庆典] [pos=before_char] [depth=3] [prob=40] [norec] [group=bell] [gw=7] Bell\\s+\\d+ => 钟声代表潮汐';
    final entry = WorldBookEntry.tryParse(line, id: 'bell')!;

    expect(entry.enabled, isFalse);
    expect(entry.priority, 8);
    expect(entry.regex && entry.caseSensitive && entry.wholeWords, isTrue);
    expect(entry.secondaryKeywords, ['雨夜', '潮汐']);
    expect(entry.excludeKeywords, ['白天', '庆典']);
    expect(entry.position, 'before_char');
    expect(entry.depth, 3);
    expect(entry.probability, 40);
    expect(entry.excludeFromRecursion, isTrue);
    expect(entry.group, 'bell');
    expect(entry.groupWeight, 7);
    expect(entry.toLine(), line);
  });

  test('new options serialize through line and JSON DTOs', () {
    final entry = WorldBookEntry(
      id: 'all',
      keywords: const ['星门'],
      content: '星门设定',
      probability: 33,
      probabilityEnabled: false,
      group: 'a,b',
      groupOverride: true,
      useGroupScoring: true,
      selectiveLogic: WorldBookSelectiveLogic.andAll,
      sticky: 2,
      cooldown: 3,
      delay: 4,
      characterFilterNames: const ['艾琳', '诺亚'],
      characterFilterExclude: true,
      matchPersonaDescription: true,
      matchCharacterDescription: true,
      matchCharacterPersonality: true,
      matchCharacterDepthPrompt: true,
      matchScenario: true,
      matchCreatorNotes: true,
    );
    final line = entry.toLine();
    final reparsed = WorldBookEntry.tryParse(line)!;
    final restored = WorldBookEntry.fromJson(entry.toJson());

    expect(line, contains('[prob_disabled]'));
    expect(reparsed.selectiveLogic, WorldBookSelectiveLogic.andAll);
    expect(reparsed.groups, ['a', 'b']);
    expect(reparsed.characterFilterExclude, isTrue);
    expect(reparsed.matchCreatorNotes, isTrue);
    expect(restored.toJson(), entry.toJson());
  });

  test('matches primary secondary exclusion and all selective logics', () {
    final base = WorldBookEntry(
      id: 'logic',
      keywords: const ['钟声'],
      secondaryKeywords: const ['雨夜', '潮汐'],
      content: 'hit',
    );
    expect(WorldBookMatcher.match([base], context()).entries, isNotEmpty);
    expect(
      WorldBookMatcher.match(
        [
          WorldBookEntry(
              id: 'all',
              keywords: const ['钟声'],
              secondaryKeywords: const ['雨夜', '潮汐'],
              selectiveLogic: WorldBookSelectiveLogic.andAll,
              content: 'all')
        ],
        context(input: '钟声 雨夜 潮汐'),
      ).entries.single.content,
      'all',
    );
    expect(
      WorldBookMatcher.match(
        [
          WorldBookEntry(
              id: 'none',
              keywords: const ['钟声'],
              secondaryKeywords: const ['雨夜'],
              selectiveLogic: WorldBookSelectiveLogic.notAny,
              content: 'none')
        ],
        context(input: '钟声'),
      ).entries.single.content,
      'none',
    );
    expect(
      WorldBookMatcher.match(
        [
          WorldBookEntry(
              id: 'notAll',
              keywords: const ['钟声'],
              secondaryKeywords: const ['雨夜', '潮汐'],
              selectiveLogic: WorldBookSelectiveLogic.notAll,
              content: 'notAll')
        ],
        context(input: '钟声 雨夜'),
      ).entries.single.content,
      'notAll',
    );
    expect(
      WorldBookMatcher.match(
        [
          WorldBookEntry(
              id: 'exclude',
              keywords: const ['钟声'],
              excludeKeywords: const ['雨夜'],
              content: 'exclude')
        ],
        context(),
      ).entries,
      isEmpty,
    );
  });

  test(
      'supports field scanning, depth, regex, whole word and character filters',
      () async {
    final entries = [
      WorldBookEntry(
          id: 'field',
          keywords: const ['秘密'],
          matchCreatorNotes: true,
          content: 'field'),
      WorldBookEntry(
          id: 'persona',
          keywords: const ['自我'],
          matchPersonaDescription: true,
          content: 'persona'),
      WorldBookEntry(
          id: 'description',
          keywords: const ['人设'],
          matchCharacterDescription: true,
          content: 'description'),
      WorldBookEntry(
          id: 'personality',
          keywords: const ['冷静'],
          matchCharacterPersonality: true,
          content: 'personality'),
      WorldBookEntry(
          id: 'depthPrompt',
          keywords: const ['深层'],
          matchCharacterDepthPrompt: true,
          content: 'depthPrompt'),
      WorldBookEntry(
          id: 'scenario',
          keywords: const ['港口'],
          matchScenario: true,
          content: 'scenario'),
      WorldBookEntry(
          id: 'depth', keywords: const ['旧港'], depth: 1, content: 'depth'),
      WorldBookEntry(
          id: 'whole',
          keywords: const ['hop'],
          wholeWords: true,
          content: 'whole'),
      WorldBookEntry(
          id: 'regex',
          keywords: const [r'Bell\s+\d+'],
          regex: true,
          content: 'regex'),
      WorldBookEntry(
          id: 'character',
          keywords: const ['钟声'],
          characterFilterNames: const ['艾琳'],
          content: 'character'),
      WorldBookEntry(
          id: 'excludedCharacter',
          keywords: const ['钟声'],
          characterFilterNames: const ['艾琳'],
          characterFilterExclude: true,
          content: 'excluded'),
    ];
    final result = await WorldBookMatcher.matchSafely(
      entries,
      context(
        input: 'Bell 42 bellhop 钟声',
        recentTexts: const ['旧港'],
        creatorNotes: '秘密',
        personaDescription: '自我',
        characterDescription: '人设',
        characterPersonality: '冷静',
        characterDepthPrompt: '深层',
        scenario: '港口',
      ),
      maxEntries: 20,
    );
    expect(
        result.entries.map((item) => item.content),
        containsAll([
          'field',
          'persona',
          'description',
          'personality',
          'depthPrompt',
          'scenario',
          'depth',
          'regex',
          'character',
        ]));
    expect(
        result.entries.map((item) => item.content), isNot(contains('whole')));
    expect(result.entries.map((item) => item.content),
        isNot(contains('excluded')));
  });

  test('灾难性 world-book regex 不在主 isolate 执行并受总预算约束', () async {
    const entries = [
      WorldBookEntry(
        id: 'catastrophic',
        keywords: [r'^(a+)+$'],
        regex: true,
        content: 'must-not-hit',
      ),
    ];
    final attack = context(input: '${'a' * 12000}!');

    final syncClock = Stopwatch()..start();
    final sync = WorldBookMatcher.match(entries, attack);
    syncClock.stop();
    expect(sync.entries, isEmpty);
    expect(syncClock.elapsed, lessThan(const Duration(milliseconds: 100)));

    final safeClock = Stopwatch()..start();
    final safe = await WorldBookMatcher.matchSafely(
      entries,
      attack,
      timeout: const Duration(milliseconds: 80),
    );
    safeClock.stop();
    expect(safe.entries, isEmpty);
    expect(safeClock.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('world-book 匹配限制 entry 与单项 keyword 数量', () async {
    final entries = List<WorldBookEntry>.generate(
      WorldBookMatcher.maxScannedEntries + 20,
      (index) => WorldBookEntry(
        id: 'entry-$index',
        keywords: index == WorldBookMatcher.maxScannedEntries
            ? const ['entry-limit-hit']
            : List<String>.generate(
                WorldBookMatcher.maxKeywordsPerEntry + 20,
                (keyword) =>
                    keyword == WorldBookMatcher.maxKeywordsPerEntry + 10
                        ? 'late-hit'
                        : 'miss-$keyword',
              ),
        content: 'content-$index',
      ),
    );

    final result = await WorldBookMatcher.matchSafely(
      entries,
      WorldBookMatchContext(input: 'late-hit entry-limit-hit'),
      maxEntries: 10,
    );
    expect(result.entries, isEmpty);
  });

  test('delay sticky cooldown and activation state are message-count based',
      () {
    final entry = WorldBookEntry(
      id: 'timed',
      keywords: const ['钟声'],
      content: 'timed',
      delay: 2,
      sticky: 2,
      cooldown: 2,
    );
    expect(WorldBookMatcher.match([entry], context(messageCount: 1)).entries,
        isEmpty);
    final first = WorldBookMatcher.match([entry], context(messageCount: 2));
    expect(first.entries, hasLength(1));
    final sticky = WorldBookMatcher.match([entry],
        context(input: '', messageCount: 4, activations: first.activations));
    expect(sticky.entries, hasLength(1));
    final cooldown = WorldBookMatcher.match(
        [entry], context(messageCount: 5, activations: first.activations));
    expect(cooldown.entries, isEmpty);
    final after = WorldBookMatcher.match(
        [entry], context(messageCount: 7, activations: first.activations));
    expect(after.entries, hasLength(1));
    expect(
        WorldBookRuntimeState.fromJson(first.state.toJson()).activations.keys,
        contains('timed'));
  });

  test(
      'probability and weighted groups are stable; override, scoring and priority apply',
      () {
    final probability = WorldBookEntry(
        id: 'chance',
        keywords: const ['钟声'],
        content: 'chance',
        probability: 50);
    final one =
        WorldBookMatcher.match([probability], context(generationSeed: 99));
    final two =
        WorldBookMatcher.match([probability], context(generationSeed: 99));
    expect(
        one.entries.map((item) => item.id), two.entries.map((item) => item.id));
    expect(
        WorldBookMatcher.match([
          WorldBookEntry(
              id: 'offChance',
              keywords: const ['钟声'],
              content: 'always',
              probability: 0,
              probabilityEnabled: false)
        ], context())
            .entries,
        hasLength(1));

    final grouped = [
      WorldBookEntry(
          id: 'low',
          keywords: const ['钟声'],
          content: 'low',
          group: 'g',
          groupWeight: 100),
      WorldBookEntry(
          id: 'override',
          keywords: const ['钟声'],
          content: 'override',
          group: 'g',
          groupOverride: true,
          priority: 9),
      WorldBookEntry(
          id: 'score',
          keywords: const ['钟声', '雨夜'],
          content: 'score',
          group: 's',
          useGroupScoring: true),
      WorldBookEntry(
          id: 'scoreLow',
          keywords: const ['钟声'],
          content: 'scoreLow',
          group: 's',
          useGroupScoring: true),
      WorldBookEntry(
          id: 'top', keywords: const ['钟声'], content: 'top', priority: 20),
    ];
    final result = WorldBookMatcher.match(grouped, context(), maxEntries: 10);
    expect(result.entries.map((item) => item.id),
        containsAll(['override', 'score', 'top']));
    expect(result.entries.first.id, 'top');
    expect(
        WorldBookMatcher.match(grouped, context(), maxEntries: 1)
            .entries
            .single
            .id,
        'top');
  });

  test('context and activation DTOs preserve persistence-ready values', () {
    final activation = WorldBookActivation(
        entryKey: 'x',
        activatedAtMessage: 2,
        stickyUntilMessage: 4,
        cooldownUntilMessage: 6);
    final original =
        context(activations: {'x': activation}, recentTexts: const ['a']);
    final restored = WorldBookMatchContext.fromJson(original.toJson());
    expect(restored.recentTexts, ['a']);
    expect(restored.activations['x']!.cooldownUntilMessage, 6);
    expect(WorldBookActivation.fromJson(activation.toJson()).toJson(),
        activation.toJson());
  });
}
