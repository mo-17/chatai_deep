# hi_download

轻量级 Flutter 下载库。一个类、一个方法、零依赖配置：

- 基于 `package:http` 流式下载，避免一次性占用大块内存
- 通过 `path_provider` 自动落盘到 `ApplicationDocumentsDirectory`
- 实时回调 `total / received / done` 给上层做进度条
- 可选 SHA-256 校验；先写入 `.part` 临时文件，校验成功后再原子替换目标文件
- 跨平台：Android / iOS / macOS / Windows / Linux / web

## 安装

```yaml
# pubspec.yaml
dependencies:
  hi_download:
    git:
      url: <repo url>
      path: hi_download
  # 或者 path 依赖
  # hi_download:
  #   path: ../hi_download
```

## 用法

```dart
import 'package:hi_download/hi_download.dart';

final path = await HiDownLoad().download(
  downLoadUrl: 'https://example.com/file.apk',
  fileName: 'app-update.apk',
  expectedSha256: '<服务端提供的 64 位 SHA-256>', // 可选
  listener: (total, received, done) {
    final pct = total > 0 ? received / total : 0;
    print('progress: ${(pct * 100).toStringAsFixed(1)}%, done: $done');
  },
);
print('saved at: $path');   // 绝对路径
```

`path` 是文件的绝对路径，可直接传给 `open_filex` / 系统文件浏览器：

```dart
import 'package:open_filex/open_filex.dart';
await OpenFilex.open(path);
```

## API

### `HiDownLoad`

```dart
class HiDownLoad {
  Future<String> download({
    required String downLoadUrl,
    required String fileName,
    required DownLoadListener listener,
    String? expectedSha256,
  });
}

typedef DownLoadListener = void Function(int total, int received, bool done);
```

| 参数 | 说明 |
|---|---|
| `downLoadUrl` | 完整下载 URL（http / https） |
| `fileName` | 保存的文件名（不含目录），落盘到 `ApplicationDocumentsDirectory/<fileName>` |
| `listener` | 流式回调。`total` 来自 `Content-Length`（无该 header 时为 0），`received` 累计已收字节数，`done=true` 时表示流已 close |
| `expectedSha256` | 可选的 64 位十六进制 SHA-256；不匹配时删除临时文件并抛出 `DownloadException` |

返回 `Future<String>` —— 校验完成并原子落盘后的文件绝对路径。

## 注意事项

- **响应缺少 `Content-Length`**：`total = 0`，可降级为不确定进度条（`LinearProgressIndicator(value: null)`）
- **macOS 沙箱**：发起 HTTP 请求需要在 `Runner/{Debug,Release}.entitlements` 加 `com.apple.security.network.client`
- **Android 网络权限**：`AndroidManifest.xml` 需要 `<uses-permission android:name="android.permission.INTERNET" />`
- **断点续传 / 取消下载**：本库暂不内建这些能力；有需要可使用 `package:dio`
- **完整性校验**：只有传入 `expectedSha256` 时启用；正式更新流程应由服务端提供可信摘要

## Example

完整可运行的 demo 见 [`example/`](./example/)：

```bash
cd hi_download/example
flutter pub get
flutter run
```

输入框可改 URL / 文件名，UI 显示实时进度条 + 完成后展示保存路径。
