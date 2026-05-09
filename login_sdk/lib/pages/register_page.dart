import 'package:flutter/material.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/util/navigator_util.dart';
import 'package:login_sdk/util/padding_extension.dart';
import 'package:login_sdk/widget/input_widget.dart';
import 'package:login_sdk/widget/login_widget.dart';

import '../util/string_util.dart';

///注册页（Flutter Native，不再跳浏览器）
class RegisterPage extends StatefulWidget {
  const RegisterPage({Key? key}) : super(key: key);

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  bool _registerEnable = false;
  String? _userName;
  String? _password;
  String? _confirmPassword;
  bool _loading = false;

  bool get _passwordMatch =>
      isNotEmpty(_password) && _password == _confirmPassword;

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
              '注册账号',
              style: TextStyle(fontSize: 26, color: Colors.white),
            ),
            const Padding(padding: EdgeInsets.only(top: 40)),
            InputWidget(
              hint: '请输入账号（3-64 位）',
              onChanged: (text) {
                _userName = text;
                _checkInput();
              },
            ),
            40.paddingHeight,
            InputWidget(
              hint: '请输入密码',
              obscureText: true,
              onChanged: (text) {
                _password = text;
                _checkInput();
              },
            ),
            40.paddingHeight,
            InputWidget(
              hint: '请确认密码',
              obscureText: true,
              onChanged: (text) {
                _confirmPassword = text;
                _checkInput();
              },
            ),
            45.paddingHeight,
            LoginButton(
              '注册',
              enable: _registerEnable && !_loading,
              onPressed: _loading ? null : () => _register(context),
            ),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [..._background, _content],
      ),
    );
  }

  void _checkInput() {
    bool enable = false;
    if (isNotEmpty(_userName) &&
        isNotEmpty(_password) &&
        isNotEmpty(_confirmPassword)) {
      if (_userName!.length >= 3 &&
          _userName!.length <= 64 &&
          _password!.length <= 64 &&
          _passwordMatch) {
        enable = true;
      }
    }
    if (enable != _registerEnable) {
      setState(() {
        _registerEnable = enable;
      });
    }
  }

  void _register(BuildContext context) async {
    setState(() => _loading = true);
    try {
      await LoginDao.register(
          userName: _userName!, password: _password!);
      if (context.mounted) {
        NavigatorUtil.goToHome(context);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('注册失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}
