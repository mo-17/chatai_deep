import 'dart:io';

import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/config/token_storage.dart';
import 'package:login_sdk/dao/login_dao.dart';

void main() {
  test('tokenFor 使用完整 SHA-256 且不暴露账号原文', () {
    final token = AccountResourceScope.tokenFor('account-a');

    expect(
      token,
      'fc164f8250803ea8d41834f1de85821035d27d3747e83610789e0f8e5313b9c3',
    );
    expect(token, hasLength(64));
    expect(token, isNot(contains('account-a')));
  });

  test('scopedDirectory 保留 documents base resolver 语义', () {
    final base = Directory('${Directory.systemTemp.path}/app-documents');
    final directory = AccountResourceScope.scopedDirectory(
      base: base,
      resourceDirectoryName: 'generated_images',
      accountHash: 'account-a',
    );

    expect(
      directory.path,
      '${base.path}/generated_images/accounts/'
      'fc164f8250803ea8d41834f1de85821035d27d3747e83610789e0f8e5313b9c3',
    );
  });

  test('无 profile 仅允许 guest 路径 fallback，隐式 mutation 校验 fail closed', () {
    LoginSdkConfig.install(LoginSdkConfig(
      baseUrl: 'localhost:3000',
      headerProvider: () async => const {},
      syncHeaders: () => const {},
      routes: LoginRoutes.imooc,
      responseAdapter: ImoocResponseAdapter(),
      storage: _NullTokenStorage(),
      onLogoutNavigate: () {},
    ));
    addTearDown(LoginSdkConfig.reset);

    expect(AccountResourceScope.currentAccountHash(), 'guest');
    expect(
      () => AccountResourceScope.verifyCapturedAccount(
        capturedAccountHash: 'guest',
        explicitAccountHash: false,
      ),
      throwsA(isA<LoginAccountChangedException>()),
    );
    expect(
      () => AccountResourceScope.verifyCapturedAccount(
        capturedAccountHash: 'guest',
        explicitAccountHash: true,
      ),
      returnsNormally,
    );
  });
}

final class _NullTokenStorage implements TokenStorage {
  @override
  Future<void> clear() async {}

  @override
  Future<Map<String, dynamic>?> readProfile() async => null;

  @override
  Map<String, dynamic>? readProfileSync() => null;

  @override
  Future<String?> readToken() async => null;

  @override
  String? readTokenSync() => null;

  @override
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras = const {},
  }) async {}
}
