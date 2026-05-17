import 'package:flutter/material.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/pages/forgot_password_page.dart';
import 'package:login_sdk/pages/login_page.dart';
import 'package:login_sdk/pages/register_page.dart';
import 'package:login_sdk/util/navigator_util.dart';
import 'package:login_sdk/widget/login_backgrounds/login_background.dart';

class LauncherPage extends StatefulWidget {
  const LauncherPage({super.key});

  @override
  State<LauncherPage> createState() => _LauncherPageState();
}

class _LauncherPageState extends State<LauncherPage> {
  LoginBgVariant _bg = LoginBgVariant.mesh;

  @override
  Widget build(BuildContext context) {
    NavigatorUtil.updateContext(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('login_sdk · example'),
        actions: [
          if (LoginDao.getBoardingPass() != null)
            IconButton(
              tooltip: 'Logout',
              icon: const Icon(Icons.logout),
              onPressed: () async {
                await LoginDao.logOut();
                if (context.mounted) setState(() {});
              },
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _statusBanner(),
              const SizedBox(height: 12),
              const Text(
                'Pick a background, then open any of the 6 page × style combos.',
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 12),
              _bgPicker(),
              const SizedBox(height: 20),
              const Text('Pages', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Expanded(child: _entryGrid()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusBanner() {
    final token = LoginDao.getBoardingPass();
    final loggedIn = token != null;
    final color = loggedIn ? Colors.green.shade50 : Colors.orange.shade50;
    final border = loggedIn ? Colors.green.shade300 : Colors.orange.shade300;
    final icon = loggedIn ? Icons.check_circle : Icons.info_outline;
    final iconColor = loggedIn ? Colors.green.shade700 : Colors.orange.shade700;
    final profile = LoginDao.getUserInfo();
    final user = profile?['userName']?.toString() ?? '';
    final text = loggedIn
        ? 'Logged in as "$user". Token: ${token.substring(0, token.length.clamp(0, 32))}…'
        : 'Not logged in. Try any of the entries below — the mock backend will accept any credentials.';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _bgPicker() {
    return DropdownButtonFormField<LoginBgVariant>(
      initialValue: _bg,
      decoration: const InputDecoration(
        labelText: 'Background variant (bg style only)',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: LoginBgVariant.values
          .map((v) => DropdownMenuItem(value: v, child: Text(v.name)))
          .toList(),
      onChanged: (v) => v == null ? null : setState(() => _bg = v),
    );
  }

  Widget _entryGrid() {
    final entries = <_Entry>[
      _Entry('Login · tabs', () => LoginPage(style: LoginPageStyle.tabs, bgVariant: _bg)),
      _Entry('Login · bg', () => LoginPage(style: LoginPageStyle.bg, bgVariant: _bg)),
      _Entry('Register · tabs', () => RegisterPage(style: RegisterPageStyle.tabs, bgVariant: _bg)),
      _Entry('Register · bg', () => RegisterPage(style: RegisterPageStyle.bg, bgVariant: _bg)),
      _Entry('Forgot · tabs', () => ForgotPasswordPage(style: ForgotPageStyle.tabs, bgVariant: _bg)),
      _Entry('Forgot · bg', () => ForgotPasswordPage(style: ForgotPageStyle.bg, bgVariant: _bg)),
    ];
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 2.2,
      ),
      itemCount: entries.length,
      itemBuilder: (_, i) => _tile(entries[i]),
    );
  }

  Widget _tile(_Entry e) {
    return ElevatedButton(
      onPressed: () async {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => e.build()));
        // 登录成功后 LoginPage 会调 goToHome → 跳回这里；触发 setState 让横幅更新
        if (mounted) setState(() {});
      },
      style: ElevatedButton.styleFrom(
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Text(e.label, style: const TextStyle(fontSize: 15)),
    );
  }
}

class _Entry {
  final String label;
  final Widget Function() build;
  _Entry(this.label, this.build);
}
