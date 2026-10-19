# kushui.shop 标准 HTTPS 迁移

2026-10-19 05:34（北京时间）：标准 HTTPS 迁移验收完成。Cloudflare zone 与免费边缘证书均 Active，根域名和 www 已启用代理。服务器侧官网 53/53、管理员/API 37/37、普通用户登录及权限 5/5 均通过；Mac 正常网络官网 53/53、Chrome 官网与后台登录、真实 Flutter 登录与权限隔离测试均通过。

自动任务 `kushui-shop-https` 已按用户要求设为 PAUSED。证书续期由服务器的 `certbot.timer` 继续执行，暂停本聊天的检查任务不影响续期。

2026-10-19 后续 P0/P1 发布：当前官网下载 **1.0.6+16**，后台版本 ID `2`、渠道 `321`、灰度 0%，待真机验收；上一全量 `+15` 继续供旧客户端更新。官方试用和邮件账号流程已实际验收。后续发布见 [客户端更新说明](../flutter/UPDATES.md)，完整结果见 [交付记录](../../docs/p0-p1-delivery.md)。原 +14 迁移验证保留为历史记录。

## 当前配置

2026-10-19 后续应用已升级到 `20261019T010046Z.HZTlt5UL`，加入管理员运行监控和试用资格/限流；官网 53/53、管理员/API 37/37、新增检查 22/22、Flutter 公网登录通过。此次没有修改 DNS、代理端口、证书或续期。官网仍为 +16 下载，+17 仅本地候选，详见 [本轮验收](../verification/next-20261019/README.md)。

- 官网 `https://kushui.shop/`，后台 `/login`（`/admin` 为跳转别名），API `/uapi/*`；保持七牛香港共享 IP，不购买独立 IP 或任何付费套餐，不联系七牛客服。
- Cloudflare Free zone `e5ee9f9b80098c17e36da68d86a14c41`，NS 为 `edward.ns.cloudflare.com` / `mallory.ns.cloudflare.com`，域名注册商仍是 GoDaddy。
- Cloudflare 控制台内的根 A 记录仍为源站 `38.127.133.6`，根 A 与 www CNAME 均 proxied。公开解析返回 Cloudflare 边缘 IP；不能将这些边缘 IP 写回 Cloudflare 的源站 A 记录。
- 原 A、CNAME 和 TXT 五条业务记录已逐条核对保留；TXT 引号是等价表示。`_domainconnect` 保持 DNS-only。
- Full (strict)、Always Use HTTPS、最低 TLS 1.2；Origin Rule `kushui-shared-ip-https-10084` 精确匹配根域名，回源端口 10084，Host/SNI/DNS 保留。
- www 在边缘 308 到根域名，保留路径及查询。源站证书只含根域名，避免将 www 发往源站。
- `kushui-api-admin-no-cache` 为 API/admin 等动态路径绕过缓存，官网与静态文件按原缓存头处理。
- Nginx `/etc/nginx/conf.d/chatai-deep-tls.conf` 已切换标准 HTTPS 跳转，`X-Forwarded-Port` 根据 Host 处理 443/直接诊断 10084；仅信任 Cloudflare 官方网段的 `CF-Connecting-IP`。
- 后端精确 CORS 已增加 `https://kushui.shop`，原来源保留；API 已重启且数据库健康。

## 证书与文件

- Certbot 2.9 已安装 Ubuntu 官方 `python3-certbot-dns-cloudflare`，`reconfigure` 的 staging 演练通过，返回 `Successfully updated configuration`。
- `/etc/letsencrypt/renewal/kushui.shop.conf` 已使用 `dns-cloudflare`；`/etc/letsencrypt/secrets/cloudflare.ini` 为 root 0600，令牌仅限本域名 Zone DNS Edit，2027-10-19 到期。Mac 令牌临时副本已删除。
- `certbot.timer` 与 `chatai-reload-nginx` deploy hook 保留；旧 GoDaddy hook/token 保留为私有备份，当前续期不使用它们。
- 当前官网 `/var/www/chatai-website/current` 指向 `/var/www/chatai-website/releases/20261018T230810Z.P2uRXQlW`；本次发布备份 `/var/backups/chatai-deep/website-20261018T230810Z.EDlgjl8V/`。
- 工作目录 `/root/chatai-cloudflare-20261019/`（0700）包含 DNS/配置备份、发布源码、`cf-dns.py`、`verify-website.py`、`verify-admin.py`、验收结果和续期日志；含凭据文件均应 0600。`wait-renew.py` 的限时等待已经结束，不必再启动。
- 迁移首包 Android `1.0.4+14`（历史）：304711027 字节，SHA-256 `dab2cd02005852db06550f9e004b4f8b2f019f5624bd6d7b8a7f063a468c0363`；签名/minSdk 24/INTERNET/AOT 新地址检查通过。仍为 debug 体验包，没有 Android 真机验收。
- 当前安装包与摘要通过 `https://kushui.shop/downloads/` 下载；原七牛 HTTPS 网关保留历史下载。首尾 Range 和本地文件逐字节一致，旧安装包不覆盖。

## 最终验收

- Mac 普通访问 `https://kushui.shop/` 返回 200、产品官网正文及 `CF-Ray`，系统信任库校验 TLS 成功。没有强制 IP、修改 hosts、系统 DNS/代理或关闭安全检查。
- Mac 执行 `python3 deploy/ubuntu/verify-website.py --apk chatgpt_flutter/build/app/outputs/flutter-apk/app-release.apk --output /tmp/chatai-cf-website-verification.json`：53/53 通过，包含静态资源、HTTP/www 跳转、精确 CORS、API 缓存隔离与 APK 摘要/大小/首尾 Range。
- Chrome 标准域名官网正常，场景切换、FAQ 展开、下载区导航及 +14 下载链接通过；后台使用既有管理员登录，仪表盘显示正常，刷新保持登录。退出后访问 `/dashboard` 返回 `/login`，验收登录态已退出。
- 从 `chatgpt_flutter/` 执行 `CHATAI_LIVE_CREDENTIALS=<0600 临时 qa-user.json> fvm flutter test ../login_sdk/test/production_backend_live_test.dart --dart-define-from-file=../deploy/flutter/production.json --no-pub --reporter expanded`：1 个公网集成用例通过。使用真实 Flutter AuthDao、TLS、令牌存储与公共请求头，覆盖普通用户登录、受保护接口、管理权限 403 与退出后 401。
- 本次专用普通用户已按 ID、邮箱、用户名及角色精确删除；服务器与 Mac 的管理员/普通用户临时凭据均已删除，没有输出密码、JWT 或完整登录响应。
- 截图位于本聊天可视化目录：`aipu-standard-https-home.png`、`aipu-standard-https-download.png`、`aipu-standard-https-dashboard.png`。没有 Android 真机、新地址原生 GUI、真实模型推理或 SMTP 投递验收。

健康检查程序应发送明确应用 User-Agent，例如 `AipuDeploymentCheck/1.0`。Cloudflare 默认检查拒绝裸 `Python-urllib`（1010），真实 Dart UA 与明确应用 UA 已实测通过；没有关闭任何 Cloudflare 防护。

迁移期间自动审批拒绝了“把旧 GoDaddy 根 A 临时改为 Cloudflare 边缘 IP”的额外变更，该操作没有执行，也没有通过其它脚本、API 或 UI 重试。本次验收是在等待正常缓存更新后完成；Cloudflare 源站 A 保持 38.127.133.6。

## 回滚边界

旧客户端 `kushui.shop:10084` 不受 Cloudflare 边缘支持，需升级 +14。确需回退时，应协调 CF 根域名/www 的 DNS-only、HTTP 跳转、官网旧版和客户端旧配置；`cf-dns.py dns-only` 仅修改两条代理状态。权威 DNS 保持 Cloudflare 时，续期也继续使用 Cloudflare 插件。只有明确将权威 DNS 回退 GoDaddy 后，才考虑恢复旧 DNS hook。不要只恢复某一个旧配置或回滚数据库。

参考：[Origin Rules 免费端口覆盖](https://developers.cloudflare.com/rules/origin-rules/)、[Cloudflare 代理端口](https://developers.cloudflare.com/fundamentals/reference/network-ports/)、[Certbot DNS 插件](https://certbot-dns-cloudflare.readthedocs.io/en/stable/)、[Browser Integrity Check](https://developers.cloudflare.com/waf/tools/browser-integrity-check/)。
