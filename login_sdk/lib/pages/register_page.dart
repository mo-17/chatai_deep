import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/auth_dao.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/util/navigator_util.dart';
import 'package:login_sdk/util/padding_extension.dart';

/// 注册页：邮箱 / 手机号 + 验证码 + 可选密码
class RegisterPage extends StatefulWidget {
  const RegisterPage({Key? key}) : super(key: key);

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  String _channel = 'email';

  void _onSuccess(LoginResult r) {
    LoginDao.saveAuthToken(r.token);
    if (mounted) NavigatorUtil.goToHome(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.network('https://o.devio.org/images/bg_cover/robot.webp', fit: BoxFit.cover),
          ),
          Positioned.fill(
            child: Container(decoration: const BoxDecoration(color: Colors.black54)),
          ),
          Positioned.fill(
            left: 25,
            right: 25,
            child: ListView(
              children: [
                100.paddingHeight,
                const Text('注册账号', style: TextStyle(fontSize: 26, color: Colors.white)),
                const Padding(padding: EdgeInsets.only(top: 40)),
                // 通道选择
                Row(
                  children: [
                    _ChannelChip(label: '邮箱', selected: _channel == 'email',
                        onTap: () => setState(() => _channel = 'email')),
                    const SizedBox(width: 12),
                    _ChannelChip(label: '手机号', selected: _channel == 'sms',
                        onTap: () => setState(() => _channel = 'sms')),
                  ],
                ),
                const SizedBox(height: 16),
                CodeLoginPage(
                  authDao: AuthDaoBridge.instance,
                  channel: _channel,
                  purpose: 'register',
                  theme: AuthKitTheme.dark(),
                  onSuccess: _onSuccess,
                ),
                15.paddingHeight,
                Align(
                  alignment: Alignment.centerRight,
                  child: InkWell(
                    onTap: () => Navigator.pop(context),
                    child: const Text('返回登录', style: TextStyle(color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),
        ],
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.white24 : Colors.white12,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? Colors.white : Colors.white30),
        ),
        child: Text(label, style: TextStyle(color: selected ? Colors.white : Colors.white60, fontSize: 13)),
      ),
    );
  }
}
