import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/dao/apk_update_dao.dart';
import 'package:chatgpt_app_core/model/apk_model.dart';
import 'package:chatgpt_app_core/pages/ai_settings_page.dart';
import 'package:chatgpt_app_core/pages/appearance_settings_page.dart';
import 'package:chatgpt_app_core/pages/assistant_list_page.dart';
import 'package:chatgpt_app_core/pages/backup_restore_page.dart';
import 'package:chatgpt_app_core/pages/capability_center_page.dart';
import 'package:chatgpt_app_core/pages/cloud_sync_page.dart';
import 'package:chatgpt_app_core/pages/generated_image_album_page.dart';
import 'package:chatgpt_app_core/pages/knowledge_base_page.dart';
import 'package:chatgpt_app_core/pages/mcp_settings_page.dart';
import 'package:chatgpt_app_core/pages/tool_audit_page.dart';
import 'package:chatgpt_app_core/pages/tts_model_manager_page.dart';
import 'package:chatgpt_app_core/pages/usage_stats_page.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/util/hi_progress_dialog.dart';
import 'package:chatgpt_app_core/widget/header_widget.dart';
import 'package:flutter/material.dart';
import 'package:hi_download/hi_download.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/util/padding_extension.dart';
import 'package:open_filex/open_filex.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:provider/provider.dart';

///我的页面
class MyPage extends StatefulWidget {
  const MyPage({super.key});

  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  String? avatar;
  String? userName;
  String? imoocId;
  static const titleStyle =
      TextStyle(fontSize: 18, fontWeight: FontWeight.w600);

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final color = themeProvider.isAnime
        ? Theme.of(context).colorScheme.primary
        : themeProvider.themeColor;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            HeaderWidget(
              avatar: avatar,
              name: userName,
              imoocId: imoocId,
            ),
            20.paddingHeight,
            const Divider(),
            // 游客模式：醒目的登录入口（走标准登出流程清掉游客态并跳登录页）。
            if (LoginDao.isGuest())
              ..._itemWidget(
                  color: color,
                  title: '登录 / 注册',
                  icon: Icons.login,
                  onTap: () => LoginDao.logOut()),
            ..._itemWidget(
                color: color,
                title: '外观与主题',
                icon: Icons.palette_outlined,
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const AppearanceSettingsPage()))),
            ..._itemWidget(
                color: color,
                title: 'AI 服务设置',
                icon: Icons.smart_toy,
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const AISettingsPage()))),
            ..._itemWidget(
                color: color,
                title: 'MCP 服务',
                icon: Icons.extension_outlined,
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const McpSettingsPage()))),
            ..._itemWidget(
                color: color,
                title: '助手管理',
                icon: Icons.support_agent,
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const AssistantListPage()))),
            ..._itemWidget(
                color: color,
                title: '知识库',
                icon: Icons.menu_book_outlined,
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const KnowledgeBasePage()))),
            ..._itemWidget(
                color: color,
                title: '离线语音模型',
                icon: Icons.record_voice_over_outlined,
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const TtsModelManagerPage()))),
            ..._itemWidget(
                color: color,
                title: 'AI 能力中心',
                icon: Icons.auto_awesome_motion_outlined,
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const CapabilityCenterPage()))),
            ..._itemWidget(
                color: color,
                title: '用量统计',
                icon: Icons.query_stats_outlined,
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const UsageStatsPage()))),
            ..._itemWidget(
                color: color,
                title: '生成图片相册',
                icon: Icons.photo_library_outlined,
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const GeneratedImageAlbumPage()))),
            ..._itemWidget(
                color: color,
                title: '工具审计',
                icon: Icons.security_outlined,
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const ToolAuditPage()))),
            ..._itemWidget(
                color: color,
                title: '跨设备云同步',
                icon: Icons.cloud_sync_outlined,
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const CloudSyncPage()))),
            ..._itemWidget(
                color: color,
                title: '备份与恢复',
                icon: Icons.backup_outlined,
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const BackupRestorePage()))),
            ..._itemWidget(
                color: color,
                title: '检测更新',
                icon: Icons.update,
                onTap: _checkUpdate),
          ],
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic>? userInfo = LoginDao.getUserInfo();
    if (userInfo != null) {
      setState(() {
        userName = userInfo['userName'];
        imoocId = userInfo['imoocId'];
        avatar = userInfo['avatar'];
      });
    }
  }

  _itemWidget(
      {required Color color,
      required String title,
      required IconData icon,
      GestureTapCallback? onTap}) {
    if (context.read<ThemeProvider>().isAnime) {
      final colorScheme = Theme.of(context).colorScheme;
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Material(
            color: colorScheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: colorScheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 60),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(icon, size: 21, color: colorScheme.primary),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded,
                          color: colorScheme.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ];
    }
    return [
      10.paddingHeight,
      Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 15, bottom: 10, right: 20),
        child: InkWell(
          onTap: onTap,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: titleStyle,
              ),
              Icon(icon, color: color)
            ],
          ),
        ),
      ),
      const Padding(
        padding: EdgeInsets.only(left: 15, right: 15),
        child: Divider(),
      )
    ];
  }

  void _checkUpdate() async {
    // ohos: 鸿蒙不支持 APK 安装，统一引导到应用市场
    if (Platform.operatingSystem == 'ohos') {
      HiDialog.showSnackBar(context, '鸿蒙版本请前往华为应用市场更新');
      return;
    }
    if (!Platform.isAndroid) {
      HiDialog.showSnackBar(context, '仅支持Android，其他平台敬请期待');
      return;
    }
    try {
      final model = await ApkUpdateDao.checkUpdate();
      AILogger.log(jsonEncode(model));
      if (!mounted) return;
      _showUpdateDialog(model);
    } catch (e) {
      AILogger.log(e.toString());
      if (!mounted) return;
      HiDialog.showSnackBar(context, '已是最新版本');
    }
  }

  void _showUpdateDialog(ApkModel model) async {
    final result = await HiDialog.showDownloadDialog(context,
        title: '有新版本啦',
        content: model.description ?? "",
        confirmText: "立即更新",
        cancelText: "取消");
    AILogger.log('result:$result');
    if (!(result ?? false) || !mounted) {
      return;
    }
    final dialog = HiProgressDialog();
    dialog.show(context, cancellable: false);
    String? path;
    path = await HiDownLoad().download(
        downLoadUrl: model.url!,
        fileName: 'ChatGPT.apk',
        listener: (int total, int received, bool done) {
          AILogger.log('total$total,received:$received');
          dialog.update((received / total * 100).toInt());
          if (done) {
            dialog.close();
            installAPK(path!);
          }
        });
    AILogger.log('path:$path');
  }
}

void installAPK(String path) async {
  final result = await OpenFilex.open(path);
  AILogger.log('installAPK:${result.type} message:${result.message}');
}
