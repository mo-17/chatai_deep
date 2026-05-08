import { create } from 'zustand';
import { persist } from 'zustand/middleware';

export const useUiStore = create<{
  sidebarCollapsed: boolean;
  toggleSidebar: () => void;
}>()(
  persist(
    (set) => ({
      sidebarCollapsed: false,
      toggleSidebar: () => set((s) => ({ sidebarCollapsed: !s.sidebarCollapsed })),
    }),
    { name: 'admin-ui' },
  ),
);
