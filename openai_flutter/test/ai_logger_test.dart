import 'package:flutter_test/flutter_test.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

void main() {
  test('redactSensitive 隐去 headers、JSON 和 URL 中的凭据', () {
    final input = 'Authorization: Bearer abc.def '
        'apiKey="sk-secret" '
        '"password":"p@ss" '
        'boarding-pass=board-token '
        'access_token=oauth-token '
        'client_secret=oauth-client-secret '
        'https://example.com?token=url-token&safe=1';

    final redacted = AILogger.redactSensitive(input);

    expect(redacted, isNot(contains('abc.def')));
    expect(redacted, isNot(contains('sk-secret')));
    expect(redacted, isNot(contains('p@ss')));
    expect(redacted, isNot(contains('board-token')));
    expect(redacted, isNot(contains('oauth-token')));
    expect(redacted, isNot(contains('oauth-client-secret')));
    expect(redacted, isNot(contains('url-token')));
    expect(redacted, contains('safe=1'));
    expect(redacted, contains('<redacted>'));
  });

  test('redactSensitive 保留普通诊断文本', () {
    const message = 'backend response: 503, retry in 2 seconds';
    expect(AILogger.redactSensitive(message), message);
  });

  test('redactSensitive 隐去 Basic、带空格引号值和 URL 凭据', () {
    const basic = 'dXNlcjpwYXNzd29yZA==';
    const input = 'Authorization: Basic $basic '
        'apiKey="secret value with spaces" '
        'https://alice:pass@example.com/v1/chat'
        '?key=query-secret&safe=1#fragment-secret';

    final redacted = AILogger.redactSensitive(input);

    expect(redacted, isNot(contains(basic)));
    expect(redacted, isNot(contains('secret value with spaces')));
    expect(redacted, isNot(contains('value with spaces')));
    expect(redacted, isNot(contains('alice:pass')));
    expect(redacted, isNot(contains('query-secret')));
    expect(redacted, isNot(contains('fragment-secret')));
    expect(redacted, contains('safe=1'));
    expect(redacted, contains('<redacted>'));
  });
}
