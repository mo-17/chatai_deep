import 'dart:async';
import 'package:chatgpt_app_core/pages/account_usage_page.dart';
import 'package:chatgpt_app_core/pages/feedback_page.dart';

import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/config/app_distribution.dart';
import 'package:chatgpt_app_core/diagnostics/diagnostics_consent_store.dart';
import 'package:chatgpt_app_core/pages/ai_settings_page.dart';
import 'package:chatgpt_app_core/pages/appearance_settings_page.dart';
import 'package:chatgpt_app_core/pages/agent_task_center_page.dart';
import 'package:chatgpt_app_core/pages/assistant_list_page.dart';
import 'package:chatgpt_app_core/pages/backup_restore_page.dart';
import 'package:chatgpt_app_core/pages/capability_center_page.dart';
import 'package:chatgpt_app_core/pages/cloud_sync_page.dart';
import 'package:chatgpt_app_core/pages/generated_image_album_page.dart';
import 'package:chatgpt_app_core/pages/knowledge_base_page.dart';
import 'package:chatgpt_app_core/pages/personal_memory_page.dart';
import 'package:chatgpt_app_core/pages/mcp_settings_page.dart';
import 'package:chatgpt_app_core/pages/tool_audit_page.dart';
import 'package:chatgpt_app_core/pages/tts_model_manager_page.dart';
import 'package:chatgpt_app_core/pages/usage_stats_page.dart';
import 'package:chatgpt_app_core/provider/ai_readiness_provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/update/app_update_controller.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/widget/header_widget.dart';
import 'package:chatgpt_app_core/widget/ai_readiness_card.dart';
import 'package:flutter/material.dart';
import '../storage/ohos_storage_service.dart';
import 'storage_management_page.dart';
import 'knowledge_assistant_page.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/util/padding_extension.dart';
import 'package:provider/provider.dart';

export 'package:chatgpt_app_core/update/app_update_controller.dart'
    show
        ApkUpdateChecker,
        ApkDownloadHandler,
        StoreUpdateOpener,
        ApkInstallHandler,
        installAPK;

///我的页面
class MyPage extends StatefulWidget {
  final ApkUpdateChecker? updateChecker;
  final ApkDownloadHandler? downloadHandler;
  final StoreUpdateOpener? storeOpener;
  final ApkInstallHandler? installHandler;
  final AppDistribution? distribution;
  final String? operatingSystem;
  final DiagnosticsConsentStore? diagnosticsConsentStore;
  final AppUpdateController? updateController;

  const MyPage({
    super.key,
    this.updateChecker,
    this.downloadHandler,
    this.storeOpener,
    this.installHandler,
    this.distribution,
    this.operatingSystem,
    this.diagnosticsConsentStore,
    this.updateController,
  });

  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  late final AppUpdateController _updates;
  String? avatar;
  String? userName;
  String? imoocId;
  static const titleStyle =
      TextStyle(fontSize: 18, fontWeight: FontWeight.w600);

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final readiness = context.watch<AIReadinessProvider?>();
    final readinessPresentation =
        readiness == null ? null : aiReadinessPresentation(readiness.state);
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
                subtitle: readinessPresentation?.title,
                badge: readiness == null
                    ? null
                    : AIReadinessStatusBadge(state: readiness.state),
                onTap: () => unawaited(_openAISettings())),
            ..._itemWidget(
                color: color,
                title: '官方试用与用量',
                icon: Icons.auto_awesome,
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const AccountUsagePage()))),
            ..._itemWidget(
                color: color,
                title: '意见反馈',
                icon: Icons.feedback_outlined,
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const FeedbackPage()))),
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
                title: '个人记忆',
                icon: Icons.psychology_alt_outlined,
                subtitle: '本账号跨普通会话使用，可查看和控制',
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const PersonalMemoryPage()))),
            ..._itemWidget(
                color: color,
                title: 'Agent 任务中心',
                icon: Icons.assignment_outlined,
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const AgentTaskCenterPage()))),
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
                title: '可信知识助手',
                icon: Icons.fact_check_outlined,
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const KnowledgeAssistantPage()))),
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
                title: '隐私与诊断',
                icon: Icons.privacy_tip_outlined,
                onTap: _showDiagnosticsSettings),
            if (OhosStorageService.isSupported)
              ..._itemWidget(
                  color: color,
                  title: '存储管理',
                  icon: Icons.storage_outlined,
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const StorageManagementPage()))),
            ..._itemWidget(
                color: color,
                title: '检测更新',
                icon: Icons.update,
                subtitle: _updates.subtitle,
                onTap: _updates.busy ? null : _checkUpdate),
          ],
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _updates = widget.updateController ??
        AppUpdateController(
          updateChecker: widget.updateChecker,
          downloadHandler: widget.downloadHandler,
          storeOpener: widget.storeOpener,
          installHandler: widget.installHandler,
          distribution: widget.distribution,
          operatingSystem: widget.operatingSystem,
        );
    _updates.addListener(_updateChanged);
    unawaited(_updates.loadVersion());
    final Map<String, dynamic>? userInfo = LoginDao.getUserInfo();
    if (userInfo != null) {
      setState(() {
        userName = userInfo['userName'];
        imoocId = userInfo['imoocId'];
        avatar = userInfo['avatar'];
      });
    }
  }

  void _updateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _updates.removeListener(_updateChanged);
    if (widget.updateController == null) _updates.dispose();
    super.dispose();
  }

  _itemWidget(
      {required Color color,
      required String title,
      required IconData icon,
      String? subtitle,
      Widget? badge,
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
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            if (subtitle != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (badge != null) ...[
                        badge,
                        const SizedBox(width: 8),
                      ],
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: titleStyle),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 8),
                badge,
              ],
              const SizedBox(width: 10),
              Icon(icon, color: color),
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

  Future<void> _openAISettings() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const AISettingsPage()),
    );
    if (!mounted) return;
    final readiness = context.read<AIReadinessProvider?>();
    if (readiness == null || readiness.state.status != AIReadyStatus.ready) {
      return;
    }
    try {
      await readiness.markCompleted();
    } catch (error) {
      if (mounted) HiDialog.showSnackBar(context, 'AI 引导状态未保存：$error');
    }
  }

  Future<void> _checkUpdate() => _updates.check(context);

  Future<void> _showDiagnosticsSettings() {
    return showDialog<void>(
      context: context,
      builder: (_) => _DiagnosticsConsentDialog(
        store:
            widget.diagnosticsConsentStore ?? const DiagnosticsConsentStore(),
      ),
    );
  }
}

class _DiagnosticsConsentDialog extends StatefulWidget {
  final DiagnosticsConsentStore store;

  const _DiagnosticsConsentDialog({required this.store});

  @override
  State<_DiagnosticsConsentDialog> createState() =>
      _DiagnosticsConsentDialogState();
}

class _DiagnosticsConsentDialogState extends State<_DiagnosticsConsentDialog> {
  late bool _consented;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _consented = widget.store.read();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('隐私与诊断'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('匿名错误诊断'),
              subtitle: Text(_saving ? '正在保存…' : '默认关闭，可随时撤回'),
              value: _consented,
              onChanged: _saving ? null : _setConsent,
            ),
            const SizedBox(height: 8),
            Text(
              '开启后只允许发送异常类型、净化后的 package/dart 调用栈、'
              'App 版本、平台、HTTP 状态码、耗时和聚合计数。不会发送对话、'
              '提示词、账号、密钥、URL、文件路径、知识库正文或工具参数。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }

  Future<void> _setConsent(bool value) async {
    setState(() => _saving = true);
    var failed = false;
    try {
      await widget.store.write(value);
    } catch (_) {
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _consented = widget.store.read();
      _saving = false;
    });
    if (failed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('诊断设置未保存，请稍后重试')),
      );
    }
  }
}
