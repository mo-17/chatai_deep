# 艾普官网与访问入口

官网由原 Ubuntu 服务器的 Nginx 提供静态 HTML/CSS/JS，通过 Cloudflare Free 的标准 HTTPS 入口访问。继续保留七牛香港共享 IP，Cloudflare Full (strict) 回源 `38.127.133.6:10084`，没有购买独立 IP，也没有新增常驻应用进程。

## 地址

2026-10-19 应用侧新增 [运行监控](https://kushui.shop/operations)，仅管理员登录可用。当前官网与下载文件保持 +16，本地 +17 为未发布候选；本轮重验官网 53/53 通过。部署与真机边界见 [验收记录](../verification/next-20261019/README.md)。

| 用途 | 地址 |
| --- | --- |
| 官网 | [https://kushui.shop/](https://kushui.shop/) |
| 客户端下载 | [官网的下载区](https://kushui.shop/#download) |
| 管理后台 | [后台登录](https://kushui.shop/login)，`/admin`、`/admin/` 为跳转别名 |
| API 前缀 | `https://kushui.shop/uapi`，拼接具体路由 |
| 连通检查 | [公开配置](https://kushui.shop/uapi/auth/public-config)、[数据库健康](https://kushui.shop/healthz) |
| www | 边缘 308 到根域名，保留路径与查询 |
| SSH 隧道备用后台 | `http://localhost:18080/login`，需先建立原 SSH 隧道 |

Flutter origin 为 `https://kushui.shop`，不添加 `/uapi`。旧版 `:10084` 客户端需升级 +15；Cloudflare 边缘不接入这个端口。API/admin 路径保持原样，没有重构 Next.js basePath。源站仍保留 10084 TCP 映射，但它供 Cloudflare 回源，不能当作已代理域名的客户端端口。

官网、后台与 API 按路径分流。受保护 API 要求 JWT，管理接口要求管理员权限。官网不采集账号、不接入统计或远程字体，场景演示标为非实时内容；官网不替代后端鉴权。

## 安装包

官网提供 Android `1.0.6+16` 体验包，最低 Android 7.0（SDK 24），包名 `com.example.chatgpt_flutter`。仍为项目原有 Debug 签名，未做 Android 真机验收；iOS、桌面、HarmonyOS 尚不提供公开下载。自动推送保持暂停，上一全量 `+15` 仍可供旧客户端更新。

- 默认下载 ARM64：64,420,181 字节；32 位 ARM：53,708,105；x86_64：71,876,813；通用包：180,471,259。所有包版本码均为 16，不包含离线语音模型。
- 元数据及每个包的 SHA-256：`website/site-assets/release.json` 的 `artifacts`，后端地址为标准 HTTPS。每个安装包都有同名 `.sha256` 文件。
- 当前下载使用 `https://kushui.shop/downloads/`。源码链接和元数据一致；新版 ARM64 已通过真实 Flutter 暂停、Range 续传及完整 SHA 校验。旧下载文件不覆盖。
- 官方试用已开放，DeepSeek Flash 每人每日 10,000 Token；真实回复与扣减 10/10 通过。通用 SMTP 已启用，指定 Gmail 的注册/验证码登录/找回密码 15/15 通过；官网使用说明和 FAQ 已同步。
- 离线语音模型在客户端明确确认后按需下载，约 125 MB；真实下载、校验及安装已验收，未做真机播放验证。

## 文件与发布

| 内容 | 路径 |
| --- | --- |
| 官网源码 | 仓库 `website/`，固定六个静态文件 |
| 线上 current | `/var/www/chatai-website/current` |
| 当前官网版本 | `/var/www/chatai-website/releases/20261018T230810Z.P2uRXQlW` |
| 安装包目录 | `/var/www/chatai-website/downloads/`，root 所有、Nginx 只读，无目录列表 |
| 官网 locations / headers | `/etc/nginx/snippets/chatai-website-{locations,headers}.conf` |
| TLS / 网关配置 | `/etc/nginx/conf.d/chatai-deep-{tls,public}.conf` |
| 当前发布备份 | `/var/backups/chatai-deep/website-20261018T230810Z.EDlgjl8V/` |
| 迁移与验收记录 | `/root/chatai-cloudflare-20261019/`，root 专用 |

服务器发布命令：

```bash
sudo bash <源码目录>/deploy/ubuntu/publish-website.sh \
  <源码目录>/website \
  /var/www/chatai-website/downloads/aipu-1.0.6-16-universal.apk
```

脚本、`nginx-website-locations.conf` 和 `nginx-website-headers.conf` 必须在同一目录。脚本验证静态文件集、APK 大小/摘要，备份配置，原子切换 current，检查 Nginx 与 API/admin，失败时尝试恢复。发布不重建或重启 API/admin。同版本安装包不得被不同内容覆盖；新版本须同步更新元数据、HTML 和发布脚本。

不能将旧 +13 官网页面单独恢复到新的代理配置上，否则旧安装包仍引用不再支持的端口。跨 DNS、TLS 和客户端的回退边界见 [CLOUDFLARE.md](CLOUDFLARE.md)。

## 客户端更新发布（2026-10-19）

Android 当前官网下载 **1.0.6+16**，沿用历史签名。后台版本记录 ID `2`、渠道 `321`、`enabled=true`、`forceUpdate=false`、`rolloutPercent=0`，待真机覆盖升级验收；旧全量 +15 保留。自动/手动检查、按架构下载与发布流程见 [UPDATES.md](../flutter/UPDATES.md)。

本轮官网/下载回归 53/53、独立 QA 渠道灰度/暂停/上一全量回退 8/8、真实 Flutter ARM64 暂停与断点续传校验通过；Chrome 下载区显示 1.0.6 · Build 16 / 64.4 MB。两份独立客户端的真实云同步通过；完整结果见 [交付记录](../../docs/p0-p1-delivery.md)。Android 真机安装及覆盖后数据保留尚未验收。

## 验收状态（2026-10-19）

服务器通过新标准域名完成：官网及下载 **53/53**、管理员/API **37/37**、普通用户密码登录与权限 **5/5**。包含 CF 边缘、可信 TLS、官网/后台资源、HTTP/www 跳转、查询保留、精确 CORS、API 缓存隔离、JWT 鉴权和下载分段检查。临时普通用户已删除，删除后的 JWT 返回 401；Mac/服务器临时凭据已清理。

2026-10-19 05:34（北京时间）Mac 正常网络再次通过 **53/53**，无强制解析或 TLS 绕过，报告为 `/tmp/chatai-cf-website-verification.json`。Chrome 标准 HTTPS 官网的场景切换、FAQ 展开和下载区导航正常；后台管理员登录、仪表盘、刷新保持登录以及退出后访问 `/dashboard` 返回登录页均通过。真实 Flutter 生产后端集成测试 **1/1** 通过，覆盖普通用户登录和权限隔离。测试用户与两端临时凭据已删除，浏览器已退出测试登录。

标准地址截图为本聊天可视化目录中的 `aipu-standard-https-home.png`、`aipu-standard-https-download.png` 和 `aipu-standard-https-dashboard.png`。自动任务 `kushui-shop-https` 已设为 PAUSED。早先带端口官网的窄屏与 iOS 模拟器验收是历史证据；本次未做 Android 真机、新地址原生 GUI、真实模型推理或 SMTP 验收。

```bash
python3 deploy/ubuntu/verify-website.py \
  --apk chatgpt_flutter/build/app/outputs/flutter-apk/app-release.apk \
  --output /tmp/chatai-cf-website-verification.json
```

源站证书续期已切到 Cloudflare DNS 插件并通过 staging；令牌于 2027-10-19 到期。运维见 [SERVER.md](SERVER.md)。
