import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/favorite_model.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/util/hi_utils.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/util/navigator_util.dart';

import '../widget/favorite_widget.dart';
import '../widget/forward_sheet.dart';
import 'meessage_detail_page.dart';

///收藏的消息页面
class WonderfulPage extends StatefulWidget {
  const WonderfulPage({Key? key}) : super(key: key);

  @override
  State<WonderfulPage> createState() => _WonderfulPageState();
}

class _WonderfulPageState extends State<WonderfulPage> {
  late FavoriteDao favoriteDao;
  List<FavoriteModel> favoriteList = [];

  get _listView => ListView.builder(
      itemCount: favoriteList.length,
      itemBuilder: (BuildContext context, int index) => FavoriteWidget(
            model: favoriteList[index],
            onLongPress: _onLongPress,
            onTap: _jumpToDetail,
          ));

  @override
  void initState() {
    super.initState();
    _doInit();
    // 备份导入后重新加载收藏列表（页面常驻，不会再走 initState）。
    BackupService.restoreTick.addListener(_loadData);
  }

  @override
  void dispose() {
    BackupService.restoreTick.removeListener(_loadData);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('精彩内容'),
      ),
      body: _listView,
    );
  }

  void _doInit() async {
    var dbManager =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    favoriteDao = await FavoriteDao.create(dbManager);
    _loadData();
  }

  void _loadData() async {
    var list = await favoriteDao.getFavoriteList();
    setState(() {
      favoriteList = list;
    });
  }

  void _onLongPress(FavoriteModel model, BuildContext ancestor) {
    HiDialog.showPopMenu(ancestor, offsetX: -50, items: [
      PopupMenuItem(
        onTap: () => HiUtils.copyMessage(model.content, context),
        child: const Text('复制'),
      ),
      PopupMenuItem(
        child: const Text('删除'),
        onTap: () => _onDelete(model),
      ),
      PopupMenuItem(
        child: const Text('转发'),
        onTap: () => showForwardSheet(context, content: model.content),
      )
    ]);
  }

  _onDelete(FavoriteModel model) async {
    var result = await favoriteDao.removeFavorite(model);
    var showText = '';
    if (result != null && result > 0) {
      showText = '删除成功';
    } else {
      showText = '删除失败';
    }
    if (!mounted) return;
    HiDialog.showSnackBar(context, showText);
    setState(() {
      favoriteList.remove(model);
    });
  }

  void _jumpToDetail(FavoriteModel model, BuildContext ancestor) {
    NavigatorUtil.push(context, MessageDetailPage(model: model));
  }
}
