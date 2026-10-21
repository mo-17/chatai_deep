import 'dart:async';
import 'package:login_sdk/platform/app_io.dart';

import 'package:chatgpt_app_core/config/app_distribution.dart';
import 'package:chatgpt_app_core/dao/apk_update_dao.dart';
import 'package:chatgpt_app_core/model/apk_model.dart';
import 'package:chatgpt_app_core/update/apk_update_policy.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:flutter/material.dart';
import 'package:hi_download/hi_download.dart';
import 'package:open_filex/open_filex.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

typedef ApkUpdateChecker = Future<ApkModel> Function();
typedef ApkDownloadHandler = Future<String> Function(
  ApkModel model,
  DownLoadListener listener,
);
typedef StoreUpdateOpener = Future<void> Function(String url);
typedef ApkInstallHandler = Future<void> Function(String path);

/// 一个首页会话共用一个更新流程，避免自动/手动检查重叠或重复安装。
class AppUpdateController extends ChangeNotifier {
  final ApkUpdateChecker? updateChecker;
  final ApkDownloadHandler? downloadHandler;
  final StoreUpdateOpener? storeOpener;
  final ApkInstallHandler? installHandler;
  final AppDistribution distribution;
  final String operatingSystem;
  final Future<PackageInfo> Function() packageInfoLoader;

  AppUpdateController({
    this.updateChecker,
    this.downloadHandler,
    this.storeOpener,
    this.installHandler,
    AppDistribution? distribution,
    String? operatingSystem,
    Future<PackageInfo> Function()? packageInfoLoader,
  })  : distribution = distribution ?? DistributionConfig.current,
        operatingSystem = operatingSystem ?? Platform.operatingSystem,
        packageInfoLoader = packageInfoLoader ?? PackageInfo.fromPlatform;

  bool _busy = false;
  bool _automaticChecked = false;
  bool _disposed = false;
  String _versionLabel = '版本信息加载中';
  Future<PackageInfo>? _packageInfo;
  DownloadCancellationToken? _downloadToken;

  bool get busy => _busy;
  String get versionLabel => _versionLabel;
  String get subtitle => _busy ? '正在检查或更新，请稍候…' : _versionLabel;

  Future<PackageInfo> _info() => _packageInfo ??= packageInfoLoader();

  Future<void> loadVersion() async {
    try {
      final info = await _info();
      _versionLabel = '当前版本 ${info.version}（${info.buildNumber}）';
    } catch (_) {
      _versionLabel = '版本信息暂不可用';
    }
    _changed();
  }

  /// 自动检查只在正式 Android 分发包运行一次；无更新/网络失败时保持安静。
  Future<void> check(BuildContext context, {bool manual = true}) async {
    if (_disposed || _busy || !context.mounted) return;
    if (operatingSystem != 'android') {
      if (manual) {
        _message(context,
            operatingSystem == 'ohos' ? '鸿蒙版本请前往华为应用市场更新' : '此平台请通过官网或应用商店更新');
      }
      return;
    }
    if (!manual) {
      if (_automaticChecked || distribution == AppDistribution.development) {
        return;
      }
      _automaticChecked = true;
    }
    _busy = true;
    _changed();
    try {
      final model = await (updateChecker?.call() ??
          ApkUpdateDao.checkUpdate(
            packageInfo: await _info(),
            distribution: distribution,
            platform: operatingSystem,
          ));
      if (_disposed || !context.mounted) return;
      // 用户在请求期间进入其它页面/弹窗时不抢占；仍可在“我的”手动检查。
      if (!manual && ModalRoute.of(context)?.isCurrent != true) return;
      const policy = ApkUpdatePolicy();
      final action = policy.decide(model, distribution);
      if (action == UpdateAction.none) {
        if (manual) _message(context, '当前已是最新版本');
        return;
      }
      await _present(context, model, action, policy);
    } catch (error) {
      AILogger.log('update check failed: ${error.runtimeType}');
      if (manual && context.mounted) _message(context, '检查更新失败，请稍后重试');
    } finally {
      _busy = false;
      _changed();
    }
  }

  Future<void> _present(BuildContext context, ApkModel model,
      UpdateAction action, ApkUpdatePolicy policy) async {
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: !model.forceUpdate,
      builder: (dialogContext) => PopScope(
        canPop: !model.forceUpdate,
        child: AlertDialog(
          title: const Text('有新版本啦'),
          content: SingleChildScrollView(
            child: Text([
              if (model.versionName?.isNotEmpty == true)
                '新版本 ${model.versionName}（${model.versionCode ?? ''}）',
              if (model.description?.isNotEmpty == true) model.description!,
              if (action == UpdateAction.downloadApk) '下载完成后由系统确认安装，已有数据将保留。',
            ].join('\n\n')),
          ),
          actions: [
            if (!model.forceUpdate)
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(action == UpdateAction.openStore ? '前往更新' : '立即更新'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || _disposed || !context.mounted) return;
    if (action == UpdateAction.openStore) {
      try {
        await (storeOpener ?? _openStore)(policy.urlFor(model, distribution));
      } catch (_) {
        if (context.mounted) _message(context, '无法打开应用市场，请稍后重试');
      }
      return;
    }

    final progress = ValueNotifier<double?>(null);
    final token = DownloadCancellationToken();
    _downloadToken = token;
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('正在下载更新'),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, value, __) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: value),
                const SizedBox(height: 12),
                Text(value == null
                    ? '正在下载并校验安装包…'
                    : '已下载 ${(value * 100).floor()}%'),
              ],
            ),
          ),
          actions: [
            if (downloadHandler == null)
              TextButton(onPressed: token.cancel, child: const Text('暂停下载')),
          ],
        ),
      ),
    );
    unawaited(navigator.push(route));
    String path;
    try {
      void onProgress(int total, int received, bool done) {
        progress.value = total > 0 ? (received / total).clamp(0.0, 1.0) : null;
      }

      path = await (downloadHandler != null
          ? downloadHandler!(model, onProgress)
          : _downloadApk(model, onProgress, token));
    } on DownloadCancelled {
      if (context.mounted) _message(context, '下载已暂停，下次更新将继续下载');
      return;
    } catch (error) {
      AILogger.log('update download failed: ${error.runtimeType}');
      if (context.mounted) _message(context, '更新下载或校验失败，请重试');
      return;
    } finally {
      // 只移除自己创建的进度路由，避免误关闭后来打开的页面。
      if (navigator.mounted && route.isActive) navigator.removeRoute(route);
      progress.dispose();
      _downloadToken = null;
    }
    if (_disposed || !context.mounted) return;
    try {
      await (installHandler ?? installAPK)(path);
    } catch (error) {
      AILogger.log('open APK installer failed: ${error.runtimeType}');
      if (context.mounted) {
        _message(context, '无法打开安装程序，请允许本应用安装更新后重试');
      }
    }
  }

  void _message(BuildContext context, String message) {
    if (!_disposed && context.mounted) HiDialog.showSnackBar(context, message);
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _downloadToken?.cancel();
    super.dispose();
  }
}

Future<String> _downloadApk(ApkModel model, DownLoadListener listener,
        DownloadCancellationToken token) =>
    HiDownLoad().download(
      downLoadUrl: model.downloadUrl,
      fileName: 'aipu-update.apk',
      listener: listener,
      expectedSha256: model.sha256,
      cancellationToken: token,
    );

Future<void> _openStore(String rawUrl) async {
  if (!await launchUrl(Uri.parse(rawUrl),
      mode: LaunchMode.externalApplication)) {
    throw StateError('store URL unavailable');
  }
}

Future<void> installAPK(String path) async {
  final result = await OpenFilex.open(path,
      type: 'application/vnd.android.package-archive');
  if (result.type != ResultType.done) {
    throw StateError('APK installer unavailable: ${result.type}');
  }
}
