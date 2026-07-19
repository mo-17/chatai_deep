import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/reasoning_control_adapter.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_cache.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_fingerprint.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });

  group('TranslationModelProbeRecord', () {
    test('严格 JSON 往返只保存探测证据且没有 cancelled 状态', () {
      final checkedAt = DateTime.utc(2026, 7, 20, 8, 30);
      final record = TranslationModelProbeRecord(
        fingerprint: _fingerprint(1),
        status: TranslationModelProbeStatus.failed,
        checkedAt: checkedAt,
        firstEventMs: 120,
        totalMs: 840,
        safeErrorCode: 'auth_failed',
        reasoningControlSuppressed: true,
      );

      final json = record.toJson();
      expect(json.keys.toSet(), {
        'fingerprint',
        'status',
        'checkedAt',
        'firstEventMs',
        'totalMs',
        'safeErrorCode',
        'reasoningControlSuppressed',
      });
      expect(json['checkedAt'], checkedAt.millisecondsSinceEpoch);
      expect(
        TranslationModelProbeStatus.values.map((value) => value.name),
        ['verified', 'failed'],
      );

      final restored = TranslationModelProbeRecord.fromJson(json);
      expect(restored.fingerprint, record.fingerprint);
      expect(restored.status, record.status);
      expect(restored.checkedAt, checkedAt);
      expect(restored.firstEventMs, 120);
      expect(restored.totalMs, 840);
      expect(restored.safeErrorCode, 'auth_failed');
      expect(restored.reasoningControlSuppressed, isTrue);
    });

    test('严格拒绝错误字段类型、非法摘要、负延迟与 cancelled', () {
      final valid = TranslationModelProbeRecord(
        fingerprint: _fingerprint(2),
        status: TranslationModelProbeStatus.verified,
        checkedAt: DateTime.utc(2026, 7, 20),
        reasoningControlSuppressed: false,
      ).toJson();
      final invalid = <Map<String, dynamic>>[
        {...valid, 'fingerprint': 42},
        {...valid, 'fingerprint': 'ABC'},
        {...valid, 'status': 1},
        {...valid, 'status': 'cancelled'},
        {...valid, 'checkedAt': '2026-07-20'},
        {...valid, 'firstEventMs': -1},
        {...valid, 'totalMs': 1.5},
        {...valid, 'safeErrorCode': 401},
        {...valid, 'reasoningControlSuppressed': 'false'},
        Map<String, dynamic>.from(valid)..remove('reasoningControlSuppressed'),
      ];

      for (final json in invalid) {
        expect(
          () => TranslationModelProbeRecord.fromJson(json),
          throwsFormatException,
          reason: json.toString(),
        );
      }
    });

    test('构造与 JSON 解析只接受计划内 safe error code', () {
      const allowed = <String?>[
        null,
        'auth_failed',
        'unsupported_api',
        'rate_limited',
        'first_event_timeout',
        'idle_timeout',
        'network_unreachable',
        'invalid_output',
        'unknown',
      ];
      for (final code in allowed) {
        final record = TranslationModelProbeRecord(
          fingerprint: _fingerprint(3),
          status: TranslationModelProbeStatus.failed,
          checkedAt: DateTime.utc(2026, 7, 20),
          safeErrorCode: code,
          reasoningControlSuppressed: false,
        );
        expect(record.toJson()['safeErrorCode'], code);
      }

      const sensitive =
          'Authorization: Bearer sk-secret https://private.example/v1';
      final invalid = <String>[
        sensitive,
        'cancelled',
        'not_planned',
        'x' * 512,
      ];
      final validJson = TranslationModelProbeRecord(
        fingerprint: _fingerprint(4),
        status: TranslationModelProbeStatus.failed,
        checkedAt: DateTime.utc(2026, 7, 20),
        safeErrorCode: 'unknown',
        reasoningControlSuppressed: false,
      ).toJson();

      for (final code in invalid) {
        expect(
          () => TranslationModelProbeRecord(
            fingerprint: _fingerprint(4),
            status: TranslationModelProbeStatus.failed,
            checkedAt: DateTime.utc(2026, 7, 20),
            safeErrorCode: code,
            reasoningControlSuppressed: false,
          ),
          throwsArgumentError,
          reason: code,
        );
        expect(
          () => TranslationModelProbeRecord.fromJson({
            ...validJson,
            'safeErrorCode': code,
          }),
          throwsFormatException,
          reason: code,
        );
      }
    });

    test('非法 safe error code 异常不保留或渲染敏感输入', () {
      const sensitive =
          'Authorization: Bearer sk-secret https://private.example/v1';
      Object? constructorError;
      try {
        TranslationModelProbeRecord(
          fingerprint: _fingerprint(5),
          status: TranslationModelProbeStatus.failed,
          checkedAt: DateTime.utc(2026, 7, 20),
          safeErrorCode: sensitive,
          reasoningControlSuppressed: false,
        );
      } catch (error) {
        constructorError = error;
      }
      expect(constructorError, isA<ArgumentError>());
      expect((constructorError as ArgumentError).invalidValue, isNull);

      final validJson = TranslationModelProbeRecord(
        fingerprint: _fingerprint(5),
        status: TranslationModelProbeStatus.failed,
        checkedAt: DateTime.utc(2026, 7, 20),
        safeErrorCode: 'unknown',
        reasoningControlSuppressed: false,
      ).toJson();
      Object? jsonError;
      try {
        TranslationModelProbeRecord.fromJson({
          ...validJson,
          'safeErrorCode': sensitive,
        });
      } catch (error) {
        jsonError = error;
      }
      expect(jsonError, isA<FormatException>());
      expect((jsonError as FormatException).source, isNull);

      for (final rendered in [
        constructorError.toString(),
        jsonError.toString(),
      ]) {
        expect(rendered, isNot(contains(sensitive)));
        expect(rendered, isNot(contains('Authorization')));
        expect(rendered, isNot(contains('sk-secret')));
        expect(rendered, isNot(contains('https://private.example/v1')));
      }
    });
  });

  group('TranslationModelProbeCache', () {
    final now = DateTime.utc(2026, 7, 20, 12);

    test('key 固定按账号隔离且空账号被拒绝', () {
      expect(
        TranslationModelProbeCache.keyFor('account-a'),
        'translation_model_probe_v1_account-a',
      );
      expect(
        () => TranslationModelProbeCache.keyFor('  '),
        throwsArgumentError,
      );
    });

    test('账号 A 与 B 的记录和 generation 完全隔离', () async {
      final cache = TranslationModelProbeCache(now: () => now);
      await _loginAs('account-a');
      final tokenA = cache.tokenFor(
        accountHash: 'account-a',
        providerId: 'deepseek',
      );
      expect(
        await cache.put(
          _record(1, now),
          expectedAccountHash: 'account-a',
          providerId: 'deepseek',
          expectedToken: tokenA,
        ),
        isTrue,
      );

      await _loginAs('account-b');
      final tokenB = cache.tokenFor(
        accountHash: 'account-b',
        providerId: 'deepseek',
      );
      expect(tokenB.sameAs(tokenA), isTrue);
      expect(
          cache.lookup(accountHash: 'account-b', fingerprint: _fingerprint(1)),
          isNull);
      expect(
        await cache.put(
          _record(2, now),
          expectedAccountHash: 'account-b',
          providerId: 'deepseek',
          expectedToken: tokenB,
        ),
        isTrue,
      );

      expect(
          cache.lookup(accountHash: 'account-a', fingerprint: _fingerprint(1)),
          isNotNull);
      expect(
          cache.lookup(accountHash: 'account-a', fingerprint: _fingerprint(2)),
          isNull);
      expect(
          cache.lookup(accountHash: 'account-b', fingerprint: _fingerprint(1)),
          isNull);
      expect(
          cache.lookup(accountHash: 'account-b', fingerprint: _fingerprint(2)),
          isNotNull);
    });

    test('精确七天即过期，七天内一毫秒仍命中，下一次写入清理索引', () async {
      final cache = TranslationModelProbeCache(now: () => now);
      final token =
          cache.tokenFor(accountHash: 'guest', providerId: 'deepseek');
      final almostExpired = _record(
          3,
          now
              .subtract(TranslationModelProbeCache.ttl)
              .add(const Duration(milliseconds: 1)));
      final expired = _record(4, now.subtract(TranslationModelProbeCache.ttl));
      await cache.put(
        almostExpired,
        expectedAccountHash: 'guest',
        providerId: 'deepseek',
        expectedToken: token,
      );
      await cache.put(
        expired,
        expectedAccountHash: 'guest',
        providerId: 'deepseek',
        expectedToken: token,
      );

      expect(
          cache.lookup(
              accountHash: 'guest', fingerprint: almostExpired.fingerprint),
          isNotNull);
      expect(
          cache.lookup(accountHash: 'guest', fingerprint: expired.fingerprint),
          isNull);

      await cache.put(
        _record(5, now),
        expectedAccountHash: 'guest',
        providerId: 'deepseek',
        expectedToken: token,
      );
      final envelope = _envelope('guest');
      expect((envelope['records'] as Map).containsKey(expired.fingerprint),
          isFalse);
      expect(
        ((envelope['providers'] as Map)['deepseek'] as List),
        isNot(contains(expired.fingerprint)),
      );
    });

    test('每账号只保留 checkedAt 最新 50 条并同步清理 provider index', () async {
      final cache = TranslationModelProbeCache(now: () => now);
      final token =
          cache.tokenFor(accountHash: 'guest', providerId: 'deepseek');
      for (var i = 0; i < 55; i++) {
        expect(
          await cache.put(
            _record(i, now.add(Duration(milliseconds: i))),
            expectedAccountHash: 'guest',
            providerId: 'deepseek',
            expectedToken: token,
          ),
          isTrue,
        );
      }

      final envelope = _envelope('guest');
      final records = envelope['records'] as Map;
      final providerIndex = (envelope['providers'] as Map)['deepseek'] as List;
      expect(records, hasLength(TranslationModelProbeCache.maxRecords));
      expect(providerIndex, hasLength(TranslationModelProbeCache.maxRecords));
      for (var i = 0; i < 5; i++) {
        expect(records.containsKey(_fingerprint(i)), isFalse);
        expect(providerIndex, isNot(contains(_fingerprint(i))));
      }
      for (var i = 5; i < 55; i++) {
        expect(records.containsKey(_fingerprint(i)), isTrue);
      }
    });

    test('损坏 envelope 回退为空，损坏 record 被忽略并在下次写入清理', () async {
      final key = TranslationModelProbeCache.keyFor('guest');
      await HiCache.getInstance().setString(key, '{');
      final cache = TranslationModelProbeCache(now: () => now);
      expect(cache.lookup(accountHash: 'guest', fingerprint: _fingerprint(1)),
          isNull);
      final emptyToken =
          cache.tokenFor(accountHash: 'guest', providerId: 'deepseek');
      expect(emptyToken.accountGeneration, 0);
      expect(emptyToken.providerGeneration, 0);
      expect(
        await cache.put(
          _record(1, now),
          expectedAccountHash: 'guest',
          providerId: 'deepseek',
          expectedToken: emptyToken,
        ),
        isTrue,
      );

      await HiCache.getInstance().setString(
        key,
        jsonEncode({
          'version': 1,
          'accountGeneration': 0,
          'providerGenerations': <String, int>{},
          'records': {
            _fingerprint(7): {
              'fingerprint': _fingerprint(7),
              'status': 'cancelled',
              'checkedAt': now.millisecondsSinceEpoch,
              'reasoningControlSuppressed': false,
            },
          },
          'providers': {
            'deepseek': [_fingerprint(7)],
          },
        }),
      );
      expect(cache.lookup(accountHash: 'guest', fingerprint: _fingerprint(7)),
          isNull);
      final token =
          cache.tokenFor(accountHash: 'guest', providerId: 'deepseek');
      await cache.put(
        _record(8, now),
        expectedAccountHash: 'guest',
        providerId: 'deepseek',
        expectedToken: token,
      );
      final cleaned = _envelope('guest');
      expect((cleaned['records'] as Map).containsKey(_fingerprint(7)), isFalse);
      expect(
        ((cleaned['providers'] as Map)['deepseek'] as List),
        isNot(contains(_fingerprint(7))),
      );
    });

    test('损坏 safe error code fail closed，后续落盘不含 secret 或 raw endpoint',
        () async {
      const sensitive =
          'Authorization: Bearer sk-secret https://private.example/v1';
      final key = TranslationModelProbeCache.keyFor('guest');
      await HiCache.getInstance().setString(
        key,
        jsonEncode({
          'version': 1,
          'accountGeneration': 0,
          'providerGenerations': {'deepseek': 0},
          'records': {
            _fingerprint(31): {
              'fingerprint': _fingerprint(31),
              'status': 'failed',
              'checkedAt': now.millisecondsSinceEpoch,
              'safeErrorCode': sensitive,
              'reasoningControlSuppressed': false,
            },
          },
          'providers': {
            'deepseek': [_fingerprint(31)],
          },
        }),
      );
      final cache = TranslationModelProbeCache(now: () => now);

      expect(
        cache.lookup(accountHash: 'guest', fingerprint: _fingerprint(31)),
        isNull,
      );
      final token =
          cache.tokenFor(accountHash: 'guest', providerId: 'deepseek');
      expect(
        await cache.put(
          _record(32, now),
          expectedAccountHash: 'guest',
          providerId: 'deepseek',
          expectedToken: token,
        ),
        isTrue,
      );

      final raw = HiCache.getInstance().get(key) as String;
      expect(raw, isNot(contains(sensitive)));
      expect(raw, isNot(contains('sk-secret')));
      expect(raw, isNot(contains('https://private.example/v1')));
      expect(raw, isNot(contains(_fingerprint(31))));
    });

    test('provider index 任一结构损坏时 records fail closed 且保留 generation CAS',
        () async {
      final key = TranslationModelProbeCache.keyFor('guest');
      final corruptIndexes = <Map<String, dynamic>>[
        {'deepseek': _fingerprint(40)},
        {
          '': [_fingerprint(40)],
        },
        {
          'deepseek': [42],
        },
        {
          'deepseek': ['not-a-sha256'],
        },
      ];
      final cache = TranslationModelProbeCache(now: () => now);

      for (final providers in corruptIndexes) {
        await HiCache.getInstance().setString(
          key,
          jsonEncode({
            'version': 1,
            'accountGeneration': 4,
            'providerGenerations': {'deepseek': 7},
            'records': {
              _fingerprint(40): _record(40, now).toJson(),
            },
            'providers': providers,
          }),
        );

        final token =
            cache.tokenFor(accountHash: 'guest', providerId: 'deepseek');
        expect(token.accountGeneration, 4, reason: providers.toString());
        expect(token.providerGeneration, 7, reason: providers.toString());
        expect(
          cache.lookup(accountHash: 'guest', fingerprint: _fingerprint(40)),
          isNull,
          reason: providers.toString(),
        );
      }

      await cache.invalidateProviders(
        accountHash: 'guest',
        providerIds: {'deepseek'},
      );
      expect(
        cache.lookup(accountHash: 'guest', fingerprint: _fingerprint(40)),
        isNull,
      );
      final envelope = _envelope('guest');
      expect(envelope['accountGeneration'], 4);
      expect(
        (envelope['providerGenerations'] as Map)['deepseek'],
        8,
      );
      expect(envelope['records'], isEmpty);
      expect(envelope['providers'], isEmpty);
    });

    test('provider invalidation 只删除其索引记录并递增对应 generation', () async {
      final cache = TranslationModelProbeCache(now: () => now);
      final deepseekToken =
          cache.tokenFor(accountHash: 'guest', providerId: 'deepseek');
      final openaiToken =
          cache.tokenFor(accountHash: 'guest', providerId: 'openai');
      final backendToken =
          cache.tokenFor(accountHash: 'guest', providerId: null);
      await cache.put(
        _record(10, now),
        expectedAccountHash: 'guest',
        providerId: 'deepseek',
        expectedToken: deepseekToken,
      );
      await cache.put(
        _record(11, now),
        expectedAccountHash: 'guest',
        providerId: 'openai',
        expectedToken: openaiToken,
      );
      await cache.put(
        _record(12, now),
        expectedAccountHash: 'guest',
        providerId: null,
        expectedToken: backendToken,
      );

      await cache.invalidateProviders(
        accountHash: 'guest',
        providerIds: {'deepseek'},
      );

      expect(cache.lookup(accountHash: 'guest', fingerprint: _fingerprint(10)),
          isNull);
      expect(cache.lookup(accountHash: 'guest', fingerprint: _fingerprint(11)),
          isNotNull);
      expect(cache.lookup(accountHash: 'guest', fingerprint: _fingerprint(12)),
          isNotNull);
      expect(
        cache
            .tokenFor(accountHash: 'guest', providerId: 'deepseek')
            .providerGeneration,
        deepseekToken.providerGeneration + 1,
      );
      expect(
        cache
            .tokenFor(accountHash: 'guest', providerId: 'openai')
            .sameAs(openaiToken),
        isTrue,
      );
      expect(
        cache
            .tokenFor(accountHash: 'guest', providerId: null)
            .sameAs(backendToken),
        isTrue,
      );
      expect((_envelope('guest')['providers'] as Map).containsKey('deepseek'),
          isFalse);
    });

    test('跨实例同 key 队列：invalidate 先入队会拒绝旧 token 的 put', () async {
      final first = TranslationModelProbeCache(now: () => now);
      final second = TranslationModelProbeCache(now: () => now);
      final oldToken =
          first.tokenFor(accountHash: 'guest', providerId: 'deepseek');

      final invalidating = first.invalidateProviders(
        accountHash: 'guest',
        providerIds: {'deepseek'},
      );
      final putting = second.put(
        _record(20, now),
        expectedAccountHash: 'guest',
        providerId: 'deepseek',
        expectedToken: oldToken,
      );

      await invalidating;
      expect(await putting, isFalse);
      expect(first.lookup(accountHash: 'guest', fingerprint: _fingerprint(20)),
          isNull);
    });

    test('invalidate 入队时冻结 provider IDs，不受调用方随后修改 Set 影响', () async {
      final cache = TranslationModelProbeCache(now: () => now);
      final token =
          cache.tokenFor(accountHash: 'guest', providerId: 'deepseek');
      await cache.put(
        _record(25, now),
        expectedAccountHash: 'guest',
        providerId: 'deepseek',
        expectedToken: token,
      );
      final providerIds = <String>{'deepseek'};

      final invalidating = cache.invalidateProviders(
        accountHash: 'guest',
        providerIds: providerIds,
      );
      providerIds
        ..clear()
        ..add('openai');
      await invalidating;

      expect(
        cache.lookup(accountHash: 'guest', fingerprint: _fingerprint(25)),
        isNull,
      );
      expect(
        cache
            .tokenFor(accountHash: 'guest', providerId: 'deepseek')
            .providerGeneration,
        token.providerGeneration + 1,
      );
    });

    test('跨实例同 key 队列：put 先入队随后 invalidate 会删除记录', () async {
      final first = TranslationModelProbeCache(now: () => now);
      final second = TranslationModelProbeCache(now: () => now);
      final token =
          first.tokenFor(accountHash: 'guest', providerId: 'deepseek');

      final putting = first.put(
        _record(21, now),
        expectedAccountHash: 'guest',
        providerId: 'deepseek',
        expectedToken: token,
      );
      final invalidating = second.invalidateProviders(
        accountHash: 'guest',
        providerIds: {'deepseek'},
      );

      expect(await putting, isTrue);
      await invalidating;
      expect(first.lookup(accountHash: 'guest', fingerprint: _fingerprint(21)),
          isNull);
    });

    test('clear 保留递增 account generation，旧 token 永不复活，fresh token 可写', () async {
      final first = TranslationModelProbeCache(now: () => now);
      final second = TranslationModelProbeCache(now: () => now);
      final oldToken =
          first.tokenFor(accountHash: 'guest', providerId: 'deepseek');

      final clearing = first.clearAccount('guest');
      final stalePut = second.put(
        _record(22, now),
        expectedAccountHash: 'guest',
        providerId: 'deepseek',
        expectedToken: oldToken,
      );
      await clearing;
      expect(await stalePut, isFalse);

      final freshToken =
          first.tokenFor(accountHash: 'guest', providerId: 'deepseek');
      expect(freshToken.accountGeneration, oldToken.accountGeneration + 1);
      expect(
        await second.put(
          _record(23, now),
          expectedAccountHash: 'guest',
          providerId: 'deepseek',
          expectedToken: freshToken,
        ),
        isTrue,
      );
      expect(first.lookup(accountHash: 'guest', fingerprint: _fingerprint(23)),
          isNotNull);
    });

    test('put 入队后账号已切换会在写入前拒绝', () async {
      await _loginAs('account-a');
      final cache = TranslationModelProbeCache(now: () => now);
      final token =
          cache.tokenFor(accountHash: 'account-a', providerId: 'deepseek');
      final putting = cache.put(
        _record(24, now),
        expectedAccountHash: 'account-a',
        providerId: 'deepseek',
        expectedToken: token,
      );
      await _loginAs('account-b');

      await expectLater(putting, throwsStateError);
      expect(
          cache.lookup(accountHash: 'account-a', fingerprint: _fingerprint(24)),
          isNull);
    });

    test('序列化只含 SHA-256 身份，不含 API Key、endpoint 或 generation token', () async {
      final settings = _settings();
      final profile = _localProfile(settings);
      final fingerprint = TranslationModelProbeFingerprint.build(
        settings: settings,
        profile: profile,
      );
      final cache = TranslationModelProbeCache(now: () => now);
      final token =
          cache.tokenFor(accountHash: 'guest', providerId: 'deepseek');
      await cache.put(
        TranslationModelProbeRecord(
          fingerprint: fingerprint,
          status: TranslationModelProbeStatus.verified,
          checkedAt: now,
          firstEventMs: 100,
          totalMs: 200,
          reasoningControlSuppressed: false,
        ),
        expectedAccountHash: 'guest',
        providerId: 'deepseek',
        expectedToken: token,
      );

      final rawCache = HiCache.getInstance().get(
        TranslationModelProbeCache.keyFor('guest'),
      ) as String;
      expect(rawCache, contains(fingerprint));
      expect(rawCache, isNot(contains('sk-secret')));
      expect(rawCache, isNot(contains('https://private.example/v1')));
      final envelope = (jsonDecode(rawCache) as Map).cast<String, dynamic>();
      final recordJson = ((envelope['records'] as Map)[fingerprint] as Map)
          .cast<String, dynamic>();
      expect(recordJson.containsKey('providerGeneration'), isFalse);
      expect(recordJson.containsKey('accountGeneration'), isFalse);
    });
  });

  group('TranslationModelProbeFingerprint', () {
    test('只改 API Key 保持同一摘要，且 suppression 证据不改变身份', () {
      final settings = _settings();
      final profile = _localProfile(settings);
      final original = TranslationModelProbeFingerprint.build(
        settings: settings,
        profile: profile,
      );
      final changedKey = settings.clone()
        ..activeProvider.apiKey = 'sk-replaced';

      expect(
        TranslationModelProbeFingerprint.build(
            settings: changedKey, profile: profile),
        original,
      );
      expect(
        TranslationModelProbeFingerprint.build(
          settings: settings,
          profile: profile.suppressReasoningControl(),
        ),
        original,
      );
    });

    test('host 大小写和 dot segment 规范化等价，fragment 被丢弃', () {
      final canonical = _settings(endpoint: 'https://private.example/v1');
      final equivalent = _settings(
        endpoint: 'HTTPS://PRIVATE.EXAMPLE/a/../v1#',
      );
      final withFragment = _settings(
        endpoint: 'https://private.example/v1/chat/completions#local-note',
      );

      final expected = TranslationModelProbeFingerprint.build(
        settings: canonical,
        profile: _localProfile(canonical),
      );
      expect(
        TranslationModelProbeFingerprint.build(
          settings: equivalent,
          profile: _localProfile(equivalent),
        ),
        expected,
      );
      expect(
        TranslationModelProbeFingerprint.build(
          settings: withFragment,
          profile: _localProfile(withFragment),
        ),
        expected,
      );
    });

    test('显式 port、path 与 query 的任一变化都会改变摘要', () {
      final endpoints = [
        'https://private.example/v1/chat/completions',
        'https://private.example:443/v1/chat/completions',
        'https://private.example:8443/v1/chat/completions',
        'https://private.example/v2/chat/completions',
        'https://private.example/v1/chat/completions?tenant=a',
        'https://private.example/v1/chat/completions?tenant=b',
        'https://[2001:db8::1]/v1/chat/completions',
        'https://[2001:DB8::1]:443/v1/chat/completions',
      ];
      final fingerprints = <String>{
        for (final endpoint in endpoints)
          TranslationModelProbeFingerprint.build(
            settings: _settings(endpoint: endpoint),
            profile: _localProfile(_settings(endpoint: endpoint)),
          ),
      };

      expect(fingerprints, hasLength(endpoints.length));
    });

    test('model、mode 与 reasoning policy 的任一变化都会改变摘要', () {
      final settings = _settings();
      final localA = _localProfile(settings);
      final localB = TranslationRequestProfile(
        mode: TranslationExecutionMode.local,
        providerId: 'deepseek',
        modelId: 'model-b',
        reasoningPolicy: ChatReasoningPolicy.offIfSupported,
        reasoningControlSuppressed: false,
      );
      final localDefaultReasoning = TranslationRequestProfile(
        mode: TranslationExecutionMode.local,
        providerId: 'deepseek',
        modelId: 'model-a',
        reasoningPolicy: ChatReasoningPolicy.providerDefault,
        reasoningControlSuppressed: false,
      );
      final backend = TranslationRequestProfile(
        mode: TranslationExecutionMode.backend,
        modelId: 'model-a',
        reasoningPolicy: ChatReasoningPolicy.offIfSupported,
        reasoningControlSuppressed: false,
      );

      final fingerprints = {
        TranslationModelProbeFingerprint.build(
            settings: settings, profile: localA),
        TranslationModelProbeFingerprint.build(
            settings: settings, profile: localB),
        TranslationModelProbeFingerprint.build(
          settings: settings,
          profile: localDefaultReasoning,
        ),
        TranslationModelProbeFingerprint.build(
            settings: settings, profile: backend),
      };
      expect(fingerprints, hasLength(4));
    });

    test('摘要明确纳入 protocol 与 reasoning policy version', () {
      final settings = _settings();
      final profile = _localProfile(settings);
      final actual = TranslationModelProbeFingerprint.build(
        settings: settings,
        profile: profile,
      );
      String expectedFor({
        required int protocolVersion,
        required int policyVersion,
      }) {
        final canonical = jsonEncode({
          'protocolVersion': protocolVersion,
          'reasoningPolicyVersion': policyVersion,
          'mode': 'local',
          'providerId': 'deepseek',
          'providerCode': 'deepseek',
          'modelId': 'model-a',
          'endpoint': 'https://private.example/v1/chat/completions',
          'reasoningPolicy': 'offIfSupported',
        });
        return sha256.convert(utf8.encode(canonical)).toString();
      }

      expect(
        actual,
        expectedFor(
          protocolVersion: TranslationModelProbeFingerprint.protocolVersion,
          policyVersion: ReasoningControlAdapter.policyVersion,
        ),
      );
      expect(
        actual,
        isNot(
          expectedFor(
            protocolVersion:
                TranslationModelProbeFingerprint.protocolVersion + 1,
            policyVersion: ReasoningControlAdapter.policyVersion,
          ),
        ),
      );
      expect(
        actual,
        isNot(
          expectedFor(
            protocolVersion: TranslationModelProbeFingerprint.protocolVersion,
            policyVersion: ReasoningControlAdapter.policyVersion + 1,
          ),
        ),
      );
    });
  });
}

TranslationModelProbeRecord _record(int id, DateTime checkedAt) {
  return TranslationModelProbeRecord(
    fingerprint: _fingerprint(id),
    status: TranslationModelProbeStatus.verified,
    checkedAt: checkedAt,
    reasoningControlSuppressed: false,
  );
}

String _fingerprint(int id) => id.toRadixString(16).padLeft(64, '0');

Map<String, dynamic> _envelope(String accountHash) {
  final raw = HiCache.getInstance().get(
    TranslationModelProbeCache.keyFor(accountHash),
  ) as String;
  return (jsonDecode(raw) as Map).cast<String, dynamic>();
}

Future<void> _loginAs(String accountHash) {
  return LoginSdkConfig.instance.storage.writeProfile(
    token: 'token-$accountHash',
    userName: accountHash,
    extras: {'accountHash': accountHash},
  );
}

AISettings _settings({
  String apiKey = 'sk-secret',
  String endpoint = 'https://private.example/v1',
}) {
  final settings = AISettings.defaults();
  settings
    ..mode = AIMode.local
    ..activeProviderId = 'deepseek'
    ..providers = [
      AiProvider(
        id: 'deepseek',
        type: 'openai',
        name: 'DeepSeek',
        apiKey: apiKey,
        apiHost: endpoint,
        models: [AiModel(id: 'model-a'), AiModel(id: 'model-b')],
        selectedModelId: 'model-a',
        enabled: true,
      ),
    ];
  return settings;
}

TranslationRequestProfile _localProfile(AISettings settings) {
  return TranslationRequestProfile(
    mode: TranslationExecutionMode.local,
    providerId: 'deepseek',
    modelId: settings.activeProvider.effectiveModelId,
    reasoningPolicy: ChatReasoningPolicy.offIfSupported,
    reasoningControlSuppressed: false,
  );
}
