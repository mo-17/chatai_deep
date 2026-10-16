import 'dart:async';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/composer_reference_trigger.dart';
import 'package:chatgpt_app_core/chat/domain/composer_reference.dart';
import 'package:chatgpt_app_core/widget/message_reference_picker.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final FutureOr<void> Function()? onSend;

  /// 默认保留旧调用的立即清空行为；异步发送页面可在持久化成功后自行清空。
  final bool clearOnSend;

  /// 同步发送闸门。返回 false 时不调用 [onSend]，也不清空输入内容。
  final bool Function()? canSend;
  final VoidCallback? onStop;

  /// 仅由普通对话显式传入；其余共享输入场景不启用。
  final String? suggestedMessage;
  final VoidCallback? onAcceptSuggestion;
  final VoidCallback? onDismissSuggestion;
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
  final Widget? modelAccessory;
  final String hint;
  final String initialText;
  final TextEditingController? controller;
  final bool enable;

  /// 可单独锁定本轮草稿编辑；默认 true 保留旧调用在等待回答时继续输入的行为。
  final bool editingEnabled;
  final bool isStreaming;
  final bool referencesEnabled;
  final String? referenceScopeKey;
  final bool Function()? isReferenceScopeCurrent;
  final List<ComposerReference> references;
  final Future<ComposerReference?> Function()? pickHistoryReference;
  final ValueChanged<ComposerReference>? onReferencePicked;
  final ValueChanged<String>? onRemoveReference;
  final Future<void> Function(ComposerReference)? onPreviewReference;
  final ValueChanged<bool>? onReferencePickerChanged;
  final bool speechInputEnabled;
  final String? speechLocale;

  const MessageInputWidget(
    this.hint, {
    super.key,
    this.onChanged,
    this.onSend,
    this.clearOnSend = true,
    this.canSend,
    this.onStop,
    this.suggestedMessage,
    this.onAcceptSuggestion,
    this.onDismissSuggestion,
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
    this.modelAccessory,
    this.initialText = '',
    this.controller,
    this.enable = true,
    this.editingEnabled = true,
    this.isStreaming = false,
    this.referencesEnabled = false,
    this.referenceScopeKey,
    this.isReferenceScopeCurrent,
    this.references = const [],
    this.onPreviewReference,
    this.pickHistoryReference,
    this.onReferencePicked,
    this.onRemoveReference,
    this.onReferencePickerChanged,
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
  int _editingRevision = 0;
  int _inputGeneration = 0;
  String _lastWords = '';
  final _picker = ImagePicker();
  late TextEditingValue _previousValue;
  TextEditingValue _changeBefore = TextEditingValue.empty;
  bool _suppressPasteTrigger = false;
  int _pickerDepth = 0;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? TextEditingController();
    if (_controller.text.isEmpty && widget.initialText.isNotEmpty) {
      _controller.text = widget.initialText;
    }
    _showSend = _controller.text.isNotEmpty;
    _previousValue = _controller.value;
    _controller.addListener(_onControllerChanged);
    if (_controller.text.isNotEmpty) widget.onChanged?.call(_controller.text);
    _initSpeech();
  }

  @override
  void didUpdateWidget(covariant MessageInputWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.referenceScopeKey != widget.referenceScopeKey) {
      _editingRevision++;
    }
    if (oldWidget.editingEnabled != widget.editingEnabled) _editingRevision++;
    if (oldWidget.editingEnabled && !widget.editingEnabled) {
      _speech?.cancel();
      _isListening = false;
      _focusNode.unfocus();
    }
    if (identical(oldWidget.controller, widget.controller)) return;
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) _controller.dispose();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? TextEditingController();
    _previousValue = _controller.value;
    _controller.addListener(_onControllerChanged);
    _showSend = _controller.text.isNotEmpty;
  }

  void _onControllerChanged() {
    final text = _controller.text;
    final textChanged = _previousValue.text != text;
    if (textChanged) {
      _changeBefore = _previousValue;
      _inputGeneration++;
    }
    _previousValue = _controller.value;
    // 光标、选区及 composing 范围不是正文编辑，不能使等待中的引用冻结失效。
    if (textChanged) widget.onChanged?.call(text);
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
    if (!widget.editingEnabled) return;
    final revision = _editingRevision;
    if (!widget.speechInputEnabled) {
      _focusNode.requestFocus();
      return;
    }
    if (_speech == null) await _initSpeech();
    if (!mounted || !widget.editingEnabled || revision != _editingRevision) {
      return;
    }

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
      if (!mounted || !widget.editingEnabled || revision != _editingRevision) {
        return;
      }
      final localeId =
          pickSpeechLocaleId(locales, preferredLocale: widget.speechLocale);
      await _speech!.listen(
        onResult: (result) {
          if (!mounted ||
              !widget.editingEnabled ||
              revision != _editingRevision) {
            return;
          }
          final text = '$_lastWords${result.recognizedWords}';
          _controller.text = text;
          _controller.selection = TextSelection.fromPosition(
            TextPosition(offset: text.length),
          );
          setState(() => _showSend = text.isNotEmpty);
        },
        // 锁定的 7.x 插件尚无 SpeechListenOptions.localeId，保留兼容入口。
        // ignore: deprecated_member_use
        localeId: localeId,
      );
      if (!mounted || !widget.editingEnabled || revision != _editingRevision) {
        await _speech?.cancel();
        return;
      }
      _isListening = true;
      if (mounted) setState(() {});
    } catch (_) {
      _isListening = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _onPhotoTap() async {
    if (!widget.editingEnabled) return;
    if (!widget.imagesEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.imagesDisabledReason)),
      );
      return;
    }
    final revision = _editingRevision;
    final generation = _inputGeneration;
    _pickerEnter();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('拍照'),
              onTap: () {
                Navigator.pop(context, ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('从相册选择'),
              onTap: () {
                Navigator.pop(context, ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
    if (source != null &&
        mounted &&
        widget.editingEnabled &&
        revision == _editingRevision &&
        generation == _inputGeneration &&
        widget.isReferenceScopeCurrent?.call() != false) {
      await _pickImage(source);
    }
    _pickerLeave();
  }

  Future<bool> _pickImage(ImageSource source) async {
    if (!widget.editingEnabled || !widget.imagesEnabled) return false;
    final revision = _editingRevision;
    final generation = _inputGeneration;
    _pickerEnter();
    try {
      final picked = await _picker.pickImage(
        source: source,
        imageQuality: 70,
        maxWidth: 2048,
        maxHeight: 2048,
      );
      if (picked != null &&
          mounted &&
          widget.editingEnabled &&
          revision == _editingRevision &&
          generation == _inputGeneration &&
          widget.isReferenceScopeCurrent?.call() != false) {
        widget.onImagesPicked
            ?.call({...widget.pendingImages, picked.path}.toList());
        return true;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选取图片失败: $e')),
        );
      }
    } finally {
      _pickerLeave();
    }
    return false;
  }

  bool get _showPhotoBtn =>
      Platform.operatingSystem != 'ohos'; // image_picker 暂未支持鸿蒙

  bool get _showFileBtn =>
      Platform.operatingSystem != 'ohos'; // file_picker 暂未支持鸿蒙

  bool get _hasPendingImages => widget.pendingImages.isNotEmpty;

  bool get _hasPendingFiles => widget.pendingFiles.isNotEmpty;

  bool get _showSendButton =>
      _showSend ||
      _hasPendingImages ||
      _hasPendingFiles ||
      widget.references.isNotEmpty ||
      widget.isStreaming;

  Future<bool> _onFileTap() async {
    if (!widget.editingEnabled) return false;
    final revision = _editingRevision;
    final generation = _inputGeneration;
    _pickerEnter();
    try {
      // 不按数量截断；发送前按整轮附件大小和解析字数检查。
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: FileProcessor.pickerExtensions,
        allowMultiple: true,
        withData: false,
      );
      if (result == null ||
          !mounted ||
          !widget.editingEnabled ||
          revision != _editingRevision ||
          generation != _inputGeneration ||
          widget.isReferenceScopeCurrent?.call() == false) {
        return false;
      }
      // 去重：跳过已在待发送列表里的、以及本批内重复的路径。
      final seen = widget.pendingFiles.toSet();
      final picked = <String>[];
      for (final f in result.files) {
        final p = f.path;
        if (p == null || !seen.add(p)) continue;
        picked.add(p);
      }
      if (picked.isEmpty) return false;
      widget.onFilesPicked?.call([...widget.pendingFiles, ...picked]);
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选取文件失败: $e')),
        );
      }
    } finally {
      _pickerLeave();
    }
    return false;
  }

  void _pickerEnter() {
    if (_pickerDepth++ == 0 && widget.referencesEnabled) {
      widget.onReferencePickerChanged?.call(true);
    }
  }

  void _pickerLeave() {
    if (_pickerDepth > 0 &&
        --_pickerDepth == 0 &&
        mounted &&
        widget.referencesEnabled) {
      widget.onReferencePickerChanged?.call(false);
    }
  }

  Future<void> _openReferenceMenu({int? triggerOffset}) async {
    if (!widget.referencesEnabled ||
        !widget.editingEnabled ||
        _pickerDepth > 0) {
      return;
    }
    final value = _controller.value;
    final revision = _editingRevision;
    final generation = _inputGeneration;
    final scope = widget.referenceScopeKey;
    bool current() =>
        mounted &&
        widget.editingEnabled &&
        revision == _editingRevision &&
        generation == _inputGeneration &&
        scope == widget.referenceScopeKey &&
        widget.isReferenceScopeCurrent?.call() != false;
    _pickerEnter();
    try {
      final kind = await showModalBottomSheet<ComposerReferenceKind>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (ctx) => SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                const ListTile(title: Text('添加引用')),
                if (_showFileBtn)
                  ListTile(
                      key: const ValueKey('reference_choose_file'),
                      leading: const Icon(Icons.attach_file),
                      title: const Text('@文件'),
                      onTap: () =>
                          Navigator.pop(ctx, ComposerReferenceKind.file)),
                if (_showPhotoBtn)
                  ListTile(
                      key: const ValueKey('reference_choose_photo'),
                      leading: const Icon(Icons.photo_library_outlined),
                      title: const Text('@相册'),
                      enabled: widget.imagesEnabled,
                      subtitle: widget.imagesEnabled
                          ? null
                          : Text(widget.imagesDisabledReason),
                      onTap: () =>
                          Navigator.pop(ctx, ComposerReferenceKind.photo)),
                ListTile(
                    key: const ValueKey('reference_choose_history'),
                    leading: const Icon(Icons.history),
                    title: const Text('@历史消息'),
                    onTap: () => Navigator.pop(
                        ctx, ComposerReferenceKind.historyMessage)),
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消')),
              ])));
      if (kind == null || !current()) return;
      var accepted = false;
      switch (kind) {
        case ComposerReferenceKind.file:
          accepted = await _onFileTap();
        case ComposerReferenceKind.photo:
          accepted = await _pickImage(ImageSource.gallery);
        case ComposerReferenceKind.historyMessage:
          final reference = await widget.pickHistoryReference?.call();
          if (reference != null && current()) {
            widget.onReferencePicked?.call(reference);
            accepted = true;
          }
      }
      if (accepted &&
          current() &&
          triggerOffset != null &&
          _controller.value == value) {
        final text =
            value.text.replaceRange(triggerOffset, triggerOffset + 1, '');
        _controller.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: triggerOffset));
      }
    } finally {
      _pickerLeave();
    }
  }

  Widget _referenceButton() => SizedBox.square(
      dimension: 44,
      child: IconButton(
          key: const ValueKey('composer_reference_button'),
          tooltip: '添加引用',
          onPressed: widget.editingEnabled ? _openReferenceMenu : null,
          icon: const Icon(Icons.alternate_email)));

  Widget _referenceBar() {
    if (widget.references.isEmpty) return const SizedBox.shrink();
    return SizedBox(
        height: 58,
        child: ListView.separated(
            key: const ValueKey('composer_reference_tags'),
            scrollDirection: Axis.horizontal,
            itemCount: widget.references.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (_, i) {
              final reference = widget.references[i];
              return Card(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                InkWell(
                    key: ValueKey('preview_reference_${reference.id}'),
                    onTap: !widget.editingEnabled
                        ? null
                        : () =>
                            widget.onPreviewReference?.call(reference) ??
                            showReferencePreview(context, reference,
                                isCurrent: widget.isReferenceScopeCurrent),
                    child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(children: [
                          Icon(
                              reference.available
                                  ? switch (reference.kind) {
                                      ComposerReferenceKind.file =>
                                        Icons.attach_file,
                                      ComposerReferenceKind.photo =>
                                        Icons.photo_library_outlined,
                                      ComposerReferenceKind.historyMessage =>
                                        Icons.history,
                                    }
                                  : Icons.warning_amber,
                              size: 18),
                          const SizedBox(width: 4),
                          ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 180),
                              child: Text(
                                  '${reference.available ? '' : '不可用 · '}${reference.label}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis))
                        ]))),
                IconButton(
                    key: ValueKey('remove_reference_${reference.id}'),
                    tooltip: '移除引用',
                    onPressed: widget.editingEnabled
                        ? () => widget.onRemoveReference?.call(reference.id)
                        : null,
                    icon: const Icon(Icons.close, size: 18)),
              ]));
            }));
  }

  Widget _contextMenu(BuildContext context, EditableTextState state) =>
      AdaptiveTextSelectionToolbar.buttonItems(
          anchors: state.contextMenuAnchors,
          buttonItems: state.contextMenuButtonItems
              .map((item) => item.type == ContextMenuButtonType.paste
                  ? ContextMenuButtonItem(
                      type: item.type,
                      label: item.label,
                      onPressed: () async {
                        _suppressPasteTrigger = true;
                        try {
                          await state.pasteText(SelectionChangedCause.toolbar);
                        } finally {
                          _suppressPasteTrigger = false;
                        }
                        state.hideToolbar();
                      })
                  : item)
              .toList());

  Future<void> _pasteFromKeyboard() async {
    if (!widget.editingEnabled) return;
    final revision = _editingRevision;
    final generation = _inputGeneration;
    final value = _controller.value;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted ||
        !widget.editingEnabled ||
        revision != _editingRevision ||
        generation != _inputGeneration ||
        data?.text == null) {
      return;
    }
    final start =
        value.selection.isValid ? value.selection.start : value.text.length;
    final end =
        value.selection.isValid ? value.selection.end : value.text.length;
    _controller.value = TextEditingValue(
        text: value.text.replaceRange(start, end, data!.text!),
        selection: TextSelection.collapsed(offset: start + data.text!.length));
  }

  Widget _pasteShortcuts(Widget input) => CallbackShortcuts(bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () =>
            unawaited(_pasteFromKeyboard()),
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
            unawaited(_pasteFromKeyboard()),
      }, child: input);

  @override
  void dispose() {
    _speech?.cancel();
    _focusNode.dispose();
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  get _fileBtn => GestureDetector(
        onTap: widget.editingEnabled ? _onFileTap : null,
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
        onTap: widget.editingEnabled ? _onPhotoTap : null,
        child: Container(
          margin: const EdgeInsets.only(right: 6),
          child: Icon(
            Icons.add_photo_alternate,
            color: widget.imagesEnabled ? Colors.grey : Colors.grey.shade300,
            size: 26,
          ),
        ),
      );

  /// 两种布局共用同一开关：选中、关闭和暂不可用有独立的视觉状态。
  Widget _webSearchBtn({required bool isAnime}) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.enable &&
        widget.editingEnabled &&
        !widget.isStreaming &&
        widget.onToggleWebSearch != null;
    return Padding(
      padding: EdgeInsets.only(right: isAnime ? 0 : 6),
      child: SizedBox.square(
        dimension: 44,
        child: IconButton(
          key: const ValueKey('web_search_toggle'),
          tooltip: widget.webSearchEnabled ? '关闭联网搜索' : '开启联网搜索',
          isSelected: widget.webSearchEnabled,
          onPressed: enabled ? widget.onToggleWebSearch : null,
          style: IconButton.styleFrom(
            minimumSize: const Size.square(44),
            maximumSize: const Size.square(44),
            padding: EdgeInsets.zero,
            backgroundColor: widget.webSearchEnabled
                ? scheme.primary
                : scheme.surfaceContainerHighest,
            foregroundColor: widget.webSearchEnabled
                ? scheme.onPrimary
                : scheme.onSurfaceVariant,
            disabledBackgroundColor: scheme.onSurface.withValues(alpha: 0.08),
            disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.38),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(isAnime ? 14 : 10),
            ),
          ),
          icon: Icon(
            isAnime ? Icons.travel_explore_rounded : Icons.travel_explore,
            size: isAnime ? 22 : 24,
          ),
        ),
      ),
    );
  }

  get _micBtn => GestureDetector(
        onTap: widget.editingEnabled ? _onMicTap : null,
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
              : (widget.enable && widget.editingEnabled ? _onSend : null),
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
              : (widget.enable && widget.editingEnabled ? _onSend : null),
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
                            cacheWidth: 144,
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
                            onPressed: widget.editingEnabled
                                ? () => widget.onRemoveImage?.call(i)
                                : null,
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
                        cacheWidth: 144,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      top: -4,
                      right: -4,
                      child: GestureDetector(
                        onTap: widget.editingEnabled
                            ? () => widget.onRemoveImage?.call(i)
                            : null,
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
    Widget chip(int i) => Container(
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
                    onPressed: widget.editingEnabled
                        ? () => widget.onRemoveFile?.call(i)
                        : null,
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
                  onTap: widget.editingEnabled
                      ? () => widget.onRemoveFile?.call(i)
                      : null,
                  child: const Icon(
                    Icons.close,
                    size: 14,
                    color: Colors.black54,
                  ),
                ),
            ],
          ),
        );
    // 大量附件只构建可见条目，输入区高度不随文件数量增长。
    return SizedBox(
      height: isAnime ? 58 : 32,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: ListView.separated(
          key: ValueKey(
              isAnime ? 'anime_pending_files_scroll' : 'pending_files_scroll'),
          scrollDirection: Axis.horizontal,
          itemCount: widget.pendingFiles.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (_, index) => chip(index),
        ),
      ),
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
        widthFactor: 1,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: widget.editingEnabled ? widget.onModelTap : null,
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
                  constraints: BoxConstraints(
                      maxWidth: widget.modelAccessory == null ? 240 : 180),
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
        child: _pasteShortcuts(TextField(
          contextMenuBuilder: _contextMenu,
          readOnly: !widget.editingEnabled,
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
        )),
      );

  List<Widget> _animeTools() => [
        if (widget.referencesEnabled) _referenceButton(),
        if (widget.showWebSearch) _webSearchBtn(isAnime: true),
        if (_showPhotoBtn)
          _animeToolButton(
            icon: Icons.add_photo_alternate_rounded,
            tooltip:
                widget.imagesEnabled ? '添加图片' : widget.imagesDisabledReason,
            onPressed: widget.editingEnabled ? _onPhotoTap : null,
            muted: !widget.imagesEnabled,
          ),
        if (_showFileBtn)
          _animeToolButton(
            icon: Icons.attach_file_rounded,
            tooltip: '添加文件',
            onPressed: widget.editingEnabled ? _onFileTap : null,
          ),
        if (widget.speechInputEnabled)
          _animeToolButton(
            icon: _isListening ? Icons.mic_rounded : Icons.mic_none_rounded,
            tooltip: _isListening ? '停止语音输入' : '语音输入',
            onPressed: widget.editingEnabled ? _onMicTap : null,
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
            if (_showSendButton) _animeSendButton(color),
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
            if (_showSendButton) _animeSendButton(color),
          ],
        );
      },
    );
  }

  Widget get _animeInput => Expanded(
        child: _pasteShortcuts(TextField(
          contextMenuBuilder: _contextMenu,
          readOnly: !widget.editingEnabled,
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
        )),
      );

  Widget _classicComposer(Color color) =>
      LayoutBuilder(builder: (_, constraints) {
        final tools = <Widget>[
          if (widget.referencesEnabled) _referenceButton(),
          if (widget.showWebSearch) _webSearchBtn(isAnime: false),
          if (_showPhotoBtn) _photoBtn,
          if (_showFileBtn) _fileBtn,
          if (widget.speechInputEnabled) _micBtn,
        ];
        if (widget.referencesEnabled && constraints.maxWidth < 420) {
          return Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
                height: 44,
                child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: tools))),
            SizedBox(
                height: 45,
                child: Row(
                    children: [_input, if (_showSendButton) _sendBtn(color)])),
          ]);
        }
        return SizedBox(
            height: 45,
            child: Row(children: [
              ...tools,
              _input,
              if (_showSendButton) _sendBtn(color)
            ]));
      });

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
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _buildModelBar(color, isAnime: isAnime),
                if (widget.modelAccessory != null) widget.modelAccessory!,
              ],
            ),
          ),
          if (_canShowSuggestion) _buildSuggestion(),
          if (widget.referencesEnabled) _referenceBar(),
          if (!widget.referencesEnabled) _buildThumbnailBar(isAnime: isAnime),
          if (!widget.referencesEnabled) _buildFileBar(isAnime: isAnime),
          if (isAnime) _buildAnimeComposer(color) else _classicComposer(color),
        ],
      ),
    );
  }

  bool get _canShowSuggestion =>
      widget.suggestedMessage?.isNotEmpty == true &&
      widget.onAcceptSuggestion != null &&
      widget.enable &&
      widget.editingEnabled &&
      !widget.isStreaming &&
      _controller.text.isEmpty &&
      (!_controller.value.composing.isValid ||
          _controller.value.composing.isCollapsed) &&
      widget.pendingImages.isEmpty &&
      widget.pendingFiles.isEmpty &&
      widget.references.isEmpty &&
      _pickerDepth == 0;

  Widget _buildSuggestion() {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Material(
        key: const ValueKey('composer_prediction'),
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextButton(
                key: const ValueKey('accept_composer_prediction'),
                style: TextButton.styleFrom(
                  foregroundColor: colors.onSecondaryContainer,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.all(12),
                ),
                onPressed: () {
                  if (_canShowSuggestion) widget.onAcceptSuggestion?.call();
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('下一条消息建议 · 点击填入',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: colors.onSecondaryContainer)),
                    const SizedBox(height: 4),
                    Text(widget.suggestedMessage!),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: '忽略建议',
              onPressed: widget.onDismissSuggestion,
              color: colors.onSecondaryContainer,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  void _onChanged(String value) {
    setState(() {
      _showSend = value.isNotEmpty;
    });
    final pasted = _suppressPasteTrigger;
    _suppressPasteTrigger = false;
    if (widget.referencesEnabled && !pasted && _pickerDepth == 0) {
      final offset = composerReferenceTrigger(_changeBefore, _controller.value);
      if (offset != null) unawaited(_openReferenceMenu(triggerOffset: offset));
    }
  }

  void _onSend() {
    // 流式进行中或被禁用时（如回车键触发），忽略发送，避免并发请求。
    if (widget.isStreaming ||
        !widget.enable ||
        !widget.editingEnabled ||
        _pickerDepth > 0) {
      return;
    }
    if (widget.canSend?.call() == false) return;
    if (widget.onSend != null) {
      widget.onSend!();
      if (widget.clearOnSend) {
        _controller.clear();
        _lastWords = '';
        setState(() {
          _showSend = false;
        });
      }
    }
  }
}
