import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/util/wechat_date_format.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wechat date format', () {
    debugPrint(WechatDateFormat.format(1972058683000).toString());
    debugPrint(WechatDateFormat.format(1772052683000).toString());
  });

  test('copyWith 复用同一 GlobalKey（内容更新不重建气泡子树）', () {
    final m = MessageModel(
        ownerType: OwnerType.receiver, content: '', createdAt: 1000);
    final updated = m.copyWith(content: '答案');
    expect(identical(updated.key, m.key), isTrue,
        reason: '内容更新应保留 GlobalKey，否则 ListView 会销毁并重建整个气泡');
    expect(updated.content, '答案');
  });

  test('显式传入 key 时使用该 key，否则新建', () {
    final k = GlobalKey();
    final a = MessageModel(
        ownerType: OwnerType.sender, content: 'x', createdAt: 1, key: k);
    expect(identical(a.key, k), isTrue);
    final b = MessageModel(
        ownerType: OwnerType.sender, content: 'y', createdAt: 2);
    expect(identical(b.key, k), isFalse);
  });
}
