import 'dart:async';

import 'package:flutter/material.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/util/padding_extension.dart';
import 'package:login_sdk/widget/input_widget.dart';
import 'package:login_sdk/widget/login_widget.dart';

import '../util/string_util.dart';

///忘记密码页：两步流程
///Step 1 — 输入账号 → 获取 reset code
///Step 2 — 输入 code + 新密码 → 确认重置
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({Key? key}) : super(key: key);

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  bool _step2 = false;
  String? _userName;
  String? _code;
  String? _newPassword;
  bool _loading = false;
  int _countdown = 0;
  Timer? _timer;

  bool get _step1Enable =>
      isNotEmpty(_userName) &&
      _userName!.length >= 3 &&
      _userName!.length <= 64;

  bool get _step2Enable =>
      isNotEmpty(_code) &&
      _code!.length == 6 &&
      isNotEmpty(_newPassword) &&
      _newPassword!.length <= 64;

  get _background {
    return [
      Positioned.fill(
          child: Image.network(
              'https://o.devio.org/images/bg_cover/robot.webp',
              fit: BoxFit.cover)),
      Positioned.fill(
          child: Container(
        decoration: const BoxDecoration(color: Colors.black54),
      ))
    ];
  }

  get _content {
    return Positioned.fill(
        left: 25,
        right: 25,
        child: ListView(
          children: [
            100.paddingHeight,
            const Text(
              '忘记密码',
              style: TextStyle(fontSize: 26, color: Colors.white),
            ),
            const Padding(padding: EdgeInsets.only(top: 40)),
            if (!_step2) ..._buildStep1() else ..._buildStep2(),
            15.paddingHeight,
            Align(
              alignment: Alignment.centerRight,
              child: InkWell(
                onTap: () => Navigator.pop(context),
                child: const Text(
                  '返回登录',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ],
        ));
  }

  List<Widget> _buildStep1() {
    return [
      InputWidget(
        hint: '请输入账号',
        onChanged: (text) {
          _userName = text;
          setState(() {});
        },
      ),
      40.paddingHeight,
      LoginButton(
        _countdown > 0 ? '已发送 ($_countdown s)' : '获取 Reset Code',
        enable: _step1Enable && !_loading && _countdown == 0,
        onPressed: _requestCode,
      ),
      if (_countdown > 0) ...[
        10.paddingHeight,
        const Text(
          'code 已显示在下方，5 分钟内有效',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    ];
  }

  List<Widget> _buildStep2() {
    return [
      InputWidget(
        hint: '请输入 6 位 Reset Code',
        keyboardType: TextInputType.number,
        onChanged: (text) {
          _code = text;
          setState(() {});
        },
      ),
      40.paddingHeight,
      InputWidget(
        hint: '请输入新密码',
        obscureText: true,
        onChanged: (text) {
          _newPassword = text;
          setState(() {});
        },
      ),
      45.paddingHeight,
      LoginButton(
        '确认重置',
        enable: _step2Enable && !_loading,
        onPressed: _loading ? null : () => _confirmReset(context),
      ),
    ];
  }

  Future<void> _requestCode() async {
    setState(() => _loading = true);
    try {
      final resp =
          await LoginDao.requestPasswordReset(_userName!);
      final data = resp['data'] as Map<String, dynamic>?;
      final code = data?['code'] as String? ?? '';
      _startCountdown();
      setState(() {
        _step2 = true;
        _code = code;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Reset Code: $code（5 分钟内有效）'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('请求失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _confirmReset(BuildContext context) async {
    setState(() => _loading = true);
    try {
      await LoginDao.confirmPasswordReset(
        _userName!,
        _code!,
        _newPassword!,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('密码已重置，请用新密码登录'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('重置失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startCountdown() {
    _countdown = 300;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_countdown > 0) {
        setState(() => _countdown--);
      } else {
        t.cancel();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [..._background, _content],
      ),
    );
  }
}
