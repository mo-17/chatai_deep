import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/auth_kit_theme.dart';
import '../l10n/auth_kit_l10n.dart';

/// 6 格验证码输入 + 倒计时重发按钮
class VerificationCodeInput extends StatefulWidget {
  final void Function(String code)? onCompleted;

  /// 每次编辑都通知父页，删除后不能继续使用上次完整验证码。
  final void Function(String code)? onChanged;
  final VoidCallback? onSendCode;

  /// 首次发送接点：仅成功返回 true 才开始计时；父页负责展示失败信息。
  /// 原 void 接点保留给已经发送过验证码的旧重发页面。
  final Future<bool> Function()? onSendCodeAsync;
  final int countdownSeconds;
  final AuthKitTheme? theme;

  const VerificationCodeInput({
    super.key,
    this.onCompleted,
    this.onChanged,
    this.onSendCode,
    this.onSendCodeAsync,
    this.countdownSeconds = 60,
    this.theme,
  }) : assert(onSendCode == null || onSendCodeAsync == null);

  @override
  State<VerificationCodeInput> createState() => _VerificationCodeInputState();
}

class _VerificationCodeInputState extends State<VerificationCodeInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  int _countdown = 0;
  bool _sending = false;
  late bool _hasSent;
  Timer? _timer;

  AuthKitTheme get _theme => widget.theme ?? AuthKitTheme.defaults();
  AuthKitL10n get l10n => AuthKitL10n.instance;

  @override
  void initState() {
    super.initState();
    _hasSent = widget.onSendCodeAsync == null;
    _controller.addListener(_refreshDecoration);
    _focusNode.addListener(_refreshDecoration);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void startCountdown() {
    setState(() {
      _hasSent = true;
      _countdown = widget.countdownSeconds;
    });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdown <= 1) {
        timer.cancel();
        setState(() => _countdown = 0);
      } else {
        setState(() => _countdown--);
      }
    });
  }

  Future<void> _sendCode() async {
    if (_sending || _countdown > 0) return;
    final send = widget.onSendCodeAsync;
    if (send == null) {
      widget.onSendCode?.call();
      startCountdown();
      return;
    }
    setState(() => _sending = true);
    try {
      final succeeded = await send();
      if (mounted && succeeded) startCountdown();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _refreshDecoration() {
    if (mounted) setState(() {});
  }

  void _onChanged(String code) {
    widget.onChanged?.call(code);
    if (code.length == 6) {
      widget.onCompleted?.call(code);
    }
  }

  Widget _buildEditor() {
    return LayoutBuilder(builder: (context, constraints) {
      // 单个原生编辑器负责剪贴板、选区、退格与系统填充；六格仅作背景。
      final width = constraints.hasBoundedWidth
          ? math.min(constraints.maxWidth, 314.0)
          : 314.0;
      final slotWidth = math.max(0.0, width - 2) / 6;
      final gap = math.min(8.0, slotWidth / 4);
      final scaler = MediaQuery.textScalerOf(context);
      var style = Theme.of(context).textTheme.titleMedium!.copyWith(
        color: _theme.textColor,
        fontSize: 22,
        fontWeight: FontWeight.w600,
        height: 1.2,
        letterSpacing: 0,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
      final painter = TextPainter(
          text: TextSpan(text: '0', style: style),
          textDirection: TextDirection.ltr,
          textScaler: scaler)
        ..layout();
      final digitSpace = math.max(1.0, slotWidth - gap - 4);
      if (painter.width > digitSpace) {
        style = style.copyWith(fontSize: 22 * digitSpace / painter.width);
        painter.text = TextSpan(text: '0', style: style);
        painter.layout();
      }
      final height = math.max(52.0, painter.height + 24);
      // Flutter 的 letterSpacing 是逻辑像素；字体已按当前 textScaler 测量。
      final inputStyle =
          style.copyWith(letterSpacing: slotWidth - painter.width);
      painter.dispose();
      final selection = _controller.selection;
      bool selected(int i) {
        if (!_focusNode.hasFocus || !selection.isValid) return false;
        if (selection.isCollapsed) {
          return i == selection.extentOffset.clamp(0, 5);
        }
        return i >= selection.start && i < selection.end;
      }

      return SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              left: 0,
              right: 2,
              top: 0,
              bottom: 0,
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: List.generate(6, (i) {
                      final active = selected(i);
                      return Expanded(
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: gap / 2),
                          child: DecoratedBox(
                            key: ValueKey('verification-code-cell-$i'),
                            decoration: BoxDecoration(
                              color: _theme.surfaceColor,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: active
                                    ? _theme.primaryColor
                                    : _theme.borderColor,
                                width: active ? 2 : 1,
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ),
            ),
            AutofillGroup(
              onDisposeAction: AutofillContextAction.cancel,
              child: Semantics(
                label: l10n.enterCode,
                child: TextField(
                  key: const ValueKey('verification-code-editor'),
                  controller: _controller,
                  focusNode: _focusNode,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  autocorrect: false,
                  enableSuggestions: false,
                  enableInteractiveSelection: true,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 6,
                  maxLengthEnforcement: MaxLengthEnforcement.enforced,
                  textDirection: TextDirection.ltr,
                  textAlignVertical: TextAlignVertical.center,
                  style: inputStyle,
                  cursorColor: _theme.primaryColor,
                  decoration: const InputDecoration(
                    isDense: true,
                    isCollapsed: true,
                    filled: false,
                    contentPadding: EdgeInsets.symmetric(vertical: 12),
                    counterText: '',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                  onChanged: _onChanged,
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildEditor(),
        const SizedBox(height: 16),
        _countdown > 0
            ? Text(
                '${_countdown}s',
                style: TextStyle(color: _theme.subtitleColor, fontSize: 14),
              )
            : TextButton(
                onPressed: _sending ||
                        (widget.onSendCode == null &&
                            widget.onSendCodeAsync == null)
                    ? null
                    : _sendCode,
                child: Text(
                  _sending
                      ? l10n.sendingCode
                      : _hasSent
                          ? l10n.resendCode
                          : l10n.sendCode,
                  style: TextStyle(color: _theme.primaryColor),
                ),
              ),
      ],
    );
  }
}
