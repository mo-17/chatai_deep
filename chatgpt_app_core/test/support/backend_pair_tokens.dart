import 'package:login_sdk/login_sdk.dart';

/// 独立的合成登录状态，供常规测试使用，不依赖外部验收脚本。
class PairTokens implements TokenStorage {
  String account = 'account-a', token = 'synthetic-jwt';
  int clears = 0;

  @override
  Future<void> clear() async {
    clears++;
    token = '';
  }

  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();
  @override
  Map<String, dynamic>? readProfileSync() =>
      {'accountHash': account, 'userName': 'synthetic'};
  @override
  Future<String?> readToken() async => readTokenSync();
  @override
  String? readTokenSync() => token.isEmpty ? null : token;
  @override
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras = const {},
  }) async {
    this.token = token;
    account = extras['accountHash']?.toString() ?? account;
  }
}
