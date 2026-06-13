/// 当前轮用户消息携带的附件（阶段四：文件解析 + 图片多模态）。
///
/// 对应源项目 `prepareParams/fileProcessor.ts` 的产物：按能力探测结果，
/// 附件已在 UI 层（FileProcessor）分拣成三类——
/// - [images]：模型支持 vision 时的图片（base64 data URI，MIME 已修正）；
/// - [nativeFiles]：模型支持原生文件输入（如 PDF）时的文件 part；
/// - [extraText]：降级路径抽取出的文本（PDF 抽文本 / 文本文件直读），
///   发送时拼接在当前轮 prompt 之后。
///
/// [buildUserContent] 把「prompt + 附件」组装成 OpenAI Chat Completions 的
/// user content（无附件时退化为纯字符串）。本仓库两个 ChatService 实现
/// （直连 / 后端代理）都是 OpenAI 兼容协议，故组装收敛在这一处 ——
/// 将来接入非 OpenAI 协议的 provider 时在其适配层另行转换。
class ChatAttachments {
  /// 图片 data URI（`data:image/...;base64,xxx`）或 http(s) 直链。
  final List<String> images;

  /// 原生发给模型的文件（base64 data URI），仅当 caps.pdf 等能力位为 true。
  final List<NativeFilePart> nativeFiles;

  /// 降级抽取的附件文本，拼进当前轮 prompt（对用户透明）。
  final String extraText;

  const ChatAttachments({
    this.images = const [],
    this.nativeFiles = const [],
    this.extraText = '',
  });

  bool get isEmpty =>
      images.isEmpty && nativeFiles.isEmpty && extraText.isEmpty;

  /// 追加一段降级文本（阶段五：联网搜索结果回填走同一通路），返回新实例。
  ChatAttachments withExtraText(String more) {
    if (more.isEmpty) return this;
    return ChatAttachments(
      images: images,
      nativeFiles: nativeFiles,
      extraText: extraText.isEmpty ? more : '$extraText\n\n$more',
    );
  }

  /// 组装当前轮 user content：
  /// - 无附件 -> 直接返回 [prompt] 字符串（与旧行为完全一致）；
  /// - 有附件 -> OpenAI 多模态 content 数组（text + image_url + file parts）。
  Object buildUserContent(String prompt) {
    if (isEmpty) return prompt;
    final text = extraText.isEmpty ? prompt : '$prompt\n\n$extraText';
    return <Map<String, dynamic>>[
      if (text.isNotEmpty) {'type': 'text', 'text': text},
      for (final img in images)
        {
          'type': 'image_url',
          'image_url': {'url': img},
        },
      for (final f in nativeFiles)
        {
          'type': 'file',
          'file': {'filename': f.filename, 'file_data': f.dataUri},
        },
    ];
  }
}

/// 原生喂给模型的单个文件（OpenAI Chat Completions 的 file content part）。
class NativeFilePart {
  final String filename;

  /// `data:<mime>;base64,xxx` 形式的完整 data URI。
  final String dataUri;

  const NativeFilePart({required this.filename, required this.dataUri});
}
