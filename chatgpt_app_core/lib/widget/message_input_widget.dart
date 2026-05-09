import 'dart:io';

import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

///聊天输入框
class MessageInputWidget extends StatefulWidget {
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSend;
  final String hint;
  final bool enable;

  const MessageInputWidget(this.hint,
      {Key? key, this.onChanged, this.onSend, this.enable = true})
      : super(key: key);

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
    final match =
        RegExp(r'Version (\d+)\.(\d+)').firstMatch(Platform.operatingSystemVersion);
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
          debugPrint('speech error: ${error.errorMsg}, permanent: ${error.permanent}');
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
        debugPrint('speech locales: ${locales.map((l) => l.localeId).toList()}');
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
        localeId: 'zh_CN',
      );
      _isListening = true;
      if (mounted) setState(() {});
    } catch (_) {
      _isListening = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _speech?.cancel();
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          height: 35,
          disabledColor: color.withOpacity(0.6),
          color: color,
          onPressed: widget.enable ? _onSend : null,
          child: const Text(
            '发送',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
        ),
      );

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
      ));

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
      height: 50 + bottom,
      padding: EdgeInsets.only(left: 20, right: 20, top: 5, bottom: bottom),
      decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.2)),
      child: Row(
        children: [_micBtn, _input, if (_showSend) _sendBtn(color)],
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
