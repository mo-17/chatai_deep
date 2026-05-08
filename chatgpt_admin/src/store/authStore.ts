import { create } from 'zustand';
import { persist, createJSONStorage } from 'zustand/middleware';

interface AuthState {
  token: string | null;
  admin: { id: number; userName: string; avatar?: string } | null;
  setAuth: (token: string, admin: AuthState['admin']) => void;
  logout: () => void;
}

export const useAuthStore = create<AuthState>()(
  persist(
    (set) => ({
      token: null,
      admin: null,
      setAuth: (token, admin) => set({ token, admin }),
      logout: () => set({ token: null, admin: null }),
    }),
    {
      name: 'admin-auth',
      storage: createJSONStorage(() => localStorage),
    },
  ),
);
