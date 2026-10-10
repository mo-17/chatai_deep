/// 单个附件及本轮附件合计的本地处理限制。按请求传入，避免账号切换时使用旧配置。
final class AttachmentProcessingLimits {
  static const int defaultMaxTextChars = 200000;
  static const int minTextChars = 1024;
  static const int maximumTextChars = 1048576;

  static const int defaultMaxTextFileBytes = 10 * 1024 * 1024;
  static const int minTextFileBytes = 1024 * 1024;
  static const int maximumTextFileBytes = 32 * 1024 * 1024;

  static const int defaultMaxTotalFileBytes = 64 * 1024 * 1024;
  static const int minTotalFileBytes = 1024 * 1024;
  static const int maximumTotalFileBytes = 256 * 1024 * 1024;

  static const int defaultMaxTotalTextChars = 1000000;
  static const int minTotalTextChars = 1024;
  static const int maximumTotalTextChars = 4194304;

  final int maxTextChars;
  final int maxTextFileBytes;

  /// 图片与文件本轮合计的原始字节上限，附件数量不另设固定上限。
  final int maxTotalFileBytes;

  /// 抽取正文与附件标记本轮合计的字符上限；任务模式按导入原文计。
  /// 图片与原生 PDF 不计字符，但仍受大小与模型输入预算限制。
  final int maxTotalTextChars;

  const AttachmentProcessingLimits({
    this.maxTextChars = defaultMaxTextChars,
    this.maxTextFileBytes = defaultMaxTextFileBytes,
    this.maxTotalFileBytes = defaultMaxTotalFileBytes,
    this.maxTotalTextChars = defaultMaxTotalTextChars,
  });

  /// 旧备份或外部调用传入非法值时，每个字段分别回退默认值。
  AttachmentProcessingLimits get normalized => AttachmentProcessingLimits(
        maxTextChars:
            maxTextChars >= minTextChars && maxTextChars <= maximumTextChars
                ? maxTextChars
                : defaultMaxTextChars,
        maxTextFileBytes: maxTextFileBytes >= minTextFileBytes &&
                maxTextFileBytes <= maximumTextFileBytes
            ? maxTextFileBytes
            : defaultMaxTextFileBytes,
        maxTotalFileBytes: maxTotalFileBytes >= minTotalFileBytes &&
                maxTotalFileBytes <= maximumTotalFileBytes
            ? maxTotalFileBytes
            : defaultMaxTotalFileBytes,
        maxTotalTextChars: maxTotalTextChars >= minTotalTextChars &&
                maxTotalTextChars <= maximumTotalTextChars
            ? maxTotalTextChars
            : defaultMaxTotalTextChars,
      );
}
