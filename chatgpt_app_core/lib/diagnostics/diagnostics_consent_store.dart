import 'package:flutter_hi_cache/flutter_hi_cache.dart';

abstract interface class DiagnosticsConsentKeyValueStore {
  Object? read(String key);

  Future<bool> writeBool(String key, bool value);
}

/// 当前进程内的隐私否决状态。
///
/// 持久化失败时仍需立即停止上传，因此 deny 的优先级高于底层 cache。
final class DiagnosticsConsentSessionState {
  bool _denied = false;

  bool get denied => _denied;

  void _deny() => _denied = true;

  void _allow() => _denied = false;
}

/// HiCache 的可等待适配器。
///
/// 不调用 HiCache.setBool，因为旧 wrapper 会丢弃 SharedPreferences 返回的
/// Future，导致 UI 无法知道写盘是否成功。
final class HiCacheDiagnosticsConsentKeyValueStore
    implements DiagnosticsConsentKeyValueStore {
  const HiCacheDiagnosticsConsentKeyValueStore();

  @override
  Object? read(String key) => HiCache.getInstance().prefs?.get(key);

  @override
  Future<bool> writeBool(String key, bool value) async {
    final preferences = HiCache.getInstance().prefs;
    if (preferences == null) {
      throw StateError('HiCache 尚未初始化');
    }
    return preferences.setBool(key, value);
  }
}

/// 设备全局诊断同意状态；缺失、旧版本和损坏值均默认关闭。
final class DiagnosticsConsentStore {
  static const key = 'diagnostics_consent_v1';
  static final DiagnosticsConsentSessionState _globalSession =
      DiagnosticsConsentSessionState();

  final DiagnosticsConsentKeyValueStore _storage;
  final DiagnosticsConsentSessionState? _session;

  const DiagnosticsConsentStore({
    DiagnosticsConsentKeyValueStore storage =
        const HiCacheDiagnosticsConsentKeyValueStore(),
    DiagnosticsConsentSessionState? session,
  })  : _storage = storage,
        _session = session;

  DiagnosticsConsentSessionState get _effectiveSession =>
      _session ?? _globalSession;

  bool read() {
    if (_effectiveSession.denied) return false;
    try {
      return _storage.read(key) == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> write(bool value) async {
    final session = _effectiveSession;
    final previous = read();
    // SharedPreferences 会先改进程内 cache 再等待平台写盘。所有写入都先 deny，
    // 防止“启用”尚未确认或最终失败时出现短暂上传窗口。
    session._deny();
    late final bool persisted;
    try {
      persisted = await _storage.writeBool(key, value);
    } catch (error, stackTrace) {
      session._deny();
      await _restore(previous);
      Error.throwWithStackTrace(error, stackTrace);
    }
    if (!persisted) {
      session._deny();
      await _restore(previous);
      throw StateError('诊断同意设置未能持久化');
    }
    if (value) {
      session._allow();
    } else {
      session._deny();
    }
  }

  Future<void> _restore(bool value) async {
    try {
      // SharedPreferences 会在平台写入完成前先改内存 cache；失败时再写回
      // 最后确认值，确保当前会话不会把失败的“同意”当成已生效。
      await _storage.writeBool(key, value);
    } catch (_) {
      // 保留原始写入异常；会话 deny 仍保证当前进程 fail-closed。
    }
  }
}
