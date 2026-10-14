export type DeliveryFailure = 'failed' | 'unknown';

/** 不保留原始 SMTP 响应、cause、地址或凭据，供状态与日志使用。 */
export class MailDeliveryError extends Error {
  constructor(
    readonly safeCode: string,
    readonly deliveryStatus: DeliveryFailure,
  ) {
    super('邮件服务暂时不可用');
  }
}

export function safeMailFailure(error: unknown): MailDeliveryError {
  if (error instanceof MailDeliveryError) return error;
  const e = error as { code?: unknown; responseCode?: unknown } | null;
  if (e?.code === 'EAUTH')
    return new MailDeliveryError('smtp_authentication_failed', 'failed');
  if (e?.code === 'EENVELOPE' || e?.code === 'EMESSAGE')
    return new MailDeliveryError('smtp_message_rejected', 'failed');
  if (
    e?.code === 'ETIMEDOUT' ||
    e?.code === 'ECONNECTION' ||
    e?.code === 'ESOCKET'
  )
    return new MailDeliveryError('smtp_delivery_unknown', 'unknown');
  if (
    typeof e?.responseCode === 'number' &&
    e.responseCode >= 400 &&
    e.responseCode <= 599
  )
    return new MailDeliveryError('smtp_rejected', 'failed');
  return new MailDeliveryError('smtp_delivery_unknown', 'unknown');
}
