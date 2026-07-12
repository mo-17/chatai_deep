import 'dart:async';

import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/util/padding_extension.dart';
import 'package:openai_flutter/utils/ai_logger.dart';

///可实时更新进度的进度条弹框
class HiProgressDialog {
  final StreamController<int> _controller = StreamController();
  bool _isShowing = false;
  BuildContext? _context;

  get _dialogBody => StreamBuilder<int>(
      stream: _controller.stream,
      builder: (BuildContext context, AsyncSnapshot<int> snapshot) {
        return snapshot.connectionState == ConnectionState.active
            ? Row(
                children: [
                  Expanded(
                      child: LinearProgressIndicator(
                    value: (snapshot.data ?? 0) / 100,
                  )),
                  10.paddingWidth,
                  Text('已完成：${snapshot.data}%')
                ],
              )
            : const LinearProgressIndicator(value: 0);
      });

  ///更新进度
  void update(int progress) {
    if (_controller.isClosed) return;

    ///不用setState，提升刷新性能
    _controller.sink.add(progress);
  }

  ///展示进度条弹框，cancellable 弹框是否可以通过触屏取消
  bool show(BuildContext context, {bool cancellable = true}) {
    if (_isShowing) {
      AILogger.log('Dialog already shown/showing');
      return false;
    }
    _context = context;
    showDialog(
        context: context,
        builder: (BuildContext context) {
          final anime = AppVisualTheme.of(context).isAnime;
          return PopScope(
              canPop: cancellable,
              child: Dialog(
                shape: anime
                    ? Theme.of(context).dialogTheme.shape
                    : const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(Radius.circular(2))),
                child: Padding(
                  padding: EdgeInsets.all(anime ? 20 : 10),
                  child: _dialogBody,
                ),
              ));
        });
    AILogger.log('Dialog shown');
    _isShowing = true;
    return true;
  }

  bool close() {
    if (_context == null) {
      AILogger.log('_context is null');
      return false;
    }
    if (!_controller.isClosed) {
      _controller.close();
    }
    if (_isShowing) {
      _isShowing = false;
      Navigator.of(_context!).pop();
      AILogger.log('Dialog dismissed');
      return true;
    } else {
      AILogger.log('Dialog already dismissed');
      return false;
    }
  }
}
