import 'package:flutter/services.dart';
import 'package:login_sdk/login_sdk.dart';

/// 通过 HarmonyOS HUKS 插件持久化密文；AES 密钥只存在系统 Universal KeyStore。
class OhosHuksSecureKeyValueStore implements SecureKeyValueStore {
  static const MethodChannel _channel =
      MethodChannel('com.hzb.flutter_ai/secure_storage');
  static const String _probeKey = '__secure_storage_probe_v1__';

  @override
  Future<String?> read(String key) =>
      _channel.invokeMethod<String>('read', {'key': key});

  @override
  Future<void> write(String key, String value) =>
      _channel.invokeMethod<void>('write', {'key': key, 'value': value});

  @override
  Future<void> delete(String key) =>
      _channel.invokeMethod<void>('delete', {'key': key});

  /// 启动前做完整写入/读回/删除探测。插件缺失或 HUKS 不可用时 release
  /// 直接启动失败，绝不静默回退到 plaintext preferences。
  Future<void> ensureAvailable() async {
    final marker = DateTime.now().microsecondsSinceEpoch.toString();
    await write(_probeKey, marker);
    final restored = await read(_probeKey);
    if (restored != marker) {
      throw StateError('HarmonyOS 安全存储写入校验失败');
    }
    await delete(_probeKey);
  }
}
