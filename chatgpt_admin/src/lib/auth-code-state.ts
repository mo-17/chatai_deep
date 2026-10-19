import type { CodeRecord } from './api/auth-admin';

// 保持 page.tsx 仅导出 Next.js 页面允许的成员。
export function codeState(r: CodeRecord, now = Date.now()) {
  if (r.invalidationReason === 'locked') return '已锁定';
  if (r.invalidationReason === 'expired') return '已过期';
  if (r.invalidationReason === 'superseded') return '已被新码替代';
  if (r.consumedAt && (!r.invalidatedAt || r.invalidationReason === 'consumed')) return '已核销';
  if (r.invalidatedAt) return '已失效';
  if (new Date(r.expiresAt).getTime() <= now) return '已过期';
  return r.deliveryStatus === 'sent' ? '待验证' : '不可验证';
}
