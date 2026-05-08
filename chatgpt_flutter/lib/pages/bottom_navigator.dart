import 'package:chatgpt_flutter/pages/conversation_list_page.dart';
import 'package:chatgpt_flutter/pages/my_page.dart';
import 'package:chatgpt_flutter/pages/study_page.dart';
import 'package:chatgpt_flutter/pages/wonderful_page.dart';
import 'package:chatgpt_flutter/provider/ai_settings_provider.dart';
import 'package:chatgpt_flutter/provider/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/util/navigator_util.dart';
import 'package:provider/provider.dart';

///首页底部导航器
class BottomNavigator extends StatefulWidget {
  const BottomNavigator({Key? key}) : super(key: key);

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AISettingsProvider>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    //更新导航器的context，供退出登录时使用
    NavigatorUtil.updateContext(context);
    var themeProvider = context.watch<ThemeProvider>();
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
          _bottomItem('学习', Icons.newspaper, 2),
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
