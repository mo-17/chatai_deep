# Ubuntu 2 核 2 GB 部署

首次照着部署请先阅读 [完整分步部署教程](DEPLOYMENT_GUIDE.md)：覆盖 SSH/deploy 密钥、共享 IP 映射、GoDaddy/Cloudflare、HTTPS 自动续期、官网与 APK 发布、Flutter 登录验收及清理。本文件保留基础脚本说明和故障恢复细节。

适用 Ubuntu **22.04 / 24.04 LTS**、x86_64 / aarch64，一台专用服务器同时运行 NestJS、Next.js、PostgreSQL。使用 systemd，无需安装宝塔、Docker、PM2 或 Flutter。默认只允许经 SSH 隧道访问，适合暂无域名时先完成测试。

现有服务器已迁移到 Cloudflare Free 标准 HTTPS，官网 `https://kushui.shop/`、后台 `/login`、API `/uapi/*`；继续使用七牛香港共享 IP，通过 Origin Rule 严格回源 10084。迁移进度及验收边界见 [CLOUDFLARE.md](./CLOUDFLARE.md)，网站发布见 [WEBSITE.md](./WEBSITE.md)，源站续期现使用 Cloudflare DNS 插件，运维见 [SERVER.md](./SERVER.md)。下文为新服务器的基础部署流程。

## 最短执行流程

### 1. 在当前 Mac 打包源码

在项目根目录执行。归档采用显式文件清单，包含本次新增的部署文件，不需要先提交 Git；不包含真实环境文件、密钥文件、node_modules、Flutter 工程、上传文件、包根测试目录或 `*.spec.ts` / `*.test.ts`。后端仍被导入的 `src/test` 业务模块会保留，但生产模式下不启用。

```bash
python3 deploy/ubuntu/package.py source "$PWD" /tmp/chatai-ubuntu-source.tgz
scp /tmp/chatai-ubuntu-source.tgz 用户名@服务器IP:~/
```

如果 SSH 使用其它端口，`scp` 添加 `-P 端口`，后面的 `ssh` 添加 `-p 端口`。重复打包时请使用新的输出文件名，脚本会拒绝覆盖现有归档。

### 2. 登录 Ubuntu 并初始化

以下命令在服务器上执行。建议以有 sudo 权限的 SSH 用户登录。

```bash
mkdir -p ~/chatai-source
tar -xzf ~/chatai-ubuntu-source.tgz -C ~/chatai-source
cd ~/chatai-source

sudo bash deploy/ubuntu/setup.sh
sudo bash deploy/ubuntu/deploy.sh --source "$PWD"
```

`setup.sh` 会安装 Ubuntu 软件包、项目专用 Node.js **22.23.3** 和 pnpm **10.12.4**，在系统没有活动 swap 时创建 2 GB swap（要求根分区至少有 6 GB 空间，Btrfs 需单独处理），创建 `chatai` 系统用户、`chatai_app` 数据库与角色，生成独立的 DB / JWT / 加密主密钥 / 初始管理员密码。已经有 swap 时保留原配置；也可显式执行 `setup.sh --skip-swap`。

专用 Node.js 位于 `/opt/chatai-deep/node`，不替换系统 Node.js。下载的 Node.js 压缩包会按脚本内固定的官方 SHA-256 摘要校验。服务器必须能访问 Ubuntu 软件源、nodejs.org 和 npm registry；私网或国内线路受限时，请先解决下载连通性，脚本不自动替换镜像源。

`deploy.sh` 以非 root 用户顺序安装依赖、编译 backend、使用 webpack / 单 worker 编译 admin，再独立执行 TypeScript 检查。默认构建 Node 堆为 1024 MB；这不是整机内存上限，构建时间和峰值取决于依赖及机器状态。若发生 OOM，优先使用下文的外部 Linux 构建方式。

构建成功后才停止旧应用，备份数据库 / 上传文件 / 密钥，执行编译后的 migration；migration 成功才切换 `current`、启动服务并检查 API、admin、Nginx 三层。脚本不修改防火墙、安全组、其它 Nginx 站点或已有 PostgreSQL 全局参数。系统 Nginx 的默认站点可能监听公网 80，但不会通过它暴露应用；应用入口为本机 8080。

源码包必须保留根目录 `.npmrc`，其中的 HeroUI 依赖提升配置供 Tailwind `@source` 扫描使用。`build.sh` 安装依赖后先检查 `node_modules/@heroui/theme/dist`，成品验证再检查按钮尺寸、前景色和输入框标签状态等 CSS。缺少这些样式时，Next.js 本身仍可能编译成功，因此不能跳过部署检查。若出现“HeroUI 样式源不存在”，应恢复本仓库配置并重新安装依赖、构建，不在旧成品上补拷单个 CSS 文件。

### 3. 在 Mac 建立隧道并登录

```bash
ssh -N -o ExitOnForwardFailure=yes \
  -L 8080:127.0.0.1:8080 用户名@服务器IP
```

保持该终端运行，浏览器打开 **http://localhost:8080**。API 为 `http://localhost:8080/uapi/*`，健康检查为 `http://localhost:8080/healthz`。本机 8080 被占用时，可将隧道左侧改为 `18080`，并使用 `http://localhost:18080` 访问；如有跨源请求，还需调整 `CORS_ORIGINS`。

在服务器查看首次生成的管理员用户名 / 密码（不要将输出发到聊天或提交 Git）：

```bash
sudo grep '^ADMIN_DEFAULT_' /etc/chatai-deep/backend.env
```

首次登录后修改管理员密码，在后台配置 AI 服务商、API Key 和模型。验证码注册 / 登录需要另行配置 SMTP。`ADMIN_DEFAULT_PASSWORD` 是首次播种值，修改环境文件不会修改数据库中已有管理员的密码。

## 配置与内存预算

| 项目 | 路径或默认值 |
| --- | --- |
| 后端环境文件 | `/etc/chatai-deep/backend.env`，root-only，首次生成后不覆盖 |
| 版本目录 / 当前版本 | `/opt/chatai-deep/releases/*` / `/opt/chatai-deep/current` |
| 上传文件 | `/var/lib/chatai-deep/uploads`，版本更新时保留 |
| Next.js 缓存 | `/var/cache/chatai-deep/next/*` |
| 备份 | `/var/backups/chatai-deep/*`，含数据库、文件和加密主密钥 |
| API | `127.0.0.1:3000`；Node 堆 384 MB，systemd MemoryMax 640 MB |
| Admin | `127.0.0.1:3001`；Node 堆 256 MB，systemd MemoryMax 512 MB |
| Nginx | `127.0.0.1:8080`；关闭 SSE 缓冲，读取超时 3600 秒，请求体上限 50 MB（后端各路由另有上限） |
| PostgreSQL | 本机；应用连接池 3，专用角色连接上限 8 |

这些是低并发起步值，不是并发容量承诺。达到 systemd 内存上限时进程可能被终止并重启，应先检查日志和实际占用。不要同时另跑 PM2 实例。后端 stdio MCP 子进程也计入 API unit 的内存和进程预算；需要额外 Node/Python 工具链的 MCP 请单独安装并验证。

编辑配置使用 `sudoedit /etc/chatai-deep/backend.env`。采用简单 `KEY=value` 格式；含空格时加引号，不写多行值、shell 表达式或 `export`。保留固定的本机地址、数据库身份和 `DB_SYNCHRONIZE=false`；生成的 DB 密码与数据库对应，不要只修改文件中的密码。`APP_SECRET_KEY` 必须与数据库一起保留，否则已有加密凭据可能无法解密。

修改环境文件后：

```bash
sudo systemctl restart chatai-deep-api
```

## 更新与外部构建

更新时重新打包、上传，解压到**新的空源码目录**，再次运行 `deploy.sh --source "$PWD"`。不在已部署的 `current` 中直接编辑或执行 Git pull。已有密钥、数据库及上传文件均保留；脚本不会自动删除旧版本、旧缓存或备份，需定期检查磁盘空间。

2 GB 主机初次构建如果吃紧，可在**另一台相同 CPU 架构的 Linux 机器**上使用 Node.js 22 和 pnpm 10.12.4 预构建：

```bash
# Linux 构建机；目标目录必须为空
bash deploy/ubuntu/build.sh "$PWD" /tmp/chatai-linux-release
tar -czf /tmp/chatai-linux-release.tgz -C /tmp/chatai-linux-release .
scp /tmp/chatai-linux-release.tgz 用户名@服务器IP:~/

# Ubuntu 目标服务器；setup.sh 仍需先执行
mkdir -p ~/chatai-prepared
tar -xzf ~/chatai-linux-release.tgz -C ~/chatai-prepared
sudo bash ~/chatai-source/deploy/ubuntu/deploy.sh --prepared ~/chatai-prepared
```

构建机建议使用与服务器相同的 Ubuntu LTS 版本，以保证原生模块的 glibc 兼容性。脚本检查 Linux、CPU 架构、Node major、构建入口和外部符号链接；不能替代全部原生 ABI 验证。不要上传 macOS / Windows 的 `node_modules`，也不要在预构建目录放入环境文件。部署完成前仍需目标服务器健康检查。

## 检查、备份与失败恢复

```bash
sudo systemctl status chatai-deep-api chatai-deep-admin --no-pager
sudo journalctl -u chatai-deep-api -u chatai-deep-admin -n 100 --no-pager
curl -f http://127.0.0.1:8080/healthz
sudo ss -lntp
free -h
df -h /

# 短暂停止应用，一致备份后自动恢复原本正在运行的服务
sudo bash deploy/ubuntu/backup.sh
```

应看到 API / admin / 应用 Nginx 入口分别仅监听 127.0.0.1 的 3000 / 3001 / 8080。PostgreSQL 默认本机监听；如服务器原本修改过 PostgreSQL，请另行检查 5432 的监听配置和防火墙。当前脚本不会自动改变其它服务的访问策略。

- **构建失败**：旧版本继续运行；修复后重跑。失败目录会保留，便于查日志并人工清理。
- **停止服务或备份失败**：不会继续迁移。服务可能已经停止，排除问题后再启动当前版本或重跑部署。没有 `COMPLETE` 标记的备份不视为完整备份。
- **migration 失败**：保留原 `current`，应用保持停止。先检查日志和最新完整备份，确认 migration 状态后再决定重试或恢复；不自动回退 schema，也不自动启动旧代码。
- **migration 成功但启动失败**：新数据库可能已经变更，不能只切回旧代码。修复新版本重试，或人工停机恢复同一次备份的数据库、uploads 和 `backend.env`。数据库恢复会覆盖数据，必须先核对具体备份，脚本不会自动执行破坏性恢复。
- **初始化重复执行**：不覆盖已有密钥、不重设数据库密码。已有同名路径 / 角色但不属于此安装时会停止，避免接管其它服务。

备份内的 `SHA256SUMS` 可用 `sha256sum -c SHA256SUMS` 检查。`database.dump` 是 PostgreSQL custom 格式，可用 `pg_restore --list database.dump` 检查目录。请把完整备份另存到受控位置；数据库、上传文件和 `APP_SECRET_KEY` 必须对应同一备份。

## Flutter 与后续 HTTPS

当前模式适合电脑端测试。Android USB 调试也可将手机 8080 转发到 Mac 的 SSH 隧道，再使用 debug 包：

```bash
# Mac：先保持前面的 SSH 隧道运行，手机已连接且 adb 已授权
adb reverse tcp:8080 tcp:8080
cd chatgpt_flutter
fvm flutter run \
  --dart-define=BACKEND_HOST=127.0.0.1:8080 \
  --dart-define=BACKEND_HTTPS=false
```

手机断开 USB 后该路径不可用。正式公网接入需配置可信 HTTPS（通常使用域名），再设置 Nginx 的公网入口、证书和 `CORS_ORIGINS`，并重新打包 App 指向公网 API。当前脚本不自动开放公网 HTTP 登录入口、不申请证书，也不声称已完成生产或手机端验收。

参考：[Ubuntu PostgreSQL](https://ubuntu.com/server/docs/how-to/databases/install-postgresql/)、[Node.js 下载与校验](https://nodejs.org/en/download)、[Next.js 自托管](https://nextjs.org/docs/app/guides/self-hosting)、[systemd 资源控制](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html)。

## 本地验证

以下命令在完整仓库中运行；上传源码包不包含测试目录。

```bash
python3 -m unittest discover -s deploy/ubuntu/tests -v
bash -n deploy/ubuntu/{common,setup,build,deploy,backup}.sh
git diff --check
```

测试覆盖密钥不被覆盖、环境配置校验、源码包排除敏感文件、架构检查、DNS hook 的凭据保护与安全清理，以及真实部署脚本在模拟系统命令下的备份 / migration 失败与成功路径。macOS 的构建验证不能证明 Ubuntu 的安装、systemd、Nginx 和数据库迁移已经运行成功；首次部署仍以目标服务器检查为准。
