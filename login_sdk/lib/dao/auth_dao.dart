import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/header_util.dart';

/// 配置好的 AuthDao 单例，供 login_sdk 页面使用
class AuthDaoBridge {
  AuthDaoBridge._();

  static final AuthApiClient client = AuthApiClient(
    baseUrl: BackendConfig.buildUri('').toString().replaceAll(RegExp(r'/$'), ''),
    headerProvider: () async => {
      ...hiHeaders(),
      'Content-Type': 'application/json',
    },
  );

  static final AuthDao instance = AuthDao(client);
}
