import { create } from 'zustand';
import { persist, createJSONStorage } from 'zustand/middleware';

interface AuthState {
  token: string | null;
  admin: { id: number; userName: string; avatar?: string } | null;
  sessionEpoch: number;
  setAuth: (token: string, admin: AuthState['admin']) => void;
  logout: () => void;
}

// 只在内存中标识当前会话；同token重登录/rehydrate也撤销旧云请求。
let epoch = 0;
const nextEpoch = () => ++epoch;

export const useAuthStore = create<AuthState>()(
  persist(
    (set) => ({
      token: null,
      admin: null,
      sessionEpoch: nextEpoch(),
      setAuth: (token, admin) => set({ token, admin, sessionEpoch: nextEpoch() }),
      logout: () => set({ token: null, admin: null, sessionEpoch: nextEpoch() }),
    }),
    {
      name: 'admin-auth',
      storage: createJSONStorage(() => sessionStorage),
      partialize: ({ token, admin }) => ({ token, admin }),
      merge: (persisted, current) => {
        const saved = persisted as Partial<AuthState> | undefined;
        return { ...current, token: saved?.token ?? null, admin: saved?.admin ?? null,
          sessionEpoch: nextEpoch() };
      },
    },
  ),
);
