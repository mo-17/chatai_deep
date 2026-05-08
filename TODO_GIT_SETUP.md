# Git 入库待办

本文件记录两组待执行任务，供另一个模型按顺序完成。所有路径均相对仓库根目录 `/Users/huangzhibin/AndroidStudioProjects/flutter/chatai_deep/`。

## 背景速览

仓库结构：

```
chatai_deep/
├── chatgpt_flutter/      # 主 Flutter 工程（已有独立 .git，已配 .gitignore）
├── chatgpt_backend/      # NestJS 后端
├── openai_flutter/       # 主工程依赖：OpenAI SDK
├── chat_message/         # 主工程依赖：聊天 UI
├── login_sdk/            # 主工程依赖：登录
├── hi_download/          # 主工程依赖：APK 下载
├── chat_db/              # 课程独立 demo 包（主工程未依赖）
└── flutter_network/      # 课程独立 demo 包（主工程未依赖）
```

`chatgpt_flutter/.gitignore` 已在前一轮更新过，里面已涵盖标准 Flutter 模板 + `coverage/`、`.fvm/`、`devtools_options.yaml`、`.env*`、`*.bak`、`Thumbs.db` 等增量规则，本次任务**不要再动它**。

---

## 任务 A：保护 `chatgpt_flutter` 中的 OpenAI API Key

### 背景
`chatgpt_flutter/lib/util/hi_const.dart` 里 `HiConst.apiKey` 是 OpenAI 密钥占位符（当前值：`'改为你的openai 秘钥'`）。

该文件被 `chatgpt_flutter/lib/main.dart` 直接 `import`，**不能整体 gitignore**，否则编译报错。需要改成「示例文件入库 + 真实文件忽略」的模式。

### 步骤

1. **新建示例文件** `chatgpt_flutter/lib/util/hi_const.example.dart`
   - 内容与当前 `hi_const.dart` 完全相同（占位符版本），保留中文注释
   - 这是**入库**的模板

2. **保留 `chatgpt_flutter/lib/util/hi_const.dart` 在工作区**（不要删除，否则编译失败），但把它加入忽略：
   - 在 `chatgpt_flutter/.gitignore` 末尾追加：
     ```
     # 本地 OpenAI API Key，请勿提交。复制 hi_const.example.dart 后填入
     /lib/util/hi_const.dart
     ```
   - 路径前缀的 `/` 是为了只匹配 `chatgpt_flutter/lib/util/hi_const.dart`，避免误伤其它子包同名文件（虽然目前没有，预防性写法）

3. **验证忽略生效**：
   ```bash
   cd chatgpt_flutter
   git check-ignore -v lib/util/hi_const.dart
   # 期望输出: .gitignore:<行号>:/lib/util/hi_const.dart   lib/util/hi_const.dart
   ```

4. **更新主工程 README** `chatgpt_flutter/README.md`，在 `## 仓库介绍` 之后追加一节：
   ```markdown
   ## 本地配置
   首次 clone 后，复制示例文件并填入自己的 OpenAI 密钥：
   ```bash
   cp lib/util/hi_const.example.dart lib/util/hi_const.dart
   ```
   然后编辑 `lib/util/hi_const.dart`，把 `apiKey` 改成你自己的 key（从 https://platform.openai.com/account/api-keys 获取）。
   该文件已加入 `.gitignore`，不会被误提交。
   ```

5. **同步更新仓库根 `CLAUDE.md`**：
   - 找到「Wiring you must do before the app runs」一节里关于 OpenAI key 的第 1 条
   - 把描述改成「复制 `lib/util/hi_const.example.dart` 为 `lib/util/hi_const.dart` 并填入真实 key；后者已被 `.gitignore`，前者保留占位符入库」

### 验收标准
- `git status` 在 `chatgpt_flutter/` 下不再显示 `lib/util/hi_const.dart`
- `lib/util/hi_const.example.dart` 是新文件，等待入库
- `flutter analyze` 仍然通过（说明真实文件还在工作区）

---

## 任务 B：为其它子包初始化各自的 `.gitignore` 与 git 仓库

### 决策点（开工前请先与用户确认）
当前只有 `chatgpt_flutter/` 是独立 git 仓库。其它包要不要各自独立入库？两种方案：

- **方案 1（推荐）**：每个包独立 `git init`，各自 push 到独立远程仓库。匹配课程「组件化」结构，主工程通过 `path:` 依赖。
- **方案 2**：仓库根目录统一 `git init`，作为 monorepo 一并管理。这种情况下 `chatgpt_flutter/.git` 需要先移除，且根目录 `.gitignore` 要合并各子包规则。

**默认按方案 1 执行**。如用户选方案 2，跳过本任务等待新指令。

### 各包对应的 `.gitignore` 模板

下表列出每个包需要写入 `<package>/.gitignore` 的内容。如已存在 `.gitignore`，请合并去重，不要覆盖。

#### B1. Flutter 包（`openai_flutter/`、`chat_message/`、`login_sdk/`、`hi_download/`、`chat_db/`、`flutter_network/`）

这些都是 Flutter package（非 application），共用同一份模板。每个包根目录写入：

```gitignore
# Files and directories created by pub.
.dart_tool/
.packages
.pub-cache/
.pub/
build/
pubspec.lock         # 库类型工程不提交 lockfile

# IntelliJ / Android Studio
*.iml
*.ipr
*.iws
.idea/

# VS Code
.vscode/

# macOS
.DS_Store

# Flutter generated
.flutter-plugins
.flutter-plugins-dependencies
**/doc/api/

# Symbolication / Obfuscation
app.*.symbols
app.*.map.json

# 编辑器备份
*.bak
*.orig
*~
```

注意：
- **`pubspec.lock` 故意忽略**：这些是 library 性质的包，按 Dart 官方建议不入库 lockfile（与 `chatgpt_flutter` 这种 application 不同）。
- 如果某个包当前已经把 `pubspec.lock` 提交了，需要 `git rm --cached pubspec.lock` 后再写忽略。

#### B2. NestJS 后端 `chatgpt_backend/`

```gitignore
# 依赖
node_modules/

# 构建产物
dist/
build/

# 日志
logs/
*.log
npm-debug.log*
yarn-debug.log*
yarn-error.log*
pnpm-debug.log*

# 测试覆盖率
coverage/
*.lcov

# IDE
.idea/
.vscode/
*.iml
*.swp

# OS
.DS_Store
Thumbs.db

# 环境变量
.env
.env.*
!.env.example

# TypeScript 增量编译缓存
*.tsbuildinfo
```

后端的 `package-lock.json` **要保留入库**（应用工程，需锁定依赖版本）。

### 步骤

对 `openai_flutter`、`chat_message`、`login_sdk`、`hi_download`、`chat_db`、`flutter_network`、`chatgpt_backend` 七个包，各自执行：

1. 切到包目录：`cd <package>`
2. 检查是否已有 `.gitignore`：
   - 若无 → 直接按 B1/B2 模板写入
   - 若有 → 读取现有内容，合并去重后写回
3. 检查是否已有 `.git/`：
   - 若无 → `git init`，然后 `git add .`，但**先**确认 `git status` 里没有 `node_modules/`、`build/`、`.dart_tool/` 等不该入库的内容
   - 若有 → 跳过 `git init`，但若上一步合并了新规则，对已被误跟踪的文件执行 `git rm --cached <path>`（典型：`pubspec.lock`、`node_modules/`）

### 特别注意
- **不要执行 `git commit`**，留给用户审阅后自行提交
- **不要执行 `git remote add` 或 `git push`**，远程仓库地址由用户决定
- **不要触碰 `chatgpt_flutter/`**，它已配置好

### 验收标准
对七个包逐个验证：
```bash
cd <package>
git status                              # 工作区干净，未跟踪列表里没有 node_modules/build/.dart_tool 等
git ls-files | grep -E '(node_modules|/build/|\.dart_tool|pubspec\.lock)' && echo "FAIL" || echo "OK"
```
对 Flutter 包，`pubspec.lock` 不应出现在 `git ls-files` 输出中。
对后端，`node_modules/`、`dist/` 不应出现。

---

## 执行顺序建议

1. 先做任务 A（影响 `chatgpt_flutter` 安全性，且范围小）
2. 再与用户确认方案 1/2，然后做任务 B
3. 完成后输出一份简短报告：每个包的 `.gitignore` 改动行数 + `git status` 摘要
