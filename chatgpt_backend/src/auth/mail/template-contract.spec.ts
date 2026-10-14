import { AdminAuthController } from '../../../libs/auth-kit/src/controllers/admin-auth.controller';
import {
  renderCodeEmail,
  renderConfiguredCodeEmail,
  validateCodeTemplate,
} from '../../../libs/auth-kit/src/verification/senders/email-code.template';
import type { AuthKitModuleOptions } from '../../../libs/auth-kit/src/auth-kit.module';
import type { Repository } from 'typeorm';
import type { SmtpProvider } from '../../../libs/auth-kit/src/verification/entities/smtp-provider.entity';
import type { VerificationCode } from '../../../libs/auth-kit/src/verification/entities/verification-code.entity';
import type { EmailTemplate } from '../../../libs/auth-kit/src/verification/entities/email-template.entity';
import type { AuthSettingsService } from '../../../libs/auth-kit/src/settings/auth-settings.service';
import type { EmailSenderManager } from '../../../libs/auth-kit/src/verification/senders/email-sender.manager';
const params = { code: '123456', purposeLabel: '登录', ttlMinutes: 5 };
function fixture() {
  const saved: Record<string, unknown> = {};
  const repo = {
    findOne: jest.fn(() => Promise.resolve(null)),
    findOneOrFail: jest.fn(() => Promise.resolve(saved)),
    create: jest.fn((v: Record<string, unknown>) => v),
    save: jest.fn((v: Record<string, unknown>) =>
      Promise.resolve(Object.assign(saved, v)),
    ),
    upsert: jest.fn((v: Record<string, unknown>) =>
      Promise.resolve(Object.assign(saved, v)),
    ),
    find: jest.fn(() => Promise.resolve([])),
  };
  const controller = new AdminAuthController(
    {} as Repository<SmtpProvider>,
    {} as Repository<VerificationCode>,
    repo as unknown as Repository<EmailTemplate>,
    {} as AuthSettingsService,
    {} as EmailSenderManager,
    { appSecretKey: 'synthetic-template-key-only' } as AuthKitModuleOptions,
  );
  return { controller, repo, saved };
}
describe('A1 controlled mail template contract; no network', () => {
  it('missing template exactly preserves original default rendering', () => {
    expect(renderConfiguredCodeEmail(params, null)).toEqual(
      renderCodeEmail(params),
    );
  });
  it('three placeholders replace all occurrences once, escape inserted HTML, expressions stay literal', () => {
    const rendered = renderConfiguredCodeEmail(
      { ...params, purposeLabel: '<b>登录&"\'</b>' },
      {
        subject: '{{code}} {{purposeLabel}} {{ttlMinutes}}',
        body: '<p>{{code}} / {{code}} / {{purposeLabel}} / {{ttlMinutes}} / ${process.env.SECRET}</p>',
      },
    );
    expect(rendered.html).toBe(
      '<p>123456 / 123456 / &lt;b&gt;登录&amp;&quot;&#39;&lt;/b&gt; / 5 / ${process.env.SECRET}</p>',
    );
    expect(rendered.subject).toBe('123456 <b>登录&"\'</b> 5');
  });
  it.each(['{{secret}}', '{{ code }}', '{{code}', 'x}}'])(
    'rejects unknown or incomplete placeholder %s',
    (token) => {
      expect(validateCodeTemplate({ subject: '标题', body: token })).toBe(
        false,
      );
    },
  );
  it('subject CRLF and invalid legacy row fall back safely', () => {
    expect(
      validateCodeTemplate({
        subject: 'ok\r\nBcc:synthetic',
        body: '<p>body</p>',
      }),
    ).toBe(false);
    expect(
      renderConfiguredCodeEmail(params, {
        subject: 'ok\r\nBcc:synthetic',
        body: 'bad',
      }),
    ).toEqual(renderCodeEmail(params));
  });
  it('PUT key/subject/body upserts exact fields and returns projection', async () => {
    const { controller, repo } = fixture();
    const result = await controller.updateTemplate('code-login', {
      subject: '验证码 {{code}}',
      body: '<p>{{ttlMinutes}}</p>',
    });
    expect(repo.upsert).toHaveBeenCalledWith(
      {
        key: 'code-login',
        subject: '验证码 {{code}}',
        body: '<p>{{ttlMinutes}}</p>',
      },
      ['key'],
    );
    expect(repo.save).not.toHaveBeenCalled();
    expect(result.data.key).toBe('code-login');
  });
  it.each([
    ['arbitrary', { subject: 'ok', body: 'ok' }],
    ['code-login', { subject: 'ok\nBcc:synthetic', body: 'ok' }],
    ['code-login', { subject: 'ok', body: '{{secret}}' }],
    [
      'code-login',
      { subject: 'ok', body: 'ok', html: '<script>synthetic</script>' },
    ],
  ])('rejects unsafe or unknown PUT %s before storing', async (key, body) => {
    const { controller, repo } = fixture();
    await expect(controller.updateTemplate(key, body)).rejects.toThrow();
    expect(repo.save).not.toHaveBeenCalled();
    expect(repo.upsert).not.toHaveBeenCalled();
  });
});
