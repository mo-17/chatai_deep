import 'dart:io';

import 'package:chatgpt_flutter_ohos/ohos_runtime_security.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';

void main() {
  group('OhosRuntimeSecurity', () {
    test('后端配置拒绝包含路径的 authority，避免请求构造时才失败', () async {
      for (final releaseMode in [false, true]) {
        for (final host in [
          'api.example.com/',
          'api.example.com:443/',
          'api.example.com/uapi',
        ]) {
          await expectLater(
            OhosRuntimeSecurity.configureBackend(
              host: host,
              useHttps: true,
              releaseMode: releaseMode,
              resolver: (_) async => [InternetAddress('93.184.216.34')],
            ),
            throwsStateError,
            reason: 'release=$releaseMode, host=$host',
          );
        }
      }
    });

    test('release 拒绝未配置、HTTP 和私网开发地址', () async {
      await expectLater(
        OhosRuntimeSecurity.validateBackend(
          host: '',
          useHttps: true,
          releaseMode: true,
        ),
        throwsStateError,
      );
      await expectLater(
        OhosRuntimeSecurity.validateBackend(
          host: 'api.example.com',
          useHttps: false,
          releaseMode: true,
        ),
        throwsStateError,
      );
      for (final host in [
        '127.0.0.1:3000',
        '192.168.1.9:3000',
        'localhost',
        'localhost.',
        '[::ffff:127.0.0.1]',
        '[::ffff:10.0.0.1]',
        '[ff02::1]',
        '[fec0::1]',
        '[2001:10::1]',
        '[2001:db8::1]',
        '[3fff::1]',
      ]) {
        await expectLater(
          OhosRuntimeSecurity.validateBackend(
            host: host,
            useHttps: true,
            releaseMode: true,
          ),
          throwsStateError,
          reason: host,
        );
      }
    });

    test('release DNS 混入私网地址时 fail closed', () async {
      await expectLater(
        OhosRuntimeSecurity.validateBackend(
          host: 'mixed.example.com',
          useHttps: true,
          releaseMode: true,
          resolver: (_) async => [
            InternetAddress('93.184.216.34'),
            InternetAddress('10.0.0.8'),
          ],
        ),
        throwsStateError,
      );
    });

    test('release 公网 HTTPS 配置让登录与聊天统一生成 https URL', () async {
      await OhosRuntimeSecurity.configureBackend(
        host: 'api.example.com',
        useHttps: true,
        releaseMode: true,
        resolver: (_) async => [InternetAddress('93.184.216.34')],
      );
      expect(
        BackendConfig.buildUri('/uapi/auth/login/password').scheme,
        'https',
      );
      expect(
        BackendConfig.buildUri('/uapi/chat/completions/stream').scheme,
        'https',
      );
    });

    test('debug 仍可显式使用局域网开发后端', () async {
      await expectLater(
        OhosRuntimeSecurity.validateBackend(
          host: '192.168.1.9:3000',
          useHttps: false,
          releaseMode: false,
        ),
        completes,
      );
    });
  });
}
