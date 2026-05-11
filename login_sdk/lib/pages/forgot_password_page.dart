import 'package:auth_kit_flutter/auth_kit_flutter.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/auth_dao.dart';
import 'package:login_sdk/util/padding_extension.dart';

/// 忘记密码页：选择邮箱/手机号 → 发送验证码 → 输入验证码 + 新密码 → 重置
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({Key? key}) : super(key: key);

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  String _channel = 'email';

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
                const Text('忘记密码', style: TextStyle(fontSize: 26, color: Colors.white)),
                const Padding(padding: EdgeInsets.only(top: 40)),
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
                ResetPasswordPage(
                  authDao: AuthDaoBridge.instance,
                  initialChannel: _channel,
                  theme: AuthKitTheme.dark(),
                  onSuccess: () {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('密码已重置，请用新密码登录'), backgroundColor: Colors.green),
                      );
                      Navigator.pop(context);
                    }
                  },
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
