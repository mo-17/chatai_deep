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

  const HeaderWidget({Key? key, this.name, this.avatar, this.imoocId})
      : super(key: key);

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
            height: 60,
            width: 60,
            errorBuilder: (_, __, ___) => _placeholder));
  }

  get _rightLayout => Expanded(
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name ?? "",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          Text(
            'imooc id：$imoocId',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          )
        ],
      ));

  @override
  Widget build(BuildContext context) {
    var themeProvider = context.watch<ThemeProvider>();
    var color = themeProvider.themeColor;
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Row(
        children: [
          20.paddingWidth,
          _avatar,
          15.paddingWidth,
          _rightLayout,
          _logoutBtn(color),
          20.paddingWidth,
        ],
      ),
    );
  }

  _logoutBtn(MaterialColor color) {
    return GestureDetector(
      onTap: () => LoginDao.logOut(),
      child: Icon(
        Icons.logout,
        color: color,
      ),
    );
  }
}
