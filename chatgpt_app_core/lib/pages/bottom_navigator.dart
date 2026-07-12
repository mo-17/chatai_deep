import 'package:chatgpt_app_core/migration/guest_migration_service.dart';
import 'package:chatgpt_app_core/pages/conversation_list_page.dart';
import 'package:chatgpt_app_core/pages/my_page.dart';
import 'package:chatgpt_app_core/pages/study_page.dart';
import 'package:chatgpt_app_core/pages/wonderful_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
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

  @override
  void initState() {
    super.initState();
    // 确保每次进入主页按当前账号加载 AI 设置
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<AISettingsProvider>().load();
      if (!mounted) return;
      await _maybeMigrateGuestData();
    });
  }

  /// 正式账号首次进入主页时，若检测到游客模式攒下的数据，弹窗询问是否导入。
  /// 每个账号只问一次（导入或拒绝后置位标记）。
  Future<void> _maybeMigrateGuestData() async {
    if (!await GuestMigrationService.shouldPrompt() || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入游客数据'),
        content: const Text('检测到你在游客模式下的会话记录和 AI 服务设置，'
            '是否合并到当前账号？（追加导入，不影响账号已有数据）'),
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
    if (!mounted) return;
    if (confirmed != true) {
      // 拒绝：标记已处理，下次不再询问。
      await GuestMigrationService.markDone();
      return;
    }
    try {
      final result = await GuestMigrationService.migrate();
      if (!mounted) return;
      await context.read<AISettingsProvider>().load();
      if (!mounted) return;
      final note = result.settingsImported ? '，并已套用游客的 AI 设置' : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入 ${result.conversations} 个会话$note')),
      );
    } catch (e) {
      // 失败不置标记，下次仍可重试。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    //更新导航器的context，供退出登录时使用
    NavigatorUtil.updateContext(context);
    return Scaffold(
      body: PageView(
        controller: _controller,
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        physics: const NeverScrollableScrollPhysics(),
        children: const [
          ConversationListPage(),
          WonderfulPage(),
          StudyPage(),
          MyPage()
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
            icon: Icon(Icons.chat_bubble_outline_rounded),
            selectedIcon: Icon(Icons.chat_bubble_rounded),
            label: '聊天',
          ),
          NavigationDestination(
            icon: Icon(Icons.local_fire_department_outlined),
            selectedIcon: Icon(Icons.local_fire_department_rounded),
            label: '精彩',
          ),
          NavigationDestination(
            icon: Icon(Icons.theater_comedy_outlined),
            selectedIcon: Icon(Icons.theater_comedy_rounded),
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
