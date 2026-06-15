import 'package:chat_message/models/message_model.dart';
import 'package:chat_message/util/wechat_date_format.dart';
import 'package:chat_message/widget/default_message_widget.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

DefaultMessageWidget _widgetFor(String? ownerName) => DefaultMessageWidget(
      key: GlobalKey(),
      message: MessageModel(
        ownerType: OwnerType.sender,
        ownerName: ownerName,
        content: '你好',
        createdAt: 1000,
      ),
    );

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

  group('senderInitials（空名不再红屏）', () {
    test('空串 / 纯空白 / null ownerName 返回空串，不抛 RangeError', () {
      // 回归：后端登录响应缺 userName 时 login_sdk 存成 ''，
      // 旧实现 ''[0] 会在气泡 build 期间抛 RangeError 红屏。
      expect(_widgetFor('').senderInitials, '');
      expect(_widgetFor('   ').senderInitials, '');
      expect(_widgetFor(null).senderInitials, '');
    });

    test('单词取首字素、多词取首个词', () {
      expect(_widgetFor('Alice').senderInitials, 'A');
      expect(_widgetFor('张三').senderInitials, '张');
      expect(_widgetFor('John Doe').senderInitials, 'John');
    });
  });

  testWidgets('空 ownerName 的发送气泡可正常渲染（红屏复现）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: _widgetFor('')),
      ),
    ));
    // 修复前此处会因 RangeError 抛异常；修复后正常构建。
    expect(tester.takeException(), isNull);
    expect(find.text('你好'), findsOneWidget);
  });
}
