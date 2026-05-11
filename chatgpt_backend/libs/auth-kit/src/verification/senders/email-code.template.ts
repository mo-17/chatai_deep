/**
 * 验证码邮件 HTML 模板
 */
export function renderCodeEmail(params: {
  code: string;
  purposeLabel: string;
  ttlMinutes: number;
}): { subject: string; html: string } {
  const { code, purposeLabel, ttlMinutes } = params;
  const subject = `ChatAI Deep - ${purposeLabel}验证码`;
  const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${subject}</title>
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
