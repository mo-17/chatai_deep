import 'dart:ui' as ui;

import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/auth_dao.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/util/navigator_util.dart';
import 'package:login_sdk/widget/login_backgrounds/login_background.dart';
import 'package:login_sdk/widget/login_palette.dart';

/// 注册页样式 —— tabs: 简洁白底，bg: 沉浸背景 + 玻璃卡片
enum RegisterPageStyle { tabs, bg }

/// 注册页 — G+ 配套
class RegisterPage extends StatefulWidget {
  /// 是否显示协议勾选条
  final bool showAgreement;
  final RegisterPageStyle style;
  final LoginBgVariant bgVariant;

  const RegisterPage({
    super.key,
    this.showAgreement = true,
    this.style = RegisterPageStyle.tabs,
    this.bgVariant = LoginBgVariant.mesh,
  });

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  String _tab = 'email';
  final _identifierCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  CountryCode _countryCode = supportedCountries[0];
  String _code = '';
  bool _loading = false;
  bool _agreementChecked = false;
  String? _error;
  late RegisterPageStyle _activeStyle;
  late LoginBgVariant _activeBgVariant;

  // Recomputed in build().
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
    _passwordCtrl.dispose();
    super.dispose();
  }

  String get _fullPhoneIdentifier =>
      '${_countryCode.dialCode} ${_identifierCtrl.text.trim()}';

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
        purpose: 'register',
      );
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _handleSubmit() async {
    if (widget.showAgreement && !_agreementChecked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先阅读并同意用户协议和隐私政策'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final identifier = _identifierCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (identifier.isEmpty || _code.length < 4 || password.length < 8) {
      setState(() => _error = '请完整填写表单（密码至少 8 位）');
      return;
    }
    final channel = _tab == 'email' ? 'email' : 'sms';
    final fullId = channel == 'sms' ? _fullPhoneIdentifier : identifier;
    setState(() { _loading = true; _error = null; });
    try {
      final result = await AuthDaoBridge.instance.register(
        channel: channel,
        identifier: fullId,
        code: _code,
        password: password,
      );
      LoginDao.saveAuthToken(
        result.token,
        userName: result.extra['userName']?.toString(),
        avatar: result.extra['avatar']?.toString(),
      );
      if (mounted) NavigatorUtil.goToHome(context);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_activeStyle == RegisterPageStyle.bg) {
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
                  _buildTabHeader(),
                  const SizedBox(height: 12),
                  _buildForm(),
                  const SizedBox(height: 18),
                  Center(child: _buildFooterLink()),
                  if (widget.showAgreement) ...[
                    const SizedBox(height: 18),
                    _buildAgreement(),
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
          _buildTabHeader(),
          const SizedBox(height: 12),
          _buildForm(),
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
                  // Back arrow over the bg.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: Icon(Icons.arrow_back_ios_new,
                            color: _p.heroText, size: 18),
                      ),
                    ),
                  ),
                  // Glass card.
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
                  const SizedBox(height: 14),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Center(child: _buildFooterLink()),
                  ),
                  if (widget.showAgreement) ...[
                    const SizedBox(height: 14),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _buildAgreement(),
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

  // ---- Shared sub-builders ----

  Widget _buildBackArrow() {
    return SizedBox(
      height: 36,
      child: Align(
        alignment: Alignment.centerLeft,
        child: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: Icon(Icons.arrow_back_ios_new,
              color: _p.heroText, size: 18),
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
        Text('注册新账号',
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: _p.cardText,
                letterSpacing: -0.2)),
        const SizedBox(height: 6),
        Text('欢迎加入 艾普 · Demo',
            style: TextStyle(fontSize: 12, color: _p.cardSub)),
      ],
    );
  }

  Widget _buildForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildIdentifierInput(),
        const SizedBox(height: 10),
        VerificationCodeInput(
          onCompleted: (c) => _code = c,
          onSendCode: _handleSendCode,
          theme: _themeForInputs,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _passwordCtrl,
          obscureText: true,
          style: TextStyle(fontSize: 14, color: _p.cardText),
          decoration: _inputDecoration('设置密码（8-20 位）'),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text('由字母 + 数字组成，区分大小写',
              style: TextStyle(fontSize: 11, color: _p.cardSub)),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          height: _theme.inputHeight,
          child: ElevatedButton(
            onPressed: _loading ? null : _handleSubmit,
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
                : const Text('创建账号',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500)),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!,
              style: TextStyle(color: _p.errorColor, fontSize: 13)),
        ],
      ],
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

  Widget _buildFooterLink() {
    return Text.rich(
      TextSpan(
        style: TextStyle(fontSize: 12, color: _p.cardSub),
        children: [
          const TextSpan(text: '已有账号？'),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text('返回登录',
                    style: TextStyle(
                        fontSize: 12,
                        color: _p.linkColor,
                        fontWeight: FontWeight.w500)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAgreement() {
    final checked = _agreementChecked;
    return GestureDetector(
      onTap: () => setState(() => _agreementChecked = !_agreementChecked),
      child: Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: checked ? _p.agreementBoxBorder : _p.cardBorderSoft,
              ),
              color: checked ? _p.agreementBoxBg : Colors.transparent,
            ),
            alignment: Alignment.center,
            child: checked
                ? Icon(Icons.check, size: 10, color: _p.agreementCheck)
                : null,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: TextStyle(
                    fontSize: 11, color: _p.agreementText, height: 1.5),
                children: [
                  const TextSpan(text: '已阅读并同意'),
                  TextSpan(
                    text: '《用户协议》',
                    style: TextStyle(
                        color: _p.agreementLink,
                        fontWeight: FontWeight.w500),
                  ),
                  const TextSpan(text: '和'),
                  TextSpan(
                    text: '《隐私政策》',
                    style: TextStyle(
                        color: _p.agreementLink,
                        fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Debug bg cycle pill ----

  void _cycleDebugMode() {
    setState(() {
      if (_activeStyle == RegisterPageStyle.tabs) {
        _activeStyle = RegisterPageStyle.bg;
        _activeBgVariant = LoginBgVariant.mesh;
      } else {
        const variants = LoginBgVariant.values;
        final idx = variants.indexOf(_activeBgVariant);
        if (idx < variants.length - 1) {
          _activeBgVariant = variants[idx + 1];
        } else {
          _activeStyle = RegisterPageStyle.tabs;
        }
      }
    });
  }

  String get _debugPillLabel {
    if (_activeStyle == RegisterPageStyle.tabs) return 'T';
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
