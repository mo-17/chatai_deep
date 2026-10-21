import 'dart:typed_data';
import 'package:file_picker/file_picker.dart' as picker;
import 'package:login_sdk/dao/login_dao.dart';
import 'picked_file.dart';
export 'package:file_picker/file_picker.dart' hide FilePicker;

/// 浏览器 File 对象没有设备路径：读取用户选中的字节后签发应用内路径。
class FilePicker {
  static Future<picker.FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    picker.FileType type = picker.FileType.any,
    List<String>? allowedExtensions,
    Function(picker.FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async {
    final account = LoginDao.getAccountHash() ?? 'guest';
    final result = await picker.FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      type: type,
      allowedExtensions: allowedExtensions,
      onFileLoading: onFileLoading,
      compressionQuality: compressionQuality,
      allowMultiple: allowMultiple,
      withData: false,
      withReadStream: true,
      cancelUploadOnWindowBlur: cancelUploadOnWindowBlur,
    );
    if (result == null) return null;
    if (result.files.length > 100 ||
        result.files.fold<int>(0, (total, file) => total + file.size) >
            64 * 1024 * 1024 ||
        result.files.any(
            (file) => file.size < 0 || file.size > browserPickedFileMaxBytes)) {
      throw const FormatException('网页端每次最多 100 个文件、合计 64 MiB，单个文件最多 32 MiB');
    }
    final files = <picker.PlatformFile>[];
    for (final selected in result.files) {
      final stream = selected.readStream;
      if (stream == null) throw const FormatException('未读取到选中文件的内容');
      final bytes = await readBrowserPickedBytes(selected.size, stream);
      final path = await storeBrowserPickedBytes(selected.name, bytes,
          accountHash: account);
      files.add(picker.PlatformFile(
          name: selected.name,
          size: bytes.length,
          path: path,
          bytes: bytes,
          readStream: withReadStream ? Stream.value(bytes) : null));
    }
    return picker.FilePickerResult(files);
  }

  static Future<String?> getDirectoryPath(
          {String? dialogTitle,
          bool lockParentWindow = false,
          String? initialDirectory}) async =>
      throw UnsupportedError('网页端请选择多个文件或 ZIP 导入');

  static Future<String?> saveFile(
      {String? dialogTitle,
      String? fileName,
      String? initialDirectory,
      picker.FileType type = picker.FileType.any,
      List<String>? allowedExtensions,
      Uint8List? bytes,
      bool lockParentWindow = false}) async {
    await picker.FilePicker.saveFile(
        dialogTitle: dialogTitle,
        fileName: fileName,
        type: type,
        allowedExtensions: allowedExtensions,
        bytes: bytes);
    // 插件成功触发下载后返回 null；提供下载回执，避免业务误报用户取消。
    // 这不是设备文件路径，也不代表用户已经把文件保存到磁盘。
    return '浏览器下载：$fileName';
  }
}
