# 本次服务器部署交接

2026-10-18 已在真实 Ubuntu 24.04 x86_64 服务器部署 **NestJS API、Next.js 管理后台、PostgreSQL 16**。

| 项目 | 当前值 |
| --- | --- |
| SSH | `deploy@38.127.133.6`，端口 `10072` |
| Mac 部署私钥 | `~/.ssh/chatai_deploy` |
| 远端主机名 | `i-6ace0ac0820728a083805736` |
| 当前版本 | `/opt/chatai-deep/releases/20261019T010046Z.HZTlt5UL` |
| 当前版本入口 | `/opt/chatai-deep/current` |
| Node / pnpm | `22.23.3` / `10.12.4` |
| 运行账号 | `chatai`，应用不以 root 运行 |
| API / admin | `127.0.0.1:3000` / `127.0.0.1:3001` |
| Nginx | `127.0.0.1:8080` 隧道入口；本机 `80` 接网关 / HTTP 映射；本机 `443` 接 TLS 映射 |
| 官网 / 下载 | `https://kushui.shop/` / `https://kushui.shop/#download` |
| 公网后台 | `https://kushui.shop/login` |
| API 前缀 | `https://kushui.shop/uapi`，客户端 origin 不带 `/uapi` |
| 备用网关入口 | `https://01a14fea704875d49fb78b48f2092eee.cn-hongkong-2.a8g1v3.xyz` |
| 环境配置 | `/etc/chatai-deep/backend.env`，`root:root`、`0600` |
| 最新完整备份 | `/var/backups/chatai-deep/20261019T010112Z.sgzdT8zt` |

代码包通过 deploy 上传；deploy 的 sudo 需要密码，因此本次系统初始化和服务安装使用此前授权的 root 密钥。未给 deploy 新增免密 sudo 权限。

当前官网下载 **1.0.6+16**，按架构分发，ARM64 约 64.4 MB。版本记录 ID `2`、渠道 `321`、非强制更新、灰度 0%，待真机覆盖升级验收；上一全量 `+15`（ID `1`）继续给旧客户端更新。发布维护见 [客户端更新说明](../flutter/UPDATES.md)。

2026-10-19 P0/P1 已部署：官方试用（DeepSeek Flash、每人每日 10,000 Token）和额度保护开启；通用 SMTP 已配置、测试与启用。真实推理/扣减 10/10、真实邮件账号流程 15/15、官网 53/53 通过。数据库现有 11 个迁移、33 张 public 表；临时账号与凭据已清理。设备验收边界及操作步骤见 [交付记录](../../docs/p0-p1-delivery.md)。

2026-10-19 后台样式修复已重新部署：源码包补齐 `.npmrc`，恢复 HeroUI 样式扫描，并新增构建前目录检查和成品 CSS 检查；侧栏独立滚动、固定页头/底栏，内容区可收缩。线上 CSS `ed910ceba16599f4.css` 为 238,413 字节，登录按钮高度恢复 40px、填写后标签不重叠。Chrome 登录/仪表盘/模型和服务商弹窗/下拉菜单/额度页验证通过，侧栏内容滚动时底部退出按钮保持可见。部署合同测试 23 项、后台类型检查/lint、Ubuntu 构建、管理员/API 37/37 和官网 53/53 通过。后端源码与数据配置保留，无待执行 migration；旧版本 `20261018T225542Z.LDPtKYlA` 可供应用回滚。记录及报告见 [本次样式验收](../verification/admin-ui-20261019/README.md)，服务器日志在 `/root/chatai-admin-ui-20261019/`。

## 打开后台

2026-10-19 后续运行监控与风控已部署：管理员可从 `/operations` 查看数据库、API 内存、今日预算和一小时 HTTP 统计。试用开放时普通用户须验证邮箱，每人每分钟 6 次、全站最大并发 4，原每日 10,000 Token 保留。当前 12 个迁移、33 张 public 表。管理员/API 37/37、官网 53/53、新增公网资格与监控 22/22、真实 Flutter 登录通过；临时账号及凭据已清理。Android +17 仅本地候选，官网下载和灰度保持 +16 / 0%。详见 [本轮验收](../verification/next-20261019/README.md) 和 [操作说明](../../docs/trial-operations.md)。

2026-10-19 已切换 Cloudflare Free 标准 HTTPS，官网为 [艾普官网](https://kushui.shop/)，后台使用 [登录页](https://kushui.shop/login) 或 `/admin`，API 前缀为 `https://kushui.shop/uapi`。继续保留七牛香港共享 IP，不购买独立 IP；Cloudflare 使用 Full (strict) 回源至 `38.127.133.6:10084`。后台用户名为 `admin`，沿用现有密码。Flutter 旧版 `:10084` 地址需升级为新配置。网站与下载见 [WEBSITE.md](WEBSITE.md)，DNS 与回滚边界见 [CLOUDFLARE.md](CLOUDFLARE.md)。

2026-10-19 05:34（北京时间）完成标准 HTTPS 验收：服务器侧官网 53/53、管理员/API 37/37、普通用户登录与权限 5/5；Mac 普通网络官网 53/53、Chrome 后台登录与仪表盘刷新、退出后访问控制、真实 Flutter 登录与权限隔离集成用例均通过。专用测试账号及两端临时凭据已清理。自动任务 `kushui-shop-https` 已设为 PAUSED，服务器 `certbot.timer` 保持运行。

原有[七牛云网关入口](https://01a14fea704875d49fb78b48f2092eee.cn-hongkong-2.a8g1v3.xyz/login)仍可作为备用入口。

以下 SSH 隧道仍可作为备用入口。Mac 的 8080 已有其它服务，本次使用 18080。在 Mac 执行并保持终端运行：

```bash
ssh -i ~/.ssh/chatai_deploy -p 10072 \
  -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -N -L 127.0.0.1:18080:127.0.0.1:8080 deploy@38.127.133.6
```

备用入口为 `http://localhost:18080/login`。初始密码只保存在服务器配置中；请在自己的终端查看，不要发到聊天或提交 Git：

```bash
ssh -i ~/.ssh/id_ed25519 -p 10072 root@38.127.133.6 \
  "grep '^ADMIN_DEFAULT_' /etc/chatai-deep/backend.env"
```

登录后修改密码。环境文件中的初始密码仅用于首次播种，修改它不会修改数据库中已有管理员的密码。

## 已验证

- 在服务器安装依赖并依次完成 NestJS 编译、Next.js webpack 编译、独立 TypeScript 检查。
- 数据库完成 10 个迁移，当前 public schema 有 30 张表。
- 37 项服务端验收通过：数据库健康、后台 HTML 与静态资源、Next.js `/api` 转发、管理员登录和鉴权、用户/模型/服务商/全局配置/用量/Banner/版本/模型清单等接口；未登录请求返回 401。
- Mac 经 deploy SSH 隧道访问服务器，浏览器真实登录成功；仪表盘、2 个预置服务商、8 个预置模型、3 个未配置的 SMTP 槽位均正常显示。
- 2026-10-19 新七牛云域名的公网 HTTPS 再次通过全部 37 项检查；Mac 浏览器通过该域名真实登录并显示仪表盘。HTTP 返回 308 跳转 HTTPS，客户端伪造协议头仍会被网关覆盖；新 HTTPS 来源的 CORS 响应头正确。
- 2026-10-19 `https://kushui.shop:10084` 通过全部 37 项公网检查，Mac 浏览器实际登录并显示仪表盘；系统信任库校验证书和域名成功，TLS 1.2 / 1.3 均可连接，`http://kushui.shop:10083/login` 返回 308 至正确的 HTTPS 10084 地址。原网关登录页仍返回 200。
- 2026-10-19 已启用 GoDaddy DNS API 自动续期。Certbot staging 演练、自动 TXT 创建与清理、Nginx 重载通过；10 项部署后核验通过，正式证书指纹未变。随后再次通过全部 37 项公网检查，浏览器刷新 HTTPS 仪表盘正常。
- 2026-10-19 官网及 Android 体验包上线：48 项公网官网/下载/路由检查全部通过，原 37 项 HTTPS 后台与 API 回归再次通过。桌面和窄屏浏览器已验证官网交互，Certbot 定时器仍正常运行。继续保留共享 IP、端口 10084 与 Flutter 后端 origin。
- 完成部署后数据库、uploads、环境密钥的一致备份；摘要校验通过，`pg_restore --list` 可读取数据库备份。
- 备份期间停止应用、备份后恢复，API 和 admin 更换 PID 后再次通过全部服务端验收。
- API、admin、Nginx、PostgreSQL 均启用开机启动；应用无自动重启记录。应用账号可以写 uploads，不能修改代码或直接读取 root 环境文件。
- 空闲时整机约用 503 MiB 内存，可用约 1396 MiB；磁盘剩余约 11 GiB，已启用 2 GiB swap。该数值是验收时快照，不代表并发容量。

浏览器验收使用的本机临时密码文件已删除，未把密码或令牌写入聊天、截图、仓库或本交接文件。

## 历史域名接入（迁移 Cloudflare 前）

本节记录早先带端口方案，当前权威 DNS 已迁至 Cloudflare，标准访问地址以上文为准。

已购买 `kushui.shop`，DNS 托管在 GoDaddy，控制台显示域名服务器为 `ns11.domaincontrol.com` / `ns12.domaincontrol.com`。

邮箱验证已生效：GoDaddy 的 WHOIS 待验证提示已消失，DNS 编辑权限恢复。已保存以下解析：

| 类型 | 主机名 | 目标 | TTL |
| --- | --- | --- | --- |
| A | `@` | `38.127.133.6` | 600 秒 |
| CNAME | `www` | `kushui.shop` | 1 小时，保留现有记录 |

根域名 A 记录由 `Parked` 改为 `38.127.133.6`，GoDaddy 显示 `Your DNS record has been updated successfully`；原有 www、NS、SOA、TXT 和 `_domainconnect` 记录保留。

公网 DNS over HTTPS 验证已通过：Google DNS 返回 `kushui.shop A 38.127.133.6`（TTL 600），Cloudflare DNS 返回 `www.kushui.shop CNAME kushui.shop`，并解析到 `38.127.133.6`。这两个解析器已可查询，不代表所有本地缓存均已更新。

此前直接使用默认公网 80/443 无法访问该实例。当前已通过共享 IP 的 TCP 端口映射接通 `https://kushui.shop:10084`，继续使用现有 A 记录，无需把自有域名绑定到七牛的系统 HTTP 代理。

2026-10-19 核对香港2实例控制台：HTTP 代理新增表单只有“类型”和“内网端口”，现有代理只有复制与删除操作，实例“更多操作”也没有自定义域名绑定或证书入口。当前控制台无法自助将 `kushui.shop` 绑定到系统 HTTP 代理。

此前只读核查系统 HTTP 网关：分配域名的 HTTPS `/login` 返回 200；同一网关使用 `Host: kushui.shop` 返回 404，自有域名的 TLS SNI 握手失败。该网关仍未绑定自有域名；当前带端口 HTTPS 使用独立的 TCP 映射，不经过上述 HTTP 网关。

[七牛云 ICP 备案 FAQ](https://developer.qiniu.com/las/12988/las-faq-domain-icp) 明确针对中国内地服务器；共享 IP 通用文档虽写有“不支持未备案域名绑定访问”，但未说明香港区的自定义 HTTP 代理绑定流程。不得据此认定香港服务器必须备案，或认定必须购买独立 IP。是否支持香港2工单人工绑定、标准 80/443 与自有证书，仍需官方答复；咨询草稿在本目录 `qiniu-domain-inquiry.md`。用户明确选择“先不联系七牛”，草稿未发送，空白工单页已关闭；未经后续授权不得联系官方。

此前仅查看过独立公网 IP 报价草稿，未勾选服务协议、未创建 IP 或产生订单。[LAS FAQ Q14](https://developer.qiniu.com/las/13371/las-refund) 与共享 IP 使用说明对能否原地更换独立 IP 的表述存在差异，该报价不代表已确认可绑定本实例。本次继续使用共享 IP，未购买独立 IP、未联系七牛客服。

## 源站 TLS 与共享 IP 端口

公网入口现为 Cloudflare 的 `https://kushui.shop`，由 Cloudflare 回源到服务器 Nginx 443。下列映射继续保留，但根域名已代理，不能再将域名的 `:10084` 作为客户端入口；直接诊断源站需显式解析到源站 IP 并保留 SNI。

| 公网入口 | 实例内入口 | 用途 |
| --- | --- | --- |
| `38.127.133.6:10072` | `22` | 原有 SSH |
| `38.127.133.6:10083` | `80` | 源站 HTTP，308 跳转标准 HTTPS |
| `38.127.133.6:10084` | `443` | Cloudflare 严格 HTTPS 回源 |

已安装 Certbot 2.9.0，使用 Let's Encrypt DNS-01 验证签发 `kushui.shop` 的 ECDSA 证书。GoDaddy 新增 `_acme-challenge` TXT 后，Google 与 Cloudflare 公共 DNS 均返回正确验证值，证书签发成功。根域名 A、www、NS、SOA、DMARC 等原有记录保留。TXT 验证值是公开 DNS 数据，未放入仓库文档。

- 证书：`/etc/letsencrypt/live/kushui.shop/fullchain.pem`
- 私钥：`/etc/letsencrypt/live/kushui.shop/privkey.pem`，`root:root`、`0600`，只保存在服务器
- 签发机构：Let's Encrypt YE1
- 到期时间：**2027-01-17 00:32:15，Asia/Shanghai（北京时间）**；服务器证书输出为 `2027-01-16 16:32:15 GMT`
- 源配置：本目录 `nginx-tls-port.conf`，安装到 `/etc/nginx/conf.d/chatai-deep-tls.conf`
- 原网关配置：`nginx-gateway.conf`，安装到 `/etc/nginx/conf.d/chatai-deep-public.conf`；自有域名的 HTTP 路由移至独立 TLS 配置文件，避免跳转到错误的公网端口
- 后端已添加精确来源 `https://kushui.shop`，原来源保留；仅信任 Cloudflare 官方网段的 `CF-Connecting-IP`
- 修改前配置备份、验收脚本与无凭据结果：`/root/chatai-https-20261019.BNSxAGtY/`

37 项公网验收包含管理员登录、未登录请求拒绝、主要管理接口、PostgreSQL 健康、Next.js API 转发与全部登录页静态资源。Mac 浏览器已通过自有域名实际登录，临时的本机凭据文件已删除。

### 证书续期

DNS 已迁至 Cloudflare，Certbot 已使用官方 `dns-cloudflare` 插件完成 staging 演练并保存配置。源站继续使用现有 Let's Encrypt 正式证书；没有部署 staging 证书。Cloudflare 的边缘 Universal SSL 已显示 Active，覆盖根域名和一级子域名，由 Cloudflare 自动续签；源站证书只覆盖根域名，www 在边缘 308 跳转到根域名，保留路径和查询。

- Certbot：2.9；Ubuntu 官方包 `python3-certbot-dns-cloudflare`、`python3-cloudflare` 已安装。
- 续期配置：`/etc/letsencrypt/renewal/kushui.shop.conf`，`authenticator = dns-cloudflare`，ACME 地址为正式环境。
- 凭据：`/etc/letsencrypt/secrets/cloudflare.ini`，root 0600；令牌仅授权 `kushui.shop / Zone DNS Edit`。
- 令牌 `chatai-certbot-kushui-shop` 到期日 **2027-10-19**，需在此日期前轮换；保留相同权限、0600 并重新做 staging 验证，不将令牌放入聊天、仓库、截图或命令参数。
- `certbot.timer` 保持启用；`/etc/letsencrypt/renewal-hooks/deploy/chatai-reload-nginx` 先 `nginx -t` 再 reload。
- 演练记录：`/root/chatai-cloudflare-20261019/certbot-reconfigure.log`，返回 `Successfully updated configuration`。
- 旧 GoDaddy token/hook 和迁移前配置保留为私有备份，当前续期不再使用它们。不要在 Cloudflare 权威 DNS 下切回 GoDaddy 验证方式。

```bash
systemctl list-timers certbot.timer --no-pager
sudo journalctl -u certbot.service -n 80 --no-pager
sudo certbot renew --cert-name kushui.shop --dry-run --run-deploy-hooks
```

修改验证方式或轮换令牌后，可重复执行下列命令；它在 staging 验证成功后才保存新的续期参数：

```bash
sudo certbot reconfigure --cert-name kushui.shop \
  --authenticator dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/secrets/cloudflare.ini \
  --dns-cloudflare-propagation-seconds 120 \
  --non-interactive --run-deploy-hooks
```


## 七牛云映射（2026-10-19，公网验收通过）

备用 HTTP 代理域名：`01a14fea704875d49fb78b48f2092eee.cn-hongkong-2.a8g1v3.xyz`。七牛云网关为该域名提供 HTTPS，再转发至本机 Nginx 80；它与本次自有域名的 443 证书配置相互独立。

已将本目录的 `nginx-gateway.conf` 安装至服务器 `/etc/nginx/conf.d/chatai-deep-public.conf`，按映射域名路由到 API 与管理后台。`nginx -t` 通过后重载，HTTP 自动跳转 HTTPS。已实测网关设置并覆盖 `X-Forwarded-Proto`，配置适用于该 TLS 网关；普通公网 IP 直连需另配本机 TLS。长映射域名使用 `server_names_hash_bucket_size 128`，不要在其它 http 级配置中重复定义。

后台环境配置已添加新映射域名的 HTTPS CORS 来源。修改前的 Nginx 配置和 root-only 环境文件备份在 `/root/chatai-public-20261019/new-domain.XpheusHk/`，原有 `127.0.0.1:8080` 隧道入口保留。

公网验收脚本与无凭据结果保存在 `/root/chatai-public-20261019/verify-new-domain.py` 和 `new-domain-verification.json`。37 项全部通过，包括 PostgreSQL 健康、登录页与所有引用静态资源、未登录鉴权拒绝、管理员登录、Next.js API 转发及主要管理接口。Mac 浏览器实际登录并显示仪表盘，临时凭据文件已删除。

旧映射 `01a134db158e7762b017af8a3940002c.cn-hongkong-2.r4j2x7.top` 后来在上游返回 404，请求未到达本机 Nginx；当前使用上面的新映射。网关配置保留旧主机名，但不代表上游仍为它提供映射。自有域名路由由独立 TLS 配置管理。

## 尚需配置

初始部署时 AI 服务商 Key 与 SMTP 未配置；尚未验证真实模型推理或邮件投递。当前标准 HTTPS 的服务器侧、Mac 正常网络、Chrome 官网/后台及真实 Flutter 登录集成验收已通过；Android +14 仍为 Debug 签名体验包，没有 Android 真机验收。早先带端口及 iOS 模拟器的结果保留为历史证据，不替代新地址的设备界面验收。

Flutter 当前生产 origin 为 `https://kushui.shop`。此前已添加带端口的生产构建配置，并修复登录后请求缺少 Bearer JWT 导致的 401。真实 Flutter 公网验收通过登录、受保护模型清单、未登录 401 及普通用户访问管理接口 403；iOS 模拟器原生界面登录、冷启动恢复和退出登录均通过。临时测试账号和本地、服务器临时凭据已清理。

Android `1.0.4+14` 已构建并通过签名、联网权限及 AOT 新地址检查，仍使用项目原有 debug 签名；Android/iOS 真机与 HarmonyOS 尚未验收。macOS 构建完成但独立启动受现有 Keychain entitlement 的签名要求阻止，尚需配置签名身份及 provisioning。启动命令、安装包信息、测试边界和后续官网规划见 [Flutter 部署说明](../flutter/README.md)。

## 运维命令

以下在服务器执行，sudo 会要求 deploy 的密码；也可使用已配置的 root 密钥完成管理。

```bash
systemctl is-active chatai-deep-api chatai-deep-admin nginx
curl -f http://127.0.0.1:8080/healthz
sudo journalctl -u chatai-deep-api -u chatai-deep-admin -n 100 --no-pager
sudo systemctl restart chatai-deep-api chatai-deep-admin
sudo bash /opt/chatai-deep/current/deploy/ubuntu/backup.sh
```

本次初始化/构建日志和不含凭据的服务端验收记录分别位于 root 私有目录：

- `/root/chatai-bootstrap-20261018/deployment.log`
- `/root/chatai-bootstrap-20261018/verification.json`

后续更新与恢复使用同目录下 [README.md](README.md) 的步骤。数据库与 `APP_SECRET_KEY` 必须一起备份，不要直接把 `current` 切到旧代码来回滚数据库变更。

本次上传源码包的 SHA-256：`504370c3144c02af2c6f964400455efb48bca949d1bf3f368e59e08ddee732ee`。
