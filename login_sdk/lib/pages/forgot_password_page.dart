import 'dart:async';
import 'dart:ui' as ui;

import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/auth_dao.dart';
import 'package:login_sdk/widget/login_backgrounds/login_background.dart';
import 'package:login_sdk/widget/login_palette.dart';

/// 忘记密码页样式 —— tabs: 简洁白底，bg: 沉浸背景 + 玻璃卡片
enum ForgotPageStyle { tabs, bg }

/// 忘记密码 — G+ 配套，三步流程：验证身份 → 设置新密码 → 完成
class ForgotPasswordPage extends StatefulWidget {
  final ForgotPageStyle style;
  final LoginBgVariant bgVariant;

  const ForgotPasswordPage({
    super.key,
    this.style = ForgotPageStyle.tabs,
    this.bgVariant = LoginBgVariant.mesh,
  });

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  int _step = 1; // 1 verify | 2 reset | 3 done

  // Step 1 fields
  String _tab = 'email';
  final _identifierCtrl = TextEditingController();
  CountryCode _countryCode = supportedCountries[0];
  String _code = '';

  // Step 2 fields
  final _newPasswordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();

  // Submitted identity (used by step 2's reset call)
  String? _submittedChannel;
  String? _submittedIdentifier;
  String? _submittedCode;

  bool _loading = false;
  String? _error;
  Timer? _redirectTimer;

  late ForgotPageStyle _activeStyle;
  late LoginBgVariant _activeBgVariant;
  LoginBackgroundMeta? _bgMeta;
  late LoginPalette _p;

  @override
  void initState() {
    super.initState();
    _activeStyle = widget.style;
    _activeBgVariant = widget.bgVariant;
  }

  static const _lightTheme = AuthKitTheme(
    primaryColor: Color(0xFF0F3460),
    backgroundColor: Colors.white,
    surfaceColor: Color(0xFFF7F8FA),
    textColor: Color(0xFF0F1115),
    subtitleColor: Color(0x940F1115),
    borderColor: Color(0x1A0F1115),
    errorColor: Color(0xFFE53935),
    borderRadius: 12,
    inputHeight: 48,
  );

  static const _darkTheme = AuthKitTheme(
    primaryColor: Color(0xFF64B5F6),
    backgroundColor: Color(0xFF111315),
    surfaceColor: Color(0xFF191C1F),
    textColor: Color(0xFFF3F4F6),
    subtitleColor: Color(0x8CF3F4F6),
    borderColor: Color(0x1AFFFFFF),
    errorColor: Color(0xFFEF5350),
    borderRadius: 12,
    inputHeight: 48,
  );

  AuthKitTheme get _theme =>
      MediaQuery.of(context).platformBrightness == Brightness.dark
          ? _darkTheme
          : _lightTheme;

  bool get _isDark =>
      MediaQuery.of(context).platformBrightness == Brightness.dark;

  AuthKitTheme get _themeForInputs => AuthKitTheme(
        primaryColor: _theme.primaryColor,
        backgroundColor: _p.inputBg,
        surfaceColor: _p.modeOuterBg,
        textColor: _p.cardText,
        subtitleColor: _p.cardSub,
        borderColor: _p.cardBorderSoft,
        errorColor: _p.errorColor,
        borderRadius: _theme.borderRadius,
        inputHeight: _theme.inputHeight,
      );

  @override
  void dispose() {
    _identifierCtrl.dispose();
    _newPasswordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    _redirectTimer?.cancel();
    super.dispose();
  }

  String get _fullPhoneIdentifier =>
      '${_countryCode.dialCode} ${_identifierCtrl.text.trim()}';

  String _maskedIdentifier() {
    final id = _submittedIdentifier ?? '';
    if (_submittedChannel == 'email' && id.contains('@')) {
      final at = id.indexOf('@');
      final head = id.substring(0, at);
      final mask = head.isEmpty ? '*' : '${head[0]}***';
      return '$mask${id.substring(at)}';
    }
    if (id.length > 4) {
      final tail = id.substring(id.length - 4);
      return '***$tail';
    }
    return '***';
  }

  Future<void> _handleSendCode() async {
    final identifier = _identifierCtrl.text.trim();
    if (identifier.isEmpty) {
      setState(() => _error = '请输入邮箱或手机号');
      return;
    }
    final channel = _tab == 'email' ? 'email' : 'sms';
    final fullId = channel == 'sms' ? _fullPhoneIdentifier : identifier;
    setState(() => _error = null);
    try {
      await AuthDaoBridge.instance.sendCode(
        channel: channel,
        identifier: fullId,
        purpose: 'reset_password',
      );
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _goToStep2() {
    final identifier = _identifierCtrl.text.trim();
    if (identifier.isEmpty) {
      setState(() => _error = '请输入邮箱或手机号');
      return;
    }
    if (_code.length < 4) {
      setState(() => _error = '请输入验证码');
      return;
    }
    final channel = _tab == 'email' ? 'email' : 'sms';
    setState(() {
      _submittedChannel = channel;
      _submittedIdentifier =
          channel == 'sms' ? _fullPhoneIdentifier : identifier;
      _submittedCode = _code;
      _error = null;
      _step = 2;
    });
  }

  Future<void> _handleReset() async {
    final newPwd = _newPasswordCtrl.text;
    final confirm = _confirmPasswordCtrl.text;
    if (newPwd.length < 8) {
      setState(() => _error = '新密码至少 8 位');
      return;
    }
    if (newPwd != confirm) {
      setState(() => _error = '两次输入的密码不一致');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      await AuthDaoBridge.instance.resetPassword(
        channel: _submittedChannel!,
        identifier: _submittedIdentifier!,
        code: _submittedCode!,
        newPassword: newPwd,
      );
      if (!mounted) return;
      setState(() => _step = 3);
      _redirectTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) Navigator.pop(context);
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_activeStyle == ForgotPageStyle.bg) {
      _bgMeta = loginBackgroundFor(_activeBgVariant, _theme.primaryColor);
      _p = LoginPalette.forBg(_theme, _isDark, _bgMeta!);
      return _buildBg();
    }
    _bgMeta = null;
    _p = LoginPalette.forTabs(_theme, _isDark);
    return _buildTabs();
  }

  // ---- Tabs (plain) layout ----

  Widget _buildTabs() {
    return Scaffold(
      backgroundColor: _theme.backgroundColor,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildBackArrow(),
                  const SizedBox(height: 18),
                  _buildTitleBlock(),
                  const SizedBox(height: 22),
                  if (_step != 3) _buildStepper(),
                  if (_step != 3) const SizedBox(height: 18),
                  if (_step == 1) _buildStep1(),
                  if (_step == 2) _buildStep2(),
                  if (_step == 3) _buildStep3(),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!,
                        style: TextStyle(
                            color: _p.errorColor, fontSize: 13)),
                  ],
                  if (_step != 3) ...[
                    const SizedBox(height: 18),
                    Center(child: _buildFooterLink()),
                  ],
                ],
              ),
            ),
          ),
          if (kDebugMode) _buildDebugPill(),
        ],
      ),
    );
  }

  // ---- Bg + glass card layout ----

  Widget _buildBg() {
    final bgMeta = _bgMeta!;
    final cardRadius =
        (_theme.borderRadius + 4).clamp(16, double.infinity).toDouble();
    final card = Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      decoration: BoxDecoration(
        color: _p.cardBg,
        borderRadius: BorderRadius.circular(cardRadius),
        border: Border.all(color: _p.cardBorder),
        boxShadow: [
          BoxShadow(
            blurRadius: 40,
            offset: const Offset(0, 10),
            color: _p.cardShadow,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTitleBlock(),
          const SizedBox(height: 18),
          if (_step != 3) _buildStepper(),
          if (_step != 3) const SizedBox(height: 16),
          if (_step == 1) _buildStep1(),
          if (_step == 2) _buildStep2(),
          if (_step == 3) _buildStep3(),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: TextStyle(color: _p.errorColor, fontSize: 13)),
          ],
        ],
      ),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          Positioned.fill(child: bgMeta.widget),
          SafeArea(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        onPressed: () {
                          if (_step == 2) {
                            setState(() => _step = 1);
                          } else {
                            Navigator.pop(context);
                          }
                        },
                        icon: Icon(Icons.arrow_back_ios_new,
                            color: _p.heroText, size: 18),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(cardRadius),
                      child: bgMeta.isSolidCard
                          ? card
                          : BackdropFilter(
                              filter: ui.ImageFilter.blur(
                                  sigmaX: 24, sigmaY: 24),
                              child: card,
                            ),
                    ),
                  ),
                  if (_step != 3) ...[
                    const SizedBox(height: 14),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Center(child: _buildFooterLink()),
                    ),
                  ],
                  const SizedBox(height: 60),
                ],
              ),
            ),
          ),
          if (kDebugMode) _buildDebugPill(),
        ],
      ),
    );
  }

  // ---- Sub-builders ----

  Widget _buildBackArrow() {
    return SizedBox(
      height: 36,
      child: Align(
        alignment: Alignment.centerLeft,
        child: IconButton(
          onPressed: () {
            if (_step == 2) {
              setState(() => _step = 1);
            } else {
              Navigator.pop(context);
            }
          },
          icon: Icon(Icons.arrow_back_ios_new, color: _p.heroText, size: 18),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ),
    );
  }

  Widget _buildTitleBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_step == 3 ? '密码已重置' : '找回密码',
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: _p.cardText,
                letterSpacing: -0.2)),
        const SizedBox(height: 6),
        Text(_subtitleForStep(),
            style: TextStyle(fontSize: 12, color: _p.cardSub)),
      ],
    );
  }

  String _subtitleForStep() {
    switch (_step) {
      case 1:
        return '输入注册邮箱或手机号验证身份';
      case 2:
        return '为账号 ${_maskedIdentifier()} 设置新密码';
      default:
        return '请使用新密码重新登录';
    }
  }

  Widget _buildStepper() {
    return Row(
      children: [
        for (var i = 1; i <= 3; i++) ...[
          _buildStepDot(i),
          if (i < 3) _buildStepConnector(i),
        ],
        const Spacer(),
        Text(
          _step == 1 ? '验证身份' : _step == 2 ? '设置新密码' : '完成',
          style: TextStyle(fontSize: 11, color: _p.cardSub),
        ),
      ],
    );
  }

  Widget _buildStepDot(int n) {
    final active = _step >= n;
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? _p.tabActive : _p.modeOuterBg,
      ),
      alignment: Alignment.center,
      child: Text(
        '$n',
        style: TextStyle(
          color: active ? _p.submitFg : _p.cardSub,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildStepConnector(int n) {
    return Container(
      width: 60,
      height: 2,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: _step > n ? _p.tabActive : _p.cardDivider,
    );
  }

  Widget _buildStep1() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTabHeader(),
        const SizedBox(height: 12),
        _buildIdentifierInput(),
        const SizedBox(height: 10),
        VerificationCodeInput(
          onCompleted: (c) => _code = c,
          onSendCode: _handleSendCode,
          theme: _themeForInputs,
        ),
        const SizedBox(height: 14),
        _buildPrimaryButton('下一步', _goToStep2),
      ],
    );
  }

  Widget _buildStep2() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _newPasswordCtrl,
          obscureText: true,
          style: TextStyle(fontSize: 14, color: _p.cardText),
          decoration: _inputDecoration('新密码（8-20 位）'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _confirmPasswordCtrl,
          obscureText: true,
          style: TextStyle(fontSize: 14, color: _p.cardText),
          decoration: _inputDecoration('确认新密码'),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text('由字母 + 数字组成，区分大小写',
              style: TextStyle(fontSize: 11, color: _p.cardSub)),
        ),
        const SizedBox(height: 14),
        _buildPrimaryButton('确认重置', _loading ? null : _handleReset),
      ],
    );
  }

  Widget _buildStep3() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 12),
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _theme.primaryColor.withValues(alpha: 0.10),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.check, size: 30, color: _p.tabActive),
        ),
        const SizedBox(height: 18),
        Text(
          '新密码已生效\n页面将在 3 秒后跳转到登录',
          textAlign: TextAlign.center,
          style:
              TextStyle(fontSize: 13, color: _p.cardSub, height: 1.6),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: _buildPrimaryButton('立即登录', () {
            _redirectTimer?.cancel();
            if (mounted) Navigator.pop(context);
          }),
        ),
      ],
    );
  }

  Widget _buildPrimaryButton(String label, VoidCallback? onTap) {
    return SizedBox(
      width: double.infinity,
      height: _theme.inputHeight,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: _p.submitBg,
          foregroundColor: _p.submitFg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_theme.borderRadius),
          ),
        ),
        child: _loading
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: _p.submitFg),
              )
            : Text(label,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w500)),
      ),
    );
  }

  Widget _buildFooterLink() {
    return Text.rich(
      TextSpan(
        style: TextStyle(fontSize: 12, color: _p.cardSub),
        children: [
          const TextSpan(text: '遇到问题？'),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text('联系客服',
                  style: TextStyle(
                      fontSize: 12,
                      color: _p.linkColor,
                      fontWeight: FontWeight.w500)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabHeader() {
    return Column(
      children: [
        Row(
          children: [
            _buildTabItem('email', '邮箱'),
            const SizedBox(width: 22),
            _buildTabItem('phone', '手机号'),
          ],
        ),
        Container(height: 1, color: _p.cardDivider),
      ],
    );
  }

  Widget _buildTabItem(String key, String label) {
    final active = _tab == key;
    return GestureDetector(
      onTap: () => setState(() {
        _tab = key;
        _identifierCtrl.clear();
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? _p.tabActive : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? _p.cardText : _p.cardSub,
          ),
        ),
      ),
    );
  }

  Widget _buildIdentifierInput() {
    if (_tab == 'email') {
      return IdentifierField(
        channel: 'email',
        controller: _identifierCtrl,
        theme: _themeForInputs,
      );
    }
    return Row(
      children: [
        CountryCodePicker(
          selected: _countryCode,
          onChanged: (cc) => setState(() => _countryCode = cc),
          theme: _themeForInputs,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _identifierCtrl,
            keyboardType: TextInputType.phone,
            style: TextStyle(fontSize: 14, color: _p.cardText),
            decoration: _inputDecoration(AuthKitL10n.instance.phoneHint),
          ),
        ),
      ],
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(fontSize: 14, color: _p.cardSub),
      filled: _p.inputBg.a > 0,
      fillColor: _p.inputBg,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_theme.borderRadius),
        borderSide: BorderSide(color: _p.cardBorderSoft),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_theme.borderRadius),
        borderSide: BorderSide(color: _p.cardBorderSoft),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_theme.borderRadius),
        borderSide: BorderSide(color: _p.tabActive, width: 2),
      ),
    );
  }

  // ---- Debug bg cycle pill ----

  void _cycleDebugMode() {
    setState(() {
      if (_activeStyle == ForgotPageStyle.tabs) {
        _activeStyle = ForgotPageStyle.bg;
        _activeBgVariant = LoginBgVariant.mesh;
      } else {
        const variants = LoginBgVariant.values;
        final idx = variants.indexOf(_activeBgVariant);
        if (idx < variants.length - 1) {
          _activeBgVariant = variants[idx + 1];
        } else {
          _activeStyle = ForgotPageStyle.tabs;
        }
      }
    });
  }

  String get _debugPillLabel {
    if (_activeStyle == ForgotPageStyle.tabs) return 'T';
    return kLoginBgPillLabels[_activeBgVariant.index];
  }

  Widget _buildDebugPill() {
    return Positioned(
      bottom: 60,
      right: 16,
      child: GestureDetector(
        onTap: _cycleDebugMode,
        child: Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black54,
            boxShadow: [
              BoxShadow(
                  blurRadius: 8,
                  color: Color(0x40000000),
                  offset: Offset(0, 2)),
            ],
          ),
          child: Center(
            child: Text(
              _debugPillLabel,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
