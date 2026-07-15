/// 平台安全存储的最小抽象。
///
/// `login_sdk` 与业务 core 不直接依赖具体插件；Android/iOS/桌面壳层可注入
/// KeyStore/Keychain 实现，暂无原生插件的平台继续使用既有 HiCache 路径。
abstract interface class SecureKeyValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}
