import 'dart:async';

import 'package:chatgpt_app_core/config/app_distribution.dart';
import 'package:chatgpt_app_core/model/apk_model.dart';
import 'package:chatgpt_app_core/update/app_update_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hi_download/hi_download.dart';
import 'package:package_info_plus/package_info_plus.dart';

ApkModel _release({bool force = false}) => ApkModel(
      versionName: '1.0.5',
      versionCode: '15',
      downloadUrl: 'https://example.com/aipu-15.apk',
      description: '自动检测与应用内更新',
      forceUpdate: force,
    );

Widget _host(AppUpdateController controller) => MaterialApp(
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                    key: const Key('check'),
                    onPressed: () => unawaited(controller.check(context)),
                    child: const Text('检查'),
                  ))),
    );

BuildContext _context(WidgetTester tester) =>
    tester.element(find.byKey(const Key('check')));

void main() {
  AppUpdateController create({
    required ApkUpdateChecker checker,
    ApkDownloadHandler? download,
    ApkInstallHandler? install,
    AppDistribution distribution = AppDistribution.direct,
  }) {
    final controller = AppUpdateController(
      operatingSystem: 'android',
      distribution: distribution,
      updateChecker: checker,
      downloadHandler: download,
      installHandler: install,
      packageInfoLoader: () async => PackageInfo(
        appName: '艾普',
        packageName: 'com.example.chatgpt_flutter',
        version: '1.0.5',
        buildNumber: '15',
      ),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test('版本文字来自安装包信息', () async {
    final controller = create(checker: () async => _release());
    await controller.loadVersion();
    expect(controller.versionLabel, '当前版本 1.0.5（15）');
  });

  testWidgets('自动无更新只检查一次且安静，手动检查仍可重试', (tester) async {
    var calls = 0;
    final controller = create(checker: () async {
      calls++;
      return ApkModel(updateAvailable: false);
    });
    await tester.pumpWidget(_host(controller));
    await controller.check(_context(tester), manual: false);
    await controller.check(_context(tester), manual: false);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.text('检查'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('当前已是最新版本'), findsOneWidget);
  });

  testWidgets('开发包不自动请求，手动检查仍可使用', (tester) async {
    var calls = 0;
    final controller = create(
      distribution: AppDistribution.development,
      checker: () async {
        calls++;
        return ApkModel(updateAvailable: false);
      },
    );
    await tester.pumpWidget(_host(controller));
    await controller.check(_context(tester), manual: false);
    expect(calls, 0);
    await controller.check(_context(tester));
    expect(calls, 1);
  });

  testWidgets('自动网络失败不打断用户，手动失败提示并解除忙碌', (tester) async {
    final controller = create(checker: () async => throw StateError('offline'));
    await tester.pumpWidget(_host(controller));
    await controller.check(_context(tester), manual: false);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    await controller.check(_context(tester));
    await tester.pumpAndSettle();
    expect(find.text('检查更新失败，请稍后重试'), findsOneWidget);
    expect(controller.busy, isFalse);
  });

  testWidgets('自动与手动检查共享锁，取消前不会重复弹窗', (tester) async {
    final pending = Completer<ApkModel>();
    var calls = 0;
    var downloads = 0;
    final controller = create(
      checker: () {
        calls++;
        return pending.future;
      },
      download: (_, __) async {
        downloads++;
        return '/unused.apk';
      },
    );
    await tester.pumpWidget(_host(controller));
    final check = controller.check(_context(tester), manual: false);
    await controller.check(_context(tester));
    expect(calls, 1);
    pending.complete(_release());
    await tester.pumpAndSettle();
    expect(find.textContaining('新版本 1.0.5（15）'), findsOneWidget);
    await controller.check(_context(tester));
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await check;
    expect(downloads, 0);
    expect(controller.busy, isFalse);
  });

  testWidgets('确认后显示进度，下载完成才打开安装程序', (tester) async {
    final pending = Completer<String>();
    DownLoadListener? listener;
    String? installed;
    final controller = create(
      checker: () async => _release(),
      download: (_, progress) {
        listener = progress;
        return pending.future;
      },
      install: (path) async {
        installed = path;
      },
    );
    await tester.pumpWidget(_host(controller));
    await tester.tap(find.text('检查'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即更新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    listener!(100, 50, false);
    await tester.pump();
    expect(find.text('已下载 50%'), findsOneWidget);
    expect(installed, isNull);
    pending.complete('/verified/aipu.apk');
    await tester.pumpAndSettle();
    expect(installed, '/verified/aipu.apk');
    expect(find.text('正在下载更新'), findsNothing);
    expect(controller.busy, isFalse);
  });

  testWidgets('校验失败清理进度路由，禁止安装并允许重试', (tester) async {
    var installed = false;
    final controller = create(
      checker: () async => _release(),
      download: (_, __) async => throw const DownloadException('hash mismatch'),
      install: (_) async {
        installed = true;
      },
    );
    await tester.pumpWidget(_host(controller));
    await tester.tap(find.text('检查'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即更新'));
    await tester.pumpAndSettle();
    expect(find.text('更新下载或校验失败，请重试'), findsOneWidget);
    expect(find.text('正在下载更新'), findsNothing);
    expect(installed, isFalse);
    expect(controller.busy, isFalse);
    expect(find.byKey(const Key('check')), findsOneWidget);
  });

  testWidgets('安装入口失败有提示，不能把打开失败当安装成功', (tester) async {
    final controller = create(
      checker: () async => _release(),
      download: (_, __) async => '/verified/aipu.apk',
      install: (_) async => throw StateError('permission denied'),
    );
    await tester.pumpWidget(_host(controller));
    await tester.tap(find.text('检查'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即更新'));
    await tester.pumpAndSettle();
    expect(find.text('无法打开安装程序，请允许本应用安装更新后重试'), findsOneWidget);
    expect(controller.busy, isFalse);
  });

  testWidgets('强制更新阻止系统返回关闭弹窗', (tester) async {
    final controller = create(checker: () async => _release(force: true));
    await tester.pumpWidget(_host(controller));
    await tester.tap(find.text('检查'));
    await tester.pumpAndSettle();
    expect(find.text('取消'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('立即更新'), findsOneWidget);
    Navigator.of(_context(tester)).pop(false);
    await tester.pumpAndSettle();
  });

  testWidgets('页面销毁后检查结果不再弹窗', (tester) async {
    final pending = Completer<ApkModel>();
    final controller = create(checker: () => pending.future);
    await tester.pumpWidget(_host(controller));
    final check = controller.check(_context(tester));
    await tester.pumpWidget(const SizedBox());
    pending.complete(_release());
    await check;
    expect(tester.takeException(), isNull);
  });
}
