import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 用目标平台判断，避免宽屏手机和鸿蒙平板被误当成桌面。
bool get isDesktopTarget =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

bool get supportsWideAppLayout => kIsWeb || isDesktopTarget;

/// 主页保留同一棵内容树，缩放窗口时不会重建当前页或丢失滚动位置。
class DesktopHomeLayout extends StatelessWidget {
  final Widget body;
  final Widget bottomNavigationBar;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const DesktopHomeLayout({
    super.key,
    required this.body,
    required this.bottomNavigationBar,
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final wide = supportsWideAppLayout && constraints.maxWidth >= 840;
          final mac = defaultTargetPlatform == TargetPlatform.macOS;
          return CallbackShortcuts(
            bindings: supportsWideAppLayout
                ? {
                    for (final (index, key) in [
                      LogicalKeyboardKey.digit1,
                      LogicalKeyboardKey.digit2,
                      LogicalKeyboardKey.digit3,
                      LogicalKeyboardKey.digit4,
                    ].indexed)
                      SingleActivator(key, meta: mac, control: !mac): () =>
                          onSelected(index),
                  }
                : {},
            child: Focus(
              skipTraversal: true,
              autofocus: supportsWideAppLayout,
              child: Scaffold(
                body: Row(children: [
                  if (wide)
                    SafeArea(
                      child: SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight,
                          ),
                          child: IntrinsicHeight(
                            child: NavigationRail(
                              key: const ValueKey('desktop_navigation'),
                              selectedIndex: selectedIndex,
                              onDestinationSelected: onSelected,
                              labelType: NavigationRailLabelType.all,
                              leading: const Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Text('艾普'),
                              ),
                              destinations: const [
                                NavigationRailDestination(
                                  icon: Icon(Icons.chat_bubble_outline),
                                  selectedIcon: Icon(Icons.chat_bubble),
                                  label: Text('聊天'),
                                ),
                                NavigationRailDestination(
                                  icon: Icon(
                                      Icons.local_fire_department_outlined),
                                  selectedIcon:
                                      Icon(Icons.local_fire_department),
                                  label: Text('精彩'),
                                ),
                                NavigationRailDestination(
                                  icon: Icon(Icons.theater_comedy_outlined),
                                  selectedIcon: Icon(Icons.theater_comedy),
                                  label: Text('创作'),
                                ),
                                NavigationRailDestination(
                                  icon: Icon(Icons.account_circle_outlined),
                                  selectedIcon: Icon(Icons.account_circle),
                                  label: Text('我的'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  Expanded(key: const ValueKey('home_content'), child: body),
                ]),
                bottomNavigationBar: wide ? null : bottomNavigationBar,
              ),
            ),
          );
        },
      );
}

/// 同一个顶层路由内显示列表与详情，沿用现有生成确认与返回生命周期。
class DesktopConversationLayout extends StatelessWidget {
  final Widget master;
  final Widget detail;

  const DesktopConversationLayout({
    super.key,
    required this.master,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final split = supportsWideAppLayout && constraints.maxWidth >= 1100;
          return Row(children: [
            if (split) ...[
              SizedBox(width: 380, child: master),
              const VerticalDivider(width: 1),
            ],
            Expanded(key: const ValueKey('conversation_detail'), child: detail),
          ]);
        },
      );
}
