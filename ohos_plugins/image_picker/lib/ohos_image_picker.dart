import 'package:flutter/services.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

/// 鸿蒙壳显式注册，其他平台继续使用 image_picker 原有实现。
class OhosImagePicker extends ImagePickerPlatform {
  static const _channel = MethodChannel('com.hzb.flutter_ai/image_picker');
  static Future<void> Function()? beforeSelection;

  static void registerWith() =>
      ImagePickerPlatform.instance = OhosImagePicker();

  @override
  Future<LostDataResponse> getLostData() async {
    // 应用通过带账号/会话作用域的恢复通道取回；通用 API 不跨账号取图片。
    await _channel.invokeMethod<void>('retrieveLostData');
    return LostDataResponse.empty();
  }

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    final validated = ImagePickerOptions.createAndValidate(
      maxWidth: options.maxWidth,
      maxHeight: options.maxHeight,
      imageQuality: options.imageQuality,
      preferredCameraDevice: options.preferredCameraDevice,
    );
    await beforeSelection?.call();
    final row = await _channel.invokeMapMethod<String, dynamic>('pickImage', {
      'source': source.name,
      'maxWidth': validated.maxWidth ?? 2048,
      'maxHeight': validated.maxHeight ?? 2048,
      'quality': validated.imageQuality ?? 85,
      'frontCamera': validated.preferredCameraDevice == CameraDevice.front,
    });
    return row == null ? null : _file(row);
  }

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    MultiImagePickerOptions.createAndValidate(
      imageOptions: options.imageOptions,
      limit: options.limit,
    );
    final image = ImagePickerOptions.createAndValidate(
      maxWidth: options.imageOptions.maxWidth,
      maxHeight: options.imageOptions.maxHeight,
      imageQuality: options.imageOptions.imageQuality,
    );
    final limit = (options.limit ?? 10).clamp(2, 10);
    await beforeSelection?.call();
    final rows = await _channel.invokeListMethod<dynamic>('pickImages', {
      'source': 'gallery',
      'maxWidth': image.maxWidth ?? 2048,
      'maxHeight': image.maxHeight ?? 2048,
      'quality': image.imageQuality ?? 85,
      'limit': limit,
    });
    if (rows == null) return [];
    if (rows.length > limit) throw const FormatException('鸿蒙图片选择器返回数量超限');
    final files = <XFile>[];
    final seen = <String>{};
    for (final row in rows) {
      if (row is! Map) throw const FormatException('鸿蒙图片选择器返回无效结果');
      final file = _file(Map<String, dynamic>.from(row));
      if (seen.add(file.path)) files.add(file);
    }
    return files;
  }

  XFile _file(Map<String, dynamic> row) {
    final path = row['path'];
    if (path is! String ||
        !path.startsWith('/') ||
        path.contains('\x00') ||
        path.split('/').contains('..') ||
        row['name'] is! String ||
        row['mimeType'] is! String) {
      throw const FormatException('鸿蒙图片选择器返回无效结果');
    }
    return XFile(
      path,
      name: row['name'] as String,
      mimeType: row['mimeType'] as String,
    );
  }
}
