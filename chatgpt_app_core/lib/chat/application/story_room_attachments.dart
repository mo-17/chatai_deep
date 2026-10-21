import 'package:login_sdk/platform/app_io.dart';

import 'package:chatgpt_app_core/chat/application/attachment_batch_budget.dart';
import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';

/// 酒馆房间附件去重和历史重建规则；新附件数量不设固定上限。
class StoryRoomAttachmentPolicy {
  const StoryRoomAttachmentPolicy._();

  static List<String> normalizePaths(
    Iterable<String> paths, {
    int? limit,
  }) {
    if (limit != null && limit <= 0) return [];
    final seen = <String>{};
    final result = <String>[];
    for (final raw in paths) {
      final path = raw.trim();
      if (path.isEmpty || !seen.add(path)) continue;
      result.add(path);
      if (limit != null && result.length >= limit) break;
    }
    return result;
  }

  /// 旧消息没有附件字段时保持原来的纯文本历史；新消息把已抽取文本接在
  /// 用户内容之后，使重开房间后仍能把降级文件上下文发回模型。
  static String historyContent(StoryMessageModel message) {
    final text = message.content.trim();
    final attachmentText = message.attachmentContext.trim();
    if (attachmentText.isEmpty) return text;
    if (text.isEmpty) return attachmentText;
    return '$text\n\n$attachmentText';
  }
}

/// 当前轮发给每个角色的同一份附件包。
class StoryRoomAttachmentBundle {
  final List<String> imagePaths;
  final List<String> filePaths;
  final String attachmentContext;
  final ChatAttachments attachments;

  const StoryRoomAttachmentBundle({
    this.imagePaths = const [],
    this.filePaths = const [],
    this.attachmentContext = '',
    this.attachments = const ChatAttachments(),
  });

  bool get isEmpty => attachments.isEmpty;
}

/// 把故事房间选择的本地路径转换成 provider 无关的附件包。
///
/// 图片只在模型支持 vision 时编码进请求；文件交给 [FileProcessor] 决定走
/// 原生 PDF 还是抽文本降级。路径和降级文本另外留在 [StoryMessageModel]，用于
/// 重建历史和重新生成。旧消息恢复仍容错失效路径；新附件须通过完整预检。
class StoryRoomAttachmentService {
  const StoryRoomAttachmentService._();

  static Future<StoryRoomAttachmentBundle> prepare({
    required Iterable<String> imagePaths,
    required Iterable<String> filePaths,
    required ModelCapabilities capabilities,
    AttachmentProcessingLimits limits = const AttachmentProcessingLimits(),
    String fallbackContext = '',
    bool reuseExtractedContext = false,
    AttachmentBatchBudget? batchBudget,
    bool Function()? isCancelled,
  }) async {
    final images = StoryRoomAttachmentPolicy.normalizePaths(imagePaths);
    final files = StoryRoomAttachmentPolicy.normalizePaths(filePaths);
    final budget = reuseExtractedContext
        ? AttachmentBatchBudget.forHistoricalRetry()
        : batchBudget ?? AttachmentBatchBudget(limits: limits);
    void checkCancelled() {
      if (isCancelled?.call() == true) {
        throw const AttachmentProcessingCancelledException();
      }
    }

    checkCancelled();
    if (!reuseExtractedContext) {
      await budget
          .preflightPaths([...images, ...files], isCancelled: isCancelled);
    }

    final imageData = <String>[];
    final savedImagePaths =
        reuseExtractedContext || !capabilities.image ? images : <String>[];
    if (capabilities.image) {
      for (final path in images) {
        checkCancelled();
        try {
          if (await appFile(path).exists()) {
            imageData.add(await FileProcessor.encodeImage(path,
                batchBudget: reuseExtractedContext ? null : budget,
                onSnapshot: reuseExtractedContext ? null : savedImagePaths.add,
                isCancelled: isCancelled));
          } else if (!reuseExtractedContext) {
            throw const FormatException('图片附件不存在');
          }
        } on AttachmentBatchLimitException {
          rethrow;
        } on AttachmentProcessingCancelledException {
          rethrow;
        } catch (_) {
          if (!reuseExtractedContext) rethrow;
          // 单张图片损坏时保留其路径用于消息摘要，跳过本次请求编码。
        }
      }
    }

    var processed = const ProcessedFiles();
    final savedContext = fallbackContext.trim();
    final filesToProcess = reuseExtractedContext && savedContext.isNotEmpty
        ? files
            .where((path) =>
                capabilities.pdf && path.toLowerCase().endsWith('.pdf'))
            .toList()
        : files;
    if (filesToProcess.isNotEmpty) {
      checkCancelled();
      try {
        processed = await FileProcessor.process(filesToProcess, capabilities,
            limits: limits, batchBudget: budget, isCancelled: isCancelled);
      } on AttachmentBatchLimitException {
        rethrow;
      } on AttachmentProcessingCancelledException {
        rethrow;
      } catch (_) {
        if (!reuseExtractedContext) rethrow;
        // 历史文件可能已被系统清理，使用落库的旧文本上下文继续请求。
      }
    }
    checkCancelled();
    final extracted = processed.extraText.trim();
    // 重试沿用已保存的正文，后续降低上限或修改源文件不会改变旧提问。
    final context = reuseExtractedContext && savedContext.isNotEmpty
        ? savedContext
        : (extracted.isNotEmpty ? extracted : savedContext);
    return StoryRoomAttachmentBundle(
      imagePaths: savedImagePaths,
      filePaths: files,
      attachmentContext: context,
      attachments: ChatAttachments(
        images: imageData,
        nativeFiles: processed.nativeFiles,
        extraText: context,
      ),
    );
  }
}
