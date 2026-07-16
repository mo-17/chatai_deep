import 'package:chatgpt_app_core/config/app_distribution.dart';
import 'package:chatgpt_app_core/model/apk_model.dart';

enum UpdateAction { none, downloadApk, openStore }

class ApkUpdatePolicy {
  const ApkUpdatePolicy();

  UpdateAction decide(
    ApkModel model,
    AppDistribution distribution,
  ) {
    if (!model.updateAvailable) return UpdateAction.none;
    final action = distribution == AppDistribution.store
        ? UpdateAction.openStore
        : UpdateAction.downloadApk;
    _validatedUri(
      urlFor(model, distribution),
      requireHttps: distribution == AppDistribution.store,
    );
    return action;
  }

  String urlFor(
    ApkModel model,
    AppDistribution distribution,
  ) {
    if (distribution == AppDistribution.store) {
      // Store 只能消费服务端显式下发的 storeUrl。不能回退到旧协议的
      // 通用 url，否则连接旧后台时可能把 direct APK 当作商店地址。
      return model.storeUrl;
    }
    return model.downloadUrl;
  }

  static Uri _validatedUri(
    String raw, {
    required bool requireHttps,
  }) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        (requireHttps
            ? uri.scheme != 'https'
            : uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('更新地址无效');
    }
    return uri;
  }
}
