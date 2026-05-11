// React 19 narrowed `ReactPortal.children` (now required) and `key`
// (string | null instead of Key | null). That breaks the
// `ReactElement → ReactNode` assignability React-18-era UI libraries
// (HeroUI v2) rely on when their components return `JSX.Element`. Relax
// both fields so the union check succeeds again.

import 'react';

declare module 'react' {
  interface ReactPortal {
    children?: ReactNode;
    key: Key | null;
  }
}
