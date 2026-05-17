import 'package:flutter/material.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/login_sdk.dart';

import 'launcher_page.dart';
import 'mock_backend.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 启动进程内 mock backend（端口 0 = 让系统分配空闲端口，避开 chatgpt_backend 占的 3000）
  final mock = MockBackend();
  final port = await mock.start(port: 0);
  // ignore: avoid_print
  print('[example] mock backend listening on 127.0.0.1:$port');

  // 强制 BackendConfig 指向 mock；这必须发生在 AuthDaoBridge 首次访问之前
  BackendConfig.host = '127.0.0.1:$port';
  BackendConfig.useHttps = false;

  // 也可以演示注入 LoginSdkConfig；这里用默认 imooc 配置即可。
  await LoginConfig.instance().init(homePage: const LauncherPage());

  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'login_sdk example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F3460)),
        useMaterial3: true,
      ),
      home: const LauncherPage(),
    );
  }
}
