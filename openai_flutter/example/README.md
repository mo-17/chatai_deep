# openai_flutter_example

`openai_flutter` 的可独立运行 demo。展示：

- `AIConfigBuilder` + `AICompletion.createChatStream(...)` 流式聊天
- 字打字机效果（token 逐个 yield）
- 进程内 SSE mock server — 不需要真实 OpenAI / DeepSeek API key

## 运行

```bash
cd openai_flutter/example
flutter pub get
flutter run        # 或 flutter run -d macos
```

## 切换到真实 API

main.dart 里的 `AIConfigBuilder` 改成：

```dart
final config = AIConfigBuilder(
  apiKey: '<your sk-... key>',
  chatUrl: 'https://api.openai.com/v1/chat/completions',
  // proxy: 'host:port',           // 可选
  // organization: 'org-...',      // 可选
);
```

DeepSeek 同接口兼容：

```dart
final config = AIConfigBuilder(
  apiKey: '<your deepseek key>',
  chatUrl: 'https://api.deepseek.com/v1/chat/completions',
);
```

> 注：流式 reasoning 内容（DeepSeek `deepseek-reasoner` 等模型的 `reasoning_content` delta 字段）会和 `content` 一起被 yield —— 你 UI 端如要分别显示推理过程与正文，需要自行解析 raw SSE，或扩展 `AIHttp.postStream` 区分两个 stream。

## 文件

```
example/
├── lib/
│   ├── main.dart            # ChatPage：流式聊天 UI
│   └── mock_sse_server.dart # 进程内 SSE mock，按 25ms/token yield
└── pubspec.yaml             # 依赖 openai_flutter via `path: ../`
```
