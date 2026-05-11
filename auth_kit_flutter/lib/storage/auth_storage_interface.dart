/// Token 存储接口 —— 宿主项目实现（如通过 HiCache / SharedPreferences）。
abstract class IAuthStorage {
  Future<String?> getToken();
  Future<void> setToken(String token);
  Future<void> removeToken();
}
