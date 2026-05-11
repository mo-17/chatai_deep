import { nextui } from '@nextui-org/react';
import type { Config } from 'tailwindcss';

const config: Config = {
  content: [
    './src/**/*.{js,ts,jsx,tsx,mdx}',
    // pnpm 把 @nextui-org/theme 锁在 .pnpm 虚拟 store；产物是 .mjs，必须显式扫描
    '../node_modules/.pnpm/@nextui-org+*/node_modules/@nextui-org/**/dist/**/*.{js,mjs}',
  ],
  theme: {
    extend: {},
  },
  darkMode: 'class',
  plugins: [nextui()],
};
export default config;
