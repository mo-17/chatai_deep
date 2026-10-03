/// 单个附件的本地读取与文字提取限制。按请求传入，避免账号切换时使用旧配置。
final class AttachmentProcessingLimits {
  static const int defaultMaxTextChars = 200000;
  static const int minTextChars = 1024;
  static const int maximumTextChars = 1048576;

  static const int defaultMaxTextFileBytes = 10 * 1024 * 1024;
  static const int minTextFileBytes = 1024 * 1024;
  static const int maximumTextFileBytes = 32 * 1024 * 1024;

  final int maxTextChars;
  final int maxTextFileBytes;

  const AttachmentProcessingLimits({
    this.maxTextChars = defaultMaxTextChars,
    this.maxTextFileBytes = defaultMaxTextFileBytes,
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
      );
}
