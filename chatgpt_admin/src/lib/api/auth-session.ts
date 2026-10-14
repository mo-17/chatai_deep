import { useAuthStore } from '@/store/authStore';

export interface AuthSession { token: string; epoch: number; origin: string; backendOrigin: string }
export class AuthSessionStale extends Error {
  constructor() { super('会话已变化，请重新打开页面'); }
}
function origins() {
  const origin = typeof window === 'undefined' ? '' : window.location.origin;
  const url = new URL(process.env.NEXT_PUBLIC_BACKEND || 'http://localhost:3000');
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw new AuthSessionStale();
  return { origin, backendOrigin: url.origin };
}
export function captureAuthSession(): AuthSession {
  const state = useAuthStore.getState();
  if (!state.token) throw new AuthSessionStale();
  return { token: state.token, epoch: state.sessionEpoch, ...origins() };
}
export function isAuthSessionCurrent(session: AuthSession): boolean {
  const state = useAuthStore.getState();
  try {
    const current = origins();
    return state.token === session.token && state.sessionEpoch === session.epoch &&
      current.origin === session.origin && current.backendOrigin === session.backendOrigin;
  } catch { return false; }
}
export function assertAuthSession(session: AuthSession) {
  if (!isAuthSessionCurrent(session)) throw new AuthSessionStale();
}
