import { sanitizeFeedbackDiagnostics } from './feedback.service';
describe('Feedback diagnostics privacy', () => {
  it('drops secrets, content, urls and unknown identifiers', () => {
    expect(
      sanitizeFeedbackDiagnostics({
        appVersion: '1.0.6+16',
        platform: 'android',
        locale: 'zh-CN',
        token: 'secret',
        deviceId: 'secret',
        chat: 'private',
        apiKey: 'secret',
        logs: ['secret'],
      }),
    ).toEqual({ appVersion: '1.0.6+16', platform: 'android', locale: 'zh-CN' });
    expect(
      sanitizeFeedbackDiagnostics({
        appVersion: 'https://example.com/?token=secret',
        platform: 'a'.repeat(81),
      }),
    ).toEqual({});
  });
});
