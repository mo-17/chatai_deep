# Android 客户端检查、灰度与升级

当前官网下载版本为 **1.0.6+16**，后端使用 `https://kushui.shop`。自动推送保持 **0%**，待 Android 真机覆盖升级及数据保留验收；上一全量 **1.0.5+15** 保留给旧客户端更新。

本地最新 `1.0.9+19` 候选增加可信知识助手，包含 +18 连续语音和 +17 试用引导；尚未上传或注册，不改变本页的线上版本。版本、可信边界和验收见 [知识助手说明](../../docs/trusted-knowledge-assistant.md)，连续语音见 [语音说明](../../docs/continuous-voice.md)。+17 的历史记录见 [试用操作说明](../../docs/trial-operations.md)。

本功能为整包升级：检查版本、展示说明、暂停/继续下载、SHA-256 校验、打开 Android 系统安装界面，由用户确认覆盖安装。Flutter 免安装 Dart 补丁尚未接入。

## 用户怎么更新

1. 从 [官网下载区](https://kushui.shop/#download) 选择 Android 64 位包（多数手机）；其它架构可展开选择。不要卸载旧应用或清除数据。
2. 应用中「我的 → 检测更新」显示真实版本和 build number；正式放量后按安装标识稳定命中灰度。
3. 点击更新下载，支持暂停后继续；必须完成整包 SHA-256 校验才能交给系统安装。系统的来源安装权限与最终安装由用户确认。
4. 进入首页会自动检查一次；无更新或自动检查失败时不打断使用。手动检查失败可重试，调试构建不自动请求生产更新。
5. 旧 `:10084` 客户端无法通过 Cloudflare 边缘请求接口时，先从官网覆盖安装，再使用标准 HTTPS。

升级包沿用原 direct 包名和历史签名，签名检查已经通过；实际覆盖后的数据保留仍需设备验收。当前所有包为原有 Debug 签名体验包，商店发布需按 [正式签名说明](../../docs/android-release-signing.md) 配置；不能直接更换签名覆盖已有安装。

## 当前发布

| 项目 | 当前值 |
| --- | --- |
| versionName / versionCode | `1.0.6` / `16`，四个 APK 相同 |
| 渠道 cid / 记录 ID | `321` / `2` |
| forceUpdate / rolloutPercent | `false` / `0` |
| ARM64 / 32 位 ARM | 64,420,181 / 53,708,105 字节 |
| x86_64 / 通用包 | 71,876,813 / 180,471,259 字节 |
| 下载前缀 | `https://kushui.shop/downloads/aipu-1.0.6-16-` |
| 元数据 | `website/site-assets/release.json`，含四架构 URL / 大小 / SHA-256 |
| 旧全量 | `1.0.5+15`，记录 ID `1`，100%，非强制 |

离线语音 ONNX 权重不再进入 APK。模型经明确确认后从官网下载、校验和安装，约 125 MB；旧版已解压的模型继续兼容。

匿名检查示例：

```text
GET /uapi/checkUpdate?cid=321&version=1.0.5&versionCode=15&channel=direct&platform=android&abi=arm64-v8a&installationId=<随机安装标识>
```

安装标识为客户端首次生成并保存的随机值。服务端按版本、批次盐和安装标识确定灰度，不能随请求随机变化；没有安装标识的旧客户端只接收 100% 版本。版本暂停为 0%，即使 forceUpdate 也不推送；同渠道仍会回退到此前可用的全量版本。当前 +14 检查仍可得到 +15，+16 不会降级。Store 渠道不会收到 direct APK。

## 下一版怎么发布

1. 核对 `chatgpt_flutter/pubspec.yaml`，当前候选为 `1.0.9+19`，后续新版本 build number 必须严格递增。先完成该候选的真机和真实模型质量验收。
2. 在仓库根目录执行：

   ```bash
   bash deploy/flutter/build-release.sh 16 '<更新说明>' /tmp/chatai-client-release19
   ```

   脚本分别构建通用、ARM64、32 位 ARM 和 x86_64，所有 APK 同一版本码。不要直接发布 Flutter `--split-per-abi` 生成的 1000/2000/4000 偏移版本码。脚本核对真实包名、历史签名、版本、架构和 SHA，并拒绝打包 ONNX 权重或覆盖同名不同内容文件。

3. 生成官网元数据和下载文字：

   ```bash
   python3 deploy/flutter/prepare-website.py \
     --manifest /tmp/chatai-client-release19/release.json --website website
   ```

4. 用现有 SSH 密钥把 APK、摘要文件及官网源码上传到服务器私有暂存目录；先核对每个文件摘要，再以不可变文件名发布到 `/var/www/chatai-website/downloads/`。保留旧包。
5. 使用 [官网发布脚本](../ubuntu/WEBSITE.md) 原子切换官网，参数传该版本通用包；它与元数据的回退下载 URL / 摘要对应。不要把未核验的源码目录或私有配置放到公网。
6. 登录 [版本管理](https://kushui.shop/versions)，手动导入该目录的 `release.json`。核对四架构 URL、摘要、版本和渠道，保持灰度 0%。浏览器自动文件上传因扩展权限未完成验收，人工文件选择不依赖本聊天的自动化权限。
7. 先检查官网、真实下载/续传、旧/当前/未来版本协议，再在 Android 真机执行覆盖安装与数据保留清单。具体清单见 [P0/P1 交付记录](../../docs/p0-p1-delivery.md)。
8. 验收后逐步调整为 5%、20%、100%。保持灰度批次盐不变，避免用户在同一轮反复进出分组；后台随时可暂停推送。暂停不撤回已下载文件，也不能自动降级已安装版本。

只增加 pubspec 版本或只上传 APK 都不会让旧客户端发现更新，必须同步后台记录。数据库迁移为加法变更，回滚应用不删除新增表/列。

## 验证和本次证据

本轮：后端 582 项、客户端联合回归 74 项；独立 PostgreSQL 事务 5 项、生产灰度 8 项、官网 53 项均通过。真实 Flutter 登录、双客户端同步、语音模型完整下载/安装和新版 ARM64 暂停/续传/整包 SHA 验收分别通过；不累计为真机证明。设备覆盖升级和语音播放尚未验收。

从 `chatgpt_flutter/` 执行：

```bash
fvm flutter test ../chatgpt_app_core/test/app_update_controller_test.dart \
  ../chatgpt_app_core/test/apk_update_dao_test.dart \
  ../hi_download/test/hi_download_test.dart --no-pub

CHATAI_RELEASE_MANIFEST=../website/site-assets/release.json \
  fvm flutter test ../chatgpt_app_core/test/production_release_download_live_test.dart \
  --dart-define-from-file=../deploy/flutter/production.json --no-pub
```

第二条会实际下载当前 ARM64 包，默认未设置环境变量则跳过，结束清理临时下载。该用例目前断言 build 16，后续版本要同步断言。`production_update_live_test.dart` 仍验证全量 +15；本轮 `register-release.py` 用于 +16 的注册及独立灰度验收，也需随下一次正式放量调整固定的上一全量断言。

服务器应用版本为 `/opt/chatai-deep/releases/20261019T002542Z.Bh12fxpT`（后台样式修复）；官网为 `/var/www/chatai-website/releases/20261018T230810Z.P2uRXQlW`。客户端仍为 +16 体验包、自动推送 0%。运维见 [部署教程](../ubuntu/DEPLOYMENT_GUIDE.md)、[官网发布](../ubuntu/WEBSITE.md) 和 [服务器交接](../ubuntu/SERVER.md)。
