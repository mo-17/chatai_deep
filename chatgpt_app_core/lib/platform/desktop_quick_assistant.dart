import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:login_sdk/platform/app_io.dart';
import '../backup/backup_service.dart';
import '../chat/application/ocr_task_center.dart';
import '../dao/ai_catalog_dao.dart';
import '../pages/ocr_task_center_page.dart';
import '../util/uuid_v4.dart';

class DesktopQuickAssistant extends ChangeNotifier {
  static final instance = DesktopQuickAssistant();
  static const channel = MethodChannel('aipu/desktop-assistant');
  static const _key = 'desktop_quick_assistant_enabled';
  bool get supported => !kIsWeb && (Platform.isMacOS || Platform.isWindows);
  bool enabled = false;
  String? error;
  GlobalKey<NavigatorState>? _navigator;
  bool _tasksOpen = false;
  final _captures =
      <String, ({AiCatalogIdentity identity, int restore, DateTime at})>{};
  Future<void> initialize(GlobalKey<NavigatorState> navigator) async {
    if (!supported) return;
    _navigator = navigator;
    channel.setMethodCallHandler(handle);
    if (HiCache.getInstance().get(_key) == true) await configure(true);
  }

  Future<void> configure(bool value) async {
    if (!supported) return;
    try {
      final applied =
          await channel.invokeMethod<bool>('configure', {'enabled': value});
      if (applied != value) throw PlatformException(code: 'unavailable');
      enabled = value;
      error = null;
      await HiCache.getInstance().setBool(_key, value);
    } catch (_) {
      enabled = false;
      error = '快捷助手未启用，请检查快捷键占用或系统权限后重试';
      await HiCache.getInstance().setBool(_key, false);
    }
    notifyListeners();
  }

  Future<void> capture() async {
    if (!supported) return;
    try {
      await channel.invokeMethod<void>('capture');
    } catch (_) {
      _notice('截图未完成，请检查系统屏幕录制权限后重试');
    }
  }

  Future<Object?> handle(MethodCall call) async {
    if (call.method == 'beginCapture') {
      final identity = AiCatalogIdentity.capture();
      if (!identity.authenticated || _navigator?.currentState == null) {
        _notice('请先登录后使用截图 OCR');
        return null;
      }
      final id = generateUuidV4();
      _captures.clear();
      _captures[id] = (
        identity: identity,
        restore: BackupService.restoreTick.value,
        at: DateTime.now()
      );
      return id;
    }
    if (call.method == 'captureCancelled' || call.method == 'captureFailed') {
      final args = call.arguments;
      if (args is Map) _captures.remove(args['token']);
      if (call.method == 'captureFailed') _notice('截图未完成，请检查屏幕录制权限或重新选择区域');
    } else if (call.method == 'captured') {
      final args = call.arguments;
      if (args is! Map ||
          args['token'] is! String ||
          args['bytes'] is! Uint8List) {
        return null;
      }
      final scope = _captures.remove(args['token']);
      bool current() =>
          scope != null &&
          scope.identity.current &&
          scope.restore == BackupService.restoreTick.value &&
          DateTime.now().difference(scope.at) < const Duration(minutes: 2);
      if (!current()) {
        _notice('账号已变化或截图已过期，请重新截图');
        return null;
      }
      final bytes = args['bytes'] as Uint8List;
      if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
        _notice('截图超过 8 MiB，请选择更小的区域');
        return null;
      }
      try {
        final service = await OcrTaskCenter.open();
        if (!current()) return null;
        await service.add(
            '截图_${DateTime.now().millisecondsSinceEpoch}.png', bytes);
        if (current()) await openTasks();
      } catch (_) {
        _notice('截图未保存，请检查账号或任务中心存储空间');
      }
    } else if (call.method == 'tasks') {
      await openTasks();
    }
    return null;
  }

  Future<void> openTasks() async {
    final navigator = _navigator?.currentState;
    if (navigator == null || _tasksOpen) return;
    _tasksOpen = true;
    try {
      await navigator
          .push(MaterialPageRoute(builder: (_) => const OcrTaskCenterPage()));
    } finally {
      _tasksOpen = false;
    }
  }

  void _notice(String message) {
    final context = _navigator?.currentContext;
    if (context != null) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(message)));
    }
  }
}
