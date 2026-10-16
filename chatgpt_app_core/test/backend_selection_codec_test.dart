import 'dart:convert';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> pair(
          {String account = 'account-a',
          String origin = 'http://127.0.0.1:39991'}) =>
      {
        'version': 1,
        'mode': 'pair',
        'providerCode': ' p/a ',
        'modelId': ' m/b ',
        'scope': {'accountHash': account, 'origin': origin},
      };

  test('NULL legacy is distinct from follow and invalid explicit values', () {
    expect(BackendSelection.fromStorage(null), isNull);
    final follow = BackendSelection.follow();
    expect(follow.isFollow, isTrue);
    expect(follow.toSafeJson(), {'version': 1, 'mode': 'follow'});
    expect(BackendSelection.fromStorage('null')!.isValid, isFalse);
    expect(BackendSelection.fromStorage('null')!.toSqlText(), 'null');
  });
  test(
      'valid pair preserves exact identifiers and matches only original account/origin',
      () {
    final source = pair();
    final value = BackendSelection.fromStorage(source)!;
    expect(value.isPair, isTrue);
    expect(value.providerCode, ' p/a ');
    expect(value.modelId, ' m/b ');
    expect(value.toSafeJson(), source);
    expect(
        value.matchesScope(
            accountHash: 'account-a', origin: 'http://127.0.0.1:39991'),
        isTrue);
    expect(
        value.matchesScope(
            accountHash: 'account-b', origin: 'http://127.0.0.1:39991'),
        isFalse);
    expect(
        value.matchesScope(
            accountHash: 'account-a', origin: 'http://127.0.0.1:39992'),
        isFalse);
  });
  test(
      'valid foreign scope remains serializable without rebinding or export rejection',
      () {
    final source =
        pair(account: 'foreign-account', origin: 'https://foreign.invalid');
    final value = BackendSelection.fromStorage(source)!;
    expect(value.isValid, isTrue);
    expect(
        value.matchesScope(
            accountHash: 'current', origin: 'http://127.0.0.1:39991'),
        isFalse);
    expect(value.toStorageJson(), source);
    expect(value.toSafeJson(), source);
    expect(jsonDecode(value.toSqlText()), source);
  });
  test(
      'canonical origin normalizes host/scheme/effective port but not identifiers',
      () {
    final value = BackendSelection.pair(
        providerCode: ' P ',
        modelId: ' M ',
        accountHash: 'a',
        origin: 'HTTPS://EXAMPLE.COM:443');
    expect(
        value.origin, BackendSelection.canonicalOrigin('https://example.com'));
    expect(
        value.matchesScope(accountHash: 'a', origin: 'https://example.com:443'),
        isTrue);
    expect(value.providerCode, ' P ');
    expect(value.modelId, ' M ');
    expect(BackendSelection.canonicalOrigin('http://[::1]:39991'), isNotNull);
  });
  for (final bad in [
    '',
    ' ',
    'null',
    '{',
    '[]',
    'true',
    '1',
    '{"version":9,"mode":"follow"}',
    {'version': 1.0, 'mode': 'follow'},
    {'version': 1, 'mode': 'unknown'},
    {'version': 1, 'mode': 'follow', 'modelId': 'hidden'},
  ]) {
    test(
        'malformed/unknown value remains non-NULL and safe export rejects $bad',
        () {
      final value = BackendSelection.fromStorage(bad)!;
      expect(value.isValid, isFalse);
      expect(value.toStorageJson(), bad);
      if (bad is String) expect(value.toSqlText(), bad);
      expect(value.toSafeJson, throwsFormatException);
    });
  }
  for (final origin in [
    'file:///tmp/x',
    'https://user:synthetic-token@host.invalid',
    'https://host.invalid/path',
    'https://host.invalid?token=synthetic-token',
    'https://host.invalid#synthetic-token',
    'http://127.0.0.1:0',
  ]) {
    test('invalid origin shape cannot masquerade as scope mismatch: $origin',
        () {
      final source = pair(origin: origin);
      final value = BackendSelection.fromStorage(source)!;
      expect(value.isValid, isFalse);
      expect(value.toStorageJson(), source);
      expect(value.toSafeJson, throwsFormatException);
    });
  }
  for (final identifier in ['', ' \t ', 7, null]) {
    test('present invalid identifier $identifier never becomes a fallback', () {
      final source = pair()..['providerCode'] = identifier;
      final value = BackendSelection.fromStorage(source)!;
      expect(value.isValid, isFalse);
      expect(value.toStorageJson(), source);
      expect(value.toSafeJson, throwsFormatException);
    });
  }
  test(
      'unknown credential fields are preserved for unrelated storage, never safe-exported',
      () {
    final source = pair()..['token'] = 'synthetic-private-token';
    final value = BackendSelection.fromStorage(source)!;
    expect(value.toStorageJson(), source);
    try {
      value.toSafeJson();
      fail('expected refusal');
    } on FormatException catch (error) {
      expect('$error', isNot(contains('synthetic-private-token')));
    }
  });
  test('defensive copies prevent caller mutation of pair/scope', () {
    final source = pair();
    final value = BackendSelection.fromStorage(source)!;
    (source['scope'] as Map)['accountHash'] = 'changed';
    final exported = value.toSafeJson();
    exported['modelId'] = 'changed';
    expect(value.accountHash, 'account-a');
    expect(value.modelId, ' m/b ');
  });
  test('tuple key does not collide at slash/colon boundaries', () {
    final a = BackendSelection.pair(
        providerCode: 'a/b',
        modelId: 'c',
        accountHash: 'a',
        origin: 'https://host.invalid');
    final b = BackendSelection.pair(
        providerCode: 'a',
        modelId: 'b/c',
        accountHash: 'a',
        origin: 'https://host.invalid');
    expect(a.pairKey, isNot(b.pairKey));
    expect(jsonDecode(a.pairKey!), ['a', 'https://host.invalid', 'a/b', 'c']);
  });
  test(
      'top-level settings codec does not accept follow but preserves its original declaration',
      () {
    final value = BackendSelection.fromStorage({'version': 1, 'mode': 'follow'},
        allowFollow: false)!;
    expect(value.isValid, isFalse);
    expect(value.toStorageJson(), {'version': 1, 'mode': 'follow'});
  });
  test(
      'legacy SQL update omits NULL only; explicit follow/unknown non-NULL remains',
      () {
    final legacy = <String, dynamic>{'title': 'new', 'backendSelection': null};
    BackendSelection.preserveLegacyUpdate(legacy);
    expect(legacy, {'title': 'new'});
    for (final raw in ['unknown', BackendSelection.follow().toSqlText()]) {
      final row = <String, dynamic>{'backendSelection': raw};
      BackendSelection.preserveLegacyUpdate(row);
      expect(row, {'backendSelection': raw});
    }
  });
  test(
      'illegal SQL BLOB keeps original bytes/type for unrelated save, not a JSON fallback',
      () {
    final raw = Uint8List.fromList([0, 255, 123, 2]);
    final value = BackendSelection.fromStorage(raw)!;
    raw[0] = 7;
    expect(value.isValid, isFalse);
    final encoded = value.toSqlValue();
    expect(encoded, isA<Uint8List>());
    expect(encoded, [0, 255, 123, 2]);
    expect(value.toSqlText, throwsFormatException);
    expect(value.toSafeJson, throwsFormatException);
  });
}
