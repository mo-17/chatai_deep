import 'package:flutter/material.dart';
import '../theme/auth_kit_theme.dart';
import '../l10n/auth_kit_l10n.dart';
import '../dao/auth_dao.dart';
import '../widgets/identifier_field.dart';
import '../widgets/verification_code_input.dart';

/// 验证码登录 / 注册页面
class CodeLoginPage extends StatefulWidget {
  final AuthDao authDao;
  final String channel; // 'email' | 'sms'
  final String purpose; // 'login' | 'register'
  final AuthKitTheme? theme;
  final void Function(LoginResult result)? onSuccess;
  final VoidCallback? onSwitchToPassword;

  const CodeLoginPage({
    super.key,
    required this.authDao,
    required this.channel,
    this.purpose = 'login',
    this.theme,
    this.onSuccess,
    this.onSwitchToPassword,
  });

  @override
  State<CodeLoginPage> createState() => _CodeLoginPageState();
}

class _CodeLoginPageState extends State<CodeLoginPage> {
  final _identifierCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _codeSent = false;
  bool _loading = false;
  String? _error;

  AuthKitTheme get _theme => widget.theme ?? AuthKitTheme.defaults();
  AuthKitL10n get l10n => AuthKitL10n.instance;

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
        channel: widget.channel,
        identifier: identifier,
        purpose: widget.purpose,
      );
      setState(() => _codeSent = true);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _onCodeCompleted(String code) async {
    setState(() { _loading = true; _error = null; });
    try {
      final identifier = _identifierCtrl.text.trim();
      late LoginResult result;
      if (widget.purpose == 'register') {
        result = await widget.authDao.register(
          channel: widget.channel,
          identifier: identifier,
          code: code,
          password: _passwordCtrl.text.trim().isEmpty ? null : _passwordCtrl.text.trim(),
        );
      } else {
        result = await widget.authDao.loginByCode(
          channel: widget.channel,
          identifier: identifier,
          code: code,
        );
      }
      widget.onSuccess?.call(result);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRegister = widget.purpose == 'register';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IdentifierField(
            channel: widget.channel,
            controller: _identifierCtrl,
            theme: _theme,
          ),
          const SizedBox(height: 16),
          if (isRegister) ...[
            TextField(
              controller: _passwordCtrl,
              obscureText: true,
              style: TextStyle(fontSize: 15, color: _theme.textColor),
              decoration: InputDecoration(
                hintText: '${l10n.passwordHint}（${l10n.confirm}）',
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
            const SizedBox(height: 12),
          ],
          if (!_codeSent) ...[
            const SizedBox(height: 8),
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
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Text(l10n.sendCode, style: const TextStyle(fontSize: 16)),
              ),
            ),
          ] else ...[
            const SizedBox(height: 8),
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
            Text(_error!, style: TextStyle(color: _theme.errorColor, fontSize: 13), textAlign: TextAlign.center),
          ],
          if (widget.onSwitchToPassword != null) ...[
            const SizedBox(height: 16),
            TextButton(
              onPressed: widget.onSwitchToPassword,
              child: Text(l10n.passwordLogin, style: TextStyle(color: _theme.primaryColor)),
            ),
          ],
        ],
      ),
    );
  }
}
