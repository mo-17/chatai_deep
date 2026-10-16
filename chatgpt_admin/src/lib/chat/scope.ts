import { api } from '@/lib/api/client';
import {
  captureAuthSession,
  isAuthSessionCurrent,
  type AuthSession,
} from '@/lib/api/auth-session';
import { useAuthStore } from '@/store/authStore';
import { ChatFailure } from './errors';

export interface ChatScope {
  session: AuthSession;
  ownerId: number;
  apiBase: string;
}
function apiBase() {
  const origin =
    typeof window === 'undefined'
      ? 'http://ssr.invalid'
      : window.location.origin;
  const url = new URL(api.defaults.baseURL || '/api', origin);
  if (
    !['http:', 'https:'].includes(url.protocol) ||
    url.username ||
    url.password
  )
    throw new ChatFailure('scope_changed');
  return url.toString().replace(/\/$/, '');
}
export function captureChatScope(): ChatScope {
  const state = useAuthStore.getState();
  if (
    !state.admin ||
    !Number.isSafeInteger(state.admin.id) ||
    state.admin.id <= 0
  )
    throw new ChatFailure('ownership_unverified');
  try {
    return {
      session: captureAuthSession(),
      ownerId: state.admin.id,
      apiBase: apiBase(),
    };
  } catch {
    throw new ChatFailure('scope_changed');
  }
}
export function chatScopeCurrent(scope: ChatScope): boolean {
  try {
    return (
      isAuthSessionCurrent(scope.session) &&
      useAuthStore.getState().admin?.id === scope.ownerId &&
      apiBase() === scope.apiBase
    );
  } catch {
    return false;
  }
}
export function assertChatScope(scope: ChatScope) {
  if (!chatScopeCurrent(scope)) throw new ChatFailure('scope_changed');
}
export function chatScopeKey(scope: ChatScope): string {
  return JSON.stringify([
    scope.ownerId,
    scope.session.origin,
    scope.session.backendOrigin,
    scope.apiBase,
  ]);
}
export function chatContextSignature(): string {
  try {
    const scope = captureChatScope();
    return JSON.stringify([
      chatScopeKey(scope),
      scope.session.epoch,
      scope.session.token,
    ]);
  } catch {
    return JSON.stringify([
      useAuthStore.getState().sessionEpoch,
      'unavailable',
    ]);
  }
}
