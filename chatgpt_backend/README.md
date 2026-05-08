<p align="center">
  <a href="http://nestjs.com/" target="blank"><img src="https://nestjs.com/img/logo-small.svg" width="120" alt="Nest Logo" /></a>
</p>

[circleci-image]: https://img.shields.io/circleci/build/github/nestjs/nest/master?token=abc123def456
[circleci-url]: https://circleci.com/gh/nestjs/nest

  <p align="center">A progressive <a href="http://nodejs.org" target="_blank">Node.js</a> framework for building efficient and scalable server-side applications.</p>
    <p align="center">
<a href="https://www.npmjs.com/~nestjscore" target="_blank"><img src="https://img.shields.io/npm/v/@nestjs/core.svg" alt="NPM Version" /></a>
<a href="https://www.npmjs.com/~nestjscore" target="_blank"><img src="https://img.shields.io/npm/l/@nestjs/core.svg" alt="Package License" /></a>
<a href="https://www.npmjs.com/~nestjscore" target="_blank"><img src="https://img.shields.io/npm/dm/@nestjs/common.svg" alt="NPM Downloads" /></a>
<a href="https://circleci.com/gh/nestjs/nest" target="_blank"><img src="https://img.shields.io/circleci/build/github/nestjs/nest/master" alt="CircleCI" /></a>
<a href="https://discord.gg/G7Qnnhy" target="_blank"><img src="https://img.shields.io/badge/discord-online-brightgreen.svg" alt="Discord"/></a>
<a href="https://opencollective.com/nest#backer" target="_blank"><img src="https://opencollective.com/nest/backers/badge.svg" alt="Backers on Open Collective" /></a>
<a href="https://opencollective.com/nest#sponsor" target="_blank"><img src="https://opencollective.com/nest/sponsors/badge.svg" alt="Sponsors on Open Collective" /></a>
  <a href="https://paypal.me/kamilmysliwiec" target="_blank"><img src="https://img.shields.io/badge/Donate-PayPal-ff3f59.svg" alt="Donate us"/></a>
    <a href="https://opencollective.com/nest#sponsor"  target="_blank"><img src="https://img.shields.io/badge/Support%20us-Open%20Collective-41B883.svg" alt="Support us"></a>
  <a href="https://twitter.com/nestframework" target="_blank"><img src="https://img.shields.io/twitter/follow/nestframework.svg?style=social&label=Follow" alt="Follow us on Twitter"></a>
</p>
  <!--[![Backers on Open Collective](https://opencollective.com/nest/backers/badge.svg)](https://opencollective.com/nest#backer)
  [![Sponsors on Open Collective](https://opencollective.com/nest/sponsors/badge.svg)](https://opencollective.com/nest#sponsor)-->

## Description

[Nest](https://github.com/nestjs/nest) framework TypeScript starter repository.

## 环境变量

复制 `.env.example` 为 `.env`，填入真实的 API Key：

```bash
cp .env.example .env
```

编辑 `.env` 文件：

```
JWT_SECRET=chatgpt-flutter-secret-key
```

- `JWT_SECRET`：JWT 签名密钥
- `ADMIN_DEFAULT_USERNAME` / `ADMIN_DEFAULT_PASSWORD`：首次启动自动创建的管理员账号（默认 `admin` / `admin123`）
- AI 服务商与模型在管理后台 → AI 配置 中维护

## 管理后台 API

所有管理端点前缀 `/uapi/admin`，需要管理员 JWT（`role=admin`）。

### 认证
| 方法 | 路径 | 说明 |
|-|-|-|
| POST | `/uapi/admin/login` | 管理员登录，返回 `{ token, admin }` |
| GET | `/uapi/admin/me` | 当前管理员信息 |
| POST | `/uapi/admin/change-password` | 修改密码 |

### 用户管理
| 方法 | 路径 | 说明 |
|-|-|-|
| GET | `/uapi/admin/users` | 用户列表（keyword, page, pageSize, role, banned） |
| GET | `/uapi/admin/users/:id` | 用户详情 |
| PATCH | `/uapi/admin/users/:id` | 编辑用户（avatar, role, banned） |
| POST | `/uapi/admin/users/:id/reset-password` | 重置密码 |
| DELETE | `/uapi/admin/users/:id` | 删除用户及用量 |

### Banner 管理
| 方法 | 路径 | 说明 |
|-|-|-|
| GET/POST | `/uapi/admin/banners` | 列表 / 新增 |
| GET/PATCH/DELETE | `/uapi/admin/banners/:id` | 详情 / 编辑 / 删除 |

### 版本管理
| 方法 | 路径 | 说明 |
|-|-|-|
| GET/POST | `/uapi/admin/versions` | 列表 / 新增 |
| GET/PATCH/DELETE | `/uapi/admin/versions/:id` | 详情 / 编辑 / 删除 |

### 用量统计
| 方法 | 路径 | 说明 |
|-|-|-|
| GET | `/uapi/admin/usage/list` | 明细列表（userId, provider, model, from, to, page, pageSize） |
| GET | `/uapi/admin/usage/summary` | 概览（今日/本周/本月/全部 + 用户数） |
| GET | `/uapi/admin/usage/series` | 按日趋势（from, to，默认近30天） |
| GET | `/uapi/admin/usage/by-provider` | 按 provider 聚合 |
| GET | `/uapi/admin/usage/top-users` | Top N 用户（limit, days） |
| GET | `/uapi/admin/usage/export` | 导出 CSV |

### 默认管理员
首次启动时若数据库中无 `role=admin` 的用户，会自动创建：
- 账号：`admin`（可通过 `ADMIN_DEFAULT_USERNAME` 环境变量自定义）
- 密码：`admin123`（可通过 `ADMIN_DEFAULT_PASSWORD` 环境变量自定义）
- **正式环境务必修改默认密码**

## 本地启动

```bash
# 1. 确保 Postgres 已运行，数据库 chatgpt_flutter 和角色 huangzhibin 已创建
# 2. 安装依赖
npm install
# 3. 配置环境变量
cp .env.example .env
# 编辑 .env 填入你的 API Key
# 4. 启动开发服务器
npm run start:dev
```

后端监听 `http://localhost:3000`，`/uapi/chat/completions` 端点需要携带登录 JWT。

## Project setup

```bash
$ npm install
```

## Compile and run the project

```bash
# development
$ npm run start

# watch mode
$ npm run start:dev

# production mode
$ npm run start:prod
```

## Run tests

```bash
# unit tests
$ npm run test

# e2e tests
$ npm run test:e2e

# test coverage
$ npm run test:cov
```

## Deployment

When you're ready to deploy your NestJS application to production, there are some key steps you can take to ensure it runs as efficiently as possible. Check out the [deployment documentation](https://docs.nestjs.com/deployment) for more information.

If you are looking for a cloud-based platform to deploy your NestJS application, check out [Mau](https://mau.nestjs.com), our official platform for deploying NestJS applications on AWS. Mau makes deployment straightforward and fast, requiring just a few simple steps:

```bash
$ npm install -g @nestjs/mau
$ mau deploy
```

With Mau, you can deploy your application in just a few clicks, allowing you to focus on building features rather than managing infrastructure.

## Resources

Check out a few resources that may come in handy when working with NestJS:

- Visit the [NestJS Documentation](https://docs.nestjs.com) to learn more about the framework.
- For questions and support, please visit our [Discord channel](https://discord.gg/G7Qnnhy).
- To dive deeper and get more hands-on experience, check out our official video [courses](https://courses.nestjs.com/).
- Deploy your application to AWS with the help of [NestJS Mau](https://mau.nestjs.com) in just a few clicks.
- Visualize your application graph and interact with the NestJS application in real-time using [NestJS Devtools](https://devtools.nestjs.com).
- Need help with your project (part-time to full-time)? Check out our official [enterprise support](https://enterprise.nestjs.com).
- To stay in the loop and get updates, follow us on [X](https://x.com/nestframework) and [LinkedIn](https://linkedin.com/company/nestjs).
- Looking for a job, or have a job to offer? Check out our official [Jobs board](https://jobs.nestjs.com).

## Support

Nest is an MIT-licensed open source project. It can grow thanks to the sponsors and support by the amazing backers. If you'd like to join them, please [read more here](https://docs.nestjs.com/support).

## Stay in touch

- Author - [Kamil Myśliwiec](https://twitter.com/kammysliwiec)
- Website - [https://nestjs.com](https://nestjs.com/)
- Twitter - [@nestframework](https://twitter.com/nestframework)

## License

Nest is [MIT licensed](https://github.com/nestjs/nest/blob/master/LICENSE).
