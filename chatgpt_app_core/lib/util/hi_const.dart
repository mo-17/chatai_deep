import 'package:login_sdk/dao/backend_host.dart';

class HiConst {
  HiConst._();

  ///本地保存的代理的key
  static const String keyHiProxy = 'hi_proxy';

  // apiKey 已不再使用，改为通过 AI 设置页配置
}

class BackendConst {
  BackendConst._();

  static String get host => BackendConfig.host;

  static Uri buildUri(String path, [Map<String, dynamic>? queryParameters]) =>
      BackendConfig.buildUri(path, queryParameters);
}
