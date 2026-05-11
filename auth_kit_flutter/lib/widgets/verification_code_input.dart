import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/auth_kit_theme.dart';
import '../l10n/auth_kit_l10n.dart';

/// 6 格验证码输入 + 倒计时重发按钮
class VerificationCodeInput extends StatefulWidget {
  final void Function(String code)? onCompleted;
  final VoidCallback? onSendCode;
  final int countdownSeconds;
  final AuthKitTheme? theme;

  const VerificationCodeInput({
    super.key,
    this.onCompleted,
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
            return SizedBox(
              width: 44,
              height: 52,
              child: TextField(
                controller: _controllers[i],
                focusNode: _focusNodes[i],
                textAlign: TextAlign.center,
                maxLength: 1,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                decoration: InputDecoration(
                  counterText: '',
                  filled: true,
                  fillColor: _theme.surfaceColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: _theme.borderColor),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: _theme.primaryColor, width: 2),
                  ),
                ),
                onChanged: (v) => _onChanged(i, v),
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
