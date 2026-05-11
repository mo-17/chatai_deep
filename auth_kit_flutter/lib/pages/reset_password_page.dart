import 'package:flutter/material.dart';
import '../theme/auth_kit_theme.dart';
import '../l10n/auth_kit_l10n.dart';
import '../dao/auth_dao.dart';
import '../widgets/identifier_field.dart';
import '../widgets/verification_code_input.dart';

/// 验证码重置密码页面
class ResetPasswordPage extends StatefulWidget {
  final AuthDao authDao;
  final String? initialChannel; // 'email' | 'sms'
  final AuthKitTheme? theme;
  final VoidCallback? onSuccess;
  final VoidCallback? onCancel;

  const ResetPasswordPage({
    super.key,
    required this.authDao,
    this.initialChannel,
    this.theme,
    this.onSuccess,
    this.onCancel,
  });

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  late String _channel;
  final _identifierCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _codeSent = false;
  bool _loading = false;
  String? _error;
  String? _successMsg;

  AuthKitTheme get _theme => widget.theme ?? AuthKitTheme.defaults();
  AuthKitL10n get l10n => AuthKitL10n.instance;

  @override
  void initState() {
    super.initState();
    _channel = widget.initialChannel ?? 'email';
  }

  @override
  void dispose() {
    _identifierCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final identifier = _identifierCtrl.text.trim();
    if (identifier.isEmpty) {
      setState(() => _error = l10n.identifierHint);
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      await widget.authDao.sendCode(
        channel: _channel,
        identifier: identifier,
        purpose: 'reset_password',
      );
      setState(() => _codeSent = true);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _onCodeCompleted(String code) async {
    final newPassword = _passwordCtrl.text.trim();
    if (newPassword.isEmpty) {
      setState(() => _error = l10n.passwordHint);
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      await widget.authDao.resetPassword(
        channel: _channel,
        identifier: _identifierCtrl.text.trim(),
        code: code,
        newPassword: newPassword,
      );
      setState(() => _successMsg = '密码重置成功');
      Future.delayed(const Duration(seconds: 1), () {
        widget.onSuccess?.call();
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.resetPassword),
        backgroundColor: _theme.backgroundColor,
        leading: widget.onCancel != null
            ? IconButton(icon: const Icon(Icons.close), onPressed: widget.onCancel)
            : null,
      ),
      backgroundColor: _theme.backgroundColor,
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 通道切换
            Row(
              children: [
                _ChannelChip(label: 'Email', selected: _channel == 'email',
                    onTap: () => setState(() { _channel = 'email'; _codeSent = false; })),
                const SizedBox(width: 12),
                _ChannelChip(label: 'SMS', selected: _channel == 'sms',
                    onTap: () => setState(() { _channel = 'sms'; _codeSent = false; })),
              ],
            ),
            const SizedBox(height: 16),
            IdentifierField(
              channel: _channel,
              controller: _identifierCtrl,
              theme: _theme,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordCtrl,
              obscureText: true,
              style: TextStyle(fontSize: 15, color: _theme.textColor),
              decoration: InputDecoration(
                hintText: '${l10n.passwordHint}（新密码）',
                prefixIcon: Icon(Icons.lock_outline, color: _theme.subtitleColor),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(_theme.borderRadius),
                  borderSide: BorderSide(color: _theme.borderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(_theme.borderRadius),
                  borderSide: BorderSide(color: _theme.borderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(_theme.borderRadius),
                  borderSide: BorderSide(color: _theme.primaryColor, width: 2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (!_codeSent) ...[
              SizedBox(
                width: double.infinity,
                height: _theme.inputHeight,
                child: ElevatedButton(
                  onPressed: _loading ? null : _sendCode,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _theme.primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(_theme.borderRadius),
                    ),
                  ),
                  child: _loading
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text(l10n.sendCode, style: const TextStyle(fontSize: 16)),
                ),
              ),
            ] else ...[
              Text(l10n.codeSent, textAlign: TextAlign.center,
                  style: TextStyle(color: _theme.subtitleColor, fontSize: 13)),
              const SizedBox(height: 16),
              VerificationCodeInput(
                onCompleted: _onCodeCompleted,
                onSendCode: _sendCode,
                theme: _theme,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: _theme.errorColor, fontSize: 13),
                  textAlign: TextAlign.center),
            ],
            if (_successMsg != null) ...[
              const SizedBox(height: 12),
              Text(_successMsg!, style: TextStyle(color: Colors.green, fontSize: 13),
                  textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChannelChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ChannelChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AuthKitTheme.defaults();
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? t.primaryColor : t.surfaceColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? t.primaryColor : t.borderColor),
        ),
        child: Text(label,
            style: TextStyle(color: selected ? Colors.white : t.textColor, fontSize: 13)),
      ),
    );
  }
}
