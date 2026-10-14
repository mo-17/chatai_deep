import 'package:login_sdk/config/token_storage.dart';

class MemoryTokenStorage implements TokenStorage {
  Map<String, dynamic>? _profile;

  @override
  Future<String?> readToken() async => readTokenSync();

  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();

  @override
  String? readTokenSync() => _profile?['boardingPass'] as String?;

  @override
  Map<String, dynamic>? readProfileSync() => _profile;

  @override
  Future<void> writeProfile({
    required String token,
    required String userName,
    String? avatar,
    Map<String, dynamic> extras = const {},
  }) async {
    _profile = <String, dynamic>{
      'boardingPass': token,
      'userName': userName,
      'avatar': avatar,
      'accountHash': userName.hashCode.toString(),
      ...extras,
    };
  }

  @override
  Future<void> clear() async => _profile = null;
}
