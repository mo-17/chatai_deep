# 试用引导、运行监控和风控验收

日期：2026-10-19。当前应用 `/opt/chatai-deep/releases/20261019T010046Z.HZTlt5UL`；上版 `20261019T002542Z.Bh12fxpT` 保留供应用回滚。

基于线上源码隔离构建，只覆盖 14 个明确文件，未发布其它工作区改动，未提交或推送 Git。`source-manifest.json` 的 14 个摘要与生产一致。新增 `TrialGuardrails1784130000000` 加法迁移，总计 12 个迁移，没有新增表或删除业务数据。

一致备份 `/var/backups/chatai-deep/20261019T010112Z.sgzdT8zt` 的 COMPLETE、三份 SHA-256、PostgreSQL 归档可读性检查通过。API/admin/Nginx/PostgreSQL/Certbot timer 均 active；本轮构建暂存已删除，服务器剩余约 4.1 GiB。共享 IP、Cloudflare Free、DNS/续期配置及暂停的自动任务保留。

| 验收 | 结果 / 文件 |
| --- | --- |
| 后端完整默认回归 | 53 集 / 587 项通过，20 集 / 329 项环境专用测试默认跳过；`local-tests.json` |
| 隔离 PostgreSQL | 8 项通过：迁移保留、资格、频率、跨实例并发及原有预算/反馈；专用实例已停止 |
| Flutter | 14 项回归通过；3 个修改文件 analyze 无问题 |
| 后台 / Ubuntu | lint、独立 typecheck、固定依赖 webpack 构建及 CSS 成品检查通过 |
| 部署合同 | 23 项通过 |
| 管理员/API | `admin-api.json`：37/37 |
| 官网站点 / 当前下载 | `website.json`：53/53，匹配公开 +16 包 |
| 未验证邮箱及监控权限 | `operations-unverified.json`：13/13，包含试用别名/真实模型、JSON/SSE 拒绝 |
| 已验证邮箱及额度 | `operations-verified.json`：9/9，只查询，不发起推理 |
| Flutter 公网登录 | 1 个集成用例通过：真实 TLS、登录、目录、管理权限 403、退出后 401 |
| 浏览器 | `browser.json`：监控、刷新开关、风控表单、标题和模型弹窗正常；console error 0 |
| 清理 | `cleanup.json`：临时账号删除、旧 JWT 401、usage/预留均为 0、两端凭据删除 |

页面宽度与内容宽度同为 1,384px；主内容宽与 scrollWidth 同为 1,160px；监控表格 6 行。侧栏高 681px，菜单可用 552px、内容 800px，底部保持在 681px。模型弹窗填写后 labelBottom 210.5px < inputTop 212.5px。退出访问 `/operations` 回到登录页，按钮 40px、最小宽 80px、白字。

截图位于本聊天可视化目录：`aipu-operations-20261019.png`、`aipu-trial-guardrails-20261019.png`。未保存浏览器测试表单，本轮没有新的模型收费调用或 SMTP 投递。

Android `1.0.7+17` 是未发布通用候选包，180,471,263 字节，SHA-256 `638a0baf54f17d7ba4a79c898617f5d7862ea59d71abe2436576282cd8bb79d6`，三个 ABI、历史签名匹配，AOT 含新试用入口与示例文案。没有连接 Android 真机，原生首聊、覆盖升级、数据保留和音频未验收。官网 +16、+16 推送 0% 和 +15 全量保留；+17 未上传、未注册。

操作与真机步骤见 [试用与运行监控](../../../docs/trial-operations.md)。HTTP 统计为进程内存数据，重启清零；页面警告不自动发送外部通知，未配置第三方人机验证或设备指纹。
