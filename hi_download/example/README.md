# hi_download_example

`hi_download` 的可独立运行 demo。展示 `HiDownLoad().download(url, fileName, listener)` 三参数用法 + 通过 `DownLoadListener(total, received, done)` 实时刷新进度。

## 运行

```bash
cd hi_download/example
flutter pub get
flutter run        # 或 flutter run -d macos
```

默认 URL 是 Flutter 官方文档站的一张图片（~50KB），输入框可改。文件保存到 `ApplicationDocumentsDirectory`，UI 会显示绝对路径。

## 在你自己的项目里用

```dart
final path = await HiDownLoad().download(
  downLoadUrl: 'https://example.com/file.apk',
  fileName: 'app-update.apk',
  listener: (total, received, done) {
    print('progress: ${received / total}, done: $done');
  },
);
print('saved at: $path');
```

`path` 是绝对路径，可直接传给 `open_filex` / `OpenFilex.open(path)` 等组件打开。
