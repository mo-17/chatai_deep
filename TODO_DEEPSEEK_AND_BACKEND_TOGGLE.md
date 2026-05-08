# DeepSeek 集成 + 本地/后端切换

本文件供另一个模型按顺序执行。所有路径相对仓库根目录 `/Users/huangzhibin/AndroidStudioProjects/flutter/chatai_deep/`。

---

## 1. 背景与目标

### 现状
- `chatgpt_flutter` 主工程仅支持直连 OpenAI（`AIConfigBuilder` + `AICompletion` 单例风格）
- API key 来自 `lib/util/hi_const.dart`（已经在 git 忽略，模板是 `hi_const.example.dart`）
- 用户没有 OpenAI key，只有 DeepSeek key

### 目标
- **支持 DeepSeek**：DeepSeek API 与 OpenAI Chat Completions **完全兼容**（同 schema），只需把 `baseUrl` 和 `model` 参数化即可，不要新建 `deepseek_flutter` 包
- **本地/后端切换**：用户可选
  - **本地（local）**：在 App 里填自己的 key，App 直接 POST 到 OpenAI/DeepSeek 端点
  - **后端（backend）**：App 走 `chatgpt_backend` 转发，后端用服务端统一 key 调上游
- **后端记录用量**（为未来计费铺垫，**本次不做计费 UI 也不做扣费逻辑**）

### 不做的事（划清边界）
- ❌ 不实装计费/扣费/支付
- ❌ 不重写聊天记录表结构
- ❌ 不删 `hi_const.example.dart`
- ❌ 不引入新的状态管理库（继续用 `provider`）
- ❌ 不新建独立 SDK 包

---

## 2. 架构

### 2.1 数据流
```
[ConversationPage]
    ↓
[CompletionDao]            ← 不感知具体 provider
    ↓
[ChatService] (interface)
    ├─ DirectChatService   → 直连 OpenAI / DeepSeek（用 openai_flutter SDK）
    └─ BackendChatService  → POST chatgpt_backend /uapi/chat/completions
```

### 2.2 设置数据结构（HiCache key: `ai_settings_v1`，存 JSON 字符串）
```jsonc
{
  "mode": "local",                 // "local" | "backend"
  "localProvider": "deepseek",     // "openai" | "deepseek"，仅 mode=local 时生效
  "openai": {
    "apiKey": "",
    "baseUrl": "https://api.openai.com/v1/chat/completions",
    "model": "gpt-3.5-turbo"        // 用户从下拉清单选，也可手填自定义
  },
  "deepseek": {
    "apiKey": "",
    "baseUrl": "https://api.deepseek.com/chat/completions",
    "model": "deepseek-chat"
  },
  "backendModel": "deepseek-chat"  // mode=backend 时使用；后端按前缀路由到对应上游
}
```

**模型字段是字符串，不做枚举绑定**——这样未来上游加新模型时不需要改 App。UI 层提供「常用模型下拉」+「自定义输入」两种方式，详见任务 6。

### 2.3 后端代理契约
```
POST /uapi/chat/completions
Headers:
  Authorization: Bearer <boardingPass>     # 现有 JWT
  Content-Type: application/json
Body: 透传 OpenAI Chat Completions 请求体（model + messages + max_tokens + ...）

成功:
  { "code": 0, "data": <上游原始响应>, "extra": { "usageMs": 123 } }
失败:
  { "code": <非0>, "message": "..." }      # 401 未登录、429 配额（占位）、502 上游故障
```

### 2.4 模型 → 上游 provider 路由（后端写死表）
| 请求 model 前缀 | 上游 |
|-|-|
| `gpt-*`、`o1-*`、`chatgpt-*` | OpenAI |
| `deepseek-*` | DeepSeek |
| 其它 | 默认 DeepSeek（可在 env 里配置 `BACKEND_DEFAULT_PROVIDER`） |

### 2.5 后端环境变量（新增）
```
OPENAI_API_KEY=sk-...
OPENAI_BASE_URL=https://api.openai.com/v1     # 可选，默认值即此
DEEPSEEK_API_KEY=sk-...
DEEPSEEK_BASE_URL=https://api.deepseek.com    # 可选
BACKEND_DEFAULT_PROVIDER=deepseek
```
后端用 `@nestjs/config`（已在 `package.json` 里）。同时新增 `chatgpt_backend/.env.example` 模板入库，`.env` 仍然忽略（任务 B 已在 `.gitignore` 里覆盖）。

---

## 3. 任务列表

### 任务 1：`openai_flutter` 通用化 —— per-instance 配置

**动机**：当前 `AIConfigBuilder` 是单例，只能持有一组 key/url。要支持「OpenAI、DeepSeek、后端」三种调用，必须改成可多实例。

**改动文件**：
- `openai_flutter/lib/http/ai_config.dart`
- `openai_flutter/lib/http/ai_http.dart`
- `openai_flutter/lib/core/ai_completions.dart`
- `openai_flutter/lib/core/interfaces/ai_create.dart`（如有）

**步骤**：

1. **重构 `AIConfigBuilder`** 为可实例化的配置容器（保留类名以减少调用方改动），废弃 `static` 单例：
   ```dart
   class AIConfigBuilder {
     final String apiKey;
     final String chatUrl;
     final String? proxy;
     final String? organization;

     AIConfigBuilder({
       required this.apiKey,
       required this.chatUrl,
       this.proxy,
       this.organization,
     });

     Map<String, String> headers() {
       final h = <String, String>{
         'Content-Type': 'application/json',
         'Authorization': apiKey.startsWith('Bearer ') ? apiKey : 'Bearer $apiKey',
       };
       if (organization != null) h['OpenAI-Organization'] = organization!;
       return h;
     }
   }
   ```
   删掉 `init()` 静态方法、`_instance`、`setProxy()` 等单例 API。

2. **`AIHttp`** 改成接受 `AIConfigBuilder` 实例参数，不再读全局：
   ```dart
   class AIHttp {
     static Future<T> post<T>({
       required AIConfigBuilder config,
       required String url,
       required Map<String, dynamic> body,
       required T Function(Map<String, dynamic>) onSuccess,
     }) async { ... }
   }
   ```
   `proxy` 在内部沿用之前对 `HttpClient` 的设置逻辑。

3. **`AICompletion`** 持有 config：
   ```dart
   class AICompletion {
     final AIConfigBuilder config;
     AICompletion(this.config);

     Future<AIResponse> createChat({
       required String prompt,
       String model = 'gpt-3.5-turbo',
       int? maxTokens = 1000,
       List<Map<String, String>>? messages,    // 新增：允许直接传 messages 数组
       double? temperature,
       ...
     }) { ... }
   }
   ```
   - `model` 参数继续保留默认值，调用方按需传
   - 新增 `messages` 直传（OpenAI Chat 协议天然多轮，比拼 prompt 字符串干净）；如果传了 `messages` 就忽略 `prompt`，否则用旧的单条 user 包裹逻辑
   - URL 用 `config.chatUrl`，不要再 hard-code

4. **不要保留向后兼容垫片**：旧的 `AIConfigBuilder.init()` / `AIConfigBuilder.instance` 直接删除，调用方在任务 6 一并改。

**验收**：`flutter analyze` 在 `openai_flutter/` 通过；`openai_flutter_test.dart` 如果被改坏，更新或删除测试。

---

### 任务 2：`chatgpt_flutter` 新增 `AISettings` 模型与持久化

**新增文件**：
- `chatgpt_flutter/lib/model/ai_settings.dart`
- `chatgpt_flutter/lib/dao/ai_settings_dao.dart`

#### 2.1 `model/ai_settings.dart`
```dart
enum AIMode { local, backend }
enum LocalProvider { openai, deepseek }

class ProviderConfig {
  String apiKey;
  String baseUrl;
  String model;
  ProviderConfig({required this.apiKey, required this.baseUrl, required this.model});
  factory ProviderConfig.fromJson(Map<String, dynamic> j) => ...;
  Map<String, dynamic> toJson() => ...;
}

class AISettings {
  AIMode mode;
  LocalProvider localProvider;
  ProviderConfig openai;
  ProviderConfig deepseek;
  String backendModel;             // mode=backend 时使用的模型名

  AISettings({...});

  factory AISettings.defaults() => AISettings(
    mode: AIMode.local,
    localProvider: LocalProvider.deepseek,
    openai: ProviderConfig(
      apiKey: '',
      baseUrl: 'https://api.openai.com/v1/chat/completions',
      model: 'gpt-3.5-turbo',
    ),
    deepseek: ProviderConfig(
      apiKey: '',
      baseUrl: 'https://api.deepseek.com/chat/completions',
      model: 'deepseek-chat',
    ),
    backendModel: 'deepseek-chat',
  );

  factory AISettings.fromJson(Map<String, dynamic> j) => ...;
  Map<String, dynamic> toJson() => ...;

  /// 当前生效的 provider 配置（仅 mode=local 时调用方应使用）
  ProviderConfig get activeLocal =>
      localProvider == LocalProvider.openai ? openai : deepseek;

  /// 当前实际要发给上游的模型名（mode 不同来源不同）
  String get effectiveModel =>
      mode == AIMode.backend ? backendModel : activeLocal.model;
}
```

#### 2.2 `dao/ai_settings_dao.dart`
```dart
class AISettingsDao {
  static const _kKey = 'ai_settings_v1';

  static AISettings load() {
    final raw = HiCache.getInstance().get(_kKey);
    if (raw == null) return AISettings.defaults();
    try {
      return AISettings.fromJson(jsonDecode(raw));
    } catch (_) {
      return AISettings.defaults();
    }
  }

  static Future<void> save(AISettings s) async {
    await HiCache.getInstance().setString(_kKey, jsonEncode(s.toJson()));
  }
}
```

**注意**：
- `HiCache` 调用模式参考现有 `LoginDao._saveUserInfo` 的写法
- 不做 `hi_const.dart` 旧 key 的迁移（`HiConst.apiKey` 此后仅作为开发期默认 fallback，**不再被 main.dart 使用**）

---

### 任务 3：`AISettingsProvider`（状态广播）

**新增文件**：`chatgpt_flutter/lib/provider/ai_settings_provider.dart`

```dart
class AISettingsProvider extends ChangeNotifier {
  AISettings _settings = AISettings.defaults();
  AISettings get settings => _settings;

  Future<void> load() async {
    _settings = AISettingsDao.load();
    notifyListeners();
  }

  Future<void> update(AISettings next) async {
    _settings = next;
    await AISettingsDao.save(next);
    notifyListeners();
  }
}
```

**注册到 `lib/provider/hi_provider.dart`**：
```dart
List<SingleChildWidget> mainProviders = [
  ChangeNotifierProvider(create: (_) => ThemeProvider()),
  ChangeNotifierProvider(create: (_) => AISettingsProvider()..load()),
];
```

---

### 任务 4：`ChatService` 抽象与三种实现

**新增目录**：`chatgpt_flutter/lib/dao/chat/`
- `chat_service.dart`（抽象 + 工厂）
- `direct_chat_service.dart`
- `backend_chat_service.dart`

#### 4.1 `chat_service.dart`
```dart
abstract class ChatService {
  /// 多轮聊天接口；history 是按时间正序的 [{role, content}]
  Future<String?> chat({
    required String prompt,
    required List<Map<String, String>> history,
  });

  /// 工厂：根据当前 AISettings 决定返回哪个实现
  factory ChatService.from(AISettings s) {
    if (s.mode == AIMode.backend) return BackendChatService();
    return DirectChatService(s.activeLocal);
  }
}
```

#### 4.2 `direct_chat_service.dart`
- 用 `AICompletion(AIConfigBuilder(apiKey: cfg.apiKey, chatUrl: cfg.baseUrl))` 调用
- `messages` 参数直接传入 `[...history, {role: user, content: prompt}]`
- 解析 `response.choices.first.message.content`
- 抛错时透传 `Exception(原始 body)`

#### 4.3 `backend_chat_service.dart`
- 调用 `POST localhost:3000/uapi/chat/completions`
- Header：`hiHeaders()`（来自 `login_sdk`，包含 boardingPass） + `Content-Type: application/json`
- Body：`{ model, messages: [...history, {role:user, content:prompt}], max_tokens: 1000 }`
  - `model`：从 `AISettings.effectiveModel` 取（即 `backendModel` 字段），用户在设置页通过下拉切换；后端按 model 前缀路由到对应上游
- 解析 `result['data']['choices'][0]['message']['content']`
- 401 时调 `LoginDao.logOut()`（参考现有 401 处理模式，如果不存在就只抛错）

#### 4.4 `direct_chat_service.dart` 中模型来源
- `cfg.model`（即 `AISettings.activeLocal.model`）作为 `AICompletion.createChat(model: cfg.model)` 传入
- 不再硬编码 `'gpt-3.5-turbo'`

**修改**：把硬编码的 `localhost:3000` 抽到一个常量 `BackendConst.host = 'localhost:3000'`，放在 `lib/util/hi_const.dart` 或新建 `lib/util/backend_const.dart`。后续 `NoticeDao`、`ApkUpdateDao`、`LoginDao` 也统一改用这个常量（可作为本任务顺带的小重构，**仅当不增加超过 5 行改动**）。

---

### 任务 5：后端 `/uapi/chat/completions` 端点

**新增目录**：`chatgpt_backend/src/chat/`
- `chat.controller.ts`
- `chat.service.ts`
- `chat.module.ts`
- `usage.entity.ts`（用量记录，留作将来计费用）

#### 5.1 `usage.entity.ts`
```ts
@Entity()
export class Usage {
  @PrimaryGeneratedColumn() id: number;
  @Column() userId: number;
  @Column() provider: string;          // 'openai' | 'deepseek'
  @Column() model: string;
  @Column() promptTokens: number;
  @Column() completionTokens: number;
  @Column() totalTokens: number;
  @CreateDateColumn() createdAt: Date;
}
```

#### 5.2 `chat.service.ts`
- 注入 `ConfigService`、`Usage` Repository
- `complete(userId, body)` 流程：
  1. 按 `body.model` 前缀决定 `provider`，若无前缀匹配用 `BACKEND_DEFAULT_PROVIDER`
  2. 取对应 `apiKey`、`baseUrl`
  3. `fetch`（Node 18+ 内置）POST 到 `${baseUrl}/chat/completions`，带 `Authorization: Bearer ${apiKey}`，body 透传
  4. 拿到响应后写一条 `Usage`（从 `response.usage` 读 token 数）
  5. 返回上游原始 JSON

#### 5.3 `chat.controller.ts`
```ts
@Controller('uapi/chat')
export class ChatController {
  constructor(private readonly svc: ChatService) {}

  @Post('completions')
  @UseGuards(JwtGuard)              // 新增 Guard，见下
  async completions(@Req() req, @Body() body) {
    const data = await this.svc.complete(req.user.userId, body);
    return { code: 0, data, extra: {} };
  }
}
```

#### 5.4 JWT Guard
- 新增 `chatgpt_backend/src/auth/jwt.guard.ts`
- 从 `Authorization: Bearer <token>` 解 JWT，secret 复用现有 `JWT_SECRET`（理想做法是把它移到 env，但**本任务先沿用现状**）
- 解出 `userId, userName` 挂到 `req.user`

#### 5.5 注册
- `app.module.ts` 加 `ConfigModule.forRoot({ isGlobal: true })`、`ChatModule`、`TypeOrmModule.forFeature([Usage])`
- 入参：env 变量见第 2.5 节

#### 5.6 `.env.example`
新建 `chatgpt_backend/.env.example`：
```
OPENAI_API_KEY=sk-replace-me
OPENAI_BASE_URL=https://api.openai.com/v1
DEEPSEEK_API_KEY=sk-replace-me
DEEPSEEK_BASE_URL=https://api.deepseek.com
BACKEND_DEFAULT_PROVIDER=deepseek
JWT_SECRET=chatgpt-flutter-secret-key
```
更新 `chatgpt_backend/README.md`，加一节「环境变量」说明 + 「本地启动」步骤（`cp .env.example .env`，填值，`npm run start:dev`）。

---

### 任务 6：UI —— AI 设置页（含模型下拉切换）

**新增文件**：
- `chatgpt_flutter/lib/pages/ai_settings_page.dart`
- `chatgpt_flutter/lib/util/model_catalog.dart`（模型清单常量）

#### 6.1 模型清单 `model_catalog.dart`

```dart
/// 常用模型清单，UI 下拉用。用户也可点「自定义」手填，
/// 不在清单里的模型不会被拒绝——String 字段直传上游。
class ModelCatalog {
  static const openai = <ModelOption>[
    ModelOption('gpt-3.5-turbo',   '便宜快，适合日常对话'),
    ModelOption('gpt-4o-mini',     '小模型，性价比高（推荐）'),
    ModelOption('gpt-4o',          '主力模型，多模态'),
    ModelOption('gpt-4-turbo',     '上一代旗舰'),
    ModelOption('o1-mini',         '推理模型（小）'),
    ModelOption('o1',              '推理模型（强）'),
  ];

  static const deepseek = <ModelOption>[
    ModelOption('deepseek-chat',     'V3 对话模型（推荐）'),
    ModelOption('deepseek-reasoner', 'R1 推理模型，会输出思考过程'),
  ];

  /// 后端模式下可选的模型 = 两边合并，UI 用前缀 emoji 区分上游
  static List<ModelOption> backendAll() => [
    ...deepseek.map((m) => m.withPrefix('🧠 DeepSeek · ')),
    ...openai.map((m) => m.withPrefix('🤖 OpenAI · ')),
  ];
}

class ModelOption {
  final String id;       // 实际发给上游的 model 字符串
  final String label;    // UI 显示标签
  final String? hint;    // 副标签（说明）

  const ModelOption(this.id, this.hint, {this.label});
  // ... withPrefix 实现
}
```

**重要**：清单里的模型 ID **不要硬绑死**——上游随时可能加新模型/弃旧模型。所以：
- 下拉之外永远提供「自定义...」一项，点中后弹一个 TextField，输入任意字符串
- `AISettings.activeLocal.model` 持久化的是字符串，不是枚举
- 显示当前选中模型时，如果 ID 不在清单里，标签直接显示 ID 本身（说明用户填了自定义值）

#### 6.2 设置页结构

```
AppBar: 'AI 服务设置'
Body (ListView):

  ┌ 调用模式 ──────────────────────┐
  │ ◉ 本地（使用自己的 key，免费）         │
  │ ○ 后端（统一服务，可能收费）           │
  └──────────────────────────────┘

  --- mode=local 时显示下面这块 ---
  ┌ 服务商 ────────────────────────┐
  │ [DeepSeek ▼]   ← SegmentedButton   │
  │ [OpenAI  ▼]                          │
  └──────────────────────────────┘

  ┌ DeepSeek 配置（仅当 localProvider=deepseek 时展开）─┐
  │ API Key:                                            │
  │ [••••••••••••••••••••••]  [👁]                      │
  │                                                      │
  │ 模型:                                                │
  │ [deepseek-chat                                  ▼]  │  ← DropdownButton
  │   • deepseek-chat        V3 对话模型（推荐）        │
  │   • deepseek-reasoner    R1 推理模型                │
  │   • 自定义...                                        │
  │                                                      │
  │ Base URL（高级，一般不动）:                          │
  │ [https://api.deepseek.com/chat/completions       ]  │
  └─────────────────────────────────────────────────────┘

  ┌ OpenAI 配置 ──── 同上结构，模型清单换成 ModelCatalog.openai
  ...

  --- mode=backend 时显示 ---
  ┌ 后端模型 ────────────────────────────┐
  │ [🧠 DeepSeek · deepseek-chat        ▼]  │
  │   分组列出：                              │
  │     —— DeepSeek ——                       │
  │     • deepseek-chat                       │
  │     • deepseek-reasoner                   │
  │     —— OpenAI ——                         │
  │     • gpt-4o-mini                         │
  │     • gpt-4o                              │
  │     ...                                   │
  │     • 自定义...                           │
  │                                            │
  │ ⓘ 后端按 model 前缀路由到上游：           │
  │    deepseek-* → DeepSeek                  │
  │    gpt-* / o1-* → OpenAI                  │
  │ ⓘ 将记录用量供未来计费                    │
  └────────────────────────────────────────┘

  ───────────────────────────────────────
  [测试连接]              [保存]
```

#### 6.3 实现细节

- 用 `Consumer<AISettingsProvider>` 读当前值
- 三个区块用 `Card` 包，间距 16dp，跟随 `ThemeProvider` 的主色
- **模式切换**：`SegmentedButton<AIMode>` 或 `RadioListTile`
- **服务商切换**：`SegmentedButton<LocalProvider>`，切换时 UI 立即重构（`setState`）
- **模型下拉**：`DropdownButtonFormField<String>`
  - `items`：`ModelCatalog.openai`/`deepseek`/`backendAll()` 转 `DropdownMenuItem`，外加最后一项 `value: '__custom__'` 文案「自定义...」
  - `onChanged`：选到 `__custom__` 时弹 `showDialog` 让用户输入，确认后把字符串塞回去；选其它直接更新 controller
  - 若当前 `model` 不在清单里，把它作为额外一项 `DropdownMenuItem` 插入并选中（避免下拉显示空白）
- **API Key 输入**：`TextField` + `obscureText: true`，尾部 `IconButton(Icons.visibility)` 切显隐
- **Base URL 输入**：折叠在「高级」`ExpansionTile` 里，避免新手误改
- **保存**：构造新 `AISettings` → `provider.update()` → `SnackBar('已保存')`
- **测试连接**：用临时构造的 `ChatService` 发 `prompt: 'ping'`，`AlertDialog` 弹结果（成功/失败 + 错误原因）；该按钮**不依赖**保存状态——基于当前页面 controller 的实时值构造，方便用户填错时快速试

#### 6.4 MyPage 集成

在 `lib/pages/my_page.dart` 现有「检测更新」「设置代理」之间或之上加一项：
```dart
..._itemWidget(
  color: color,
  title: 'AI 服务设置',
  icon: Icons.smart_toy,
  onTap: () => Navigator.push(context,
      MaterialPageRoute(builder: (_) => const AISettingsPage())),
),
```

#### 6.5 可选增强：会话页快速切换模型

如有余力，在 `ConversationPage` 的 `AppBar` `actions` 加一个 `PopupMenuButton<String>`，列出当前模式下的可用模型清单 + 「自定义...」，点选后**只更新当前会话**的 model（不写入全局 `AISettings`）。
- 实现方式：`_ConversationPageState` 持有 `String _overrideModel?`，构造 `ChatService` 时如有 override 用之
- 切换上下文：模型变化通知用户「下一条消息将使用 X」，但当前已发出的消息不受影响
- **本任务可选**，时间紧时跳过——只需在设置页改 model 也能用

**MyPage 集成**：
在 `lib/pages/my_page.dart` 现有「检测更新」「设置代理」之间或之上加一项：
```dart
..._itemWidget(
  color: color,
  title: 'AI 服务设置',
  icon: Icons.smart_toy,
  onTap: () => Navigator.push(context,
      MaterialPageRoute(builder: (_) => const AISettingsPage())),
),
```

---

### 任务 7：`CompletionDao` 接入

**改文件**：`chatgpt_flutter/lib/dao/completion_dao.dart`

当前实现把所有历史揉成一个大 prompt 字符串发给 OpenAI（`Q:/A:` 格式），这是 GPT-3 时代的旧做法。新接口直接用 `messages` 数组更干净，但**为了兼容历史聊天记录的展示，这里只改调用层、不改存储**。

改动要点：
1. 构造 `messages: List<Map<String,String>>`（system/user/assistant 三种 role）
2. 从 `BuildContext` 拿 `AISettingsProvider.settings`（在 `_doInit` 时一次取够），`ChatService.from(settings)` 得到实例
3. 把当前 `getPromptContext()` 的拼接逻辑拆掉，改为：
   ```dart
   final history = <Map<String,String>>[];
   for (final m in messageList) {
     history.add({
       'role': m.ownerType == OwnerType.sender ? 'user' : 'assistant',
       'content': m.content,
     });
   }
   final reply = await chatService.chat(prompt: input, history: history);
   ```
4. 删除「过滤掉 `A:` 前缀和起始 `\n\n`」的字符串处理（新格式没有 Q:/A: 的污染）
5. `ConversationContextHelper` 在新流程里不再需要——可以**保留文件不删**（避免破坏未跟踪的引用），但 `CompletionDao` 不再使用它

**验证**：发一条新消息后，`debugPrint` 出 messages 数组结构正确（不出现 `Q:` `A:`）

---

### 任务 8：`main.dart` 与 `hi_const.dart` 收尾

**改 `lib/main.dart`**：
- 删除 `AIConfigBuilder.init(HiConst.apiKey)` 和 `AIConfigBuilder.instance.setProxy(proxy)` 两行（任务 1 已删了这套 API）
- `doInit` 不再依赖 `HiConst.apiKey`
- 代理设置功能暂时**保留为 TODO**：原本 `MyPage._setProxy` 把代理写到 `HiCache` 然后传给全局 `AIConfigBuilder`。新架构下代理应是**每个 ProviderConfig** 的可选字段。本任务先把 `_setProxy` 注释掉或改成弹 SnackBar「代理设置正在迁移」，后续单独迭代。

**改 `lib/util/hi_const.dart` 与 `hi_const.example.dart`**：
- 删除 `apiKey` 字段（不再使用）
- 保留 `keyHiProxy` 常量（HiCache key，可能后续仍用得到）
- 加 `BackendConst.host`（任务 4.3 提到）

**改 `chatgpt_flutter/README.md`**：
- 删掉「OpenAI 密钥」一节（已不通过文件配置）
- 加「首次运行」一节：登录后，点「我的」→「AI 服务设置」，选服务商、填 key，保存。

**改根目录 `CLAUDE.md`**：
- 「Wiring you must do before the app runs」第 1 条改成：「首次运行登录后，在『我的 → AI 服务设置』页面填入 OpenAI 或 DeepSeek 的 API key，并选择本地/后端模式」
- 「Networking」一节加：后端代理端点 `POST /uapi/chat/completions`

---

## 4. 执行顺序

按下面顺序执行，每个任务做完跑一次 `flutter analyze`（前端任务）或 `npm run lint && npm test`（后端任务）：

1. 任务 1（SDK 通用化）
2. 任务 2（数据模型）
3. 任务 3（Provider）
4. 任务 5（后端端点 + .env.example）—— 提到任务 4 之前是因为前端的 BackendChatService 要联调
5. 任务 4（ChatService 抽象 + 实现）
6. 任务 6（UI 设置页）
7. 任务 7（CompletionDao 接入）
8. 任务 8（main.dart 收尾 + 文档）

---

## 5. 验收清单

执行完后用下面场景**全部**验证（每条都要实际操作 App，不仅仅 `flutter analyze` 通过）：

### 5.1 本地 + DeepSeek
- 设置页选「本地」+「DeepSeek」+ 填 DeepSeek key + 模型下拉选 `deepseek-chat` + 保存
- 进入聊天页发一条 "你好"，应得到 DeepSeek 的中文回复
- 关 App 再开，设置不丢

### 5.2 本地 + OpenAI
- 即使没有 OpenAI key，设置页能正常切换并保存（不崩溃）
- 留待用户自己有 key 时再实测

### 5.3 后端模式
- 后端 `npm run start:dev` 起来
- App 设置页选「后端」+ 模型下拉选 `deepseek-chat` + 保存
- 发消息能收到回复（后端转 DeepSeek）
- 后端 DB 里 `usage` 表新增一条记录（`SELECT * FROM usage ORDER BY id DESC LIMIT 1;`）

### 5.3.1 模型切换
- 本地 + DeepSeek 模式下：把模型从 `deepseek-chat` 改成 `deepseek-reasoner`，保存，发消息——回复中应包含推理过程（reasoner 模型特征）
- 后端模式下：模型下拉从 `deepseek-chat` 切到 `gpt-4o-mini`，保存，发消息——后端日志或 `usage` 表记录显示 provider 已变成 `openai`
- 选择「自定义...」输入 `deepseek-chat-pro`（不存在的模型），保存后发消息应收到 4xx 错误（DeepSeek 上游返回的「model not found」），UI 不崩
- 自定义值在下拉里能正确回显（不显示空白）

### 5.4 鉴权
- App 未登录直接打 `/uapi/chat/completions` 应返 401
- 登出后再发消息应被引导回登录页

### 5.5 错误处理
- API key 错的情况下发消息，UI 应展示明确错误（不是闪退、不是空白）
- 网络断开时同上

### 5.6 历史记录兼容
- 旧聊天记录（`Q:/A:` 格式存的）打开仍能正常显示气泡（消息表结构没改）

---

## 6. 风险与注意事项

- **`openai_flutter` 改成 per-instance 是破坏性变更**：所有调用方都要改。本任务里调用方只有 `chatgpt_flutter`（已覆盖在任务 6/7/8），其它 sibling 包未引用，安全。
- **代理（proxy）功能临时禁用**：之前 `AIConfigBuilder.setProxy` 是单例的，改成 per-instance 后需要每个 ProviderConfig 各自带 proxy 字段。本任务把 UI 入口先暂闭，后续迭代再加（在 `AISettings` 模型加 `proxy` 字段、设置页加代理输入框、`AIHttp` 应用代理）。如果执行模型有余力可以一并做掉，但**不要为此扩大任务范围超过 1 小时工作量**。
- **后端 JWT_SECRET 仍硬编码**：`user.service.ts` 里的 `JWT_SECRET = 'chatgpt-flutter-secret-key'` 是硬编码。本任务**不修复**，因为修了要同时改 user 与 chat 两处的 secret 来源、并写入 .env，超出范围。新建 issue 留作下一项任务。
- **DeepSeek baseUrl 末尾路径**：DeepSeek 文档的完整 chat completions endpoint 是 `https://api.deepseek.com/chat/completions`（注意：DeepSeek 不在 `/v1/` 下，OpenAI 是 `/v1/chat/completions`）。`AISettings.defaults()` 里的默认值已正确，**不要瞎"统一"成 `/v1` 前缀**。
- **Token 用量字段**：DeepSeek 响应也带 `usage.{prompt_tokens, completion_tokens, total_tokens}`，与 OpenAI 字段一致，后端 `Usage` 实体可统一处理。
- **模型清单不要绑死**：`ModelCatalog` 只是 UI 下拉的便捷选项，**永远要保留「自定义...」入口**。上游随时会出新模型（GPT-5、DS V4...），写死会导致用户被迫等 App 更新。`AISettings` 里 `model` 始终是 `String`，绝不要改成 enum。

---

## 7. 完成后输出

请在执行结束时给出一份摘要报告，包含：
- 每个任务的状态（done / partial / blocked）
- 新增/修改的文件清单（按包分组）
- 验收清单 5.1–5.6 每条的实测结果（截图或 console 输出片段）
- 任何发现的、本文档未覆盖的边界情况
