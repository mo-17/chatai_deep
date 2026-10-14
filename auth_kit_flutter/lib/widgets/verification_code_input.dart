import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/auth_kit_theme.dart';
import '../l10n/auth_kit_l10n.dart';

/// 6 格验证码输入 + 倒计时重发按钮
class VerificationCodeInput extends StatefulWidget {
  final void Function(String code)? onCompleted;
  /// 每次编辑都通知父页，删除后不能继续使用上次完整验证码。
  final void Function(String code)? onChanged;
  final VoidCallback? onSendCode;
  final int countdownSeconds;
  final AuthKitTheme? theme;

  const VerificationCodeInput({
    super.key,
    this.onCompleted,
    this.onChanged,
    this.onSendCode,
    this.countdownSeconds = 60,
    this.theme,
  });

  @override
  State<VerificationCodeInput> createState() => _VerificationCodeInputState();
}

class _VerificationCodeInputState extends State<VerificationCodeInput> {
  final _controllers = List.generate(6, (_) => TextEditingController());
  final _focusNodes = List.generate(6, (_) => FocusNode());
  int _countdown = 0;
  Timer? _timer;

  AuthKitTheme get _theme => widget.theme ?? AuthKitTheme.defaults();
  AuthKitL10n get l10n => AuthKitL10n.instance;

  @override
  void dispose() {
    for (final c in _controllers) c.dispose();
    for (final f in _focusNodes) f.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void startCountdown() {
    setState(() => _countdown = widget.countdownSeconds);
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

  String get _code => _controllers.map((c) => c.text).join();

  void _onChanged(int index, String value) {
    if (value.length == 1 && index < 5) {
      _focusNodes[index + 1].requestFocus();
    }
    widget.onChanged?.call(_code);
    if (_code.length == 6) {
      widget.onCompleted?.call(_code);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(6, (i) {
            return Flexible(
              child: ConstrainedBox(
                // 保留常规格子尺寸；窄屏可缩宽，大字体可增高，避免裁切文字。
                constraints: const BoxConstraints(maxWidth: 44, minHeight: 52),
                child: TextField(
                  controller: _controllers[i],
                  focusNode: _focusNodes[i],
                  textAlign: TextAlign.center,
                  textAlignVertical: TextAlignVertical.center,
                  maxLength: 1,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w600),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    counterText: '',
                    filled: true,
                    fillColor: _theme.surfaceColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: _theme.borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          BorderSide(color: _theme.primaryColor, width: 2),
                    ),
                  ),
                  onChanged: (v) => _onChanged(i, v),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 16),
        _countdown > 0
            ? Text(
                '${_countdown}s',
                style: TextStyle(color: _theme.subtitleColor, fontSize: 14),
              )
            : TextButton(
                onPressed: () {
                  widget.onSendCode?.call();
                  startCountdown();
                },
                child: Text(
                  l10n.resendCode,
                  style: TextStyle(color: _theme.primaryColor),
                ),
              ),
      ],
    );
  }
}
