# chat_message

Flutter 通用聊天 UI 组件库。围绕一个流（`StreamController<List<MessageModel>>`）驱动的列表 + 气泡控件，把"消息上屏 / 时间分组 / 头像 / 图文混排"做完，业务侧只负责造 `MessageModel` 与决定何时调 `addMessage`。

- 纯 UI，零网络依赖
- `ChatController` 驱动，UI 自动滚动到最新
- 支持文本 + 图片（base64 dataURI / http(s) URL / 本地文件路径）混排
- 气泡 `tap` / `longPress` 回调
- 上拉加载历史（`loadMoreData`）
- 时间分组（`timePellet` 秒级粒度）

底层用 `package:bubble` 渲染气泡，`intl` 处理时间格式。

## 安装

```yaml
dependencies:
  chat_message:
    git:
      url: <repo url>
      path: chat_message
```

## 最小用例

```dart
import 'package:flutter/material.dart';
import 'package:chat_message/core/chat_controller.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/widget/chat_list.dart';

class ChatPage extends StatefulWidget { ... }

class _ChatPageState extends State<ChatPage> {
  late final ChatController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ChatController(
      initialMessageList: [],
      scrollController: ScrollController(),
      timePellet: 60,  // 同一分钟内多条消息只显示一次时间
    );
  }

  void _onUserSend(String text) {
    _controller.addMessage(MessageModel(
      ownerType: OwnerType.sender,
      ownerName: 'Me',
      content: text,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ChatList(
        chatController: _controller,
        onBubbleTap: (msg, ctx) => debugPrint('tap: ${msg.content}'),
      ),
    );
  }
}
```

## API

### `MessageModel`

```dart
MessageModel({
  int? id,
  required OwnerType ownerType,    // sender / receiver — 决定气泡左右
  required String content,
  required int createdAt,          // millisecondsSinceEpoch
  String? ownerName,               // 显示名（首字母用于占位头像）
  String? avatar,                  // http(s) 头像 URL，无效自动降级首字母
  List<String>? imageUrlsOrB64,    // 图片：base64 dataURI / http(s) URL / 本地路径
  List<String>? imagePaths,        // 发送中持有的本地路径（落库后置空）
});
```

`fromJson` / `toJson` / `copyWith` 都已实现 — 方便和你自己的 DAO / SQLite 层互转。

### `ChatController`

```dart
ChatController({
  required List<MessageModel> initialMessageList,
  required ScrollController scrollController,
  required int timePellet,
  MessageWidgetBuilder? messageWidgetBuilder,   // 自定义气泡渲染
});

void addMessage(MessageModel m);            // 新消息插入头部 + 自动滚动
void updateMessage(MessageModel m);         // 按 createdAt 匹配并替换（流式编辑常用）
void deleteMessage(MessageModel m);
void loadMoreData(List<MessageModel> ms);   // 上拉加载历史
void dispose();                             // 释放 stream + scrollController
```

### `ChatList`

```dart
ChatList({
  required ChatController chatController,
  EdgeInsetsGeometry? padding,
  OnBubbleClick? onBubbleTap,        // (MessageModel, BuildContext)
  OnBubbleClick? onBubbleLongPress,
});
```

### 自定义气泡

通过 `ChatController.messageWidgetBuilder` 完全替换 `DefaultMessageWidget`：

```dart
ChatController(
  ...,
  messageWidgetBuilder: (MessageModel m) => MyCustomBubble(m),
);
```

## 图片混排

`imageUrlsOrB64` 是字符串列表，按元素前缀自动选择渲染方式：

| 前缀 | 渲染 |
|---|---|
| `data:image/...;base64,xxx` | `Image.memory(base64Decode(...))` |
| `http://` / `https://` | `Image.network(...)` |
| `/...` 或本地路径 | `Image.file(...)`（文件存在时） |
| 其他 | broken image 占位 |

气泡内：1 张图 200×200，多张图按 100×100 网格。点击进入全屏 PageView 预览。

## 时间分组（`timePellet`）

`timePellet: 60` 表示"同一分钟内多条消息只显示一次时间分隔条"，`300` 即五分钟粒度。`ChatController` 在 `inflateMessage` 里按 `createdAt / (timePellet * 1000)` 取整分桶，相同桶的后续消息 `showCreatedTime = false`。

## Example

完整 demo 见 [`example/`](./example/)：

```bash
cd chat_message/example
flutter pub get
flutter run
```

演示输入框发消息 → bot 1.2s 后 echo + 历史按钮触发 `loadMoreData` + 气泡 tap SnackBar。

## 注意事项

- **消息排序**：内部 List 是"新消息在头部"，UI 用 `ListView.builder(reverse: true)` 倒序铺；不要自己 `sort()`
- **`updateMessage` 匹配键是 `createdAt`**：流式生成场景下"创建一条占位消息 → 不断 update content" 要保证同一条消息共用同一个 `createdAt`
- **`dispose()` 必须调用**：`ChatList` 已在 `dispose` 里自动调，但如果你直接持有 `ChatController` 也要同步释放
- **图片头像 fallback**：`avatar` 为空 / 非法 / 加载失败时自动用首字母占位（按 `ownerType` 选蓝 / 绿色），不会留空圈
