import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';

/// 只替代系统文件选择结果；页面仍走有界读取、解析、预览、真实事务和文件托管。
class RoleCardFixtureFilePicker extends FilePickerPlatform {
  Future<FilePickerResult?> Function()? choose;
  List<String>? allowed;
  int calls = 0;
  @override
  Future<FilePickerResult?> pickFiles(
      {String? dialogTitle,
      String? initialDirectory,
      FileType type = FileType.any,
      List<String>? allowedExtensions,
      Function(FilePickerStatus)? onFileLoading,
      int compressionQuality = 0,
      bool allowMultiple = false,
      bool withData = false,
      bool withReadStream = false,
      bool lockParentWindow = false,
      bool readSequential = false,
      bool cancelUploadOnWindowBlur = true}) async {
    calls++;
    allowed = allowedExtensions;
    return choose?.call();
  }

  static FilePickerResult selected(String path) => FilePickerResult(
      [PlatformFile(path: path, name: path.split('/').last, size: 0)]);
}
