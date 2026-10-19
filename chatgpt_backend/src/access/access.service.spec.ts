import { normalizePolicy, estimateInputReservation } from './access.service';
import { AccessPolicy } from './access-policy.entity';
const base = () =>
  Object.assign(new AccessPolicy(), {
    id: 1,
    limitsEnabled: false,
    trialEnabled: false,
    trialProviderCode: '',
    trialModel: '',
    dailyRequests: 100,
    dailyTokens: 10000,
    globalDailyTokens: 100000,
    globalDailyRequests: 500,
    maxConcurrent: 1,
    maxOutputTokens: 2048,
  });
describe('Access policy safety', () => {
  it('fails closed without limits or trial model', () => {
    expect(() => normalizePolicy({ trialEnabled: true }, base())).toThrow();
    expect(() => normalizePolicy({ dailyTokens: -1 }, base())).toThrow();
    expect(() => normalizePolicy({ maxConcurrent: 1.5 }, base())).toThrow();
    expect(() => normalizePolicy({ apiKey: 'secret' }, base())).toThrow();
    expect(() =>
      normalizePolicy({ requireVerifiedEmail: 'true' }, base()),
    ).toThrow();
    expect(() => normalizePolicy({ requestsPerMinute: 0 }, base())).toThrow();
    expect(() =>
      normalizePolicy({ globalMaxConcurrent: 101 }, base()),
    ).toThrow();
  });
  it('keeps 10k daily budget and accepts configured Flash', () => {
    const p = normalizePolicy(
      {
        limitsEnabled: true,
        trialEnabled: true,
        trialProviderCode: 'deepseek',
        trialModel: 'deepseek-flash',
      },
      base(),
    );
    expect(p.dailyTokens).toBe(10000);
  });
  it('reserves UTF8 bytes including message framing', () => {
    const body = {
      model: 'deepseek-flash',
      messages: [{ role: 'user', content: '你好 hello' }],
    };
    expect(estimateInputReservation(body)).toBeGreaterThan(
      Buffer.byteLength(JSON.stringify(body.messages)),
    );
  });
  it('rejects media and tool payloads without a trustworthy token bound', () => {
    expect(() =>
      estimateInputReservation({
        model: 'a',
        messages: [
          {
            role: 'user',
            content: [
              {
                type: 'image_url',
                image_url: { url: 'https://example.com/a' },
              },
            ],
          },
        ],
      }),
    ).toThrow();
    expect(() =>
      estimateInputReservation({
        model: 'a',
        messages: [{ role: 'tool', content: 'x' }],
      }),
    ).toThrow();
  });
});
