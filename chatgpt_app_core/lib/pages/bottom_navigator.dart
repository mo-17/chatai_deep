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
  final defaultColor = Colors.grey;
  var _activeColor = Colors.blue;
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
    final themeProvider = context.watch<ThemeProvider>();
    _activeColor = themeProvider.themeColor;
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
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          _controller.jumpToPage(index);
          setState(() {
            _currentIndex = index;
          });
        },
        type: BottomNavigationBarType.fixed,
        items: [
          _bottomItem('聊天', Icons.chat, 0),
          _bottomItem('精彩', Icons.local_fire_department, 1),
          _bottomItem('创作', Icons.theater_comedy_outlined, 2),
          _bottomItem('我的', Icons.account_circle, 3),
        ],
      ),
    );
  }

  _bottomItem(String title, IconData icon, int index) {
    return BottomNavigationBarItem(
        icon: Icon(icon, color: defaultColor),
        activeIcon: Icon(icon, color: _activeColor),
        label: title);
  }
}
