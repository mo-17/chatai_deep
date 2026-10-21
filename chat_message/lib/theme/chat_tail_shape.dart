import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 弧尾与尖尾共用可随正文伸展的轮廓；参考来源见 DECORATION_REFERENCES.md。
/// 尾部占用内部留白，不溢出消息边界，也不覆盖正文和操作按钮。
class ChatTailShape extends ShapeBorder {
  final bool isUser;
  final bool pointed;
  final bool showTail;

  const ChatTailShape(
      {required this.isUser, this.pointed = false, this.showTail = true});

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  ShapeBorder scale(double t) => this;

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    if (rect.isEmpty) return Path();
    final tail = showTail ? math.min(8.0, rect.width / 5) : 0.0;
    final body =
        Rect.fromLTRB(rect.left, rect.top, rect.right - tail, rect.bottom);
    final radius =
        math.min(pointed ? 13.0 : 20.0, math.min(body.width, body.height) / 2);
    var path = Path()
      ..addRRect(RRect.fromRectAndRadius(body, Radius.circular(radius)));
    if (showTail) {
      final reach = math.min(20.0, rect.height * .65);
      final attachment = math.min(16.0, body.width * .65);
      final tip = Path();
      if (pointed) {
        tip
          ..moveTo(body.right - attachment / 2, rect.top)
          ..lineTo(rect.right, rect.top + math.min(1, reach * .1))
          ..lineTo(body.right - attachment / 2, rect.top + reach)
          ..close();
      } else {
        tip
          ..moveTo(body.right - attachment / 2, rect.bottom - reach)
          ..cubicTo(
              body.right - math.min(1, attachment * .1),
              rect.bottom - reach * .2,
              rect.right - tail * .625,
              rect.bottom - reach * .1,
              rect.right,
              rect.bottom)
          ..quadraticBezierTo(body.right - attachment * .6, rect.bottom,
              body.right - attachment, rect.bottom - reach * .35)
          ..close();
      }
      path = Path.combine(PathOperation.union, path, tip);
    }
    if (!isUser) {
      path = path.transform(Float64List.fromList([
        -1,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        1,
        0,
        rect.left + rect.right,
        0,
        0,
        1,
      ]));
    }
    return path;
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  bool operator ==(Object other) =>
      other is ChatTailShape &&
      other.isUser == isUser &&
      other.pointed == pointed &&
      other.showTail == showTail;

  @override
  int get hashCode => Object.hash(isUser, pointed, showTail);
}
