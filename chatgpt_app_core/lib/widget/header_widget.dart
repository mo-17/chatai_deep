import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/util/padding_extension.dart';
import 'package:provider/provider.dart';

///个人主页头部组件
class HeaderWidget extends StatelessWidget {
  final String? name;
  final String? avatar;
  final String? imoocId;

  const HeaderWidget({super.key, this.name, this.avatar, this.imoocId});

  static const _placeholder = Icon(Icons.person, size: 60);

  ///只有合法的 http/https URL 才走网络加载，否则直接显示占位图，
  ///避免 Image.network 把空串/相对路径解析成 file:/// 抛 "No host specified"
  bool get _isValidNetworkUrl {
    if (avatar == null || avatar!.trim().isEmpty) return false;
    final uri = Uri.tryParse(avatar!.trim());
    if (uri == null) return false;
    return (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  Widget get _avatar {
    if (!_isValidNetworkUrl) return _placeholder;
    return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.network(avatar!.trim(),
            height: 60, width: 60, errorBuilder: (_, __, ___) => _placeholder));
  }

  Widget _rightLayout(BuildContext context, {required bool isAnime}) =>
      Expanded(
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name ?? "",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          if (imoocId?.trim().isNotEmpty == true)
            Text(
              'imooc id：${imoocId!.trim()}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: isAnime
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : Colors.grey,
              ),
            ),
        ],
      ));

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final color = themeProvider.isAnime
        ? Theme.of(context).colorScheme.primary
        : themeProvider.themeColor;
    final content = Row(
      children: [
        20.paddingWidth,
        _avatar,
        15.paddingWidth,
        _rightLayout(context, isAnime: themeProvider.isAnime),
        _logoutBtn(context, color),
        12.paddingWidth,
      ],
    );

    if (!themeProvider.isAnime) {
      return Padding(
        padding: const EdgeInsets.only(top: 60),
        child: content,
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colorScheme.primaryContainer,
            colorScheme.secondaryContainer,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: colorScheme.primary.withValues(alpha: 0.10),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            right: 16,
            top: -4,
            child: Icon(
              Icons.auto_awesome_rounded,
              size: 28,
              color: colorScheme.secondary.withValues(alpha: 0.22),
            ),
          ),
          content,
        ],
      ),
    );
  }

  Widget _logoutBtn(BuildContext context, Color color) {
    return IconButton(
      tooltip: '退出登录',
      onPressed: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('退出登录'),
            content: const Text('确定要退出登录吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确定'),
              ),
            ],
          ),
        );
        if (ok == true && context.mounted) {
          LoginDao.logOut();
        }
      },
      icon: Icon(Icons.logout, color: color),
    );
  }
}
