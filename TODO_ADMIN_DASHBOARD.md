# 后台管理系统（chatgpt_admin）

本文件供另一个模型（DeepSeek v4 Pro）按顺序执行。所有路径相对仓库根目录 `/Users/huangzhibin/AndroidStudioProjects/flutter/chatai_deep/`。

---

## 1. 背景与目标

### 现状
- 仓库已有 `chatgpt_backend/`（NestJS 11 + TypeORM + Postgres）：
  - 实体：`users`（id, userName, password, avatar, imoocId）、`Usage`（id, userId, provider, model, promptTokens, completionTokens, totalTokens, createdAt）
  - 端点：`/uapi/user/{login,registration,register-page}`、`/uapi/notice/banner`（硬编码）、`/uapi/checkUpdate`（硬编码）、`/uapi/chat/completions`（JWT 守卫）
  - JWT 守卫位于 `src/auth/jwt.guard.ts`，secret 为硬编码 `'chatgpt-flutter-secret-key'`
- 客户端只有 Flutter App（`chatgpt_flutter`），运营/客服没有任何可视化管理界面：banner 内容写死在代码里、版本号写死在代码里、无法看到任何用户和用量数据。

### 目标
- 新建独立的 Web 后台管理系统 **`chatgpt_admin/`**（与 `chatgpt_backend/` 同级），提供以下能力：
  1. **管理员登录**（账号密码）
  2. **用户管理**：列表（搜索/分页）、查看详情、封禁/解封、重置密码、删除
  3. **Banner 管理**：CRUD、置顶、上下架
  4. **版本管理**：CRUD（versionName / versionCode / url / description）
  5. **用量统计**：总览（今日 / 本周 / 本月 token 总量）、趋势图（按日折线）、provider 占比（柱状/饼图）、Top 用户（按 token 量）
  6. **用量明细**：分页列表，可按 userId / provider / model / 时间范围筛选，支持导出 CSV
- **后端 API 改造**：为上述 UI 提供 RESTful 端点，将 banner 与版本从硬编码迁移到 DB-backed。

### 技术栈（必须）
| 类别 | 选型 | 用途 |
|-|-|-|
| 框架 | **Next.js 15**（App Router，TypeScript） | 路由、SSR/CSR 混合、API Routes |
| UI 库 | **HeroUI**（即原 NextUI v2 改名） | 组件库，搭配 Tailwind |
| 样式 | **Tailwind CSS 3** | 原子化样式 |
| 数据请求 | **@tanstack/react-query v5** | 服务端状态、缓存、请求管理 |
| 客户端状态 | **Zustand v5** | 全局轻状态（登录态、主题） |
| Hook 工具 | **ahooks v3** | useDebounce、useRequest（仅在 RQ 不合适处用）、useLocalStorageState 等 |
| HTTP | **axios** | 与 RQ 搭配，统一拦截器加 token |
| 表单 | **react-hook-form** + **zod** | 表单校验 |
| 图表 | **recharts** | 折线图、柱状图、饼图 |
| 日期 | **dayjs** | 日期格式化与计算 |
| 图标 | **lucide-react** | 图标库 |

### 不做的事（划清边界）
- ❌ 不做多角色权限矩阵（只区分 admin / 普通 user，不做 RBAC）
- ❌ 不做 i18n（界面用中文）
- ❌ 不做 APK 文件上传（版本管理只录入 URL 字段）
- ❌ 不做计费/订单/支付
- ❌ 不引入 monorepo 工具（pnpm workspace / turborepo）—— `chatgpt_admin/` 独立 npm 项目
- ❌ 不动 Flutter 端任何代码
- ❌ 不动 `chatgpt_backend` 现有的 `/uapi/user/login` `/uapi/user/registration`（App 端在用）；admin 登录走新端点 `/uapi/admin/login`

---

## 2. 架构

### 2.1 部署关系
```
┌──────────────┐   HTTP    ┌──────────────────────┐
│ chatgpt_admin│ ────────▶ │ chatgpt_backend      │
│ (Next.js)    │           │ NestJS @ :3000       │
│ @ :3001      │           │ Postgres @ :5432     │
└──────────────┘           └──────────────────────┘
        ▲
        │
   运营/管理员浏览器
```
- 后台与后端是独立进程；admin 直接调 backend HTTP（同机不同端口），通过 Next.js 的 `next.config.ts` `rewrites` 转发 `/api/*` → `http://localhost:3000/uapi/*`，避免 CORS 与 token 暴露。
- admin 的 Server Components 也可以直接服务端 fetch 后端，但**本任务统一从 client 走 RQ**，简化心智模型。

### 2.2 后端鉴权
- **新增 `role` 字段** 到 `users` 表：`'user' | 'admin'`，默认 `'user'`。
- **新增端点 `POST /uapi/admin/login`**：只有 `role='admin'` 的账户能成功登录，返回的 JWT 包含 `role: 'admin'`。
- **新增 `AdminGuard`**：在 `JwtGuard` 基础上加 role 校验，所有 admin 端点（`/uapi/admin/**`）都套这个 Guard。
- 默认管理员账号通过 NestJS 启动钩子（`OnApplicationBootstrap`）seed：若 `users` 表中无 `role='admin'` 的记录，则插入一条 `userName=admin, password=admin123, role=admin`，并打印一条 warning 提示首次登录后立即修改密码。

### 2.3 后端新端点清单（全部前缀 `/uapi/admin`，全部走 `AdminGuard`）

| 方法 | 路径 | 说明 |
|-|-|-|
| POST | `/login` | （**不**走 AdminGuard）admin 登录 |
| GET  | `/me` | 当前登录管理员信息 |
| GET  | `/users` | 用户列表，query：`keyword, page, pageSize, role, banned` |
| GET  | `/users/:id` | 用户详情 |
| PATCH | `/users/:id` | 编辑（avatar / role / banned） |
| POST | `/users/:id/reset-password` | 重置密码（body: `{ password }`） |
| DELETE | `/users/:id` | 删除用户（同时清理 usage） |
| GET / POST | `/banners` | 列表、新增 |
| GET / PATCH / DELETE | `/banners/:id` | 详情、编辑、删除 |
| GET / POST | `/versions` | 列表、新增 |
| GET / PATCH / DELETE | `/versions/:id` | 详情、编辑、删除 |
| GET | `/usage/list` | 用量明细，query：`userId, provider, model, from, to, page, pageSize` |
| GET | `/usage/summary` | 概览数据（今日/本周/本月聚合） |
| GET | `/usage/series` | 按日 token 趋势，query：`from, to`（默认近 30 天） |
| GET | `/usage/by-provider` | 按 provider 聚合 token |
| GET | `/usage/top-users` | Top N 用户，query：`limit=10, days=7` |
| GET | `/usage/export` | 导出 CSV（同 list 的筛选参数） |

**统一返回格式**（与现有保持一致）：
```ts
// 成功
{ code: 0, data: <payload> }
// 失败
{ code: <非0>, message: '...' }
```
列表接口 payload 结构：
```ts
{ list: T[], total: number, page: number, pageSize: number }
```

### 2.4 前端目录结构（chatgpt_admin/）
```
chatgpt_admin/
├─ src/
│  ├─ app/                         # Next.js App Router
│  │  ├─ layout.tsx                # 根 layout（HeroUIProvider + RQ Provider + Zustand 注入）
│  │  ├─ page.tsx                  # 重定向到 /dashboard 或 /login
│  │  ├─ login/page.tsx
│  │  ├─ (dashboard)/              # 受保护路由组，套 SidebarLayout
│  │  │  ├─ layout.tsx             # 校验登录态 + 侧边栏
│  │  │  ├─ dashboard/page.tsx     # 总览
│  │  │  ├─ users/
│  │  │  │  ├─ page.tsx            # 用户列表
│  │  │  │  └─ [id]/page.tsx       # 用户详情
│  │  │  ├─ banners/page.tsx
│  │  │  ├─ versions/page.tsx
│  │  │  ├─ usage/page.tsx         # 明细列表
│  │  │  └─ settings/page.tsx      # 个人信息修改密码
│  ├─ components/
│  │  ├─ layout/Sidebar.tsx
│  │  ├─ layout/Topbar.tsx
│  │  ├─ common/DataTable.tsx      # HeroUI Table 封装
│  │  ├─ common/ConfirmDialog.tsx
│  │  ├─ common/PageHeader.tsx
│  │  ├─ charts/UsageLineChart.tsx
│  │  ├─ charts/ProviderBarChart.tsx
│  │  └─ charts/TopUsersList.tsx
│  ├─ lib/
│  │  ├─ api/client.ts             # axios 实例 + 拦截器
│  │  ├─ api/user.ts
│  │  ├─ api/banner.ts
│  │  ├─ api/version.ts
│  │  ├─ api/usage.ts
│  │  ├─ api/auth.ts
│  │  ├─ providers.tsx             # RQ + HeroUI Provider 组合
│  │  └─ utils/format.ts           # 数字/日期/字节格式化
│  ├─ hooks/
│  │  ├─ useUsers.ts               # 包装 useQuery / useMutation
│  │  ├─ useBanners.ts
│  │  ├─ useVersions.ts
│  │  └─ useUsage.ts
│  ├─ store/
│  │  ├─ authStore.ts              # zustand：token、当前管理员
│  │  └─ uiStore.ts                # zustand：侧边栏折叠状态、主题
│  ├─ schemas/                     # zod schemas
│  │  ├─ user.ts
│  │  ├─ banner.ts
│  │  └─ version.ts
│  └─ types/
│     ├─ api.ts                    # ApiResp<T>、Paged<T>
│     └─ entities.ts
├─ public/
├─ tailwind.config.ts
├─ next.config.ts
├─ tsconfig.json
├─ package.json
└─ README.md
```

### 2.5 核心约定

#### Axios 拦截器（`lib/api/client.ts`）
```ts
import axios from 'axios';
import { useAuthStore } from '@/store/authStore';

export const api = axios.create({
  baseURL: '/api',          // 由 Next rewrites 转发到 backend
  timeout: 15000,
});

api.interceptors.request.use((config) => {
  const token = useAuthStore.getState().token;
  if (token) config.headers.Authorization = `Bearer ${token}`;
  return config;
});

api.interceptors.response.use(
  (res) => {
    const body = res.data;
    if (body && typeof body === 'object' && 'code' in body) {
      if (body.code === 0) return { ...res, data: body.data };
      // 401 单独处理（也可能是 HTTP 401）
      throw new Error(body.message || '请求失败');
    }
    return res;
  },
  (err) => {
    if (err.response?.status === 401) {
      useAuthStore.getState().logout();
      if (typeof window !== 'undefined') window.location.href = '/login';
    }
    const msg = err.response?.data?.message || err.message || '网络错误';
    return Promise.reject(new Error(msg));
  },
);
```

#### Next.js rewrites（`next.config.ts`）
```ts
const nextConfig = {
  async rewrites() {
    const backend = process.env.NEXT_PUBLIC_BACKEND || 'http://localhost:3000';
    return [{ source: '/api/:path*', destination: `${backend}/uapi/:path*` }];
  },
};
export default nextConfig;
```

#### Zustand auth store（`store/authStore.ts`）
```ts
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
    { name: 'admin-auth', storage: createJSONStorage(() => localStorage) },
  ),
);
```
> **注意**：persist 的 `storage` 只在 client 可用，根 layout 必须用 `'use client'` 把 Provider 包出去；server component 不直接读 store。

#### React Query Provider（`lib/providers.tsx`）
```tsx
'use client';
import { HeroUIProvider } from '@heroui/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { useState } from 'react';

export function Providers({ children }: { children: React.ReactNode }) {
  const [client] = useState(
    () => new QueryClient({
      defaultOptions: {
        queries: { staleTime: 30_000, retry: 1, refetchOnWindowFocus: false },
      },
    }),
  );
  return (
    <QueryClientProvider client={client}>
      <HeroUIProvider>{children}</HeroUIProvider>
    </QueryClientProvider>
  );
}
```

#### 受保护路由组（`app/(dashboard)/layout.tsx`）
```tsx
'use client';
import { useAuthStore } from '@/store/authStore';
import { useRouter } from 'next/navigation';
import { useEffect } from 'react';
import { Sidebar } from '@/components/layout/Sidebar';
import { Topbar } from '@/components/layout/Topbar';

export default function DashboardLayout({ children }: { children: React.ReactNode }) {
  const token = useAuthStore((s) => s.token);
  const router = useRouter();

  useEffect(() => {
    if (!token) router.replace('/login');
  }, [token, router]);

  if (!token) return null;

  return (
    <div className="flex h-screen bg-default-50">
      <Sidebar />
      <div className="flex-1 flex flex-col overflow-hidden">
        <Topbar />
        <main className="flex-1 overflow-auto p-6">{children}</main>
      </div>
    </div>
  );
}
```

---

## 3. 任务列表

### 后端任务

#### 任务 B1：User 实体加 role/banned 字段 + admin seed

**改动文件**：
- `chatgpt_backend/src/user/user.entity.ts`
- `chatgpt_backend/src/user/user.module.ts`（新增 seed service）
- `chatgpt_backend/src/user/user.service.ts`（封禁判断）

**步骤**：

1. `user.entity.ts` 增加：
   ```ts
   @Column({ default: 'user' })
   role: string;          // 'user' | 'admin'

   @Column({ default: false })
   banned: boolean;
   ```
   `synchronize: true` 会自动加列。

2. `user.service.ts` 的 `login()` 增加封禁判断：用户存在但 `banned=true` 时返回 `BadRequestException('账号已被封禁')`。

3. 在 `user.module.ts` 增加一个 `UserSeedService implements OnApplicationBootstrap`：启动时若无 `role='admin'` 的用户，插入默认 admin（`userName=admin`, password 用 bcrypt 哈希 `admin123`），并 `console.warn('[seed] 默认管理员 admin/admin123 已创建，请尽快登录修改密码')`。

**验收**：`npm run start:dev` 启动后日志出现 seed 提示；连 DB 看到 `users` 表有 admin 行；普通账号登录无影响。

---

#### 任务 B2：Banner 与 Version 改成 DB-backed

**新增文件**：
- `chatgpt_backend/src/notice/banner.entity.ts`
- `chatgpt_backend/src/update/version.entity.ts`

**改动文件**：
- `chatgpt_backend/src/notice/notice.module.ts`、`notice.service.ts`
- `chatgpt_backend/src/update/update.module.ts`、`update.service.ts`
- `chatgpt_backend/src/app.module.ts`（注册新 entity）

##### B2.1 `banner.entity.ts`
```ts
@Entity('banners')
export class Banner {
  @PrimaryGeneratedColumn() id: number;
  @Column() title: string;
  @Column({ nullable: true }) subtitle: string;
  @Column({ nullable: true }) cover: string;
  @Column({ nullable: true }) url: string;
  @Column({ default: 0 }) sticky: number;        // 0 不置顶；非 0 越大越靠前
  @Column({ default: true }) enabled: boolean;   // 上下架
  @Column({ default: 'banner' }) type: string;
  @CreateDateColumn() createTime: Date;
  @UpdateDateColumn() updateTime: Date;
}
```

##### B2.2 `version.entity.ts`
```ts
@Entity('app_versions')
export class AppVersion {
  @PrimaryGeneratedColumn() id: number;
  @Column() versionName: string;     // '1.2.0'
  @Column() versionCode: number;     // 12
  @Column({ nullable: true }) url: string;
  @Column({ type: 'text', nullable: true }) description: string;
  @Column({ default: 'all' }) cid: string;       // 渠道
  @Column({ default: false }) forceUpdate: boolean;
  @Column({ default: true }) enabled: boolean;
  @CreateDateColumn() createTime: Date;
  @UpdateDateColumn() updateTime: Date;
}
```

##### B2.3 `notice.service.ts`：原 `getBanners()` 改为读 `banners` 表（`enabled=true` + `ORDER BY sticky DESC, createTime DESC`），并补充 `pageIndex/pageSize` 分页能力。返回结构保持现有 `{ code:0, data:{ list:[...] } }`，避免 App 端兼容问题。

##### B2.4 `update.service.ts`：原 `checkUpdate()` 改为按 `cid` 取最新一条 `enabled=true` 的版本（`ORDER BY versionCode DESC`），若高于客户端 version 才返回；否则返回原「当前已是最新版本」结构。注意保留 `code:0` + 原字段名。

**验收**：手动用 SQL 插一条 banner，访问 `GET /uapi/notice/banner` 能看到。

---

#### 任务 B3：Admin 鉴权（登录端点 + Guard）

**新增文件**：
- `chatgpt_backend/src/auth/admin.guard.ts`
- `chatgpt_backend/src/admin/admin.module.ts`
- `chatgpt_backend/src/admin/admin-auth.controller.ts`

**步骤**：

1. `admin.guard.ts`：复用 `JwtGuard` 的 token 校验逻辑（或继承），额外检查 payload 的 `role === 'admin'`，否则抛 `ForbiddenException('需要管理员权限')`。
   ```ts
   const payload = jwt.verify(token, JWT_SECRET) as { userId: number; userName: string; role?: string };
   if (payload.role !== 'admin') throw new ForbiddenException('需要管理员权限');
   request.user = payload;
   ```
   将 `JwtPayload` 接口同步增加 `role?: string`。

2. `admin-auth.controller.ts` 提供两个端点：
   - `POST /uapi/admin/login`（**不**套 AdminGuard）：参数 `{ userName, password }`；查到用户后必须 `role='admin'` 且 `banned=false`，签 JWT 时把 `role` 一起塞进 payload。
   - `GET /uapi/admin/me`（套 AdminGuard）：返回当前 admin 的 `id, userName, avatar`。
   - `POST /uapi/admin/change-password`（套 AdminGuard）：参数 `{ oldPassword, newPassword }`，校验旧密码后 bcrypt 更新。

3. `user.service.ts` 的现有 `login()` 注意：登录成功签 token 时也把 `role` 加进 payload（不影响 App 端旧逻辑，App 不读 role）；这样 `JwtGuard` 不会把普通用户当 admin。

**验收**：用 curl 登录 admin 拿 token，访问 `/uapi/admin/me` 返回成功；用普通用户 token 访问同一端点返 403。

---

#### 任务 B4：Admin CRUD 控制器

**新增目录**：`chatgpt_backend/src/admin/`
- `admin-user.controller.ts` + `admin-user.service.ts`
- `admin-banner.controller.ts` + `admin-banner.service.ts`
- `admin-version.controller.ts` + `admin-version.service.ts`
- `admin-usage.controller.ts` + `admin-usage.service.ts`

> 全部控制器在 class 级套 `@UseGuards(AdminGuard)`。

##### B4.1 用户管理（`admin-user.*`）

实现 2.3 表中 `/users*` 全部端点。要点：
- 列表：`keyword` 模糊匹配 `userName`；分页用 TypeORM 的 `findAndCount` + `take/skip`。
- 编辑：白名单字段 `avatar, role, banned`，禁止改 password / userName / id。
- 重置密码：`bcrypt.hash(newPwd, 10)`，写回。
- 删除：先删该 userId 的 `Usage` 记录再删 user（事务包裹）。
- **响应里不返回 `password` 字段**：用 `select` 显式排除，或在 service 层 `delete u.password`。

##### B4.2 Banner 管理（`admin-banner.*`）
普通 CRUD，按 2.3 表实现。新增/编辑用 `class-validator` DTO 校验非空与最大长度（title ≤ 80, subtitle ≤ 200, cover/url 必须 URL 格式）。

##### B4.3 Version 管理（`admin-version.*`）
普通 CRUD，按 2.3 表实现。`versionCode` 必须为正整数；`versionName` 形如 `x.y.z`（用 regex 校验，不严格 semver）。

##### B4.4 用量统计与明细（`admin-usage.*`）

**`GET /usage/list`**：分页 + 多条件筛选；返回 join `users` 后的 `{ id, userId, userName, provider, model, promptTokens, completionTokens, totalTokens, createdAt }`。

**`GET /usage/summary`**：返回
```ts
{
  today:    { tokens: number; calls: number };
  week:     { tokens: number; calls: number };
  month:    { tokens: number; calls: number };
  all:      { tokens: number; calls: number };
  userCount: number;            // 总用户数
  activeToday: number;          // 今日有调用的不同 userId 数
}
```
用一条 SQL（CASE WHEN）一次拉齐，不要发 5 次查询。

**`GET /usage/series`**：返回
```ts
{ list: Array<{ date: string; tokens: number; calls: number }> }   // date: 'YYYY-MM-DD'
```
默认近 30 天；用 `DATE(createdAt)` GROUP BY；缺失的日期补零（service 层补，避免前端处理）。

**`GET /usage/by-provider`**：返回
```ts
{ list: Array<{ provider: string; tokens: number; calls: number }> }
```

**`GET /usage/top-users`**：返回
```ts
{ list: Array<{ userId: number; userName: string; tokens: number; calls: number }> }
```
JOIN users 表拿到 userName。

**`GET /usage/export`**：响应 `Content-Type: text/csv; charset=utf-8`，文件名 `usage-YYYYMMDD-HHmmss.csv`，列：`id,userId,userName,provider,model,promptTokens,completionTokens,totalTokens,createdAt`。**注意**：CSV 头加 BOM `﻿` 防止 Excel 中文乱码。导出不分页，但要在 service 层加 `LIMIT 100000` 防爆。

**验收**：用 admin token 调每个端点，至少能拿到正确结构（即使数据为空时 list:[] 也算通过）。

---

#### 任务 B5：注册 admin 模块 + .env.example 更新

**改 `app.module.ts`**：注册 `AdminModule`，引入 Banner / AppVersion / Usage / User 的 TypeOrmModule.forFeature。

**新增文件**：`chatgpt_backend/.env.example` 已有，**追加**：
```
JWT_SECRET=chatgpt-flutter-secret-key
ADMIN_DEFAULT_USERNAME=admin
ADMIN_DEFAULT_PASSWORD=admin123
```
（seed service 优先读 env，未设则用兜底默认值。）

**`chatgpt_backend/README.md`**：
- 新增「管理后台 API」一节，列出 `/uapi/admin/*` 端点表
- 新增「默认管理员」说明：首次启动控制台输出 admin/admin123，**正式环境必须改 env**

**验收**：`npm run lint`、`npm run start:dev` 都成功；冷启 DB（删表后重启）能自动建表 + seed admin。

---

### 前端任务

> 前端任务**全部在 `chatgpt_admin/` 目录**进行。所有路径下文相对于 `chatgpt_admin/`。

#### 任务 F1：项目初始化

```bash
cd /Users/huangzhibin/AndroidStudioProjects/flutter/chatai_deep
npx create-next-app@latest chatgpt_admin --typescript --tailwind --eslint --app --src-dir --import-alias '@/*' --turbopack --no-git
cd chatgpt_admin
npm install @heroui/react framer-motion @tanstack/react-query @tanstack/react-query-devtools \
  zustand axios ahooks react-hook-form @hookform/resolvers zod \
  recharts dayjs lucide-react clsx
npm install -D @types/node
```

**配置 Tailwind 兼容 HeroUI**（`tailwind.config.ts`）：
```ts
import { heroui } from '@heroui/react';
import type { Config } from 'tailwindcss';

const config: Config = {
  content: [
    './src/**/*.{js,ts,jsx,tsx,mdx}',
    './node_modules/@heroui/theme/dist/**/*.{js,ts,jsx,tsx}',
  ],
  theme: {
    extend: {},
  },
  darkMode: 'class',
  plugins: [heroui()],
};
export default config;
```

**配置 `next.config.ts`**：见 2.5 节。

**新增 `.env.local.example`**：
```
NEXT_PUBLIC_BACKEND=http://localhost:3000
```

**改 `package.json` scripts**：默认 `dev` 改成 `next dev -p 3001`（避免与 backend 抢 3000）。

**验收**：`npm run dev` 起在 3001，首页能看到 Next 默认页面（暂未做页面）。

---

#### 任务 F2：基础设施

##### F2.1 类型与 API 客户端

`src/types/api.ts`：
```ts
export interface ApiResp<T> { code: number; data: T; message?: string }
export interface Paged<T> { list: T[]; total: number; page: number; pageSize: number }
```

`src/types/entities.ts`：
```ts
export interface AdminUser { id: number; userName: string; avatar?: string }
export interface AppUser {
  id: number; userName: string; avatar?: string; imoocId?: string;
  role: 'user' | 'admin'; banned: boolean;
}
export interface Banner {
  id: number; title: string; subtitle?: string; cover?: string; url?: string;
  sticky: number; enabled: boolean; type: string; createTime: string; updateTime: string;
}
export interface AppVersion {
  id: number; versionName: string; versionCode: number; url?: string; description?: string;
  cid: string; forceUpdate: boolean; enabled: boolean; createTime: string; updateTime: string;
}
export interface UsageRecord {
  id: number; userId: number; userName: string;
  provider: string; model: string;
  promptTokens: number; completionTokens: number; totalTokens: number;
  createdAt: string;
}
export interface UsageSummary {
  today: { tokens: number; calls: number };
  week:  { tokens: number; calls: number };
  month: { tokens: number; calls: number };
  all:   { tokens: number; calls: number };
  userCount: number;
  activeToday: number;
}
```

`src/lib/api/client.ts`：见 2.5 节。

`src/lib/api/auth.ts`：
```ts
import { api } from './client';
import { AdminUser } from '@/types/entities';

export const authApi = {
  login: (userName: string, password: string) =>
    api.post<{ token: string; admin: AdminUser }>('/admin/login', { userName, password })
       .then(r => r.data),
  me: () => api.get<AdminUser>('/admin/me').then(r => r.data),
  changePassword: (oldPassword: string, newPassword: string) =>
    api.post('/admin/change-password', { oldPassword, newPassword }),
};
```
> **注意 backend 实际返回**：`{ code:0, data: <token string>, extra: { userName, avatar, ... } }`。前端 `auth.ts` 的 login 函数要把这两段拼成 `{ token, admin }`。具体做法：在 axios 响应拦截器层级保留 `extra`，或在 `auth.login` 里 `r.data`（=后端 data，即 token）+ 二次取 extra。**最简方案**：让后端 `/uapi/admin/login` 直接返 `{ token, admin: { id, userName, avatar } }` 作为 `data`，对齐前端期望，不沿用 `extra`。**这是 B3 任务的隐含要求，请同步实现**。

类似地实现 `user.ts / banner.ts / version.ts / usage.ts`，每个文件导出一个对象包含该模块所有方法。

##### F2.2 Zustand stores

`src/store/authStore.ts`：见 2.5 节。

`src/store/uiStore.ts`：
```ts
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
```

##### F2.3 Providers

`src/lib/providers.tsx`：见 2.5 节。在 `app/layout.tsx` 包一层：
```tsx
import './globals.css';
import { Providers } from '@/lib/providers';

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="zh-CN" className="light">
      <body><Providers>{children}</Providers></body>
    </html>
  );
}
```

##### F2.4 工具函数 `lib/utils/format.ts`
```ts
import dayjs from 'dayjs';

export const fmtDate = (s: string) => dayjs(s).format('YYYY-MM-DD HH:mm');
export const fmtNum = (n: number) => n.toLocaleString('zh-CN');
export const fmtTokens = (n: number) =>
  n >= 1e6 ? (n / 1e6).toFixed(2) + 'M' :
  n >= 1e3 ? (n / 1e3).toFixed(2) + 'K' : String(n);
```

**验收**：项目能 build 不报错（`npm run build`）。

---

#### 任务 F3：登录页 `app/login/page.tsx`

UI：居中卡片，HeroUI `Card` + `Input` + `Button`；`react-hook-form` + zod 校验。

```tsx
'use client';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { Card, CardBody, CardHeader, Input, Button } from '@heroui/react';
import { useMutation } from '@tanstack/react-query';
import { authApi } from '@/lib/api/auth';
import { useAuthStore } from '@/store/authStore';
import { useRouter } from 'next/navigation';

const schema = z.object({
  userName: z.string().min(1, '请输入账号'),
  password: z.string().min(1, '请输入密码'),
});
type FormData = z.infer<typeof schema>;

export default function LoginPage() {
  const router = useRouter();
  const setAuth = useAuthStore((s) => s.setAuth);
  const { register, handleSubmit, formState: { errors } } = useForm<FormData>({
    resolver: zodResolver(schema),
  });
  const { mutate, isPending, error } = useMutation({
    mutationFn: ({ userName, password }: FormData) => authApi.login(userName, password),
    onSuccess: (res) => {
      setAuth(res.token, res.admin);
      router.replace('/dashboard');
    },
  });

  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-blue-50 to-purple-50">
      <Card className="w-[400px] p-2">
        <CardHeader className="flex-col items-start">
          <h1 className="text-2xl font-bold">ChatGPT Admin</h1>
          <p className="text-sm text-default-500">后台管理系统</p>
        </CardHeader>
        <CardBody>
          <form onSubmit={handleSubmit((d) => mutate(d))} className="space-y-4">
            <Input label="账号" {...register('userName')}
                   isInvalid={!!errors.userName} errorMessage={errors.userName?.message}/>
            <Input label="密码" type="password" {...register('password')}
                   isInvalid={!!errors.password} errorMessage={errors.password?.message}/>
            {error && <p className="text-danger text-sm">{(error as Error).message}</p>}
            <Button type="submit" color="primary" className="w-full" isLoading={isPending}>登录</Button>
          </form>
        </CardBody>
      </Card>
    </div>
  );
}
```

**验收**：用 admin/admin123 登录成功后跳转 `/dashboard`；账号错时显示后端返回的错误消息。

---

#### 任务 F4：侧边栏布局

`components/layout/Sidebar.tsx`：
- 顶部 Logo
- 菜单：Dashboard / 用户 / Banner / 版本 / 用量明细 / 设置
- 底部当前管理员卡片 + 退出按钮
- 折叠按钮（基于 `useUiStore`，折叠后只显示 icon）
- 当前路由高亮（`usePathname()`）

`components/layout/Topbar.tsx`：
- 左侧面包屑（基于 pathname 简单生成）
- 右侧管理员头像 + 下拉（修改密码 / 退出）

`app/(dashboard)/layout.tsx`：见 2.5 节。

**验收**：登录后能看到完整布局；点菜单切换页面时高亮正确；折叠按钮工作。

---

#### 任务 F5：Dashboard 总览页

`app/(dashboard)/dashboard/page.tsx`：

布局（响应式 grid）：
```
┌─────────────────────────────────────────┐
│  4 个 KPI 卡片（今日 / 本周 / 本月 / 全部 token）│
├──────────────────────┬──────────────────┤
│  折线图：近 30 天 token │  柱状图：provider 分布 │
│                      │                   │
├──────────────────────┴──────────────────┤
│  Top 10 用户榜（近 7 天）                  │
└─────────────────────────────────────────┘
```

实现要点：
- 三个独立的 `useQuery`：`['usage', 'summary']`、`['usage', 'series', 30]`、`['usage', 'by-provider']`、`['usage', 'top-users', 7, 10]`
- KPI 卡用 HeroUI `Card`，左侧大数（用 `fmtTokens`），右下角小字「调用次数：xxx」
- 折线图：`recharts` `<LineChart>` 带 `<XAxis>` `<YAxis>` `<Tooltip>` `<CartesianGrid>`
- 柱状图：`<BarChart>`
- Top 用户榜：HeroUI `Listbox` 或简单列表（头像 + userName + tokens）
- 加载态用 `<Skeleton>`

**验收**：admin token 下打开页面，4 个区块都有数据展示（即使 0 也不崩）；切换日期/30 天后图表能更新。

---

#### 任务 F6：用户管理

##### F6.1 列表页 `app/(dashboard)/users/page.tsx`
- 顶部：`PageHeader` 含「用户管理」标题
- 工具栏：搜索框（`useDebounce` from ahooks 防抖 400ms）、role 筛选 Select、是否封禁 Select、分页大小
- HeroUI `Table` 列：ID / 头像 / userName / role / 状态（Chip 显示「正常」/「已封禁」）/ 操作
- 操作列：「查看」「重置密码」「封禁/解封」「删除」
- 分页：HeroUI `Pagination`
- URL 参数同步：keyword、page、pageSize 写到 URL（`useSearchParams`），刷新后保持

操作交互：
- 重置密码：`Modal` 弹窗，输入新密码，提交后 mutate；成功 `addToast`
- 封禁/解封：直接 `Confirm` 后 PATCH `banned`
- 删除：`ConfirmDialog` 二次确认，强提示「将同时删除该用户的全部用量记录」

##### F6.2 详情页 `app/(dashboard)/users/[id]/page.tsx`
- 左侧用户基本信息卡（头像 / userName / role / 状态 / 创建时间）
- 右侧该用户的用量小图（近 30 天）
- 下方该用户用量明细表（分页）

**验收**：用普通用户账号注册一个，admin 进列表能搜到、能改 banned；改完 App 端用该账号登录被拒。

---

#### 任务 F7：Banner & 版本管理

两页结构相同（CRUD 表 + 弹窗表单），合并到一个章节。

##### F7.1 `app/(dashboard)/banners/page.tsx`
- Table 列：封面缩略图 / title / subtitle / sticky / enabled / 创建时间 / 操作
- 顶部「新建 Banner」按钮 → 弹 `Modal` 含表单（title 必填、subtitle、cover URL、url、sticky 数字、enabled Switch）
- 编辑：同弹窗复用，传入初始值
- 删除：二次确认
- 表单 schema 用 zod，cover/url 字段 `.url().or(z.literal(''))`（允许空）

##### F7.2 `app/(dashboard)/versions/page.tsx`
- Table 列：versionName / versionCode / cid / forceUpdate / enabled / 创建时间 / 操作
- 表单：versionName（regex 校验 `^\d+\.\d+\.\d+$`）、versionCode（正整数）、url、description（`Textarea`）、cid、forceUpdate、enabled

**验收**：新建一条 banner 后，查询 `GET /uapi/notice/banner` 能看到；新建一条版本码大于客户端的版本，App 端调 `/uapi/checkUpdate` 能拿到新版本。

---

#### 任务 F8：用量明细 + 设置页

##### F8.1 `app/(dashboard)/usage/page.tsx`
- 工具栏：用户搜索（自动补全可选，先用普通输入）、provider Select（openai/deepseek/all）、model 输入、日期范围 `DateRangePicker`、`[导出 CSV]` 按钮
- Table：id / userName / provider / model / prompt / completion / total / createdAt
- 分页同 F6
- 导出：直接 `window.open('/api/admin/usage/export?...')`，带上当前 token（这条比较坑：浏览器直接 GET 不会自动加 axios 拦截的 Authorization 头。**解决方案**：用 `fetch('/api/admin/usage/export', { headers: { Authorization: 'Bearer ' + token } })` 后 `blob()` → `URL.createObjectURL` → 触发下载链接点击 → revokeObjectURL）

##### F8.2 `app/(dashboard)/settings/page.tsx`
- 修改密码表单（旧密码 / 新密码 / 确认新密码）
- 调 `/uapi/admin/change-password`，成功后 toast + logout 跳回登录

**验收**：用量明细筛选能正常工作；导出的 CSV 用 Excel 打开中文不乱码；改密码后再用旧密码登录失败、新密码成功。

---

## 4. 执行顺序

按下面顺序执行；每个任务做完跑相应测试：

1. **B1** User schema + admin seed —— `npm run start:dev` 看到 seed 日志
2. **B3** AdminGuard + admin login —— curl 验证
3. **B2** Banner / Version 改 DB-backed —— curl `/uapi/notice/banner` 验证
4. **B4** Admin CRUD 控制器 —— 全部端点 curl 验证（建议写一个 `curl-smoke.sh`）
5. **B5** 模块注册 + .env / README 收尾
6. **F1** Next.js 项目初始化 —— `npm run dev` 起 3001
7. **F2** 类型 / API 客户端 / store / providers
8. **F3** 登录页 —— 用 admin/admin123 登录成功
9. **F4** 布局 —— 路由保护 + 侧边栏
10. **F5** Dashboard
11. **F6** 用户管理
12. **F7** Banner + 版本
13. **F8** 用量 + 设置

**关键检查点**：每完成一个前端 page，跑 `npm run build` 确保 SSR 不报错（client 组件标注是否完整、`use client` 边界是否正确）。

---

## 5. 验收清单

### 5.1 端到端登录链路
- 后端冷启自动 seed admin
- 前端登录页输入 admin/admin123 能进入 Dashboard
- 错密码显示后端错误消息（不是 "Network Error"）
- 登出后访问 `/dashboard` 自动重定向到 `/login`
- 拿普通用户的 JWT 调 `/uapi/admin/me` 返 403

### 5.2 用户管理
- 至少能看到 admin 自己 + 1 个普通账号
- 搜索 keyword 防抖生效（不会按一下就请求）
- 封禁某用户后，App 端用该账号登录返回「账号已被封禁」
- 重置密码后旧密码登录失败、新密码成功
- 删除用户后该用户的 usage 记录被一并清掉（直接 SQL 验证）

### 5.3 Banner / 版本
- 新建 banner 后 `/uapi/notice/banner` 能看到，且 sticky 排序正确
- enabled=false 的 banner 不出现在 App 端接口
- 新建一个 versionCode 高于客户端的版本，`/uapi/checkUpdate?version=低版本号` 返回新版本信息
- 列表 / 编辑 / 删除全部走通

### 5.4 用量统计
- Dashboard KPI 与 SQL 直接 count 的结果一致
- 折线图近 30 天数据连续（缺数据日期补零）
- provider 柱图条目正确
- Top 用户榜按 token 降序

### 5.5 用量明细 + 导出
- 各筛选条件单独/组合都生效
- 翻页正确
- 导出 CSV 用 Excel 打开**中文不乱码**（验证 BOM 写入正确）
- 导出文件包含当前筛选范围内的数据

### 5.6 设置 / 修改密码
- 旧密码错时返错误
- 改密成功后强制重新登录

### 5.7 通用稳定性
- `chatgpt_admin` 全部页面 `npm run build` 通过
- `chatgpt_backend` `npm run lint && npm test` 通过
- 杀掉 backend 后前端任意页面能展示「网络错误」而不是白屏卡死

---

## 6. 风险与注意事项

- **JWT secret 仍硬编码**：`'chatgpt-flutter-secret-key'` 散落在 `user.service.ts`、`jwt.guard.ts`、新加的 `admin.guard.ts`、`admin-auth.controller.ts` 多处。本任务**必须统一抽到一个常量文件** `src/auth/jwt.const.ts`：`export const JWT_SECRET = process.env.JWT_SECRET || 'chatgpt-flutter-secret-key';`，所有调用处改用此常量。这是**比较小的范围扩张**，必做。
- **role 同步进 token**：`user.service.ts` 现有 `login()` 在签 JWT 时**必须**把 role 加进 payload，否则 `AdminGuard` 校验会失败（payload 里没 role）。为旧端点签的 token 不影响 App 端使用，App 端不读 role。
- **JWT 永不过期**：现有 `jwt.sign` 没设 `expiresIn`。本任务**不修复**这个问题（修了会让所有 App 端用户被踢，超出范围）；仅在新建的 admin token 上加 `expiresIn: '7d'`，避免 admin 凭据无限期有效。
- **`synchronize: true`**：Postgres 会按实体自动加列；首次启动 B1 时新增的 `role/banned` 字段会落到 users 表。已存在的用户行 role 默认 `'user'`、banned 默认 `false`，符合预期。**不要**在生产用 `synchronize: true`，但本仓库是课程项目，沿用现状。
- **HeroUI 是 NextUI 改名**：包名是 `@heroui/react`，文档在 heroui.com。Tailwind 必须把 `node_modules/@heroui/theme/dist/**` 加到 content。否则样式不出。
- **ahooks 的 useRequest 与 React Query 重叠**：本任务里**优先用 React Query**（缓存与失效更标准）。ahooks 仅用于 useDebounce / useLocalStorageState / useToggle 等纯前端工具 hook。不要两套并存写同一份数据请求逻辑。
- **Zustand persist + Next SSR 水合警告**：根 layout 用 server component（默认），但 `Providers` 必须 `'use client'`；`useAuthStore` 在 server 组件里**不要直接读**。受保护路由组的 layout 用 `'use client'` + `useEffect` 做重定向，符合 2.5 节示例。
- **CSV 导出的 Authorization 头**：浏览器 `<a download>` 不会带 axios 拦截器加的 token，必须用 fetch + blob 方案。详见 F8。
- **Next dev port 3001**：避免与 backend 3000 冲突；如端口被占用则提示用户手动改 `package.json` 的 dev 脚本。
- **DTO 校验**：所有写入端点必须用 `class-validator` DTO，`main.ts` 里启用全局 `app.useGlobalPipes(new ValidationPipe({ whitelist: true, transform: true }))`，否则前端的 zod 校验绕过后会有脏数据落库。
- **不要在 admin 端再封一层 backend BFF**：admin 直连 NestJS 后端，rewrites 仅用于路径前缀转发。增加 BFF 会让本任务失控。
- **测试连接**：本任务无单元测试要求，但 `chatgpt_backend/test/` 下现有的 e2e 不要改坏（`npm run test:e2e` 至少不报「找不到模块」级别的错误；具体断言会因新端点变化暂时不强制通过）。

---

## 7. 完成后输出

请在执行结束时给出一份摘要报告，包含：
- 每个任务（B1–B5、F1–F8）的状态（done / partial / blocked）
- 新增 / 修改的文件清单（按 backend / admin 分组）
- 验收清单 5.1–5.7 每条的实测结果（截图 / curl 输出 / SQL 查询结果）
- 实际执行命令（admin 默认账号、起前后端的命令）
- 任何发现的、本文档未覆盖的边界情况或后续待办
