/// HarmonyOS 空实现 stub —— 仅提供共享核心用到的 share_plus 公开 API，使 OHOS 壳
/// 可编译。真正的系统分享在调用点已用 `Platform.operatingSystem == 'ohos'` 守卫，
/// 降级为复制到剪贴板，正常不会触达本文件。
///
/// 注意：本包不依赖 Flutter，故 [ShareParams.sharePositionOrigin] 用 `Object?`
/// 承接上游的 `Rect?`（Rect is Object，赋值兼容），避免引入 dart:ui。
library;

export 'package:cross_file/cross_file.dart' show XFile;

/// 对应上游 `ShareParams`，仅保留共享核心传入的字段。
class ShareParams {
  final String? text;
  final String? subject;
  final String? title;
  final Object? sharePositionOrigin;
  final List<Object>? files;

  const ShareParams({
    this.text,
    this.subject,
    this.title,
    this.sharePositionOrigin,
    this.files,
  });
}

/// 对应上游 `ShareResult`，stub 仅用于占位返回。
class ShareResult {
  final String raw;
  final String status;

  const ShareResult(this.raw, this.status);
}

/// 对应上游 `SharePlus`。OHOS 无系统分享：[share] 为空操作并返回 unavailable。
class SharePlus {
  SharePlus._();

  static final SharePlus instance = SharePlus._();

  Future<ShareResult> share(ShareParams params) async {
    if (params.files?.isNotEmpty == true) {
      throw UnsupportedError('鸿蒙系统文件分享尚未适配，请使用文件保存');
    }
    return const ShareResult('', 'unavailable');
  }
}
