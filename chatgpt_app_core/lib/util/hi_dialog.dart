import 'package:flutter/material.dart';

class HiDialog {
  HiDialog._();

  ///在context所属的widget下方弹出menu；offsetX、offsetY为水平和垂直方向的偏移量；items为弹出的菜单项
  static Future<T?> showPopMenu<T>(BuildContext context,
      {required List<PopupMenuEntry<T>> items,
      double offsetX = 0,
      offsetY = 0}) {
    var x = MediaQuery.of(context).size.width / 2 + offsetX;
    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    Offset offset = renderBox.localToGlobal(Offset.zero);
    var y = offset.dy + renderBox.size.height + offsetY;
    //计算弹框展示的位置
    final RelativeRect position = RelativeRect.fromLTRB(x, y, x, 0);
    return showMenu(context: context, position: position, items: items);
  }

  /// show a SnackBar
  static showSnackBar(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  ///设置代理弹框，返回true代表确认，false代表取消
  static Future<List> showProxySettingDialog(BuildContext context,
      {String? proxyText, GestureTapCallback? onTap}) async {
    var isSave = await showDialog<bool>(
        context: context,
        builder: (_) {
          return AlertDialog(
            title: Row(
              children: [
                const Text(
                  '设置代理',
                  style: TextStyle(fontSize: 16),
                ),
                InkWell(
                  onTap: onTap,
                  child: const Padding(
                    padding: EdgeInsetsDirectional.all(5),
                    child: Icon(Icons.question_mark_rounded,
                        color: Colors.grey, size: 18),
                  ),
                )
              ],
            ),
            titlePadding: const EdgeInsets.all(10),
            titleTextStyle:
                const TextStyle(color: Colors.black87, fontSize: 20),
            content: TextField(
              controller: TextEditingController(text: proxyText),
              onChanged: (text) => proxyText = text,
            ),
            contentPadding: const EdgeInsets.all(10),
            contentTextStyle:
                const TextStyle(fontSize: 15, color: Colors.black54),
            actions: [
              TextButton(
                  onPressed: () {
                    //关闭 返回false
                    Navigator.of(context).pop(false);
                  },
                  child: const Text('取消')),
              TextButton(
                  onPressed: () {
                    //关闭 返回true
                    Navigator.of(context).pop(true);
                  },
                  child: const Text('保存'))
            ],
          );
        });
    proxyText = proxyText == null ? proxyText : proxyText!.trim();
    return [isSave, proxyText];
  }

  ///展示确认弹框，返回true代表确认，false代表取消
  static Future<bool?> showDownloadDialog(
    BuildContext context, {
    required String title,
    required String content,
    required String confirmText,
    required String cancelText,
  }) {
    return showDialog<bool>(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Text(title),
            titlePadding: const EdgeInsets.all(10),
            titleTextStyle:
                const TextStyle(color: Colors.black87, fontSize: 16),
            content: Text(content),
            contentPadding: const EdgeInsets.all(10),
            contentTextStyle:
                const TextStyle(color: Colors.black54, fontSize: 14),
            actions: [
              TextButton(
                  onPressed: () {
                    //关闭 返回false
                    Navigator.of(context).pop(false);
                  },
                  child: Text(cancelText)),
              TextButton(
                  onPressed: () {
                    //关闭 返回true
                    Navigator.of(context).pop(true);
                  },
                  child: Text(confirmText))
            ],
          );
        });
  }
}
