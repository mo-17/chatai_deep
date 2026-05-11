import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/auth_dao.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/pages/forgot_password_page.dart';
import 'package:login_sdk/pages/register_page.dart';
import 'package:login_sdk/util/navigator_util.dart';
import 'package:login_sdk/util/padding_extension.dart';
import 'package:login_sdk/widget/input_widget.dart';
import 'package:login_sdk/widget/login_widget.dart';

import '../util/string_util.dart';

/// Tab 化登录页：账号 / 邮箱 / 手机号
class LoginPage extends StatefulWidget {
  const LoginPage({Key? key}) : super(key: key);

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _accountUserCtrl = TextEditingController();
  final _accountPwdCtrl = TextEditingController();
  bool _accountEnable = false;

  static const _tabs = ['账号', '邮箱', '手机号'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _accountUserCtrl.dispose();
    _accountPwdCtrl.dispose();
    super.dispose();
  }

  void _checkAccountInput() {
    final enable = isNotEmpty(_accountUserCtrl.text) && isNotEmpty(_accountPwdCtrl.text);
    if (enable != _accountEnable) setState(() => _accountEnable = enable);
  }

  Future<void> _accountLogin() async {
    try {
      await LoginDao.login(userName: _accountUserCtrl.text, password: _accountPwdCtrl.text);
      if (mounted) NavigatorUtil.goToHome(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('登录失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _onCodeLoginSuccess(LoginResult r) {
    LoginDao.saveAuthToken(r.token);
    if (mounted) NavigatorUtil.goToHome(context);
  }

  Widget _buildBackground() {
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: Image.network('https://o.devio.org/images/bg_cover/robot.webp', fit: BoxFit.cover),
          ),
          Positioned.fill(
            child: Container(decoration: const BoxDecoration(color: Colors.black54)),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountTab() {
    return ListView(
      children: [
        100.paddingHeight,
        const Text('ChatGPT', style: TextStyle(fontSize: 26, color: Colors.white)),
        const Padding(padding: EdgeInsets.only(top: 40)),
        InputWidget(
          hint: '请输入账号',
          onChanged: (text) {
            _accountUserCtrl.text = text;
            _checkAccountInput();
          },
        ),
        40.paddingHeight,
        InputWidget(
          hint: '请输入密码',
          obscureText: true,
          onChanged: (text) {
            _accountPwdCtrl.text = text;
            _checkAccountInput();
          },
        ),
        45.paddingHeight,
        LoginButton('登录', enable: _accountEnable, onPressed: _accountLogin),
      ],
    );
  }

  Widget _buildCodeTab(String channel) {
    return CodeLoginPage(
      authDao: AuthDaoBridge.instance,
      channel: channel,
      purpose: 'login',
      theme: AuthKitTheme.dark(),
      onSuccess: _onCodeLoginSuccess,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          _buildBackground(),
          Positioned.fill(
            left: 25,
            right: 25,
            child: Column(
              children: [
                const SizedBox(height: 60),
                TabBar(
                  controller: _tabController,
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white54,
                  indicatorColor: Colors.white,
                  tabs: _tabs.map((t) => Tab(text: t)).toList(),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildAccountTab(),
                      _buildCodeTab('email'),
                      _buildCodeTab('sms'),
                    ],
                  ),
                ),
                // 底部操作栏
                Padding(
                  padding: const EdgeInsets.only(bottom: 30),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      InkWell(
                        onTap: _jumpForgotPassword,
                        child: const Text('忘记密码？', style: TextStyle(color: Colors.white70)),
                      ),
                      InkWell(
                        onTap: _jumpRegistration,
                        child: const Text('注册账号', style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _jumpRegistration() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterPage()));
  }

  void _jumpForgotPassword() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const ForgotPasswordPage()));
  }
}
