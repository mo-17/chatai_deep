// 知名 SMTP 服务商的常用配置预设，用于 generic slot 的快速填表。
// 选中预设后会自动填 host/port/secure；账号密码仍需手动输入。

export type SmtpPresetGroup = 'cn' | 'intl' | 'cloud';

export interface SmtpPreset {
  /** 预设标识，仅 UI 内部使用 */
  id: string;
  /** 展示名 */
  name: string;
  group: SmtpPresetGroup;
  host: string;
  port: number;
  /** true=SSL (一般 465)，false=STARTTLS (一般 587/25) */
  secure: boolean;
  /** 用户名占位示例 */
  usernamePlaceholder?: string;
  /** 密码获取提示（多数服务商需要"授权码 / 应用专用密码"而不是登录密码） */
  passwordHint: string;
  /** 帮助文档链接 */
  helpUrl?: string;
}

export const GROUP_LABEL: Record<SmtpPresetGroup, string> = {
  cn: '国内邮箱',
  intl: '国际邮箱',
  cloud: '云邮件服务',
};

export const SMTP_PRESETS: SmtpPreset[] = [
  // ===== 国内邮箱 =====
  {
    id: 'qq',
    name: 'QQ 邮箱',
    group: 'cn',
    host: 'smtp.qq.com',
    port: 465,
    secure: true,
    usernamePlaceholder: 'yourname@qq.com',
    passwordHint: '需在「设置 → 账户」开启 SMTP 服务，使用生成的「授权码」作为密码，不是 QQ 登录密码。',
    helpUrl: 'https://service.mail.qq.com/detail/0/75',
  },
  {
    id: 'netease_163',
    name: '163 邮箱',
    group: 'cn',
    host: 'smtp.163.com',
    port: 465,
    secure: true,
    usernamePlaceholder: 'yourname@163.com',
    passwordHint: '需在「设置 → POP3/SMTP/IMAP」开启 SMTP，使用生成的「客户端授权密码」。',
  },
  {
    id: 'netease_126',
    name: '126 邮箱',
    group: 'cn',
    host: 'smtp.126.com',
    port: 465,
    secure: true,
    usernamePlaceholder: 'yourname@126.com',
    passwordHint: '同 163：需开启 SMTP，使用「客户端授权密码」。',
  },
  {
    id: 'sina',
    name: 'Sina 邮箱',
    group: 'cn',
    host: 'smtp.sina.com',
    port: 465,
    secure: true,
    usernamePlaceholder: 'yourname@sina.com',
    passwordHint: '需在 Sina 邮箱后台开启 SMTP 服务后再使用。',
  },
  {
    id: 'sohu',
    name: 'Sohu 邮箱',
    group: 'cn',
    host: 'smtp.sohu.com',
    port: 465,
    secure: true,
    usernamePlaceholder: 'yourname@sohu.com',
    passwordHint: '需在 Sohu 邮箱后台开启 SMTP 服务，使用「独立密码」。',
  },
  {
    id: 'aliyun_qiye',
    name: '阿里云企业邮 (mxhichina)',
    group: 'cn',
    host: 'smtp.qiye.aliyun.com',
    port: 465,
    secure: true,
    usernamePlaceholder: 'yourname@yourdomain.com',
    passwordHint: '用户名为企业邮完整地址，密码为邮箱登录密码。注意：这是企业邮箱 SMTP，非阿里云邮件推送（DM）。',
  },
  {
    id: 'tencent_exmail',
    name: '腾讯企业邮 (exmail)',
    group: 'cn',
    host: 'smtp.exmail.qq.com',
    port: 465,
    secure: true,
    usernamePlaceholder: 'yourname@yourdomain.com',
    passwordHint: '需在「设置 → 客户端专用密码」生成专用密码，不能使用登录密码。',
    helpUrl: 'https://service.exmail.qq.com/cgi-bin/help?subtype=1&id=20023&no=20011',
  },

  // ===== 国际邮箱 =====
  {
    id: 'gmail',
    name: 'Gmail',
    group: 'intl',
    host: 'smtp.gmail.com',
    port: 587,
    secure: false,
    usernamePlaceholder: 'yourname@gmail.com',
    passwordHint: '需先开启两步验证，再在 Google 账户安全设置中生成「应用专用密码」(App Password) 作为密码。',
    helpUrl: 'https://support.google.com/accounts/answer/185833',
  },
  {
    id: 'outlook',
    name: '个人 Outlook / Hotmail（OAuth2）',
    group: 'intl',
    host: 'smtp-mail.outlook.com',
    port: 587,
    secure: false,
    usernamePlaceholder: 'yourname@outlook.com',
    passwordHint: '个人 Outlook / Hotmail 必须使用 OAuth2：保存微软应用与固定发件地址后授权。企业 Microsoft 365 不适用此个人账号流程。',
  },
  {
    id: 'yahoo',
    name: 'Yahoo Mail',
    group: 'intl',
    host: 'smtp.mail.yahoo.com',
    port: 465,
    secure: true,
    usernamePlaceholder: 'yourname@yahoo.com',
    passwordHint: '需在「账户安全 → 应用密码」生成专用密码，不能直接用登录密码。',
  },
  {
    id: 'icloud',
    name: 'iCloud Mail',
    group: 'intl',
    host: 'smtp.mail.me.com',
    port: 587,
    secure: false,
    usernamePlaceholder: 'yourname@icloud.com',
    passwordHint: '需在 Apple ID 网站「登录与安全」生成 App 专用密码。',
    helpUrl: 'https://support.apple.com/zh-cn/HT204397',
  },
  {
    id: 'yandex',
    name: 'Yandex Mail',
    group: 'intl',
    host: 'smtp.yandex.com',
    port: 465,
    secure: true,
    usernamePlaceholder: 'yourname@yandex.com',
    passwordHint: '需在邮件客户端设置中开启 SMTP 访问；建议使用应用密码而非账户密码。',
  },
  {
    id: 'zoho',
    name: 'Zoho Mail',
    group: 'intl',
    host: 'smtp.zoho.com',
    port: 465,
    secure: true,
    usernamePlaceholder: 'yourname@zoho.com',
    passwordHint: '建议使用应用专用密码 (App Password)。EU 区域账号请把 host 改为 smtp.zoho.eu。',
  },
  {
    id: 'proton_bridge',
    name: 'ProtonMail (Bridge)',
    group: 'intl',
    host: '127.0.0.1',
    port: 1025,
    secure: false,
    usernamePlaceholder: 'yourname@protonmail.com',
    passwordHint: '需在本机运行 ProtonMail Bridge 客户端，用户名/密码由 Bridge 界面生成；后端服务必须能访问该本机端口。',
    helpUrl: 'https://proton.me/mail/bridge',
  },

  // ===== 云邮件服务 =====
  {
    id: 'sendgrid',
    name: 'SendGrid',
    group: 'cloud',
    host: 'smtp.sendgrid.net',
    port: 587,
    secure: false,
    usernamePlaceholder: 'apikey',
    passwordHint: '用户名固定填 "apikey"，密码使用控制台生成的 API Key (SG.xxx)。',
    helpUrl: 'https://docs.sendgrid.com/for-developers/sending-email/integrating-with-the-smtp-api',
  },
  {
    id: 'mailgun',
    name: 'Mailgun',
    group: 'cloud',
    host: 'smtp.mailgun.org',
    port: 587,
    secure: false,
    usernamePlaceholder: 'postmaster@mg.yourdomain.com',
    passwordHint: '用户名为 Mailgun 域下的 SMTP 凭据用户名，密码为对应 SMTP 密码（不是 API Key）。EU 区域请改用 smtp.eu.mailgun.org。',
  },
  {
    id: 'amazon_ses',
    name: 'Amazon SES',
    group: 'cloud',
    host: 'email-smtp.us-east-1.amazonaws.com',
    port: 587,
    secure: false,
    usernamePlaceholder: 'AKIA... (SMTP 凭据用户名)',
    passwordHint: '需在 IAM 生成 SES SMTP 凭据，其用户名/密码与 AWS 访问密钥不同。根据账户所在区域修改 host 中的 region (如 eu-west-1)。',
    helpUrl: 'https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html',
  },
  {
    id: 'postmark',
    name: 'Postmark',
    group: 'cloud',
    host: 'smtp.postmarkapp.com',
    port: 587,
    secure: false,
    usernamePlaceholder: '<Server API Token>',
    passwordHint: '用户名和密码都填同一个 Server API Token。',
  },
  {
    id: 'resend',
    name: 'Resend',
    group: 'cloud',
    host: 'smtp.resend.com',
    port: 465,
    secure: true,
    usernamePlaceholder: 'resend',
    passwordHint: '用户名固定填 "resend"，密码使用控制台生成的 API Key (re_xxx)。',
    helpUrl: 'https://resend.com/docs/send-with-smtp',
  },
  {
    id: 'brevo',
    name: 'Brevo (原 Sendinblue)',
    group: 'cloud',
    host: 'smtp-relay.brevo.com',
    port: 587,
    secure: false,
    usernamePlaceholder: 'yourname@yourdomain.com',
    passwordHint: '用户名为 Brevo 登录邮箱，密码为「SMTP & API → SMTP keys」生成的密钥（不是登录密码）。',
  },
];

/** 给定 host:port:secure，反查匹配的预设（用于编辑回显） */
export function matchPreset(host: string, port: number, secure: boolean): SmtpPreset | undefined {
  return SMTP_PRESETS.find(
    (p) => p.host === host && p.port === port && p.secure === secure,
  );
}
