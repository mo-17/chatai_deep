import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'import_operation.dart';

enum KnowledgeImportErrorKind {
  duplicate,
  cancelled,
  encrypted,
  damaged,
  tooLarge,
  missing,
  permission,
  unsupported,
  noText,
  timeout,
  busy,
  recognition,
  failed,
}

class KnowledgeImportFailure implements Exception {
  final KnowledgeImportErrorKind kind;
  final String message;
  const KnowledgeImportFailure(this.kind, this.message);

  static KnowledgeImportFailure from(Object error, {bool pdf = false}) {
    if (error is KnowledgeImportFailure) return error;
    if (error is ImportCancelled) {
      return const KnowledgeImportFailure(
          KnowledgeImportErrorKind.cancelled, '已取消，未继续导入');
    }
    if (error is TimeoutException) {
      return const KnowledgeImportFailure(
          KnowledgeImportErrorKind.timeout, '文字识别超时，请稍后重试或拆分文件');
    }
    if (error is PlatformException) {
      return switch (error.code) {
        'file_cache_full' => const KnowledgeImportFailure(
            KnowledgeImportErrorKind.tooLarge,
            '文件缓存已满，请到「我的 → 存储管理」清理无引用副本后重试'),
        'ocr_busy' => const KnowledgeImportFailure(
            KnowledgeImportErrorKind.busy, '文字识别仍在结束上一任务，请稍后重试'),
        'ocr_cancelled' => const KnowledgeImportFailure(
            KnowledgeImportErrorKind.cancelled, '识别已中断，请保持应用在前台后重试'),
        _ => const KnowledgeImportFailure(
            KnowledgeImportErrorKind.recognition, '无法识别图片或扫描页，请检查文件后重试'),
      };
    }
    if (error is FileSystemException) {
      final code = error.osError?.errorCode;
      return code == 2
          ? const KnowledgeImportFailure(
              KnowledgeImportErrorKind.missing, '导入文件已不存在，请重新选择')
          : const KnowledgeImportFailure(
              KnowledgeImportErrorKind.permission, '无法读取文件，请重新选择并授予访问权限');
    }
    // 不向界面透传底层异常、路径或文档正文。
    final detail =
        error is FormatException ? error.message.toString() : error.toString();
    final lower = detail.toLowerCase();
    if (detail == 'OCR 页数与原 PDF 不一致，请重新导入') {
      return const KnowledgeImportFailure(
          KnowledgeImportErrorKind.recognition, 'OCR 页数与原 PDF 不一致，请重新导入');
    }
    if (detail == 'PDF文字超过导入预算，请拆分或提高限额') {
      return const KnowledgeImportFailure(
          KnowledgeImportErrorKind.tooLarge, 'PDF文字超过导入预算，请拆分或提高限额');
    }
    if (detail.contains('未重复导入') || detail.contains('内容已存在')) {
      return const KnowledgeImportFailure(
          KnowledgeImportErrorKind.duplicate, '该内容已导入，无需重复导入');
    }
    if (lower.contains('password') ||
        lower.contains('encrypted') ||
        detail.contains('加密')) {
      return const KnowledgeImportFailure(
          KnowledgeImportErrorKind.encrypted, 'PDF 已加密，请先解密后导入');
    }
    if (detail.contains('过大') ||
        detail.contains('超过') ||
        detail.contains('超限') ||
        detail.contains('预算')) {
      // 仅保留本地预算校验生成的固定中文消息。
      final message = error is FormatException &&
              RegExp(r'^导入文件过大（最多 [0-9]+ (MiB|bytes)）$').hasMatch(detail)
          ? detail
          : detail.contains('页数超过')
              ? 'PDF页数超过当前导入上限，请拆分后导入'
              : '文件或正文超过导入预算，请拆分后导入';
      return KnowledgeImportFailure(KnowledgeImportErrorKind.tooLarge, message);
    }
    if (detail.contains('不存在')) {
      return const KnowledgeImportFailure(
          KnowledgeImportErrorKind.missing, '导入文件已不存在，请重新选择');
    }
    if (pdf) {
      return const KnowledgeImportFailure(
          KnowledgeImportErrorKind.damaged, 'PDF 损坏或格式无法解析，请重新导出后导入');
    }
    return const KnowledgeImportFailure(
        KnowledgeImportErrorKind.failed, '文件解析失败，请检查文件格式后重试');
  }
}
