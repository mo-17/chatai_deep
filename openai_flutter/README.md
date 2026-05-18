# openai_flutter

兼容 OpenAI Chat Completions 协议的轻量 Flutter SDK。支持任何同协议后端（OpenAI / DeepSeek / Azure OpenAI / Ollama 兼容层 / 自托管 LLM gateway），同步 / 流式两套 API。

- 每个 `AIConfigBuilder` 是独立实例 — 同一个 app 内可并存多个不同 baseUrl / apiKey 的 client
- 自带 HTTP 代理支持（`proxy: 'host:port'`）
- 流式 API 直接 yield Dart `Stream<String>`，业务侧 `await for` 即可拼字打字机
- 流式同时把 `delta.content` 和 `delta.reasoning_content`（DeepSeek 推理模型字段）yield 出来，可直接显示思考过程

## 安装

```yaml
dependencies:
  openai_flutter:
    git:
      url: <repo url>
      path: openai_flutter
```

## 快速开始

### 同步（非流式）

```dart
import 'package:openai_flutter/core/ai_completions.dart';
import 'package:openai_flutter/http/ai_config.dart';

final config = AIConfigBuilder(
  apiKey: 'sk-...',
  chatUrl: 'https://api.openai.com/v1/chat/completions',
);

final response = await AICompletion(config).createChat(
  model: 'gpt-4o-mini',
  messages: [
    {'role': 'system', 'content': 'You are a helpful assistant.'},
    {'role': 'user', 'content': 'Hello!'},
  ],
);

print(response.choices?.first.message?.content);
print('used tokens: ${response.usage?.totalTokens}');
```

### 流式（推荐）

```dart
final stream = AICompletion(config).createChatStream(
  model: 'gpt-4o-mini',
  messages: [{'role': 'user', 'content': '写一首关于夏天的短诗'}],
);

await for (final token in stream) {
  setState(() => buffer += token);   // 字打字机
}
```

## 切换 provider

只需要换 `baseUrl` + `apiKey`，协议体保持一致：

| Provider | chatUrl |
|---|---|
| OpenAI | `https://api.openai.com/v1/chat/completions` |
| DeepSeek | `https://api.deepseek.com/v1/chat/completions` |
| Azure OpenAI | `https://<your-resource>.openai.azure.com/openai/deployments/<deployment>/chat/completions?api-version=2024-02-15-preview` |
| 自托管（vLLM / Ollama OpenAI-compat） | `http://your-host:port/v1/chat/completions` |

需要走 HTTP 代理（GFW / 企业代理）：

```dart
AIConfigBuilder(
  apiKey: '...',
  chatUrl: '...',
  proxy: '127.0.0.1:7890',   // host:port
);
```

## API

### `AIConfigBuilder`

```dart
AIConfigBuilder({
  required String apiKey,        // 自动加 'Bearer ' 前缀；已有则原样使用
  required String chatUrl,       // 完整 URL
  String? proxy,                 // 'host:port'
  String? organization,          // → 'OpenAI-Organization' header
});
```

### `AICompletion`

```dart
class AICompletion {
  AICompletion(AIConfigBuilder config);

  Future<AIResponse> createChat({
    String model = 'gpt-3.5-turbo',
    dynamic prompt,                 // 与 messages 二选一
    List<Map<String, dynamic>>? messages,
    int? maxTokens = 200,
    double? temperature,
    double? topP,
    int? n,
    String? stop,
    String? user,
  });

  Stream<String> createChatStream({
    String model = 'gpt-3.5-turbo',
    dynamic prompt,
    List<Map<String, dynamic>>? messages,
    int? maxTokens = 200,
    // 其他参数同上
  });
}
```

### `AIResponse`（同步返回）

```dart
class AIResponse {
  String? id;
  String? object;
  int? created;
  String? model;
  Usage? usage;          // promptTokens / completionTokens / totalTokens
  List<Choices>? choices; // 每个 Choices 有 message.role / message.content / finishReason
}
```

### 异常

```dart
try {
  await AICompletion(config).createChat(...);
} on AIRequestException catch (e) {
  print('HTTP ${e.statusCode}: ${e.message}');
}
```

`AIRequestException` 携带 HTTP `statusCode`，可据此区分 401（apiKey 错）/ 429（限流）/ 5xx。

## 直接走底层 HTTP

`AIHttp.post` / `AIHttp.postStream` 也对外暴露，方便接 OpenAI 协议以外的端点（embeddings、images 等 — 同一份 config）：

```dart
import 'package:openai_flutter/http/ai_http.dart';

final result = await AIHttp.post<MyType>(
  config: config,
  url: 'https://api.openai.com/v1/embeddings',
  body: {'model': 'text-embedding-3-small', 'input': 'hello'},
  onSuccess: (json) => MyType.fromJson(json),
);
```

## Example

完整 demo 见 [`example/`](./example/)：

```bash
cd openai_flutter/example
flutter pub get
flutter run
```

example 内置了**进程内 SSE mock server**，按 25 ms/token yield 模拟 OpenAI 流式响应 — 不需要真实 API key 就能看到字打字机效果。切换到真实 API 只需改 main.dart 里的 `AIConfigBuilder`。

## 注意事项

- **超时**：当前同步 15s / 流式 20s 硬编码（见 `AIHttp`）。生成长文本时可能不够，需要时直接 fork 这两个数字
- **流式 reasoning 内容**：DeepSeek `deepseek-reasoner` 等模型把"思考过程"放在 `delta.reasoning_content`，会和 `delta.content` 一起被 yield；如果你需要 UI 区分这两部分，需要扩展 `AIHttp.postStream` 区分两条 stream
- **`max_tokens` 默认 200**：超过的部分会被截断（`finish_reason: length`）。需要长输出务必传 `maxTokens: null` 或合适数字
- **macOS 沙箱**：`Runner/{Debug,Release}.entitlements` 加 `com.apple.security.network.client`
- **Android 网络权限**：`AndroidManifest.xml` 需要 `<uses-permission android:name="android.permission.INTERNET" />`
- **代理仅支持 HTTP**：底层用 `HttpClient.findProxy`，SOCKS 代理不直接支持 — 通过本地 SOCKS→HTTP 转发（如 v2rayN 的 http 端口）
