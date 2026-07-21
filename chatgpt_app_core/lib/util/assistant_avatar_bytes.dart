import 'dart:io';

import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract final class AssistantAvatarBytes {
  static Future<List<int>?> read(
    AssistantModel assistant, {
    AssetBundle? bundle,
  }) async {
    final type = assistant.avatarType;
    final value = assistant.avatarValue?.trim() ?? '';
    if (type == AvatarAssetService.assetType) {
      final asset = StarcoreIconAssets.assistantAssetFor(value);
      if (asset == null) return null;
      try {
        final data = await (bundle ?? rootBundle).load(
          'packages/${StarcoreIconAssets.packageName}/$asset',
        );
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } on FlutterError {
        return null;
      }
    }
    if (type != AvatarAssetService.imageType || value.isEmpty) return null;
    try {
      return await File(value).readAsBytes();
    } on FileSystemException {
      return null;
    }
  }
}
