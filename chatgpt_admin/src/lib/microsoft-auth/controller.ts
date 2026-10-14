import { captureAuthSession, isAuthSessionCurrent, type AuthSession } from '../api/auth-session';
import { microsoftStart, microsoftFlow, microsoftComplete, microsoftStatus, microsoftDisconnect, type MicrosoftStart, type MicrosoftStatus, type FlowStatus } from '../api/auth-admin';
export interface AuthPopup { close(): void; navigate(url: string): void; source: unknown }
/** 接点在原会话/当前generation存活时才可发GET，最后await后再次验证才可应用快照。 */
export type ProviderReconciler = (isCurrent: () => boolean) => Promise<void>;
interface Dependencies {
  session(): AuthSession; current(s: AuthSession): boolean; popup(): AuthPopup | null;
  start(s: AuthSession): Promise<MicrosoftStart>; flow(id: string, s: AuthSession): Promise<{ status: FlowStatus }>;
  complete(id: string, s: AuthSession): Promise<{ status: FlowStatus }>; status(): Promise<MicrosoftStatus>;
  disconnect(s: AuthSession): Promise<unknown>; now(): number;
}
export interface MicrosoftViewState { connection: MicrosoftStatus | null; flow: FlowStatus | null; busy: boolean; attempted: boolean; notice: string }
export function validateAuthorize(result: MicrosoftStart, origin: string, now: number): string {
  if (!/^[a-f0-9-]{36}$/i.test(result.flowId) || !Number.isSafeInteger(result.expiresAt) || result.expiresAt <= now || result.expiresAt > now + 300000) throw Error('授权响应无效');
  const u = new URL(result.authorizeUrl);
  if (u.origin !== 'https://login.microsoftonline.com' || u.pathname !== '/consumers/oauth2/v2.0/authorize' || u.username || u.password || u.hash) throw Error('授权地址无效');
  const one = (key: string) => { if (u.searchParams.getAll(key).length !== 1) throw Error('授权响应无效'); return u.searchParams.get(key)!; };
  if (one('response_type') !== 'code' || one('response_mode') !== 'form_post' || one('code_challenge_method') !== 'S256' || !/^[A-Za-z0-9_-]{43}$/.test(one('code_challenge')) || !/^[A-Za-z0-9_-]{43}$/.test(one('state')) || !/^[A-Za-z0-9_-]{43}$/.test(one('nonce'))) throw Error('授权响应无效');
  const redirect = new URL(one('redirect_uri'));
  if (redirect.origin !== origin || redirect.protocol !== 'https:' || !['/api/auth/microsoft/callback', '/uapi/auth/microsoft/callback'].includes(redirect.pathname) || redirect.search || redirect.hash || redirect.username || redirect.password) throw Error('授权回调地址与当前后台不一致');
  if (one('scope').split(' ').sort().join(' ') !== ['https://outlook.office.com/SMTP.Send','offline_access','openid','profile','email'].sort().join(' ')) throw Error('授权权限无效');
  return u.href;
}
/** 原窗口保留原会话；完整换码最多调用一次，未知结果只查状态。 */
export class MicrosoftAuthorization {
  private state: MicrosoftViewState = { connection: null, flow: null, busy: false, attempted: false, notice: '' };
  private listeners = new Set<() => void>();
  private pending: { id: string; expiresAt: number; session: AuthSession } | null = null;
  private popup: AuthPopup | null = null;
  private closed = false;
  private generation = 0;
  private readonly original: AuthSession;
  constructor(private readonly deps: Dependencies, private readonly onProviderRefresh?: ProviderReconciler) { this.original = deps.session(); }
  static browser(onProviderRefresh?: ProviderReconciler) {
    return new MicrosoftAuthorization({ session: captureAuthSession, current: isAuthSessionCurrent,
      popup: () => { const w = window.open('about:blank', '_blank', 'popup,width=560,height=760'); return w ? { close: () => w.close(), navigate: url => w.location.replace(url), source: w } : null; },
      start: microsoftStart, flow: microsoftFlow, complete: microsoftComplete, status: microsoftStatus,
      disconnect: microsoftDisconnect, now: Date.now }, onProviderRefresh);
  }
  subscribe = (fn: () => void) => { this.listeners.add(fn); return () => { this.listeners.delete(fn); }; };
  getSnapshot = () => this.state;
  private set(patch: Partial<MicrosoftViewState>) { this.state = { ...this.state, ...patch }; this.listeners.forEach(fn => fn()); }
  private live(s: AuthSession, g: number) { return !this.closed && this.generation === g && this.deps.current(s); }
  private async reconcile(g: number) {
    if (!this.onProviderRefresh || !this.live(this.original, g)) return;
    try { await this.onProviderRefresh(() => this.live(this.original, g)); }
    catch { if (this.live(this.original, g)) this.set({ notice: 'SMTP 卡片状态读取失败，请刷新授权状态' }); }
  }
  async refresh() {
    if (this.closed || this.state.busy || !this.deps.current(this.original)) return;
    const s = this.original, g = this.generation;
    this.set({ busy: true, notice: '' });
    try {
      const c = await this.deps.status(); if (!this.live(s, g)) return; this.set({ connection: c });
      if (this.pending) {
        const p = this.pending;
        if (!this.deps.current(p.session) || this.deps.now() >= p.expiresAt) { this.set({ flow: 'expired' }); return; }
        const result = await this.deps.flow(p.id, p.session); if (!this.live(s, g)) return;
        // 已尝试兑换但服务器仍显示 received/start，网络是否到达尚不确定，不能补发。
        const uncertain = this.state.attempted && ['received', 'started'].includes(result.status);
        this.set({ flow: uncertain ? 'unknown' : result.status,
          ...(uncertain ? { notice: '兑换结果未确认。只能刷新状态；请勿重复兑换。' } : {}) });
      }
    } catch { if (this.live(s, g)) this.set({ notice: '状态读取失败，请稍后刷新' }); }
    finally { await this.reconcile(g); if (this.live(s, g)) this.set({ busy: false }); }
  }
  async start() {
    if (this.closed || this.state.busy || !this.deps.current(this.original)) return;
    const s = this.original; if (!this.deps.current(s)) return;
    const popup = this.deps.popup(); if (!popup) { this.set({ notice: '请允许此后台打开授权窗口' }); return; }
    this.popup?.close(); this.popup = popup; this.pending = null;
    const g = ++this.generation; this.set({ busy: true, flow: null, attempted: false, notice: '' });
    try {
      const result = await this.deps.start(s);
      if (!this.live(s, g)) { popup.close(); return; }
      const url = validateAuthorize(result, s.origin, this.deps.now());
      this.pending = { id: result.flowId, expiresAt: result.expiresAt, session: s };
      popup.navigate(url); this.set({ flow: 'started', connection: { status: 'not_connected', configured: true, emailHint: null }, notice: '请在授权窗口完成，然后刷新授权状态' });
    } catch { popup.close(); if (this.live(s, g)) this.set({ notice: '授权未发起，请检查已保存配置与后台 HTTPS 回调' }); }
    finally { await this.reconcile(g); if (this.live(s, g)) this.set({ busy: false }); }
  }
  async complete() {
    const p = this.pending; if (!p || this.closed || this.state.busy || this.state.attempted || this.state.flow !== 'received') return;
    if (!this.deps.current(p.session) || this.deps.now() >= p.expiresAt) { this.set({ flow: 'expired' }); return; }
    const g = this.generation; this.set({ attempted: true, busy: true, notice: '' });
    try {
      const result = await this.deps.complete(p.id, p.session);
      if (!this.live(p.session, g)) return;
      this.set({ flow: result.status, notice: result.status === 'connected' ? '已连接。请另行启用服务商；授权不会发送邮件。' : '请刷新状态查看结果' });
      if (result.status === 'connected') { this.popup?.close(); this.set({ connection: { status: 'connected', configured: true, emailHint: null } }); }
    } catch { if (this.live(p.session, g)) this.set({ flow: 'unknown', notice: '兑换结果未确认。只能刷新状态；请勿重复兑换。' }); }
    finally { await this.reconcile(g); if (this.live(p.session, g)) this.set({ busy: false }); }
  }
  async disconnect() {
    if (this.closed || this.state.busy || !this.deps.current(this.original)) return;
    const s = this.original, g = ++this.generation;
    this.pending = null; this.popup?.close(); this.popup = null; this.set({ busy: true, flow: null, notice: '' });
    try { await this.deps.disconnect(s); if (this.live(s, g)) this.set({ connection: { status: 'not_connected', configured: true, emailHint: null }, notice: '已断开本后台连接。微软账号中的授权需自行管理。' }); }
    catch { if (this.live(s, g)) this.set({ notice: '断开结果未确认，请刷新连接状态' }); }
    finally { await this.reconcile(g); if (this.live(s, g)) this.set({ busy: false }); }
  }
  returned(event: { origin: string; source: unknown; data: unknown }) {
    if (this.pending && event.origin === this.pending.session.origin && event.source === this.popup?.source && event.data === 'ms-smtp-returned' && this.deps.current(this.pending.session)) void this.refresh();
  }
  close() { this.closed = true; this.generation++; this.pending = null; this.popup?.close(); this.popup = null; this.listeners.clear(); }
}
