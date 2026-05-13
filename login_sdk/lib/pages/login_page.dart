import 'dart:io';
import 'dart:ui' as ui;

import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/auth_dao.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/pages/forgot_password_page.dart';
import 'package:login_sdk/pages/register_page.dart';
import 'package:login_sdk/util/navigator_util.dart';
import 'package:login_sdk/widget/login_backgrounds/login_background.dart';

enum LoginPageStyle { tabs, bg }

class LoginPage extends StatefulWidget {
  final LoginPageStyle style;
  final LoginBgVariant bgVariant;
  final VoidCallback? onLoginSuccess;

  const LoginPage({
    super.key,
    this.style = LoginPageStyle.tabs,
    this.bgVariant = LoginBgVariant.mesh,
    this.onLoginSuccess,
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
  String? _error;
  bool _agreementChecked = false;
  late LoginPageStyle _activeStyle;
  late LoginBgVariant _activeBgVariant;

  @override
  void initState() {
    super.initState();
    _activeStyle = widget.style;
    _activeBgVariant = widget.bgVariant;
  }

  // ---- Services ----
  final _appleService = AppleSignInUnavailable();
  final _huaweiService = HuaweiLoginUnavailable();

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

  bool get _isDark => MediaQuery.of(context).platformBrightness == Brightness.dark;

  // Extended tokens not in AuthKitTheme
  Color get _faint => _theme.subtitleColor.withValues(alpha: 0.62);
  Color get _divider => _theme.borderColor.withValues(alpha: 0.6);
  Color get _invText => _isDark ? const Color(0xFF0C0D0E) : Colors.white;

  @override
  void dispose() {
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

  Future<void> _handlePasswordLogin() async {
    final identifier = _identifierCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (identifier.isEmpty || password.isEmpty) {
      setState(() => _error = '请输入邮箱地址和密码');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final result = await AuthDaoBridge.instance.loginByPassword(
        channel: 'email',
        identifier: identifier,
        password: password,
      );
      await _onLoginSuccess(result);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
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
    setState(() { _loading = true; _error = null; });
    try {
      await AuthDaoBridge.instance.sendCode(
        channel: channel,
        identifier: fullId,
        purpose: 'login',
      );
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
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
    if (_code.length < 4) {
      setState(() => _error = '请输入验证码');
      return;
    }
    final channel = _tab == 'email' ? 'email' : 'sms';
    final fullId = channel == 'sms' ? _fullPhoneIdentifier : identifier;
    setState(() { _loading = true; _error = null; });
    try {
      final result = await AuthDaoBridge.instance.loginByCode(
        channel: channel,
        identifier: fullId,
        code: _code,
      );
      await _onLoginSuccess(result);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _onLoginSuccess(LoginResult result) async {
    LoginDao.saveAuthToken(
      result.token,
      userName: result.extra['userName']?.toString(),
      avatar: result.extra['avatar']?.toString(),
      imoocId: result.extra['imoocId']?.toString(),
    );
    if (mounted) {
      widget.onLoginSuccess?.call();
      if (widget.onLoginSuccess == null) {
        NavigatorUtil.goToHome(context);
      }
    }
  }

  Future<void> _handleAppleLogin() async {
    try {
      final appleResult = await _appleService.signIn();
      final authResult = await AuthDaoBridge.instance.appleLogin(
        identityToken: appleResult.identityToken,
        authorizationCode: appleResult.authorizationCode,
        fullName: appleResult.fullName,
      );
      if (authResult.needBinding) {
        if (mounted) {
          _showBindPage(
            bindTicket: authResult.bindTicket!,
            provider: 'apple',
          );
        }
        return;
      }
      if (authResult.token != null) {
        LoginDao.saveAuthToken(authResult.token!,
            userName: authResult.extra?['userName']?.toString(),
            avatar: authResult.extra?['avatar']?.toString());
        if (mounted) {
          widget.onLoginSuccess?.call();
          if (widget.onLoginSuccess == null) {
            NavigatorUtil.goToHome(context);
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Apple 登录暂未接入'), backgroundColor: Colors.orange),
        );
      }
    }
  }

  Future<void> _handleHuaweiLogin() async {
    try {
      final hwResult = await _huaweiService.signInWithQuickLogin();
      final authResult = await AuthDaoBridge.instance.huaweiLogin(
        mode: hwResult.mode,
        authCode: hwResult.authCode,
        accessToken: hwResult.accessToken,
      );
      if (authResult.needBinding) {
        if (mounted) {
          _showBindPage(
            bindTicket: authResult.bindTicket!,
            provider: 'huawei',
          );
        }
        return;
      }
      if (authResult.token != null) {
        LoginDao.saveAuthToken(authResult.token!,
            userName: authResult.extra?['userName']?.toString(),
            avatar: authResult.extra?['avatar']?.toString());
        if (mounted) {
          widget.onLoginSuccess?.call();
          if (widget.onLoginSuccess == null) {
            NavigatorUtil.goToHome(context);
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('华为登录暂未接入'), backgroundColor: Colors.orange),
        );
      }
    }
  }

  void _showBindPage({
    required String bindTicket,
    required String provider,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BindIdentityPage(
          authDao: AuthDaoBridge.instance,
          bindTicket: bindTicket,
          provider: provider,
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
      return _buildBg();
    }
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
                    if (_activeStyle == LoginPageStyle.tabs) _buildAgreement(),
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
    final bgMeta = loginBackgroundFor(_activeBgVariant, _theme.primaryColor);
    final cardRadius =
        (_theme.borderRadius + 4).clamp(16, double.infinity).toDouble();

    // Card surface — paper has its own warm palette; dark backgrounds use a
    // translucent white frosted card; light backgrounds use a high-opacity
    // white card for legibility.
    final cardColor = bgMeta.isPaper
        ? const Color(0xFFFBF6EA)
        : bgMeta.isDarkBg
            ? Colors.white.withValues(alpha: 0.10)
            : (_isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.white.withValues(alpha: 0.65));
    final cardBorderColor = bgMeta.isPaper
        ? const Color(0xFFD9C89A)
        : bgMeta.isDarkBg
            ? Colors.white.withValues(alpha: 0.18)
            : Colors.white.withValues(alpha: 0.60);

    final card = Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(cardRadius),
        border: Border.all(color: cardBorderColor),
        boxShadow: [
          BoxShadow(
            blurRadius: 40,
            offset: const Offset(0, 10),
            color: bgMeta.isDarkBg
                ? const Color(0x40000000)
                : const Color(0x14000000),
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
                  // Glass card — skip backdrop blur for paper (looks wrong on
                  // a flat sepia surface).
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(cardRadius),
                      child: bgMeta.isPaper
                          ? card
                          : BackdropFilter(
                              filter: ui.ImageFilter.blur(
                                  sigmaX: 24, sigmaY: 24),
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
    // Short code per variant, matched to LoginBgVariant ordering.
    const labels = [
      'M', // mesh
      'A', // aurora
      'B', // blueprint
      'P', // botanical
      'S', // sunset
      'C', // citylight
      'Pa', // paper
      'R', // retrowave
      'L', // liquid
      'Ri', // ribbon
      'To', // topo
      'Do', // dotmap
      'W', // wave
      'O', // origami
      'Bd', // band
      'Du', // duotone
      'Mb', // marble
      'Ph', // photo
      'Ap', // aperture
      'Mx', // matrix
    ];
    return labels[_activeBgVariant.index];
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
              BoxShadow(blurRadius: 8, color: Color(0x40000000), offset: Offset(0, 2)),
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
    return Column(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_theme.primaryColor, _theme.subtitleColor],
            ),
          ),
          alignment: Alignment.center,
          child: const Text(
            '艾',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 22),
        Text(
          '艾普 · Demo',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: _theme.textColor,
          ),
        ),
        const SizedBox(height: 18),
      ],
    );
  }

  Widget _buildTabHeader() {
    return Column(
      children: [
        SizedBox(
          height: 36,
          child: Row(
            children: [
              _buildTabItem('email', '邮箱'),
              const SizedBox(width: 22),
              _buildTabItem('phone', '手机号'),
            ],
          ),
        ),
        Container(
          height: 1,
          color: _divider,
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
              color: active ? _theme.primaryColor : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? _theme.textColor : _theme.subtitleColor,
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
          color: _theme.surfaceColor,
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
      onTap: () => setState(() { _emailMode = key; _code = ''; }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: active ? _theme.backgroundColor : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          boxShadow: active
              ? [const BoxShadow(blurRadius: 2, color: Color(0x0F000000), offset: Offset(0, 1))]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: active ? _theme.textColor : _theme.subtitleColor,
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Column(
      children: [
        if (_tab == 'email') ...[
          IdentifierField(
            channel: 'email',
            controller: _identifierCtrl,
            theme: _theme,
          ),
        ] else ...[
          Row(
            children: [
              CountryCodePicker(
                selected: _countryCode,
                onChanged: (cc) => setState(() => _countryCode = cc),
                theme: _theme,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _identifierCtrl,
                  keyboardType: TextInputType.phone,
                  style: TextStyle(fontSize: 14, color: _theme.textColor),
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
            style: TextStyle(fontSize: 14, color: _theme.textColor),
            decoration: _inputDecoration(AuthKitL10n.instance.passwordHint),
          ),
        ] else ...[
          VerificationCodeInput(
            onCompleted: _onCodeCompleted,
            onSendCode: _handleSendCode,
            theme: _theme,
          ),
        ],
        const SizedBox(height: 10),
        // Submit button
        SizedBox(
          width: double.infinity,
          height: _theme.inputHeight,
          child: ElevatedButton(
            onPressed: _loading ? null : () {
              if (_activeStyle == LoginPageStyle.tabs &&
                  !_agreementChecked) {
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
              backgroundColor: _theme.primaryColor,
              foregroundColor: _invText,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(_theme.borderRadius),
              ),
            ),
            child: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    _tab == 'phone' ? '登录 / 注册' : '登录',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            style: TextStyle(color: _theme.errorColor, fontSize: 13),
          ),
        ],
      ],
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(fontSize: 14, color: _theme.subtitleColor),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
    );
  }

  Widget _buildHelperLinks() {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ForgotPasswordPage()),
              );
            },
            child: Text(
              _emailMode == 'password' ? '忘记密码？' : '收不到验证码？',
              style: TextStyle(fontSize: 12, color: _theme.subtitleColor),
            ),
          ),
          GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const RegisterPage()),
              );
            },
            child: Text(
              '注册新账号',
              style: TextStyle(fontSize: 12, color: _theme.primaryColor),
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
        style: TextStyle(fontSize: 11, color: _theme.subtitleColor),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildDivider() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 34, 0, 14),
      child: Row(
        children: [
          Expanded(child: Container(height: 1, color: _divider)),
          const SizedBox(width: 10),
          Text(
            '其他方式登录',
            style: TextStyle(fontSize: 11, color: _faint),
          ),
          const SizedBox(width: 10),
          Expanded(child: Container(height: 1, color: _divider)),
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
              backgroundColor: _theme.textColor,
              foregroundColor: _theme.backgroundColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(_theme.borderRadius),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          hint,
          style: TextStyle(fontSize: 10, color: _faint),
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
    return GestureDetector(
      onTap: item.onTap,
      child: Column(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _theme.surfaceColor,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(item.icon, size: 18, color: item.color),
          ),
          const SizedBox(height: 4),
          Text(
            item.label,
            style: TextStyle(fontSize: 10, color: _theme.subtitleColor),
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
          _SocialItem('华为', Icons.phone_android, const Color(0xFFCF0A2C), () => _showUnavailableToast('华为')),
          _SocialItem('微信', Icons.chat, const Color(0xFF07C160), () => _showUnavailableToast('微信')),
          _SocialItem('QQ', Icons.forum, const Color(0xFF12B7F5), () => _showUnavailableToast('QQ')),
          _SocialItem('微博', Icons.alternate_email, const Color(0xFFE6162D), () => _showUnavailableToast('微博')),
          _SocialItem('Google', Icons.g_mobiledata, const Color(0xFF4285F4), () => _showUnavailableToast('Google')),
        ];
      case 'harmony':
        return [
          _SocialItem('微信', Icons.chat, const Color(0xFF07C160), () => _showUnavailableToast('微信')),
          _SocialItem('QQ', Icons.forum, const Color(0xFF12B7F5), () => _showUnavailableToast('QQ')),
          _SocialItem('微博', Icons.alternate_email, const Color(0xFFE6162D), () => _showUnavailableToast('微博')),
          _SocialItem('Apple', Icons.apple, Colors.black, _handleAppleLogin),
          _SocialItem('Google', Icons.g_mobiledata, const Color(0xFF4285F4), () => _showUnavailableToast('Google')),
        ];
      default: // android
        return [
          _SocialItem('华为', Icons.phone_android, const Color(0xFFCF0A2C), () => _showUnavailableToast('华为')),
          _SocialItem('微信', Icons.chat, const Color(0xFF07C160), () => _showUnavailableToast('微信')),
          _SocialItem('QQ', Icons.forum, const Color(0xFF12B7F5), () => _showUnavailableToast('QQ')),
          _SocialItem('微博', Icons.alternate_email, const Color(0xFFE6162D), () => _showUnavailableToast('微博')),
          _SocialItem('Apple', Icons.apple, Colors.black, _handleAppleLogin),
        ];
    }
  }

  Widget _buildAgreement() {
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
                border: Border.all(
                  color: _agreementChecked ? _theme.primaryColor : _theme.borderColor,
                ),
                color: _agreementChecked ? _theme.primaryColor : Colors.transparent,
              ),
              alignment: Alignment.center,
              child: _agreementChecked
                  ? const Icon(Icons.check, size: 10, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 6),
            Text.rich(
              TextSpan(
                style: TextStyle(fontSize: 11, color: _theme.subtitleColor, height: 1.5),
                children: [
                  const TextSpan(text: '已阅读并同意'),
                  TextSpan(
                    text: '《用户协议》',
                    style: TextStyle(color: _theme.primaryColor),
                  ),
                  const TextSpan(text: '和'),
                  TextSpan(
                    text: '《隐私政策》',
                    style: TextStyle(color: _theme.primaryColor),
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
