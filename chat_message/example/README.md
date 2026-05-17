# chat_message_example

`chat_message` 的可独立运行 demo。展示：

- `ChatController` 双向消息流（StreamController<List<MessageModel>>）
- `ChatList` widget 渲染 + auto-scroll
- 输入框发送 → bot 1.2s 后 echo 回复
- AppBar 历史按钮调用 `loadMoreData` 模拟"上拉加载历史"
- 气泡 tap 回调（`onBubbleTap` → SnackBar）

无网络依赖，无后端。

## 运行

```bash
cd chat_message/example
flutter pub get
flutter run        # 或 flutter run -d macos
```

## 用法速记

```dart
final controller = ChatController(
  initialMessageList: [],
  scrollController: ScrollController(),
  timePellet: 60,   // 时间分组粒度（秒）
);

// UI 端
ChatList(chatController: controller, onBubbleTap: (msg, ctx) => ...)

// 收到新消息时
controller.addMessage(MessageModel(
  ownerType: OwnerType.receiver,
  ownerName: 'Bot',
  content: '...',
  createdAt: DateTime.now().millisecondsSinceEpoch,
));

// 上拉加载历史
controller.loadMoreData(olderMessages);
```

`MessageModel` 支持文本 + 图片（`imageUrlsOrB64` 支持 base64 dataURI、http(s) URL、本地文件路径），点击气泡可放大预览。
