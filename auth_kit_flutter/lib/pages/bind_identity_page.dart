import 'package:flutter/material.dart';
import '../theme/auth_kit_theme.dart';
import '../l10n/auth_kit_l10n.dart';
import '../dao/auth_dao.dart';
import '../widgets/identifier_field.dart';
import '../widgets/verification_code_input.dart';

/// 第三方登录后绑定邮箱/手机号页面
class BindIdentityPage extends StatefulWidget {
  final AuthDao authDao;
  final String bindTicket;
  final String provider; // 'huawei' | 'apple'
  final String? preferredChannel; // 'email' | 'sms'
  final AuthKitTheme? theme;
  final void Function(LoginResult result)? onSuccess;

  const BindIdentityPage({
    super.key,
    required this.authDao,
    required this.bindTicket,
    required this.provider,
    this.preferredChannel,
    this.theme,
    this.onSuccess,
  });

  @override
  State<BindIdentityPage> createState() => _BindIdentityPageState();
}

class _BindIdentityPageState extends State<BindIdentityPage> {
  late String _channel;
  final _identifierCtrl = TextEditingController();
  bool _codeSent = false;
  bool _loading = false;
  bool _bindInFlight = false;
  String? _error;

  AuthKitTheme get _theme => widget.theme ?? AuthKitTheme.defaults();
  AuthKitL10n get l10n => AuthKitL10n.instance;

  @override
  void initState() {
    super.initState();
    _channel = widget.preferredChannel ?? 'email';
  }

  @override
  void dispose() {
    _identifierCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    if (!mounted) return;
    final identifier = _identifierCtrl.text.trim();
    if (identifier.isEmpty) {
      setState(() => _error = l10n.identifierHint);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.authDao.sendCode(
        channel: _channel,
        identifier: identifier,
        purpose: 'bind',
      );
      if (!mounted) return;
      setState(() => _codeSent = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _onCodeCompleted(String code) async {
    if (!mounted || _bindInFlight) return;
    _bindInFlight = true;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final identifier = _identifierCtrl.text.trim();
      late LoginResult result;
      if (widget.provider == 'huawei') {
        result = await widget.authDao.huaweiBindAndLogin(
          bindTicket: widget.bindTicket,
          channel: _channel,
          identifier: identifier,
          code: code,
        );
      } else {
        result = await widget.authDao.appleBindAndLogin(
          bindTicket: widget.bindTicket,
          channel: _channel,
          identifier: identifier,
          code: code,
        );
      }
      if (!mounted) return;
      widget.onSuccess?.call(result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      _bindInFlight = false;
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.bindIdentity),
        backgroundColor: _theme.backgroundColor,
      ),
      backgroundColor: _theme.backgroundColor,
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.bindIdentityDesc,
                style: TextStyle(color: _theme.subtitleColor, fontSize: 14)),
            const SizedBox(height: 24),
            // 通道切换
            Row(
              children: [
                _ChannelChip(
                    label: 'Email',
                    selected: _channel == 'email',
                    onTap: () => setState(() {
                          _channel = 'email';
                          _codeSent = false;
                        })),
                const SizedBox(width: 12),
                _ChannelChip(
                    label: 'SMS',
                    selected: _channel == 'sms',
                    onTap: () => setState(() {
                          _channel = 'sms';
                          _codeSent = false;
                        })),
              ],
            ),
            const SizedBox(height: 16),
            IdentifierField(
              channel: _channel,
              controller: _identifierCtrl,
              theme: _theme,
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
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Text(l10n.sendCode,
                          style: const TextStyle(fontSize: 16)),
                ),
              ),
            ] else ...[
              Text(l10n.codeSent,
                  textAlign: TextAlign.center,
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
              Text(_error!,
                  style: TextStyle(color: _theme.errorColor, fontSize: 13),
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

  const _ChannelChip(
      {required this.label, required this.selected, required this.onTap});

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
            style: TextStyle(
                color: selected ? Colors.white : t.textColor, fontSize: 13)),
      ),
    );
  }
}
