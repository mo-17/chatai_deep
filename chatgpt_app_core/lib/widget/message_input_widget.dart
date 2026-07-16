import 'dart:io';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// 根据偏好 / 系统 locale 选择最匹配的语音识别 localeId。
///
/// 返回 null 表示交给 speech_to_text 使用平台默认语言；永远不返回空字符串，
/// 避免部分原生实现收到 `localeId: ''` 后崩溃。
String? pickSpeechLocaleId(
  List<stt.LocaleName> locales, {
  String? preferredLocale,
  String? systemLocale,
}) {
  final candidates = locales
      .map((l) => l.localeId.trim())
      .where((id) => id.isNotEmpty)
      .toList();
  if (candidates.isEmpty) return null;
  final sysLocale = _normalizeSpeechLocale(preferredLocale) ??
      _normalizeSpeechLocale(systemLocale) ??
      _normalizeSpeechLocale(Platform.localeName);
  if (sysLocale == null) return candidates.first;
  // 精确匹配
  for (final id in candidates) {
    if (_normalizeSpeechLocale(id) == sysLocale) return id;
  }
  // 语言前缀匹配
  final lang = sysLocale.split('_').first;
  if (lang.isNotEmpty) {
    for (final id in candidates) {
      final normalized = _normalizeSpeechLocale(id);
      if (normalized != null && normalized.split('_').first == lang) {
        return id;
      }
    }
  }
  // 降级到系统默认
  return candidates.first;
}

String? _normalizeSpeechLocale(String? locale) {
  final value = locale?.trim();
  if (value == null || value.isEmpty) return null;
  return value.replaceAll('-', '_');
}

///聊天输入框
class MessageInputWidget extends StatefulWidget {
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSend;

  /// 同步发送闸门。返回 false 时不调用 [onSend]，也不清空输入内容。
  final bool Function()? canSend;
  final VoidCallback? onStop;
  final ValueChanged<List<String>>? onImagesPicked;
  final List<String> pendingImages;
  final ValueChanged<int>? onRemoveImage;
  final bool imagesEnabled;
  final String imagesDisabledReason;

  /// 待发送的文件（阶段四）。文件入口不按能力位关闭 —— 模型不支持原生
  /// 文件时走「抽文本拼 prompt」降级路径，任何模型都可用。
  final ValueChanged<List<String>>? onFilesPicked;
  final List<String> pendingFiles;
  final ValueChanged<int>? onRemoveFile;

  /// 联网搜索开关（阶段五）。独立于模型能力位 —— 搜索结果以上下文回填，
  /// 任何模型都可用；仅在配置了搜索 API Key 时展示（[showWebSearch]）。
  final bool showWebSearch;
  final bool webSearchEnabled;
  final VoidCallback? onToggleWebSearch;
  final String? modelLabel;
  final VoidCallback? onModelTap;
  final String hint;
  final String initialText;
  final TextEditingController? controller;
  final bool enable;
  final bool isStreaming;
  final bool speechInputEnabled;
  final String? speechLocale;

  const MessageInputWidget(
    this.hint, {
    super.key,
    this.onChanged,
    this.onSend,
    this.canSend,
    this.onStop,
    this.onImagesPicked,
    this.pendingImages = const [],
    this.onRemoveImage,
    this.imagesEnabled = true,
    this.imagesDisabledReason = '当前模型不支持图片',
    this.onFilesPicked,
    this.pendingFiles = const [],
    this.onRemoveFile,
    this.showWebSearch = false,
    this.webSearchEnabled = false,
    this.onToggleWebSearch,
    this.modelLabel,
    this.onModelTap,
    this.initialText = '',
    this.controller,
    this.enable = true,
    this.isStreaming = false,
    this.speechInputEnabled = true,
    this.speechLocale,
  });

  @override
  State<MessageInputWidget> createState() => _MessageInputWidgetState();
}

class _MessageInputWidgetState extends State<MessageInputWidget> {
  bool _showSend = false;
  late TextEditingController _controller;
  late bool _ownsController;
  final _focusNode = FocusNode();
  stt.SpeechToText? _speech;
  bool _hasSpeech = true; // 默认显示，初始化失败才隐藏
  bool _isListening = false;
  String _lastWords = '';
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? TextEditingController();
    if (_controller.text.isEmpty && widget.initialText.isNotEmpty) {
      _controller.text = widget.initialText;
    }
    _showSend = _controller.text.isNotEmpty;
    _controller.addListener(_onControllerChanged);
    if (_controller.text.isNotEmpty) widget.onChanged?.call(_controller.text);
    _initSpeech();
  }

  @override
  void didUpdateWidget(covariant MessageInputWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) _controller.dispose();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? TextEditingController();
    _controller.addListener(_onControllerChanged);
    _showSend = _controller.text.isNotEmpty;
  }

  void _onControllerChanged() {
    final text = _controller.text;
    widget.onChanged?.call(text);
    if (mounted && _showSend != text.isNotEmpty) {
      setState(() => _showSend = text.isNotEmpty);
    }
  }

  // iOS 17.0–17.4 模拟器存在 AVAudioEngine sampleRate 不匹配的 bug，
  // 调用 speech_to_text 的 listen() 会抛 NSException 直接终止进程，
  // 这种异常无法被 Dart 的 try-catch 捕获，只能提前禁用语音入口。
  bool _isBrokenIosSimulator() {
    if (!Platform.isIOS) return false;
    final isSimulator =
        Platform.environment.containsKey('SIMULATOR_DEVICE_NAME');
    if (!isSimulator) return false;
    final match = RegExp(r'Version (\d+)\.(\d+)')
        .firstMatch(Platform.operatingSystemVersion);
    if (match == null) return false;
    final major = int.parse(match.group(1)!);
    final minor = int.parse(match.group(2)!);
    return major == 17 && minor < 5;
  }

  Future<void> _initSpeech() async {
    // ohos: speech_to_text 暂无鸿蒙实现，关闭语音入口
    if (Platform.operatingSystem == 'ohos') {
      if (mounted) setState(() => _hasSpeech = false);
      return;
    }
    if (_isBrokenIosSimulator()) {
      debugPrint('skip speech_to_text init: iOS 17.0–17.4 simulator audio bug');
      if (mounted) setState(() => _hasSpeech = false);
      return;
    }
    try {
      _speech = stt.SpeechToText();
      final available = await _speech!.initialize(
        onError: (error) {
          debugPrint(
              'speech error: ${error.errorMsg}, permanent: ${error.permanent}');
          _isListening = false;
        },
        onStatus: (status) {
          debugPrint('speech status: $status');
          if (status == 'done' || status == 'notListening') {
            _isListening = false;
            if (mounted) setState(() {});
          }
        },
        debugLogging: true,
      );
      debugPrint('speech available: $available');
      if (available) {
        final locales = await _speech!.locales();
        debugPrint(
            'speech locales: ${locales.map((l) => l.localeId).toList()}');
      }
      if (mounted) setState(() => _hasSpeech = available);
    } catch (e) {
      debugPrint('speech init exception: $e');
      if (mounted) setState(() => _hasSpeech = false);
    }
  }

  Future<void> _onMicTap() async {
    if (!widget.speechInputEnabled) {
      _focusNode.requestFocus();
      return;
    }
    if (_speech == null) await _initSpeech();

    // 不支持语音识别时，聚焦输入框唤起系统键盘（键盘自带语音按钮）
    if (!_hasSpeech || _speech == null) {
      _focusNode.requestFocus();
      return;
    }

    if (_isListening) {
      await _speech!.stop();
      _isListening = false;
      if (mounted) setState(() {});
      return;
    }

    // 聚焦输入框，确保键盘弹出
    _focusNode.requestFocus();

    _lastWords = _controller.text;
    try {
      final locales = await _speech!.locales();
      final localeId =
          pickSpeechLocaleId(locales, preferredLocale: widget.speechLocale);
      await _speech!.listen(
        onResult: (result) {
          if (!mounted) return;
          final text = '$_lastWords${result.recognizedWords}';
          _controller.text = text;
          _controller.selection = TextSelection.fromPosition(
            TextPosition(offset: text.length),
          );
          setState(() => _showSend = text.isNotEmpty);
        },
        localeId: localeId,
      );
      _isListening = true;
      if (mounted) setState(() {});
    } catch (_) {
      _isListening = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _onPhotoTap() async {
    if (!widget.imagesEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.imagesDisabledReason)),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('拍照'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('从相册选择'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    if (widget.pendingImages.length >= 4) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('最多选择 4 张图片')),
        );
      }
      return;
    }
    try {
      final picked = await _picker.pickImage(
        source: source,
        imageQuality: 70,
        maxWidth: 2048,
        maxHeight: 2048,
      );
      if (picked != null && mounted) {
        widget.onImagesPicked?.call([...widget.pendingImages, picked.path]);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选取图片失败: $e')),
        );
      }
    }
  }

  bool get _showPhotoBtn =>
      Platform.operatingSystem != 'ohos'; // image_picker 暂未支持鸿蒙

  bool get _showFileBtn =>
      Platform.operatingSystem != 'ohos'; // file_picker 暂未支持鸿蒙

  bool get _hasPendingImages => widget.pendingImages.isNotEmpty;

  bool get _hasPendingFiles => widget.pendingFiles.isNotEmpty;

  /// 最多可同时携带的文件数（与下游 FileProcessor 处理多文件同口径）。
  static const int _maxFiles = 10;

  Future<void> _onFileTap() async {
    final remaining = _maxFiles - widget.pendingFiles.length;
    if (remaining <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最多选择 $_maxFiles 个文件')),
      );
      return;
    }
    try {
      // allowMultiple：一次可勾选多个文件；再按剩余配额截断并去重。
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: FileProcessor.pickerExtensions,
        allowMultiple: true,
      );
      if (result == null || !mounted) return;
      // 去重：跳过已在待发送列表里的、以及本批内重复的路径。
      final seen = widget.pendingFiles.toSet();
      final picked = <String>[];
      for (final f in result.files) {
        final p = f.path;
        if (p == null || !seen.add(p)) continue;
        picked.add(p);
      }
      if (picked.isEmpty) return;
      final accepted =
          picked.length > remaining ? picked.sublist(0, remaining) : picked;
      widget.onFilesPicked?.call([...widget.pendingFiles, ...accepted]);
      if (accepted.length < picked.length) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('最多选择 $_maxFiles 个文件，多余的已忽略')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选取文件失败: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _speech?.cancel();
    _focusNode.dispose();
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  get _fileBtn => GestureDetector(
        onTap: _onFileTap,
        child: Container(
          margin: const EdgeInsets.only(right: 6),
          child: const Icon(
            Icons.attach_file,
            color: Colors.grey,
            size: 24,
          ),
        ),
      );

  get _photoBtn => GestureDetector(
        onTap: _onPhotoTap,
        child: Container(
          margin: const EdgeInsets.only(right: 6),
          child: Icon(
            Icons.add_photo_alternate,
            color: widget.imagesEnabled ? Colors.grey : Colors.grey.shade300,
            size: 26,
          ),
        ),
      );

  /// 联网搜索开关：开启时用主题色高亮。
  Widget _webSearchBtn(Color themeColor) => GestureDetector(
        onTap: widget.onToggleWebSearch,
        child: Container(
          margin: const EdgeInsets.only(right: 6),
          child: Icon(
            Icons.travel_explore,
            color: widget.webSearchEnabled ? themeColor : Colors.grey,
            size: 24,
          ),
        ),
      );

  get _micBtn => GestureDetector(
        onTap: _onMicTap,
        child: Container(
          margin: const EdgeInsets.only(right: 6),
          child: Icon(
            _isListening ? Icons.mic : Icons.mic_none,
            color: _isListening ? Colors.red : Colors.grey,
            size: 26,
          ),
        ),
      );

  Widget _animeToolButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool active = false,
    bool danger = false,
    bool muted = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = danger
        ? colorScheme.errorContainer
        : active
            ? colorScheme.secondaryContainer
            : colorScheme.surfaceContainerHighest;
    final foreground = danger
        ? colorScheme.error
        : active
            ? colorScheme.secondary
            : colorScheme.onSurfaceVariant;
    return SizedBox.square(
      dimension: 44,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          minimumSize: const Size.square(44),
          maximumSize: const Size.square(44),
          padding: EdgeInsets.zero,
          backgroundColor: background,
          foregroundColor:
              muted ? foreground.withValues(alpha: 0.45) : foreground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        icon: Icon(icon, size: 22),
      ),
    );
  }

  Widget _animeSendButton(Color color) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: SizedBox.square(
        dimension: 48,
        child: IconButton.filled(
          key: const ValueKey('anime_message_send'),
          tooltip: widget.isStreaming ? '停止生成' : '发送消息',
          style: IconButton.styleFrom(
            minimumSize: const Size.square(48),
            maximumSize: const Size.square(48),
            backgroundColor: widget.isStreaming ? colorScheme.error : color,
            foregroundColor: Colors.white,
            disabledBackgroundColor: color.withValues(alpha: 0.45),
            disabledForegroundColor: Colors.white70,
          ),
          onPressed: widget.isStreaming
              ? widget.onStop
              : (widget.enable ? _onSend : null),
          icon: Icon(
            widget.isStreaming ? Icons.stop_rounded : Icons.send_rounded,
            size: 21,
          ),
        ),
      ),
    );
  }

  get _sendBtn => (color) => Container(
        margin: const EdgeInsets.only(left: 10),
        width: 65,
        child: MaterialButton(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          height: 35,
          disabledColor: color.withValues(alpha: 0.6),
          color: widget.isStreaming ? Colors.red : color,
          onPressed: widget.isStreaming
              ? widget.onStop
              : (widget.enable ? _onSend : null),
          child: Icon(
            widget.isStreaming ? Icons.stop : Icons.send,
            color: Colors.white,
            size: 18,
          ),
        ),
      );

  Widget _buildThumbnailBar({bool isAnime = false}) {
    if (!_hasPendingImages) return const SizedBox.shrink();
    return Container(
      height: isAnime ? 60 : 56,
      padding: const EdgeInsets.only(bottom: 4),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: widget.pendingImages.length,
        itemBuilder: (_, i) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: isAnime
              ? SizedBox(
                  width: 56,
                  height: 56,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 0,
                        bottom: 0,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(
                            File(widget.pendingImages[i]),
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        right: 0,
                        child: SizedBox.square(
                          dimension: 44,
                          child: IconButton(
                            tooltip: '移除图片',
                            onPressed: () => widget.onRemoveImage?.call(i),
                            padding: EdgeInsets.zero,
                            icon: Container(
                              width: 22,
                              height: 22,
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close,
                                size: 15,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.file(
                        File(widget.pendingImages[i]),
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      top: -4,
                      right: -4,
                      child: GestureDetector(
                        onTap: () => widget.onRemoveImage?.call(i),
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.close,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  /// 待发送文件条（图标 + 文件名 + 删除）。
  Widget _buildFileBar({bool isAnime = false}) {
    if (!_hasPendingFiles) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    final chips = [
      for (var i = 0; i < widget.pendingFiles.length; i++)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isAnime ? colorScheme.surfaceContainerHighest : Colors.white,
            borderRadius: BorderRadius.circular(isAnime ? 12 : 6),
            border:
                isAnime ? Border.all(color: colorScheme.outlineVariant) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.insert_drive_file_outlined,
                size: 16,
                color: isAnime ? colorScheme.primary : Colors.black54,
              ),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  widget.pendingFiles[i].split(Platform.pathSeparator).last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: isAnime ? colorScheme.onSurface : Colors.black87,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              if (isAnime)
                SizedBox.square(
                  dimension: 44,
                  child: IconButton(
                    tooltip: '移除文件',
                    onPressed: () => widget.onRemoveFile?.call(i),
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      Icons.close,
                      size: 18,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                GestureDetector(
                  onTap: () => widget.onRemoveFile?.call(i),
                  child: const Icon(
                    Icons.close,
                    size: 14,
                    color: Colors.black54,
                  ),
                ),
            ],
          ),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: isAnime
          ? SingleChildScrollView(
              key: const ValueKey('anime_pending_files_scroll'),
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < chips.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    chips[i],
                  ],
                ],
              ),
            )
          : Wrap(spacing: 6, runSpacing: 4, children: chips),
    );
  }

  Widget _buildModelBar(Color color, {bool isAnime = false}) {
    final label = widget.modelLabel;
    if (label == null || label.isEmpty) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: widget.onModelTap,
          child: Container(
            constraints: BoxConstraints(minHeight: isAnime ? 44 : 0),
            padding: EdgeInsets.symmetric(
              horizontal: isAnime ? 12 : 9,
              vertical: isAnime ? 8 : 4,
            ),
            decoration: BoxDecoration(
              color: isAnime
                  ? colorScheme.primaryContainer.withValues(alpha: 0.70)
                  : Colors.white.withValues(alpha: 0.88),
              borderRadius: BorderRadius.circular(isAnime ? 16 : 14),
              border: Border.all(
                color: isAnime
                    ? colorScheme.outlineVariant
                    : color.withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.tune, size: 14, color: color),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: isAnime
                          ? colorScheme.onPrimaryContainer
                          : Colors.black87,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  get _input => Expanded(
        child: TextField(
          focusNode: _focusNode,
          onChanged: _onChanged,
          controller: _controller,
          //回车发送消息
          onSubmitted: (_) => _onSend(),
          style: const TextStyle(
              fontSize: 18, color: Colors.black, fontWeight: FontWeight.w400),
          //输入框的样式
          decoration: InputDecoration(
              border: OutlineInputBorder(
                  //设置填充圆角
                  borderRadius: BorderRadius.circular(6),
                  //取消边框
                  borderSide:
                      const BorderSide(width: 0, style: BorderStyle.none)),
              filled: true,
              //输入框样式的大小约束
              constraints: const BoxConstraints(maxHeight: 39),
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.only(left: 10),
              hintStyle: const TextStyle(fontSize: 16),
              hintText: widget.hint),
        ),
      );

  List<Widget> _animeTools() => [
        if (widget.showWebSearch)
          _animeToolButton(
            icon: Icons.travel_explore_rounded,
            tooltip: widget.webSearchEnabled ? '关闭联网搜索' : '开启联网搜索',
            onPressed: widget.onToggleWebSearch,
            active: widget.webSearchEnabled,
          ),
        if (_showPhotoBtn)
          _animeToolButton(
            icon: Icons.add_photo_alternate_rounded,
            tooltip:
                widget.imagesEnabled ? '添加图片' : widget.imagesDisabledReason,
            onPressed: _onPhotoTap,
            muted: !widget.imagesEnabled,
          ),
        if (_showFileBtn)
          _animeToolButton(
            icon: Icons.attach_file_rounded,
            tooltip: '添加文件',
            onPressed: _onFileTap,
          ),
        if (widget.speechInputEnabled)
          _animeToolButton(
            icon: _isListening ? Icons.mic_rounded : Icons.mic_none_rounded,
            tooltip: _isListening ? '停止语音输入' : '语音输入',
            onPressed: _onMicTap,
            active: _isListening,
            danger: _isListening,
          ),
      ];

  List<Widget> _withToolSpacing(List<Widget> tools) => [
        for (var index = 0; index < tools.length; index++) ...[
          if (index > 0) const SizedBox(width: 6),
          tools[index],
        ],
      ];

  Widget _buildAnimeComposer(Color color) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tools = _animeTools();
        final inputRow = Row(
          children: [
            _animeInput,
            if (_showSend || widget.isStreaming) _animeSendButton(color),
          ],
        );
        if (constraints.maxWidth < 420 && tools.isNotEmpty) {
          return Column(
            key: const ValueKey('anime_message_compact_layout'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SingleChildScrollView(
                key: const ValueKey('anime_message_tools_scroll'),
                scrollDirection: Axis.horizontal,
                child: Row(children: _withToolSpacing(tools)),
              ),
              const SizedBox(height: 8),
              inputRow,
            ],
          );
        }
        return Row(
          children: [
            ..._withToolSpacing(tools),
            if (tools.isNotEmpty) const SizedBox(width: 6),
            _animeInput,
            if (_showSend || widget.isStreaming) _animeSendButton(color),
          ],
        );
      },
    );
  }

  Widget get _animeInput => Expanded(
        child: TextField(
          key: const ValueKey('anime_message_input'),
          focusNode: _focusNode,
          onChanged: _onChanged,
          controller: _controller,
          onSubmitted: (_) => _onSend(),
          style: Theme.of(context).textTheme.bodyLarge,
          decoration: InputDecoration(
            hintText: widget.hint,
            isDense: true,
            constraints: const BoxConstraints(minHeight: 48),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final isAnime = themeProvider.isAnime;
    final colorScheme = Theme.of(context).colorScheme;
    final color = isAnime ? colorScheme.primary : themeProvider.themeColor;
    var bottom = MediaQuery.of(context).padding.bottom;
    if (bottom == 0.0) {
      //适配iOS刘海屏以外的设备
      bottom = 20;
    }
    return Container(
      key: ValueKey(
          isAnime ? 'anime_message_composer' : 'classic_message_composer'),
      padding: EdgeInsets.only(
        left: isAnime ? 12 : 20,
        right: isAnime ? 12 : 20,
        top: isAnime ? 8 : 5,
        bottom: bottom,
      ),
      decoration: isAnime
          ? BoxDecoration(
              color: colorScheme.surface,
              border: Border(
                top: BorderSide(color: colorScheme.outlineVariant),
              ),
              boxShadow: [
                BoxShadow(
                  color: colorScheme.primary.withValues(alpha: 0.08),
                  blurRadius: 16,
                  offset: const Offset(0, -4),
                ),
              ],
            )
          : BoxDecoration(color: Colors.grey.withValues(alpha: 0.2)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildModelBar(color, isAnime: isAnime),
          _buildThumbnailBar(isAnime: isAnime),
          _buildFileBar(isAnime: isAnime),
          if (isAnime)
            _buildAnimeComposer(color)
          else
            SizedBox(
              height: 45,
              child: Row(
                children: [
                  if (widget.showWebSearch) _webSearchBtn(color),
                  if (_showPhotoBtn) _photoBtn,
                  if (_showFileBtn) _fileBtn,
                  if (widget.speechInputEnabled) _micBtn,
                  _input,
                  if (_showSend || widget.isStreaming) _sendBtn(color),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _onChanged(String value) {
    setState(() {
      _showSend = value.isNotEmpty;
    });
  }

  void _onSend() {
    // 流式进行中或被禁用时（如回车键触发），忽略发送，避免并发请求。
    if (widget.isStreaming || !widget.enable) return;
    if (widget.canSend?.call() == false) return;
    if (widget.onSend != null) {
      widget.onSend!();
      _controller.clear();
      _lastWords = '';
      setState(() {
        _showSend = false;
      });
    }
  }
}
