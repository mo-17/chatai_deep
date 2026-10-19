import 'package:flutter/services.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

/// 鸿蒙壳显式注册，其他平台继续使用 image_picker 原有实现。
class OhosImagePicker extends ImagePickerPlatform {
  static const _channel = MethodChannel('com.hzb.flutter_ai/image_picker');

  static void registerWith() =>
      ImagePickerPlatform.instance = OhosImagePicker();

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
    final row = await _channel.invokeMapMethod<String, dynamic>('pickImage', {
      'source': source.name,
      'maxWidth': validated.maxWidth ?? 2048,
      'maxHeight': validated.maxHeight ?? 2048,
      'quality': validated.imageQuality ?? 85,
      'frontCamera': validated.preferredCameraDevice == CameraDevice.front,
    });
    if (row == null) return null;
    final path = row['path'];
    if (path is! String ||
        !path.startsWith('/') ||
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
