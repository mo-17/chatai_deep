import 'dart:io';
import 'dart:ui' as ui;

import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:login_sdk/config/login_auth_dependencies.dart';
import 'package:login_sdk/config/login_sdk_config.dart' show LoginSdkConfig;
import 'package:login_sdk/dao/auth_dao.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/pages/forgot_password_page.dart';
import 'package:login_sdk/pages/register_page.dart';
import 'package:login_sdk/util/navigator_util.dart';
import 'package:login_sdk/widget/login_backgrounds/login_background.dart';
import 'package:login_sdk/widget/login_palette.dart';

enum LoginPageStyle { tabs, bg }

class LoginPage extends StatefulWidget {
  final LoginPageStyle style;
  final LoginBgVariant bgVariant;
  final VoidCallback? onLoginSuccess;
  final LoginAuthDependencies? authDependencies;

  const LoginPage({
    super.key,
    this.style = LoginPageStyle.tabs,
    this.bgVariant = LoginBgVariant.mesh,
    this.onLoginSuccess,
    this.authDependencies,
  });

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  // ---- State ----
  String _tab = 'email';
  String _emailMode = 'password';
  final _identifierCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  CountryCode _countryCode = supportedCountries[0];
  String _code = '';
  bool _loading = false;
  int _loginAttempt = 0;
  LoginAuthAttempt? _activeAuthAttempt;
  String? _error;
  bool _agreementChecked = false;
  late LoginPageStyle _activeStyle;
  late LoginBgVariant _activeBgVariant;
  late final AuthDao _authDao;
  late final IAppleSignInService _appleService;
  late final IHuaweiLoginService _huaweiService;

  @override
  void initState() {
    super.initState();
    _activeStyle = widget.style;
    _activeBgVariant = widget.bgVariant;
    final widgetDependencies = widget.authDependencies;
    final configuredDependencies = LoginSdkConfig.instance.authDependencies;
    _authDao = widgetDependencies?.authDao ??
        configuredDependencies?.authDao ??
        AuthDaoBridge.instance;
    _appleService = widgetDependencies?.appleSignInService ??
        configuredDependencies?.appleSignInService ??
        AppleSignInUnavailable();
    _huaweiService = widgetDependencies?.huaweiLoginService ??
        configuredDependencies?.huaweiLoginService ??
        HuaweiLoginUnavailable();
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

  AuthKitTheme get _theme {
    final brightness = MediaQuery.of(context).platformBrightness;
    return brightness == Brightness.dark ? _darkTheme : _lightTheme;
  }

  bool get _isDark =>
      MediaQuery.of(context).platformBrightness == Brightness.dark;

  // Background metadata + derived palette. Recomputed at the top of build()
  // so every builder reads bg-aware colors instead of raw `_theme` tokens.
  LoginBackgroundMeta? _bgMeta;
  late LoginPalette _p;

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
    final authAttempt = _activeAuthAttempt;
    _activeAuthAttempt = null;
    if (authAttempt != null) {
      LoginDao.cancelAuthAttempt(authAttempt);
    }
    _loginAttempt++;
    _identifierCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  // ---- Platform detection ----
  static String get _platform {
    if (Platform.isIOS) return 'ios';
    if (Platform.operatingSystem == 'ohos') return 'harmony';
    return 'android';
  }

  // ---- Actions ----

  int? _beginLoginAttempt() {
    if (_loading || !mounted) return null;
    final attempt = ++_loginAttempt;
    setState(() {
      _loading = true;
      _error = null;
    });
    return attempt;
  }

  LoginAuthAttempt _beginGlobalAuthAttempt() {
    final attempt = LoginDao.beginAuthAttempt();
    _activeAuthAttempt = attempt;
    return attempt;
  }

  void _releaseGlobalAuthAttempt(LoginAuthAttempt attempt) {
    LoginDao.cancelAuthAttempt(attempt);
    if (identical(_activeAuthAttempt, attempt)) {
      _activeAuthAttempt = null;
    }
  }

  bool _ownsAttempt(int attempt) => mounted && attempt == _loginAttempt;

  bool _isCurrentAttempt(int attempt) =>
      _ownsAttempt(attempt) && (ModalRoute.of(context)?.isCurrent ?? false);

  void _finishLoginAttempt(int attempt) {
    if (_ownsAttempt(attempt)) {
      setState(() => _loading = false);
    }
  }

  Future<void> _handlePasswordLogin() async {
    final identifier = _identifierCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (identifier.isEmpty || password.isEmpty) {
      setState(() => _error = '请输入邮箱地址和密码');
      return;
    }
    final attempt = _beginLoginAttempt();
    if (attempt == null) return;
    final authAttempt = _beginGlobalAuthAttempt();
    try {
      final result = await _authDao.loginByPassword(
        channel: 'email',
        identifier: identifier,
        password: password,
      );
      if (!_isCurrentAttempt(attempt)) return;
      await _onLoginSuccess(result, attempt, authAttempt);
    } on LoginAccountChangedException {
      return;
    } catch (e) {
      if (_isCurrentAttempt(attempt)) {
        setState(() => _error = e.toString());
      }
    } finally {
      _releaseGlobalAuthAttempt(authAttempt);
      _finishLoginAttempt(attempt);
    }
  }

  String get _fullPhoneIdentifier =>
      '${_countryCode.dialCode} ${_identifierCtrl.text.trim()}';

  Future<void> _handleSendCode() async {
    final identifier = _identifierCtrl.text.trim();
    if (identifier.isEmpty) {
      setState(() => _error = '请输入邮箱地址或手机号');
      return;
    }
    final channel = _tab == 'email' ? 'email' : 'sms';
    final fullId = channel == 'sms' ? _fullPhoneIdentifier : identifier;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _authDao.sendCode(
        channel: channel,
        identifier: fullId,
        purpose: 'login',
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onCodeCompleted(String code) {
    _code = code;
  }

  Future<void> _handleCodeLogin() async {
    final identifier = _identifierCtrl.text.trim();
    if (identifier.isEmpty) {
      setState(() => _error = '请输入邮箱地址或手机号');
      return;
    }
    if (_code.length != 6) {
      setState(() => _error = '请输入验证码');
      return;
    }
    final channel = _tab == 'email' ? 'email' : 'sms';
    final fullId = channel == 'sms' ? _fullPhoneIdentifier : identifier;
    final attempt = _beginLoginAttempt();
    if (attempt == null) return;
    final authAttempt = _beginGlobalAuthAttempt();
    try {
      final result = await _authDao.loginByCode(
        channel: channel,
        identifier: fullId,
        code: _code,
      );
      if (!_isCurrentAttempt(attempt)) return;
      await _onLoginSuccess(result, attempt, authAttempt);
    } on LoginAccountChangedException {
      return;
    } catch (e) {
      if (_isCurrentAttempt(attempt)) {
        setState(() => _error = e.toString());
      }
    } finally {
      _releaseGlobalAuthAttempt(authAttempt);
      _finishLoginAttempt(attempt);
    }
  }

  Future<void> _onLoginSuccess(
    LoginResult result,
    int attempt,
    LoginAuthAttempt authAttempt,
  ) async {
    if (!_isCurrentAttempt(attempt)) return;
    await LoginDao.saveAuthTokenForAttempt(
      result.token,
      attempt: authAttempt,
      userName: result.extra['userName']?.toString(),
      avatar: result.extra['avatar']?.toString(),
      imoocId: result.extra['imoocId']?.toString(),
    );
    if (!mounted || !_isCurrentAttempt(attempt)) return;
    widget.onLoginSuccess?.call();
    if (widget.onLoginSuccess == null) {
      NavigatorUtil.goToHome(context);
    }
  }

  Future<void> _handleAppleLogin() async {
    final attempt = _beginLoginAttempt();
    if (attempt == null) return;
    final authAttempt = _beginGlobalAuthAttempt();
    try {
      final appleResult = await _appleService.signIn();
      final authResult = await _authDao.appleLogin(
        identityToken: appleResult.identityToken,
        authorizationCode: appleResult.authorizationCode,
        fullName: appleResult.fullName,
      );
      await _handleThirdPartyResult(
        authResult,
        provider: 'apple',
        attempt: attempt,
        authAttempt: authAttempt,
      );
    } on LoginAccountChangedException {
      return;
    } catch (e) {
      if (mounted && _isCurrentAttempt(attempt)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Apple 登录暂未接入'), backgroundColor: Colors.orange),
        );
      }
    } finally {
      _releaseGlobalAuthAttempt(authAttempt);
      _finishLoginAttempt(attempt);
    }
  }

  Future<void> _handleHuaweiLogin() async {
    final attempt = _beginLoginAttempt();
    if (attempt == null) return;
    final authAttempt = _beginGlobalAuthAttempt();
    try {
      final hwResult = await _huaweiService.signInWithQuickLogin();
      final authResult = await _authDao.huaweiLogin(
        mode: hwResult.mode,
        authCode: hwResult.authCode,
        accessToken: hwResult.accessToken,
      );
      await _handleThirdPartyResult(
        authResult,
        provider: 'huawei',
        attempt: attempt,
        authAttempt: authAttempt,
      );
    } on LoginAccountChangedException {
      return;
    } catch (e) {
      if (mounted && _isCurrentAttempt(attempt)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('华为登录暂未接入'), backgroundColor: Colors.orange),
        );
      }
    } finally {
      _releaseGlobalAuthAttempt(authAttempt);
      _finishLoginAttempt(attempt);
    }
  }

  Future<void> _handleThirdPartyResult(
    ThirdPartyLoginResult authResult, {
    required String provider,
    required int attempt,
    required LoginAuthAttempt authAttempt,
  }) async {
    if (!_isCurrentAttempt(attempt)) return;
    final LoginResult? result;
    if (authResult.needBinding) {
      final bindTicket = authResult.bindTicket;
      if (bindTicket == null || bindTicket.isEmpty) {
        throw StateError('$provider 登录缺少 bindTicket');
      }
      result = await _showBindPage(
        bindTicket: bindTicket,
        provider: provider,
      );
    } else {
      final token = authResult.token;
      result = token == null
          ? null
          : LoginResult(token: token, extra: authResult.extra ?? const {});
    }
    if (result == null || !_isCurrentAttempt(attempt)) return;
    await _onLoginSuccess(result, attempt, authAttempt);
  }

  Future<LoginResult?> _showBindPage({
    required String bindTicket,
    required String provider,
  }) {
    return Navigator.push<LoginResult>(
      context,
      MaterialPageRoute(
        builder: (routeContext) => BindIdentityPage(
          authDao: _authDao,
          bindTicket: bindTicket,
          provider: provider,
          onSuccess: (result) {
            if (routeContext.mounted) {
              Navigator.of(routeContext).pop(result);
            }
          },
        ),
      ),
    );
  }

  void _showUnavailableToast(String name) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$name 登录暂未接入'), backgroundColor: Colors.orange),
    );
  }

  Future<void> _handleSubmit() async {
    if (_tab == 'email' && _emailMode == 'password') {
      await _handlePasswordLogin();
    } else {
      await _handleCodeLogin();
    }
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    if (_activeStyle == LoginPageStyle.bg) {
      _bgMeta = loginBackgroundFor(_activeBgVariant, _theme.primaryColor);
      _p = LoginPalette.forBg(_theme, _isDark, _bgMeta!);
      return _buildBg();
    }
    _bgMeta = null;
    _p = LoginPalette.forTabs(_theme, _isDark);
    return _buildTabs();
  }

  Widget _buildTabs() {
    return Scaffold(
      backgroundColor: _theme.backgroundColor,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
                child: Column(
                  children: [
                    _buildBrand(),
                    _buildTabHeader(),
                    if (_tab == 'email') _buildEmailModeSwitcher(),
                    _buildForm(),
                    if (_tab == 'email') _buildHelperLinks(),
                    if (_tab == 'phone') _buildPhoneHint(),
                    _buildDivider(),
                    _buildPlatformMandatory(),
                    _buildSocialDots(),
                    _buildAgreement(),
                    _buildGuestEntry(),
                    const SizedBox(height: 80),
                  ],
                ),
              ),
            ),
          ),
          if (kDebugMode) _buildDebugPill(),
        ],
      ),
    );
  }

  Widget _buildBg() {
    final bgMeta = _bgMeta!;
    final cardRadius =
        (_theme.borderRadius + 4).clamp(16, double.infinity).toDouble();

    final card = Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
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
        children: [
          _buildTabHeader(),
          if (_tab == 'email') _buildEmailModeSwitcher(),
          _buildForm(),
          if (_tab == 'email') _buildHelperLinks(),
          if (_tab == 'phone') _buildPhoneHint(),
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
                children: [
                  const SizedBox(height: 28),
                  _buildBrand(),
                  const SizedBox(height: 8),
                  // Glass card — skip backdrop blur for the literal paper bg
                  // (glass-on-printed-paper reads wrong).
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(cardRadius),
                      child: bgMeta.isSolidCard
                          ? card
                          : BackdropFilter(
                              filter:
                                  ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                              child: card,
                            ),
                    ),
                  ),
                  // Outside card
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        _buildDivider(),
                        _buildPlatformMandatory(),
                        _buildSocialDots(),
                        _buildAgreement(),
                        _buildGuestEntry(),
                        const SizedBox(height: 80),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (kDebugMode) _buildDebugPill(),
        ],
      ),
    );
  }

  void _cycleDebugMode() {
    setState(() {
      if (_activeStyle == LoginPageStyle.tabs) {
        _activeStyle = LoginPageStyle.bg;
        _activeBgVariant = LoginBgVariant.mesh;
      } else {
        const variants = LoginBgVariant.values;
        final idx = variants.indexOf(_activeBgVariant);
        if (idx < variants.length - 1) {
          _activeBgVariant = variants[idx + 1];
        } else {
          _activeStyle = LoginPageStyle.tabs;
        }
      }
    });
  }

  String get _debugPillLabel {
    if (_activeStyle == LoginPageStyle.tabs) return 'T';
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

  Widget _buildBrand() {
    final inBg = _activeStyle == LoginPageStyle.bg;
    final onColor = _bgMeta?.isDarkBg ?? false;
    final logoSize = inBg ? 52.0 : 44.0;
    return Column(
      children: [
        Container(
          width: logoSize,
          height: logoSize,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            // On dark backgrounds the brand mark uses a translucent white
            // tile (à la iOS native sign-in tile) instead of the primary
            // gradient — keeps it readable on any photo/glow image.
            color: onColor ? Colors.white.withValues(alpha: 0.18) : null,
            border: onColor
                ? Border.all(color: Colors.white.withValues(alpha: 0.35))
                : null,
            gradient: onColor
                ? null
                : LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [_theme.primaryColor, _theme.subtitleColor],
                  ),
          ),
          alignment: Alignment.center,
          child: Text(
            '艾',
            style: TextStyle(
              color: Colors.white,
              fontSize: logoSize * 0.46,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(height: inBg ? 12 : 22),
        Text(
          '艾普 · Demo',
          style: TextStyle(
            fontSize: inBg ? 16 : 15,
            fontWeight: FontWeight.w600,
            color: _p.heroText,
          ),
        ),
        if (inBg) ...[
          const SizedBox(height: 4),
          Text(
            '登录以继续',
            style: TextStyle(fontSize: 11, color: _p.heroSub),
          ),
        ],
        SizedBox(height: inBg ? 10 : 18),
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
        Container(
          height: 1,
          color: _p.cardDivider,
        ),
        const SizedBox(height: 18),
      ],
    );
  }

  Widget _buildTabItem(String key, String label) {
    final active = _tab == key;
    return GestureDetector(
      onTap: () => setState(() => _tab = key),
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

  Widget _buildEmailModeSwitcher() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: _p.modeOuterBg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildModeChip('password', '密码登录'),
            _buildModeChip('code', '验证码登录'),
          ],
        ),
      ),
    );
  }

  Widget _buildModeChip(String key, String label) {
    final active = _emailMode == key;
    return GestureDetector(
      onTap: () => setState(() {
        _emailMode = key;
        _code = '';
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: active ? _p.modeChipActiveBg : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          boxShadow: active
              ? [
                  const BoxShadow(
                      blurRadius: 2,
                      color: Color(0x0F000000),
                      offset: Offset(0, 1))
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: active ? _p.modeChipActiveFg : _p.modeChipInactiveFg,
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    final inputsTheme = _themeForInputs;
    return Column(
      children: [
        if (_tab == 'email') ...[
          IdentifierField(
            channel: 'email',
            controller: _identifierCtrl,
            theme: inputsTheme,
          ),
        ] else ...[
          Row(
            children: [
              CountryCodePicker(
                selected: _countryCode,
                onChanged: (cc) => setState(() => _countryCode = cc),
                theme: inputsTheme,
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
          ),
        ],
        const SizedBox(height: 10),
        if (_tab == 'email' && _emailMode == 'password') ...[
          TextField(
            controller: _passwordCtrl,
            obscureText: true,
            style: TextStyle(fontSize: 14, color: _p.cardText),
            decoration: _inputDecoration(AuthKitL10n.instance.passwordHint),
          ),
        ] else ...[
          VerificationCodeInput(
            onCompleted: _onCodeCompleted,
            onChanged: (c) => _code = c.length == 6 ? c : '',
            onSendCode: _handleSendCode,
            theme: inputsTheme,
          ),
        ],
        const SizedBox(height: 10),
        // Submit button
        SizedBox(
          width: double.infinity,
          height: _theme.inputHeight,
          child: ElevatedButton(
            onPressed: _loading
                ? null
                : () {
                    if (!_agreementChecked) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('请先阅读并同意用户协议和隐私政策'),
                          backgroundColor: Colors.orange,
                        ),
                      );
                      return;
                    }
                    _handleSubmit();
                  },
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
                      strokeWidth: 2,
                      color: _p.submitFg,
                    ),
                  )
                : Text(
                    _tab == 'phone' ? '登录 / 注册' : '登录',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500),
                  ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            style: TextStyle(color: _p.errorColor, fontSize: 13),
          ),
        ],
      ],
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(fontSize: 14, color: _p.cardSub),
      filled: _p.inputBg.a > 0,
      fillColor: _p.inputBg,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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

  /// 游客模式入口：不访问后端、直接进主界面（数据落在独立的 guest 账号下）。
  /// 不要求勾选协议 —— 游客不创建账号；正式注册/登录时仍会校验。
  Widget _buildGuestEntry() {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: GestureDetector(
        onTap: _handleGuestLogin,
        child: Text(
          '游客模式，暂不登录 →',
          style: TextStyle(
            fontSize: 13,
            color: _p.linkColor,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Future<void> _handleGuestLogin() async {
    final attempt = _beginLoginAttempt();
    if (attempt == null) return;
    try {
      await LoginDao.loginAsGuest();
      if (!mounted || !_isCurrentAttempt(attempt)) return;
      widget.onLoginSuccess?.call();
      if (widget.onLoginSuccess == null) {
        NavigatorUtil.goToHome(context);
      }
    } catch (error) {
      if (_isCurrentAttempt(attempt)) {
        setState(() => _error = '$error');
      }
    } finally {
      _finishLoginAttempt(attempt);
    }
  }

  Widget _buildHelperLinks() {
    final linksEnabled = !_loading;
    final disabledColor = _p.cardSub.withValues(alpha: 0.45);

    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Semantics(
            button: true,
            enabled: linksEnabled,
            child: GestureDetector(
              onTap: linksEnabled
                  ? () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ForgotPasswordPage(),
                        ),
                      );
                    }
                  : null,
              child: Text(
                _emailMode == 'password' ? '忘记密码？' : '收不到验证码？',
                style: TextStyle(
                  fontSize: 12,
                  color: linksEnabled ? _p.cardSub : disabledColor,
                ),
              ),
            ),
          ),
          Semantics(
            button: true,
            enabled: linksEnabled,
            child: GestureDetector(
              onTap: linksEnabled
                  ? () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => RegisterPage(
                            authDependencies: widget.authDependencies,
                          ),
                        ),
                      );
                    }
                  : null,
              child: Text(
                '注册新账号',
                style: TextStyle(
                  fontSize: 12,
                  color: linksEnabled ? _p.linkColor : disabledColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneHint() {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        '未注册的手机号将自动创建账号',
        style: TextStyle(fontSize: 11, color: _p.cardSub),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildDivider() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 34, 0, 14),
      child: Row(
        children: [
          Expanded(child: Container(height: 1, color: _p.outsideDivider)),
          const SizedBox(width: 10),
          Text(
            '其他方式登录',
            style: TextStyle(fontSize: 11, color: _p.outsideFaint),
          ),
          const SizedBox(width: 10),
          Expanded(child: Container(height: 1, color: _p.outsideDivider)),
        ],
      ),
    );
  }

  Widget _buildPlatformMandatory() {
    final platform = _platform;
    String label;
    String hint;
    IconData icon;
    VoidCallback? onTap;

    switch (platform) {
      case 'ios':
        label = '通过 Apple 登录';
        hint = 'iOS 应用商店要求';
        icon = Icons.apple;
        onTap = _handleAppleLogin;
        break;
      case 'harmony':
        label = '华为账号一键登录';
        hint = '鸿蒙原生账号';
        icon = Icons.phone_android;
        onTap = _handleHuaweiLogin;
        break;
      default: // android
        label = '使用 Google 登录';
        hint = 'Android 推荐方式';
        icon = Icons.g_mobiledata;
        onTap = () => _showUnavailableToast('Google');
    }

    final mandatoryBorder = _p.mandatoryBorder;
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: _theme.inputHeight,
          child: ElevatedButton.icon(
            onPressed: onTap,
            icon: Icon(icon, size: 18),
            label: Text(
              label,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _p.mandatoryBg,
              foregroundColor: _p.mandatoryFg,
              elevation: mandatoryBorder == null ? null : 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(_theme.borderRadius),
                side: mandatoryBorder == null
                    ? BorderSide.none
                    : BorderSide(color: mandatoryBorder),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          hint,
          style: TextStyle(fontSize: 10, color: _p.outsideFaint),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildSocialDots() {
    final socials = _socialList();
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: socials.map((s) => _buildSocialDot(s)).toList(),
      ),
    );
  }

  Widget _buildSocialDot(_SocialItem item) {
    final border = _p.socialBorder;
    final iconColor = _bgMeta?.isDarkBg == true ? Colors.white : item.color;
    return GestureDetector(
      onTap: item.onTap,
      child: Column(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _p.socialBg,
              shape: BoxShape.circle,
              border: border == null ? null : Border.all(color: border),
            ),
            alignment: Alignment.center,
            child: Icon(item.icon, size: 18, color: iconColor),
          ),
          const SizedBox(height: 4),
          Text(
            item.label,
            style: TextStyle(fontSize: 10, color: _p.socialLabel),
          ),
        ],
      ),
    );
  }

  List<_SocialItem> _socialList() {
    final platform = _platform;
    switch (platform) {
      case 'ios':
        return [
          _SocialItem('华为', Icons.phone_android, const Color(0xFFCF0A2C),
              () => _showUnavailableToast('华为')),
          _SocialItem('微信', Icons.chat, const Color(0xFF07C160),
              () => _showUnavailableToast('微信')),
          _SocialItem('QQ', Icons.forum, const Color(0xFF12B7F5),
              () => _showUnavailableToast('QQ')),
          _SocialItem('微博', Icons.alternate_email, const Color(0xFFE6162D),
              () => _showUnavailableToast('微博')),
          _SocialItem('Google', Icons.g_mobiledata, const Color(0xFF4285F4),
              () => _showUnavailableToast('Google')),
        ];
      case 'harmony':
        return [
          _SocialItem('微信', Icons.chat, const Color(0xFF07C160),
              () => _showUnavailableToast('微信')),
          _SocialItem('QQ', Icons.forum, const Color(0xFF12B7F5),
              () => _showUnavailableToast('QQ')),
          _SocialItem('微博', Icons.alternate_email, const Color(0xFFE6162D),
              () => _showUnavailableToast('微博')),
          _SocialItem('Apple', Icons.apple, Colors.black, _handleAppleLogin),
          _SocialItem('Google', Icons.g_mobiledata, const Color(0xFF4285F4),
              () => _showUnavailableToast('Google')),
        ];
      default: // android
        return [
          _SocialItem('华为', Icons.phone_android, const Color(0xFFCF0A2C),
              () => _showUnavailableToast('华为')),
          _SocialItem('微信', Icons.chat, const Color(0xFF07C160),
              () => _showUnavailableToast('微信')),
          _SocialItem('QQ', Icons.forum, const Color(0xFF12B7F5),
              () => _showUnavailableToast('QQ')),
          _SocialItem('微博', Icons.alternate_email, const Color(0xFFE6162D),
              () => _showUnavailableToast('微博')),
          _SocialItem('Apple', Icons.apple, Colors.black, _handleAppleLogin),
        ];
    }
  }

  Widget _buildAgreement() {
    final checked = _agreementChecked;
    final boxBorder = checked ? _p.agreementBoxBorder : _p.cardBorderSoft;
    final boxFill = checked ? _p.agreementBoxBg : Colors.transparent;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: GestureDetector(
        onTap: () => setState(() => _agreementChecked = !_agreementChecked),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: boxBorder),
                color: boxFill,
              ),
              alignment: Alignment.center,
              child: checked
                  ? Icon(Icons.check, size: 10, color: _p.agreementCheck)
                  : null,
            ),
            const SizedBox(width: 6),
            Text.rich(
              TextSpan(
                style: TextStyle(
                    fontSize: 11, color: _p.agreementText, height: 1.5),
                children: [
                  const TextSpan(text: '已阅读并同意'),
                  TextSpan(
                    text: '《用户协议》',
                    style: TextStyle(
                        color: _p.agreementLink, fontWeight: FontWeight.w500),
                  ),
                  const TextSpan(text: '和'),
                  TextSpan(
                    text: '《隐私政策》',
                    style: TextStyle(
                        color: _p.agreementLink, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SocialItem {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _SocialItem(this.label, this.icon, this.color, this.onTap);
}
