import 'dart:io';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// 根据系统 locale 选择最匹配的语音识别 localeId
String _pickLocaleId(List<stt.LocaleName> locales) {
  if (locales.isEmpty) return 'en_US';
  final sysLocale = Platform.localeName;
  // 精确匹配
  for (final l in locales) {
    if (l.localeId == sysLocale) return l.localeId;
  }
  // 语言前缀匹配
  final lang = sysLocale.split('_').first;
  for (final l in locales) {
    if (l.localeId.startsWith('$lang-') || l.localeId.startsWith('${lang}_')) {
      return l.localeId;
    }
  }
  // 降级到系统默认
  return locales.first.localeId;
}

///聊天输入框
class MessageInputWidget extends StatefulWidget {
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSend;
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
  final String hint;
  final bool enable;
  final bool isStreaming;

  const MessageInputWidget(
    this.hint, {
    Key? key,
    this.onChanged,
    this.onSend,
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
    this.enable = true,
    this.isStreaming = false,
  }) : super(key: key);

  @override
  State<MessageInputWidget> createState() => _MessageInputWidgetState();
}

class _MessageInputWidgetState extends State<MessageInputWidget> {
  bool _showSend = false;
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  stt.SpeechToText? _speech;
  bool _hasSpeech = true; // 默认显示，初始化失败才隐藏
  bool _isListening = false;
  String _lastWords = '';
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _initSpeech();
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
      debugPrint(
          'skip speech_to_text init: iOS 17.0–17.4 simulator audio bug');
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
      final localeId = _pickLocaleId(locales);
      await _speech!.listen(
        onResult: (result) {
          if (!mounted) return;
          final text = '$_lastWords${result.recognizedWords}';
          _controller.text = text;
          _controller.selection = TextSelection.fromPosition(
            TextPosition(offset: text.length),
          );
          setState(() => _showSend = text.isNotEmpty);
          widget.onChanged?.call(text);
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

  Future<void> _onFileTap() async {
    if (widget.pendingFiles.length >= 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最多选择 3 个文件')),
      );
      return;
    }
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: FileProcessor.pickerExtensions,
      );
      final path = result?.files.single.path;
      if (path != null && mounted) {
        widget.onFilesPicked?.call([...widget.pendingFiles, path]);
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
    _controller.dispose();
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

  get _sendBtn => (color) => Container(
        margin: const EdgeInsets.only(left: 10),
        width: 65,
        child: MaterialButton(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
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

  Widget _buildThumbnailBar() {
    if (!_hasPendingImages) return const SizedBox.shrink();
    return Container(
      height: 56,
      padding: const EdgeInsets.only(bottom: 4),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: widget.pendingImages.length,
        itemBuilder: (_, i) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Stack(
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
                    child: const Icon(Icons.close, size: 16, color: Colors.white),
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
  Widget _buildFileBar() {
    if (!_hasPendingFiles) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (var i = 0; i < widget.pendingFiles.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.insert_drive_file_outlined,
                      size: 16, color: Colors.black54),
                  const SizedBox(width: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      widget.pendingFiles[i]
                          .split(Platform.pathSeparator)
                          .last,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, color: Colors.black87),
                    ),
                  ),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () => widget.onRemoveFile?.call(i),
                    child: const Icon(Icons.close,
                        size: 14, color: Colors.black54),
                  ),
                ],
              ),
            ),
        ],
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

  @override
  Widget build(BuildContext context) {
    var themeProvider = context.watch<ThemeProvider>();
    var color = themeProvider.themeColor;
    var bottom = MediaQuery.of(context).padding.bottom;
    if (bottom == 0.0) {
      //适配iOS刘海屏以外的设备
      bottom = 20;
    }
    return Container(
      padding: EdgeInsets.only(left: 20, right: 20, top: 5, bottom: bottom),
      decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.2)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildThumbnailBar(),
          _buildFileBar(),
          SizedBox(
            height: 45,
            child: Row(
              children: [
                if (widget.showWebSearch) _webSearchBtn(color),
                if (_showPhotoBtn) _photoBtn,
                if (_showFileBtn) _fileBtn,
                _micBtn,
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
    if (widget.onChanged != null) widget.onChanged!(value);
    setState(() {
      _showSend = value.isNotEmpty;
    });
  }

  void _onSend() {
    // 流式进行中或被禁用时（如回车键触发），忽略发送，避免并发请求。
    if (widget.isStreaming || !widget.enable) return;
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
