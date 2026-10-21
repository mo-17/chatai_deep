import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../backup/backup_service.dart';
import '../../dao/ai_catalog_dao.dart';
import '../../db/hi_db_manager.dart';
import '../../db/ocr_task_dao.dart';
import '../../knowledge/knowledge_library.dart';
import 'file_processor.dart';
import 'import_operation.dart';
import 'knowledge_import_error.dart';
import 'pdf_ocr_result.dart';
import 'server_ocr_client.dart';

/// 本机有界串行队列。只有用户再次确认后才上传；重启不会自动重发原件。
class OcrTaskCenter extends ChangeNotifier {
  final OcrTaskDao dao;
  final String origin;
  final String account;
  final bool Function() _isCurrent;
  final ServerOcrClient Function() _createClient;
  bool _retired = false, _pumping = false, _wake = false;
  ImportCancellation? _active;
  String? activeId;
  String progress = '';
  Future<void>? _idle;
  final Set<String> _approved = {};
  final List<DateTime> _uploadTimes = [];

  OcrTaskCenter(
      {required this.dao,
      required this.origin,
      this.account = 'guest',
      required bool Function() isCurrent,
      required ServerOcrClient Function() createClient})
      : _isCurrent = isCurrent,
        _createClient = createClient;
  static Future<OcrTaskCenter>? _shared;
  static AiCatalogIdentity? _sharedIdentity;
  static int? _sharedRestore;

  static Future<OcrTaskCenter> open() {
    final identity = AiCatalogIdentity.capture();
    final restore = BackupService.restoreTick.value;
    if (!identity.authenticated) {
      throw const KnowledgeImportFailure(
          KnowledgeImportErrorKind.permission, '登录后可使用 OCR 任务中心');
    }
    if (_shared != null &&
        _sharedIdentity?.sameAs(identity) == true &&
        _sharedRestore == restore) {
      return _shared!;
    }
    final old = _shared;
    if (old != null) {
      unawaited(old.then((s) => s.retire(), onError: (Object _) {}));
    }
    _sharedIdentity = identity;
    _sharedRestore = restore;
    final pending = _shared = (() async {
      bool current() =>
          identity.current && restore == BackupService.restoreTick.value;
      if (!current()) throw const ImportCancelled();
      final storage = await HiDBManager.instance(dbName: identity.account!);
      if (!current()) throw const ImportCancelled();
      final dao = await OcrTaskDao.create(storage);
      final service = OcrTaskCenter(
          dao: dao,
          origin: identity.endpoint.origin,
          account: identity.account!,
          isCurrent: current,
          createClient: () =>
              ServerOcrClient.capture(additionalCurrent: current));
      await service.recover();
      return service;
    })();
    unawaited(pending.then<void>((_) {}, onError: (Object _, StackTrace __) {
      if (identical(_shared, pending)) _shared = null;
    }));
    return pending;
  }

  bool get current => !_retired && _isCurrent();
  Future<void> get settled => _idle ?? Future.value();
  void verify() {
    if (!current) throw const ImportCancelled();
  }

  Future<void> recover() async {
    verify();
    await dao.recover(verify);
  }

  Future<List<OcrTaskRecord>> list() async {
    verify();
    final rows = await dao.list();
    verify();
    return rows;
  }

  Future<OcrTaskData?> load(String id) async {
    verify();
    final row = await dao.load(id);
    verify();
    return row;
  }

  Future<String> add(String name, Uint8List bytes) async {
    verify();
    final safeName = name.replaceAll('\\', '/').split('/').last;
    final ext = safeName.split('.').last.toLowerCase();
    if (ext != 'pdf' && !FileProcessor.ocrImageExtensions.contains(ext)) {
      throw const FormatException('仅支持 PDF、PNG、JPEG、WebP 和 BMP');
    }
    final id = await dao.add(
        name: safeName,
        origin: origin,
        pdf: ext == 'pdf',
        bytes: bytes,
        verify: verify);
    _notify();
    return id;
  }

  /// 调用方必须先展示目标后端、文件数量及原件/结果保留规则。
  Future<void> start(List<String> ids) async {
    verify();
    final rows = await list();
    final selected =
        rows.where((r) => ids.contains(r.id) && r.retryable).toList();
    for (final row in selected) {
      if (row.origin != origin) {
        throw const FormatException('后端地址已变化，请重新选择文件创建任务');
      }
      if (activeId == row.id) {
        throw const FormatException('正在清理上次识别，请稍后重试');
      }
    }
    for (final row in selected) {
      _approved.add(row.id);
      await dao.transition(row.id, {row.state}, OcrTaskState.queued,
          verify: verify, clearResult: true);
    }
    _wake = true;
    _notify();
    if (!_pumping) {
      _pumping = true;
      _idle = _pump().whenComplete(() {
        _pumping = false;
        _notify();
      });
      unawaited(_idle!.catchError((Object _) {}));
    }
  }

  Future<void> _pump() async {
    while (current) {
      _wake = false;
      final rows = await list();
      if (!current) return;
      final next = rows
          .where(
              (r) => r.state == OcrTaskState.queued && _approved.contains(r.id))
          .firstOrNull;
      if (next == null) {
        if (_wake) continue;
        return;
      }
      final cancellation = _active = ImportCancellation();
      activeId = next.id;
      progress = '准备上传';
      _notify();
      try {
        if (!await dao.transition(
            next.id, {OcrTaskState.queued}, OcrTaskState.running,
            verify: verify)) {
          continue;
        }
        final data = await load(next.id);
        cancellation.check();
        if (data == null) continue;
        final client = _createClient();
        if (client.base.origin != origin) throw const ImportCancelled();
        await _waitUploadSlot(cancellation);
        verify();
        cancellation.check();
        _uploadTimes.add(DateTime.now());
        final result = await client.recognizeBytes(data.bytes,
            pdf: data.task.pdf,
            includePreview: true,
            cancellation: cancellation, onProgress: (stage, page, total) {
          if (current && !cancellation.isCancelled) {
            progress =
                '$stage${page == null || total == null ? '' : '（$page/$total 页）'}';
            _notify();
          }
        });
        verify();
        cancellation.check();
        await dao.transition(
            next.id, {OcrTaskState.running}, OcrTaskState.review,
            verify: verify, result: result);
      } catch (error) {
        if (current) {
          await dao.transition(
              next.id,
              {OcrTaskState.running, OcrTaskState.queued},
              cancellation.isCancelled
                  ? OcrTaskState.cancelled
                  : OcrTaskState.failed,
              verify: verify,
              error:
                  cancellation.isCancelled ? '已取消，可手动重试' : _safeError(error));
        }
      } finally {
        _approved.remove(next.id);
        _active = null;
        activeId = null;
        progress = '';
        _notify();
      }
    }
  }

  Future<void> cancel(String id) async {
    verify();
    if (activeId == id) _active?.cancel();
    _approved.remove(id);
    await dao.transition(
        id,
        {OcrTaskState.waiting, OcrTaskState.queued, OcrTaskState.running},
        OcrTaskState.cancelled,
        verify: verify,
        error: '已取消，可手动重试');
    _notify();
  }

  Future<void> _waitUploadSlot(ImportCancellation cancellation) async {
    final now = DateTime.now();
    _uploadTimes.removeWhere(
        (time) => now.difference(time) >= const Duration(seconds: 61));
    if (_uploadTimes.length < 6) return;
    progress = '等待上传频率窗口';
    _notify();
    final ready = Completer<void>();
    final remaining =
        const Duration(seconds: 61) - now.difference(_uploadTimes.first);
    final timer = Timer(remaining, () {
      if (!ready.isCompleted) ready.complete();
    });
    final remove = cancellation.listen(() {
      if (!ready.isCompleted) ready.complete();
    });
    try {
      await ready.future;
    } finally {
      timer.cancel();
      remove();
    }
  }

  Future<void> saveCorrection(String id, PdfOcrResult result) async {
    verify();
    final original = await load(id);
    if (original == null || original.result == null) {
      throw const FormatException('识别任务已不存在');
    }
    final corrected = original.result!.corrected(result.pages);
    if (!await dao.transition(id, {OcrTaskState.review, OcrTaskState.completed},
        OcrTaskState.completed,
        verify: verify, result: corrected)) {
      throw const FormatException('任务状态已变化，请重新打开');
    }
    _notify();
  }

  Future<void> importKnowledge(String id) async {
    final data = await load(id);
    if (data == null ||
        data.task.state != OcrTaskState.completed ||
        data.result == null) {
      throw const FormatException('请先核对并保存识别文字');
    }
    final library =
        await KnowledgeLibrary.create(dao.storage, account: account);
    verify();
    final title = data.task.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final docId = await library.add(title, data.result!.pages,
        pdf: data.task.pdf, beforeCommit: verify);
    if (docId == null) throw const FormatException('没有可导入的文字');
    try {
      verify();
      if (data.task.pdf) await library.preservePdf(docId, data.bytes);
      verify();
    } catch (_) {
      try {
        await library.dao.deleteDocument(docId);
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> delete(String id) async {
    verify();
    if (activeId == id) _active?.cancel();
    _approved.remove(id);
    await dao.delete(id, verify);
    _notify();
  }

  void retire() {
    _retired = true;
    _approved.clear();
    _active?.cancel();
  }

  void _notify() {
    if (current) notifyListeners();
  }

  static String _safeError(Object error) => error is FormatException
      ? error.message.toString()
      : error is KnowledgeImportFailure
          ? error.message
          : '识别未完成，请检查网络后重试';
}
