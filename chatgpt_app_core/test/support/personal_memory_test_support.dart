import 'package:login_sdk/login_sdk.dart';

class PersonalMemoryTestAccount implements TokenStorage {
  String account;
  PersonalMemoryTestAccount(this.account);
  void install() => LoginSdkConfig.install(LoginSdkConfig(
      baseUrl: 'localhost:3000',
      headerProvider: () async => const {},
      syncHeaders: () => const {},
      routes: LoginRoutes.imooc,
      responseAdapter: ImoocResponseAdapter(),
      storage: this,
      onLogoutNavigate: () {}));
  @override
  Future<void> clear() async {}
  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();
  @override
  Map<String, dynamic>? readProfileSync() => {
        'userName': '离线合成用户',
        'avatar': '',
        'accountHash': account,
        'guest': account == 'guest'
      };
  @override
  Future<String?> readToken() async => readTokenSync();
  @override
  String? readTokenSync() => 'guest-mode';
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {}
}
