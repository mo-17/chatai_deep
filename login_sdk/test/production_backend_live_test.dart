import 'dart:convert';
import 'dart:io';

import 'package:auth_kit_flutter/auth_kit_flutter.dart' show AuthApiException;
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/dao/auth_dao.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/header_util.dart';
import 'package:login_sdk/dao/login_dao.dart';

import 'support/memory_token_storage.dart';

/// 显式启用的公网验收。凭据仅从仓库外的临时文件读取，不写入构建参数或日志。
void main() {
  final credentialPath = Platform.environment['CHATAI_LIVE_CREDENTIALS'];
  test(
    '生产配置通过真实 TLS 完成登录、用户接口访问和权限隔离',
    () async {
      final origin = BackendConfig.buildUri('');
      // 校验真实编译配置后才读取密码，避免误发至本地开发或其它后端。
      expect(origin.scheme, 'https');
      expect(origin.host, 'kushui.shop');
      expect(origin.port, 443);
      final file = File(credentialPath!);
      if (!Platform.isWindows) {
        expect(file.statSync().mode & 0x3f, 0, reason: '临时凭据文件不能被组或其它用户读取');
      }
      final credentials = jsonDecode(file.readAsStringSync()) as Map;
      expect(credentials['baseUrl'], 'https://kushui.shop');
      final storage = MemoryTokenStorage();
      final previousConfig = LoginSdkConfig.instance;
      final previousOverrides = HttpOverrides.current;
      LoginDao.resetHooksForTest();
      LoginSdkConfig.install(previousConfig.copyWith(storage: storage));
      // 此测试专门验证公网；使用系统信任库，不注入假证书或关闭 TLS 校验。
      HttpOverrides.global = null;
      try {
        final api = AuthDaoBridge.client;
        final public = await api.get('/uapi/auth/public-config');
        expect(public['code'], 0);
        expect(public['data'], isA<Map>());
        await expectLater(
          api.get('/uapi/ai/catalog'),
          throwsA(isA<AuthApiException>()
              .having((error) => error.statusCode, '未登录状态', 401)),
        );

        final result = await AuthDaoBridge.instance.loginByPassword(
          channel: 'email',
          identifier: credentials['email'] as String,
          password: credentials['password'] as String,
        );
        expect(result.token.isNotEmpty, isTrue);
        final attempt = LoginDao.beginAuthAttempt();
        await LoginDao.saveAuthTokenForAttempt(
          result.token,
          attempt: attempt,
          userName: result.extra['userName'] as String?,
          extras: result.extra,
        );
        expect(hiHeaders()['boarding-pass'] == result.token, isTrue);
        expect(LoginDao.isGuest(), isFalse);
        final catalog = await api.get('/uapi/ai/catalog');
        expect(catalog['code'], 0);
        expect(catalog['data'], isA<Map>());
        await expectLater(
          api.get('/uapi/admin/users'),
          throwsA(isA<AuthApiException>()
              .having((error) => error.statusCode, '普通用户无管理权限', 403)),
        );

        await storage.clear();
        expect(hiHeaders()['boarding-pass'], isEmpty);
        await expectLater(
          api.get('/uapi/ai/catalog'),
          throwsA(isA<AuthApiException>()
              .having((error) => error.statusCode, '清理登录态后', 401)),
        );
      } finally {
        AuthDaoBridge.client.dispose();
        await storage.clear();
        LoginDao.resetHooksForTest();
        LoginSdkConfig.install(previousConfig);
        HttpOverrides.global = previousOverrides;
      }
    },
    skip: credentialPath == null || credentialPath.isEmpty
        ? '设置 CHATAI_LIVE_CREDENTIALS，并使用 production.json 显式启用公网验收'
        : false,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
