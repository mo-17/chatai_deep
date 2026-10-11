import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/role_card_validation.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/world_book.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _card({bool v3 = false, String name = '艾琳'}) => {
      'spec': v3 ? 'chara_card_v3' : 'chara_card_v2',
      'spec_version': v3 ? '3.0' : '2.0',
      'x_wrapper': {'future': true},
      'data': <String, dynamic>{
        'name': name,
        'description': '钟表师',
        'personality': '温柔',
        'first_mes': '你好',
        'creator': '合成作者',
        'character_version': '作者版本',
        'tags': ['合成'],
        'x_data': {
          'preserved': [1, 2]
        },
        if (v3) 'group_only_greetings': ['群组首句'],
        if (v3) 'source': ['https://invalid.example/synthetic-only'],
      },
    };

Map<String, dynamic> _charxCard(AssistantModel model) {
  final archive =
      ZipDecoder().decodeBytes(AssistantRoleCardService.exportCharx(model));
  return jsonDecode(utf8.decode(archive.findFile('card.json')!.readBytes()!));
}

int _crc(List<int> bytes) {
  var value = 0xffffffff;
  for (final byte in bytes) {
    value ^= byte;
    for (var i = 0; i < 8; i++) {
      value = value & 1 == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1;
    }
  }
  return value ^ 0xffffffff;
}

List<int> _int32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
List<int> _chunk(String type, List<int> data) => [
      ..._int32(data.length),
      ...ascii.encode(type),
      ...data,
      ..._int32(_crc([...ascii.encode(type), ...data])),
    ];
List<int> _png(List<(String, String)> candidates) {
  final source =
      AssistantRoleCardService.exportTavernV2Png(AssistantModel(name: 'base'));
  final output = <int>[...source.take(8)];
  var offset = 8;
  while (offset < source.length) {
    final length =
        ByteData.sublistView(source, offset, offset + 4).getUint32(0);
    final type = ascii.decode(source.sublist(offset + 4, offset + 8));
    if (type == 'IEND') {
      for (final (key, text) in candidates) {
        output.addAll(_chunk('tEXt', [
          ...ascii.encode(key),
          0,
          ...ascii.encode(base64.encode(utf8.encode(text)))
        ]));
      }
    }
    if (type != 'tEXt') {
      output.addAll(source.sublist(offset, offset + length + 12));
    }
    offset += length + 12;
  }
  return output;
}

void main() {
  test('fixed exits normalize legacy core and required lorebook fields',
      () async {
    final source = _card();
    (source['data'] as Map<String, dynamic>).addAll({
      'description': {'zh': '中文设定', 'en': 'kept original'},
      'alternate_greetings': {
        'zh': ['第二句']
      },
      'character_book': {
        'entries': {
          'old': {'key': '钟声', 'content': '旧书正文', 'regex': true},
          'empty': {'content': ''},
        }
      },
    });
    final model = AssistantRoleCardService.importJson(jsonEncode(source));
    for (final output in [
      jsonDecode(AssistantRoleCardService.exportTavernV2Json(model)),
      _charxCard(model)
    ]) {
      final data = output['data'];
      expect(data['description'], '中文设定');
      expect(data['alternate_greetings'], ['第二句']);
      expect(data['extensions']['chatai_deep_original_core']['description'],
          source['data']['description']);
      final book = data['character_book'];
      expect(book['extensions'], isA<Map>());
      expect(book['entries'], hasLength(2));
      for (final item in book['entries']) {
        expect(item['keys'], isA<List>());
        expect(item['content'], isA<String>());
        expect(item['extensions'], isA<Map>());
        expect(item['enabled'], isA<bool>());
        expect(item['insertion_order'], isA<num>());
        if (output['spec'] == 'chara_card_v3') {
          expect(item['use_regex'], isA<bool>());
        }
      }
      final reopened = AssistantRoleCardService.importJson(jsonEncode(output));
      expect(await reopened.systemPromptForSafely('钟声'), contains('旧书正文'));
    }
    final local = AssistantModel(name: '本地正则', memoryBook: r'[re] 钟.* => 正则正文');
    final exported = _charxCard(local);
    expect(exported['data']['character_book']['entries'][0]['use_regex'], true);
    expect(
        await AssistantRoleCardService.importJson(jsonEncode(exported))
            .systemPromptForSafely('钟声'),
        contains('正则正文'));
  });

  test('512 entries and large accepted raw metadata survive full JSON closure',
      () {
    final card = _card();
    (card['data'] as Map)['character_book'] = {
      'entries': List.generate(
          512,
          (i) => {
                'id': i,
                'keys': ['word$i'],
                'content': 'entry$i',
              })
    };
    (card['data'] as Map)['x_large'] = 'a' * (2 * 1024 * 1024);
    final model = AssistantRoleCardService.importJson(jsonEncode(card));
    final reopened = AssistantRoleCardService.importJson(
        AssistantRoleCardService.exportJson(model));
    expect(WorldBookCodec.decode(structuredJson: reopened.worldBookJson),
        hasLength(512));
    final output =
        jsonDecode(AssistantRoleCardService.exportTavernV2Json(reopened));
    expect(output['data']['creator'], '合成作者');
    expect(output['data']['x_large'], card['data']['x_large']);
    expect(output['data']['character_book']['entries'], hasLength(512));
    final tooLarge = _card();
    (tooLarge['data'] as Map)['description'] = 'd' * (6 * 1024 * 1024);
    expect(() => AssistantRoleCardService.importJson(jsonEncode(tooLarge)),
        throwsFormatException);
  });

  test('merge counts unmapped entries and identical merges remain stable', () {
    AssistantModel book(String name, List<Map<String, dynamic>> entries) {
      final card = _card(name: name);
      (card['data'] as Map)['character_book'] = {
        'name': name,
        'extensions': {name: true},
        'entries': entries
      };
      return AssistantRoleCardService.importJson(jsonEncode(card));
    }

    final old =
        book('旧书', List.generate(1024, (i) => {'id': i, 'content': ''}));
    final incoming = book('新书', [
      {'content': '生效正文'}
    ]);
    expect(() => AssistantRoleCardService.mergeWorldBooks(old, incoming),
        throwsFormatException);
    final small = book('小旧书', [
      {'id': 1, 'content': ''},
      {
        'keys': ['旧'],
        'content': '旧'
      }
    ]);
    final added = book('小新书', [
      {'id': 2, 'content': ''},
      {
        'keys': ['新'],
        'content': '新'
      }
    ]);
    final first = AssistantRoleCardService.mergeWorldBooks(small, added);
    final merged =
        AssistantRoleCardService.withWorldBook(added, first.structuredJson);
    final twice = AssistantRoleCardService.mergeWorldBooks(merged, added);
    expect(jsonDecode(twice.structuredJson), jsonDecode(first.structuredJson));
    expect(twice.appendedCount, 0);
    expect(
        _charxCard(merged)['data']['character_book']['entries'], hasLength(4));
  });

  test('shared CHARX URI writes one file while retaining each asset', () {
    final card = _card(v3: true);
    (card['data'] as Map)['assets'] = [
      for (final type in ['icon', 'background'])
        {
          'type': type,
          'name': 'main',
          'uri': 'embeded://assets/shared.png',
          'ext': 'png',
          'future': type,
        }
    ];
    final bytes =
        AssistantRoleCardService.exportTavernV2Png(AssistantModel(name: '合成'));
    final input = Archive()
      ..addFile(ArchiveFile.bytes('card.json', utf8.encode(jsonEncode(card))))
      ..addFile(ArchiveFile.bytes('assets/shared.png', bytes));
    final imported = AssistantRoleCardService.importPackageBytes(
        ZipEncoder().encodeBytes(input),
        filename: 'shared.charx');
    final exported = AssistantRoleCardService.exportCharx(imported);
    final zip = ZipDecoder().decodeBytes(exported);
    expect(zip.files.where((f) => f.name == 'assets/shared.png'), hasLength(1));
    final reopened = AssistantRoleCardService.importPackageBytes(exported,
        filename: 'again.charx');
    expect(reopened.resources, hasLength(2));
    expect(
        reopened.resources
            .every((r) => jsonEncode(r.bytes) == jsonEncode(bytes)),
        true);
    final assets =
        jsonDecode(utf8.decode(zip.findFile('card.json')!.readBytes()!))['data']
            ['assets'];
    expect(assets.map((a) => a['future']).toList(), ['icon', 'background']);
    AssistantRoleCardResource resource(List<int>? data) =>
        AssistantRoleCardResource(
            type: 'other',
            uri: 'embeded://same.bin',
            name: 'same',
            ext: 'bin',
            archivePath: 'same.bin',
            bytes: data == null ? null : Uint8List.fromList(data));
    expect(
        () => AssistantRoleCardService.exportCharx(
                AssistantModel(name: 'conflict'),
                resources: [
                  resource([1]),
                  resource([2])
                ]),
        throwsFormatException);
    expect(
        () => AssistantRoleCardService.exportCharx(
                AssistantModel(name: 'external'),
                resources: [
                  resource(null),
                  resource([1])
                ]),
        returnsNormally);
  });

  test('fallback CHARX paths reject dot segments and unsafe extension', () {
    for (final values in [
      ('.', 'name', 'bin'),
      ('..', 'name', 'bin'),
      ('other', '..', 'bin'),
      ('other', '.', 'bin'),
      ('other', 'name', '../x'),
      ('other', 'name', r'bin\evil')
    ]) {
      final resource = AssistantRoleCardResource(
          type: values.$1,
          uri: '',
          name: values.$2,
          ext: values.$3,
          archivePath: '../unsafe',
          bytes: Uint8List.fromList([1]));
      expect(
          () => AssistantRoleCardService.exportCharx(
              AssistantModel(name: 'path'),
              resources: [resource]),
          throwsFormatException);
    }
  });

  test(
      'snake filter edit preserves nested unknown fields and synchronizes match aliases',
      () {
    final card = _card();
    (card['data'] as Map)['character_book'] = {
      'entries': [
        {
          'keys': ['钟声'],
          'content': '正文',
          'extensions': {
            'character_filter': {
              'names': ['旧角色'],
              'tags': ['保留标签'],
              'is_exclude': false,
              'future': {
                'deep': [1, 2]
              }
            },
            for (final key in [
              'match_persona_description',
              'match_character_description',
              'match_character_personality',
              'match_character_depth_prompt',
              'match_scenario',
              'match_creator_notes'
            ])
              key: false,
          },
        }
      ]
    };
    final model = AssistantRoleCardService.importJson(jsonEncode(card));
    final entry =
        WorldBookCodec.decode(structuredJson: model.worldBookJson).single;
    final values = entry.toJson()
      ..['characterFilterNames'] = ['新角色']
      ..['characterFilterExclude'] = true;
    for (final key in [
      'matchPersonaDescription',
      'matchCharacterDescription',
      'matchCharacterPersonality',
      'matchCharacterDepthPrompt',
      'matchScenario',
      'matchCreatorNotes'
    ]) {
      values[key] = true;
    }
    final changed = AssistantRoleCardService.withWorldBook(
        model,
        WorldBookCodec.encode([WorldBookEntry.fromJson(values)],
            preservingJson: model.worldBookJson));
    final exported =
        _charxCard(changed)['data']['character_book']['entries'][0];
    final filter = exported['extensions']['character_filter'];
    expect(filter['names'], ['新角色']);
    expect(filter['tags'], ['保留标签']);
    expect(filter['future'], {
      'deep': [1, 2]
    });
    expect(filter['isExclude'], true);
    expect(filter['is_exclude'], true);
    for (final key in [
      'match_persona_description',
      'match_character_description',
      'match_character_personality',
      'match_character_depth_prompt',
      'match_scenario',
      'match_creator_notes'
    ]) {
      expect(exported['extensions'][key], true);
    }
    final reopened =
        AssistantRoleCardService.importJson(jsonEncode(_charxCard(changed)));
    final reopenedEntry =
        WorldBookCodec.decode(structuredJson: reopened.worldBookJson).single;
    expect(reopenedEntry.characterFilterNames, ['新角色']);
    expect(reopenedEntry.characterFilterExclude, true);
    expect(reopenedEntry.matchCreatorNotes, true);
  });

  test('CHARX rejects compressed package above its 32 MiB input limit', () {
    final random = Random(142);
    final resources = List.generate(
        3,
        (i) => AssistantRoleCardResource(
              type: 'other',
              uri: 'embeded://$i.bin',
              name: '$i',
              ext: 'bin',
              archivePath: '$i.bin',
              bytes: Uint8List.fromList(
                  List.generate(12 * 1024 * 1024, (_) => random.nextInt(256))),
            ));
    expect(
        () => AssistantRoleCardService.exportCharx(
            AssistantModel(name: 'compressed'),
            resources: resources),
        throwsA(isA<FormatException>().having(
            (error) => error.message, 'size diagnostic', contains('32 MiB'))));
  });

  test(
      'PNG and CHARX exporters reject products exceeding their own input budgets',
      () {
    final source = _card();
    (source['data'] as Map)['x_large'] = 'x' * (2 * 1024 * 1024);
    final model = AssistantRoleCardService.importJson(jsonEncode(source));
    expect(() => AssistantRoleCardService.exportTavernV2Png(model),
        throwsFormatException);
    final huge = AssistantModel(name: 'huge', prompt: 'x' * (16 * 1024 * 1024));
    expect(() => AssistantRoleCardService.exportCharx(huge),
        throwsFormatException);
    final resources = List.generate(
        4,
        (i) => AssistantRoleCardResource(
            type: 'other',
            uri: 'embeded://$i.bin',
            name: '$i',
            ext: 'bin',
            archivePath: '$i.bin',
            bytes: Uint8List(16 * 1024 * 1024)));
    expect(
        () => AssistantRoleCardService.exportCharx(
            AssistantModel(name: 'total'),
            resources: resources),
        throwsFormatException);
  });

  test('CHARX ZIP detection handles BOM and preserves unknown asset metadata',
      () {
    final card = _card(v3: true);
    (card['data'] as Map)['assets'] = [
      {
        'type': 'icon',
        'uri': 'embeded://assets/icon/main.png',
        'name': 'main',
        'ext': 'png',
        'x_asset': {'unknown': true}
      },
    ];
    final bytes = AssistantRoleCardService.exportTavernV2Png(
        AssistantModel(name: '合成头像'));
    final archive = Archive()
      ..addFile(ArchiveFile.bytes(
          'card.json', utf8.encode('\uFEFF${jsonEncode(card)}')))
      ..addFile(ArchiveFile.bytes('assets/icon/main.png', bytes));
    final imported = AssistantRoleCardService.importPackageBytes(
        ZipEncoder().encodeBytes(archive),
        filename: 'renamed.zip');
    expect(imported.resources.single.bytes, bytes);
    final output = ZipDecoder()
        .decodeBytes(AssistantRoleCardService.exportCharx(imported));
    final decoded =
        jsonDecode(utf8.decode(output.findFile('card.json')!.readBytes()!));
    expect(decoded['data']['assets'][0]['x_asset'], {'unknown': true});
    expect(output.findFile('assets/icon/main.png')!.readBytes(), bytes);
  });
  test(
      'nested serialized metadata shares budgets and invalid image resources fail before storage',
      () {
    Object value = 'leaf';
    for (var i = 0; i < RoleCardValidation.maxDerivedDepth + 1; i++) {
      value = [value];
    }
    expect(
        () => AssistantRoleCardService.importJson(jsonEncode({
              'name': '卡',
              'worldBookJson': jsonEncode({'entries': [], 'unknown': value}),
            })),
        throwsFormatException);
    final card = _card(v3: true);
    (card['data'] as Map)['assets'] = [
      {
        'type': 'icon',
        'uri': 'embeded://assets/icon/main.png',
        'name': 'main',
        'ext': 'png'
      },
    ];
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('card.json', utf8.encode(jsonEncode(card))))
      ..addFile(ArchiveFile.bytes('assets/icon/main.png', [1, 2, 3]));
    expect(
        () => AssistantRoleCardService.importPackageBytes(
            ZipEncoder().encodeBytes(archive),
            filename: 'invalid.charx'),
        throwsFormatException);
  });
  test(
      'shared structured merge retains old runtime entries and both metadata sets',
      () {
    AssistantModel model(String name, String word, String content) {
      final card = _card(name: name);
      (card['data'] as Map)['character_book'] = {
        'name': name,
        'extensions': {name: true},
        'entries': [
          {
            'id': 1,
            'keys': [word],
            'content': content,
            'extensions': {'future': name}
          }
        ],
      };
      return AssistantRoleCardService.importJson(jsonEncode(card));
    }

    final old = model('旧书', '钟声', '旧条目生效');
    final incoming = model('新书', '潮汐', '新条目生效');
    final preview = AssistantRoleCardService.mergeWorldBooks(old, incoming);
    final merged = AssistantRoleCardService.withWorldBook(
        incoming, preview.structuredJson);
    expect(preview.existingCount, 1);
    expect(preview.appendedCount, 1);
    expect(merged.memoryBook, preview.mergedText);
    expect(merged.systemPromptFor('钟声'), contains('旧条目生效'));
    expect(merged.systemPromptFor('潮汐'), contains('新条目生效'));
    final ids = WorldBookCodec.decode(structuredJson: merged.worldBookJson)
        .map((entry) => entry.id);
    expect(ids.toSet().length, 2);
    final exported = _charxCard(merged)['data']['character_book'];
    expect(exported['extensions']['旧书'], true);
    expect(exported['extensions']['新书'], true);
    expect(exported['entries'][0]['extensions']['future'], '旧书');
    expect(exported['entries'][1]['extensions']['future'], '新书');
    expect(old.systemPromptFor('潮汐'), isNot(contains('新条目生效')));
  });
  test(
      'editing enabled updates existing disabling aliases without losing unknown extension',
      () {
    final card = _card();
    (card['data'] as Map)['character_book'] = {
      'entries': [
        {
          'keys': ['钟声'],
          'content': '正文',
          'extensions': {'disabled': true, 'future': 7}
        },
      ]
    };
    final model = AssistantRoleCardService.importJson(jsonEncode(card));
    final entry =
        WorldBookCodec.decode(structuredJson: model.worldBookJson).single;
    expect(entry.enabled, false);
    final changed = WorldBookEntry.fromJson(entry.toJson()..['enabled'] = true);
    final next = AssistantRoleCardService.withWorldBook(model,
        WorldBookCodec.encode([changed], preservingJson: model.worldBookJson));
    final exported =
        jsonDecode(AssistantRoleCardService.exportTavernV2Json(next));
    final item = exported['data']['character_book']['entries'][0];
    expect(item['extensions'], {'disabled': false, 'future': 7});
    final reopened = AssistantRoleCardService.importJson(jsonEncode(exported));
    expect(reopened.systemPromptFor('钟声'), contains('正文'));
  });
  test('simple V2 always retains author/version/tags and unknown data', () {
    final imported = AssistantRoleCardService.importJson(jsonEncode(_card()));
    expect(imported.memoryBook, contains('[chatai_deep.tavern_raw.v1]'));
    imported.name = '改名';
    final output =
        jsonDecode(AssistantRoleCardService.exportTavernV2Json(imported));
    expect(output['spec'], 'chara_card_v2');
    expect(output['data']['name'], '改名');
    expect(output['data']['creator'], '合成作者');
    expect(output['data']['character_version'], '作者版本');
    expect(output['data']['tags'], ['合成']);
    expect(output['data']['x_data'], {
      'preserved': [1, 2]
    });
    expect(_charxCard(imported)['x_wrapper'], {'future': true});
    expect(imported.systemPromptFor('钟声'), isNot(contains('合成作者')));
    expect(imported.systemPromptFor('钟声'), isNot(contains('x_data')));
  });

  test('V2 projection fixes protocol and fills every required field', () {
    final model =
        AssistantRoleCardService.importJson(jsonEncode(_card(v3: true)));
    final card = jsonDecode(AssistantRoleCardService.exportTavernV2Json(model));
    expect(card['spec'], 'chara_card_v2');
    expect(card['spec_version'], '2.0');
    final data = card['data'] as Map;
    for (final key in [
      'name',
      'description',
      'personality',
      'scenario',
      'first_mes',
      'mes_example',
      'creator_notes',
      'system_prompt',
      'post_history_instructions',
      'creator',
      'character_version'
    ]) {
      expect(data[key], isA<String>(), reason: key);
    }
    expect(data['alternate_greetings'], isA<List>());
    expect(data['tags'], isA<List>());
    expect(data['extensions'], isA<Map>());
    expect(data.containsKey('group_only_greetings'), isFalse);
    final full = _charxCard(model);
    expect(full['spec'], 'chara_card_v3');
    expect(full['spec_version'], '3.0');
    expect(full['data']['group_only_greetings'], ['群组首句']);
    expect(full['data']['source'], ['https://invalid.example/synthetic-only']);
    expect(
        _charxCard(AssistantModel(name: '本地'))['data']['group_only_greetings'],
        isEmpty);
  });

  for (final v3First in [true, false]) {
    test('PNG prefers ccv3 regardless of chunk order $v3First', () {
      final old = ('chara', jsonEncode(_card(name: 'V2后备')));
      final current = ('ccv3', jsonEncode(_card(v3: true, name: 'V3优先')));
      final result = AssistantRoleCardService.importPackageBytes(
          _png(v3First ? [current, old] : [old, current]));
      expect(result.assistant.name, 'V3优先');
      expect(result.compatibility.text, contains('已优先读取 ccv3'));
    });
  }
  test('bad/future/wrong-type ccv3 falls back with an explicit diagnostic', () {
    for (final bad in [
      '{',
      jsonEncode(_card(v3: true)..['spec_version'] = '4.0'),
      jsonEncode(_card())
    ]) {
      final result = AssistantRoleCardService.importPackageBytes(_png([
        ('ccv3', bad),
        ('chara', jsonEncode(_card(name: '后备'))),
      ]));
      expect(result.assistant.name, '后备');
      expect(result.compatibility.text, contains('已降级读取可用 V2'));
      expect(result.diagnostics, isNotEmpty);
    }
  });
  test('conflicting ccv3 candidates are rejected', () {
    expect(
        () => AssistantRoleCardService.importBytes(_png([
              ('ccv3', jsonEncode(_card(v3: true, name: '一'))),
              ('ccv3', jsonEncode(_card(v3: true, name: '二'))),
            ])),
        throwsFormatException);
  });
  test('PNG CRC/truncation and image dimension overflow are rejected', () {
    final original = Uint8List.fromList(_png([('chara', jsonEncode(_card()))]));
    final damaged = Uint8List.fromList(original)..[29] ^= 1;
    expect(() => AssistantRoleCardService.importBytes(damaged),
        throwsFormatException);
    expect(
        () => AssistantRoleCardService.importBytes(
            original.sublist(0, original.length - 1)),
        throwsFormatException);
    final oversized = Uint8List.fromList(original);
    ByteData.sublistView(oversized).setUint32(16, 99999);
    ByteData.sublistView(oversized)
        .setUint32(29, _crc(oversized.sublist(12, 29)));
    expect(() => AssistantRoleCardService.importBytes(oversized),
        throwsFormatException);
  });

  test('BOM/UTF8 and all public JSON entries share validation', () {
    final text = '\uFEFF${jsonEncode(_card())}';
    expect(AssistantRoleCardService.importJson(text).name, '艾琳');
    expect(AssistantRoleCardService.importBytes(utf8.encode(text)).name, '艾琳');
    expect(() => AssistantRoleCardService.importBytes([0xff, 0xfe]),
        throwsFormatException);
    for (final bad in [
      _card()..['spec_version'] = 2,
      _card()..['spec_version'] = '99.0',
      _card()..['spec'] = 'unknown',
      _card()..['data'] = {'name': '错', 'personality': false},
      _card()..['data'] = {'name': '错', 'first_mes': [], 'extensions': []},
    ]) {
      expect(() => AssistantRoleCardService.importJson(jsonEncode(bad)),
          throwsFormatException);
      expect(
          () => AssistantRoleCardService.importBytes(
              utf8.encode(jsonEncode(bad))),
          throwsFormatException);
    }
  });
  test('depth and world-book entry limits are bounded', () {
    Object value = 'leaf';
    for (var i = 0; i < RoleCardValidation.maxDepth + 1; i++) {
      value = [value];
    }
    expect(
        () => AssistantRoleCardService.importJson(
            jsonEncode({'name': '卡', 'x': value})),
        throwsFormatException);
    final source = _card();
    (source['data'] as Map)['character_book'] = {
      'entries': List.generate(1025, (index) => {'content': 'entry $index'})
    };
    expect(() => AssistantRoleCardService.importJson(jsonEncode(source)),
        throwsFormatException);
  });

  test('book/entry metadata survives editing one supported field and reimport',
      () {
    final source = _card();
    (source['data'] as Map)['character_book'] = {
      'name': '世界书',
      'extensions': {
        'unknown_book': [1, 2]
      },
      'x_book': true,
      'entries': [
        {
          'id': 42,
          'keys': ['钟声'],
          'content': '第一行\n第二行',
          'enabled': true,
          'extensions': {
            'unknown_entry': {'future': true}
          },
          'x_entry': '留存'
        },
        {
          'id': 77,
          'keys': ['潮汐'],
          'content': '另一条',
          'extensions': {'kept': 7}
        },
      ],
    };
    final model = AssistantRoleCardService.importJson(jsonEncode(source));
    final oldJson = model.worldBookJson;
    final entries = WorldBookCodec.decode(structuredJson: oldJson);
    expect(entries.first.content, '第一行\n第二行');
    final changed =
        WorldBookEntry.fromJson(entries.first.toJson()..['content'] = '修改后的正文');
    model.worldBookJson =
        WorldBookCodec.encode([changed, entries.last], preservingJson: oldJson);
    model.name = '改名';
    final output =
        jsonDecode(AssistantRoleCardService.exportTavernV2Json(model));
    final book = output['data']['character_book'];
    expect(book['extensions'], {
      'unknown_book': [1, 2]
    });
    expect(book['x_book'], true);
    expect(book['entries'][0]['content'], '修改后的正文');
    expect(book['entries'][0]['id'], 42);
    expect(book['entries'][0]['extensions'], {
      'unknown_entry': {'future': true}
    });
    expect(book['entries'][0]['x_entry'], '留存');
    expect(book['entries'][1]['extensions'], {'kept': 7});
    final reopened = AssistantRoleCardService.importJson(jsonEncode(output));
    expect(reopened.systemPromptFor('钟声'), contains('修改后的正文'));
    expect(reopened.systemPromptFor('钟声'), isNot(contains('unknown_entry')));
    expect(
        jsonDecode(AssistantRoleCardService.exportTavernV2Json(reopened))[
            'data']['character_book'],
        book);
  });
}
