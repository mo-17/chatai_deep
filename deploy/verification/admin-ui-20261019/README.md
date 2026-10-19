# 后台样式修复部署与验收

日期：2026-10-19。公网后台 `https://kushui.shop/login`，继续使用七牛香港共享 IP、Cloudflare Free 和严格 HTTPS。

- 应用版本：`/opt/chatai-deep/releases/20261019T002542Z.Bh12fxpT`。
- 切换前一致备份：`/var/backups/chatai-deep/20261019T002608Z.Nmxu6a0y`，摘要、COMPLETE 标记及 PostgreSQL 归档可读性已检查。
- 旧版本：`20261018T225542Z.LDPtKYlA`，保留供应用回滚，不回滚数据库。
- 根因：源码打包漏掉 `.npmrc`，线上 `publicHoistPattern: []`，HeroUI 样式源目录缺失；CSS 仅 33,322 字节。
- 修复：打包保留配置；安装依赖后验证样式源，部署前验证按钮高度/宽度/前景色及输入框标签状态 CSS。侧栏独立滚动，头部/底部不收缩，正文在可用宽高内滚动。
- 新 CSS：`ed910ceba16599f4.css`，238,413 字节，四组组件样式检查通过；旧错误 CSS 被检查程序拒绝。
- 源码边界：基于线上源码构建，摘要确认后端源文件无变更，后台仅变更 Sidebar、Topbar、DashboardLayout 三处布局；没有打入本地其它功能改动。

| 检查 | 结果 |
| --- | --- |
| 部署回归 | 23 项通过，包括漏配置打包、缺样式成品拒绝和部署失败路径 |
| 后台类型检查、lint | 通过 |
| Ubuntu Node22 / pnpm10 固定依赖构建 | 通过，独立类型检查通过 |
| `admin-api.json` | 37/37；登录、资源、管理员接口、鉴权及数据库健康 |
| `website.json` | 53/53；标准 HTTPS、官网、下载与路由 |
| `browser.json` | Chrome 正常登录、标签不重叠、按钮 40px/白字，列表/弹窗/下拉菜单正常 |
| 侧栏 | 容器与底部均为 681px；菜单区域 552px、内容 760px，可独立滚动到 208px，底部保持可见；页面无横向溢出 |
| 浏览器控制台 | 验收过程 0 条 error |

试用和额度开关仍开启（每日 10,000 Token），generic SMTP 仍启用且测试状态 ok；+15 仍全量、+16 仍 0%，数据库迁移总数 11。本次不重做真实模型或邮件调用，不修改已有模型、Key、SMTP 或版本推送设置。浏览器新增弹窗只查看后关闭，没有保存测试记录。

验收管理员已退出当前测试标签；两端临时管理员凭据及重复构建目录已清理，用户自己的配置标签保留。截图在本聊天可视化目录：`admin-ui-fixed-login.png`、`admin-ui-fixed-dashboard.png`、`admin-ui-fixed-model-dialog.png`、`admin-ui-fixed-provider-dialog.png`。
