import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:login_sdk/login_sdk.dart';

/// 标准 Flutter 壳层的 KeyStore/Keychain 适配器。
///
/// namespace 一经发布不得修改，否则平台会把它视为另一套空存储。Apple 使用
/// first-unlock-this-device，确保系统后台任务在设备首次解锁后也能恢复账号任务，
/// 同时不通过 iCloud Keychain 跨设备同步用户凭据。
class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: false,
      migrateOnAlgorithmChange: true,
      migrateWithBackup: true,
      storageNamespace: 'chatai_deep_v1',
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
