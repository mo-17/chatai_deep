import type { CodePurpose } from '../verification-contract';

export const CODE_TEMPLATE_KEYS = [
  'code-login',
  'code-register',
  'code-bind',
  'code-reset_password',
] as const;
export function codeTemplateKey(purpose: CodePurpose): string {
  return `code-${purpose}`;
}
export function validateCodeTemplate(template: {
  subject: string;
  body: string;
}): boolean {
  if (
    !template.subject ||
    template.subject.length > 200 ||
    /[\r\n\0]/.test(template.subject) ||
    !template.body ||
    template.body.length > 65536 ||
    template.body.includes('\0')
  )
    return false;
  return [template.subject, template.body].every((text) => {
    const rest = text.replace(/\{\{(code|purposeLabel|ttlMinutes)\}\}/g, '');
    return !rest.includes('{{') && !rest.includes('}}');
  });
}
export function escapeMailHtml(value: string): string {
  return value.replace(
    /[&<>"']/g,
    (c) =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[
        c
      ]!,
  );
}
/** 固定三个占位符；不解释表达式，也不递归替换插入值。 */
export function renderConfiguredCodeEmail(
  params: { code: string; purposeLabel: string; ttlMinutes: number },
  template?: { subject: string; body: string } | null,
): { subject: string; html: string } {
  if (!template || !validateCodeTemplate(template))
    return renderCodeEmail(params);
  const values = {
    code: params.code,
    purposeLabel: params.purposeLabel,
    ttlMinutes: String(params.ttlMinutes),
  };
  const replace = (text: string, html: boolean) =>
    text.replace(
      /\{\{(code|purposeLabel|ttlMinutes)\}\}/g,
      (_match, key: keyof typeof values) =>
        html ? escapeMailHtml(values[key]) : values[key],
    );
  const subject = replace(template.subject, false);
  if (/[\r\n\0]/.test(subject) || subject.length > 200)
    return renderCodeEmail(params);
  return { subject, html: replace(template.body, true) };
}

/**
 * 验证码邮件 HTML 模板
 */
export function renderCodeEmail(params: {
  code: string;
  purposeLabel: string;
  ttlMinutes: number;
}): { subject: string; html: string } {
  const code = escapeMailHtml(params.code),
    purposeLabel = escapeMailHtml(params.purposeLabel),
    ttlMinutes = params.ttlMinutes;
  const subject = `ChatAI Deep - ${params.purposeLabel.replace(/[\r\n\0]/g, '')}验证码`;
  const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${escapeMailHtml(subject)}</title>
</head>
<body style="margin:0;padding:0;background-color:#f5f5f5;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background-color:#f5f5f5;padding:40px 20px;">
    <tr>
      <td align="center">
        <table width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,0.08);">
          <tr>
            <td style="background:linear-gradient(135deg,#0f3460,#16213e);padding:32px 24px;text-align:center;">
              <h1 style="color:#fff;font-size:22px;margin:0;font-weight:600;">ChatAI Deep</h1>
            </td>
          </tr>
          <tr>
            <td style="padding:32px 24px;">
              <p style="color:#333;font-size:16px;margin:0 0 24px;line-height:1.6;">
                您正在进行 <strong style="color:#0f3460;">${purposeLabel}</strong> 操作。
              </p>
              <div style="background:#f0f4ff;border:1px dashed #0f3460;border-radius:8px;padding:20px;text-align:center;margin-bottom:24px;">
                <span style="font-size:32px;font-weight:700;letter-spacing:8px;color:#0f3460;">${code}</span>
              </div>
              <p style="color:#888;font-size:14px;margin:0;line-height:1.6;">
                验证码 ${ttlMinutes} 分钟内有效，请勿泄露给他人。
              </p>
            </td>
          </tr>
          <tr>
            <td style="background:#fafafa;padding:16px 24px;text-align:center;">
              <p style="color:#aaa;font-size:12px;margin:0;">
                此邮件由系统自动发送，请勿回复。
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
  return { subject, html };
}
