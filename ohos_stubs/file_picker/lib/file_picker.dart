/// HarmonyOS 空实现 stub：仅提供共享核心用到的 file_picker 公开 API 形状。
/// 选择器方法等价「用户取消」返回 null（不抛异常）；各调用点另有 OHOS 守卫隐藏入口。
library file_picker;

import 'dart:typed_data';

/// 文件类型筛选（与上游枚举同名，核心用到 [custom]）。
enum FileType { any, media, image, video, audio, custom }

/// 被选文件占位（含 `path` / `bytes` / `name` / `size`）。
class PlatformFile {
  final String? path;
  final String name;
  final int size;
  final Uint8List? bytes;

  const PlatformFile({
    this.path,
    this.name = '',
    this.size = 0,
    this.bytes,
  });
}

/// 选择结果占位（`files` 列表）。
class FilePickerResult {
  final List<PlatformFile> files;

  const FilePickerResult(this.files);
}

/// 文件选择器占位。OHOS 无原生实现，方法返回 null（≈ 用户取消）。
class FilePicker {
  /// 选取文件。
  static Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
  }) async =>
      null;

  /// 保存文件。
  static Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async =>
      null;

  /// 清理临时文件（上游有此 API；OHOS 无操作）。
  static Future<bool?> clearTemporaryFiles() async => true;
}
