import 'package:chatgpt_app_core/ai_readiness/ai_readiness_startup.dart';
import 'package:chatgpt_app_core/migration/guest_migration_service.dart';
import 'package:chatgpt_app_core/pages/conversation_list_page.dart';
import 'package:chatgpt_app_core/pages/my_page.dart';
import 'package:chatgpt_app_core/pages/study_page.dart';
import 'package:chatgpt_app_core/pages/wonderful_page.dart';
import 'package:chatgpt_app_core/provider/ai_readiness_provider.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/update/app_update_controller.dart';
import 'package:chatgpt_app_core/widget/starcore_svg_icon.dart';
import 'package:chatgpt_app_core/widget/desktop_layout.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/util/navigator_util.dart';
import 'package:provider/provider.dart';

///首页底部导航器
class BottomNavigator extends StatefulWidget {
  const BottomNavigator({super.key});

  @override
  State<BottomNavigator> createState() => _BottomNavigatorState();
}

class _BottomNavigatorState extends State<BottomNavigator> {
  final PageController _controller = PageController(initialPage: 0);
  int _currentIndex = 0;
  final AppUpdateController _updates = AppUpdateController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeAccount());
  }

  Future<void> _initializeAccount() async {
    try {
      await initializeAIReadinessAfterGuestMigration(
        loadSettings: () => context.read<AISettingsProvider>().load(),
        settleGuestMigration: _maybeMigrateGuestData,
        initializeReadiness: () async {
          final settings = context.read<AISettingsProvider>();
          await context.read<AIReadinessProvider>().initialize(
                expectedAccountHash: settings.accountHash,
              );
        },
        canContinue: () => mounted,
      );
    } catch (error) {
      // 读取目标 DB / 迁移判定失败时不继续 legacy 分类，防止把旧账号误判
      // 为新用户；保留历史功能可用，并在下次进入主页时重试。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('账号数据初始化失败，请稍后重试：$error')),
      );
    }
    if (mounted) await _updates.check(context, manual: false);
  }

  /// 正式账号首次进入主页时，若检测到游客模式攒下的数据，弹窗询问是否导入。
  /// 每个账号只问一次（导入或拒绝后置位标记）。
  Future<bool> _maybeMigrateGuestData() async {
    if (!await GuestMigrationService.shouldPrompt()) return true;
    if (!mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入游客数据'),
        content: const Text('检测到你在游客模式下的会话记录、助手记忆、个人记忆和 AI 服务设置，'
            '是否合并到当前账号？（追加导入，不影响账号已有数据；个人记忆及回答偏好建议开关会关闭）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('不导入'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (!mounted) return false;
    if (confirmed != true) {
      // 拒绝：标记已处理，下次不再询问。
      await GuestMigrationService.markDone();
      return true;
    }
    try {
      final result = await GuestMigrationService.migrate();
      if (!mounted) return false;
      await context.read<AISettingsProvider>().load();
      if (!mounted) return false;
      final note = result.settingsImported ? '，并已套用游客的 AI 设置' : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                '已导入 ${result.conversations} 个会话、${result.personalMemories} 条个人记忆$note')),
      );
      return true;
    } catch (e) {
      // 失败不置标记，下次仍可重试。
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    //更新导航器的context，供退出登录时使用
    NavigatorUtil.updateContext(context);
    return DesktopHomeLayout(
      selectedIndex: _currentIndex,
      onSelected: _selectPage,
      body: PageView(
        controller: _controller,
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        physics: const NeverScrollableScrollPhysics(),
        children: [
          const ConversationListPage(),
          const WonderfulPage(),
          const StudyPage(),
          MyPage(updateController: _updates)
        ],
      ),
      bottomNavigationBar: AppBottomNavigationBar(
        currentIndex: _currentIndex,
        onSelected: _selectPage,
      ),
    );
  }

  void _selectPage(int index) {
    _controller.jumpToPage(index);
    setState(() {
      _currentIndex = index;
    });
  }

  @override
  void dispose() {
    _updates.dispose();
    _controller.dispose();
    super.dispose();
  }
}

/// 可独立测试的底部导航外观；页面与账号初始化仍由 [BottomNavigator] 管理。
class AppBottomNavigationBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onSelected;

  const AppBottomNavigationBar({
    super.key,
    required this.currentIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    if (themeProvider.isAnime) {
      return NavigationBar(
        key: const ValueKey('anime_bottom_navigation'),
        selectedIndex: currentIndex,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: onSelected,
        destinations: const [
          NavigationDestination(
            icon: StarcoreSvgIcon(
              assetName: StarcoreIconAssets.navChatDefault,
              fallback: Icon(Icons.chat_bubble_outline_rounded),
            ),
            selectedIcon: StarcoreSvgIcon(
              assetName: StarcoreIconAssets.navChatSelected,
              fallback: Icon(Icons.chat_bubble_rounded),
            ),
            label: '聊天',
          ),
          NavigationDestination(
            icon: Icon(Icons.local_fire_department_outlined),
            selectedIcon: Icon(Icons.local_fire_department_rounded),
            label: '精彩',
          ),
          NavigationDestination(
            icon: StarcoreSvgIcon(
              assetName: StarcoreIconAssets.navCreateDefault,
              fallback: Icon(Icons.theater_comedy_outlined),
            ),
            selectedIcon: StarcoreSvgIcon(
              assetName: StarcoreIconAssets.navCreateSelected,
              fallback: Icon(Icons.theater_comedy_rounded),
            ),
            label: '创作',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_circle_outlined),
            selectedIcon: Icon(Icons.account_circle_rounded),
            label: '我的',
          ),
        ],
      );
    }

    return BottomNavigationBar(
      key: const ValueKey('classic_bottom_navigation'),
      currentIndex: currentIndex,
      onTap: onSelected,
      type: BottomNavigationBarType.fixed,
      items: [
        _classicItem('聊天', Icons.chat, themeProvider.themeColor),
        _classicItem(
            '精彩', Icons.local_fire_department, themeProvider.themeColor),
        _classicItem(
            '创作', Icons.theater_comedy_outlined, themeProvider.themeColor),
        _classicItem('我的', Icons.account_circle, themeProvider.themeColor),
      ],
    );
  }

  BottomNavigationBarItem _classicItem(
    String title,
    IconData icon,
    Color activeColor,
  ) {
    return BottomNavigationBarItem(
      icon: Icon(icon, color: Colors.grey),
      activeIcon: Icon(icon, color: activeColor),
      label: title,
    );
  }
}
