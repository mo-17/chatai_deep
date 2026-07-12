import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/favorite_model.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:chatgpt_app_core/util/hi_utils.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/util/navigator_util.dart';

import '../widget/favorite_widget.dart';
import '../widget/forward_sheet.dart';
import 'meessage_detail_page.dart';

///收藏的消息页面
class WonderfulPage extends StatefulWidget {
  const WonderfulPage({super.key});

  @override
  State<WonderfulPage> createState() => _WonderfulPageState();
}

class _WonderfulPageState extends State<WonderfulPage> {
  FavoriteDao? favoriteDao;
  List<FavoriteModel> favoriteList = [];
  bool _loading = true;
  Object? _loadError;

  Widget get _listView {
    final isAnime = AppVisualTheme.of(context).isAnime;
    if (_loading) {
      return isAnime
          ? const Center(child: CircularProgressIndicator())
          : const SizedBox.shrink();
    }
    if (_loadError != null && isAnime) {
      return AppVisualEmptyState(
        animeKey: const ValueKey('wonderful_error_state'),
        icon: Icons.cloud_off_rounded,
        title: '收藏暂时没加载出来',
        message: '请检查本地数据后重试',
        action: FilledButton.icon(
          onPressed: _retryLoad,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重新加载'),
        ),
      );
    }
    if (favoriteList.isEmpty) {
      if (!isAnime) return const SizedBox.shrink();
      return const AppVisualEmptyState(
        animeKey: ValueKey('wonderful_empty_state'),
        icon: Icons.auto_awesome_rounded,
        title: '还没有精彩收藏',
        message: '长按喜欢的回复并收藏，它就会出现在这里。',
      );
    }
    return ListView.builder(
      padding: isAnime ? const EdgeInsets.symmetric(vertical: 8) : null,
      itemCount: favoriteList.length,
      itemBuilder: (BuildContext context, int index) => FavoriteWidget(
        model: favoriteList[index],
        onLongPress: _onLongPress,
        onTap: _jumpToDetail,
      ),
    );
  }

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

  Future<void> _doInit() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final dbManager =
          await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
      final dao = await FavoriteDao.create(dbManager);
      if (!mounted) return;
      favoriteDao = dao;
      await _loadData();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error;
      });
    }
  }

  Future<void> _retryLoad() {
    return favoriteDao == null ? _doInit() : _loadData();
  }

  Future<void> _loadData() async {
    final dao = favoriteDao;
    if (dao == null) return;
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final list = await dao.getFavoriteList();
      if (!mounted) return;
      setState(() {
        favoriteList = list;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error;
      });
    }
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
    final dao = favoriteDao;
    if (dao == null) return;
    final result = await dao.removeFavorite(model);
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
