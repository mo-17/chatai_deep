import 'package:chatgpt_app_core/capability/generated_image_save_service.dart';
import 'package:chatgpt_app_core/pages/generated_image_album_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('生成图片相册空态可刷新', (tester) async {
    var loads = 0;
    await tester.pumpWidget(MaterialApp(
      home: GeneratedImageAlbumPage(
        loader: () async {
          loads += 1;
          return const [];
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('生成图片相册'), findsOneWidget);
    expect(find.text('还没有保存的生成图片'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '刷新'));
    await tester.pumpAndSettle();
    expect(loads, 2);
  });

  testWidgets('生成图片相册展示已保存图片信息', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: GeneratedImageAlbumPage(
        loader: () async => [
          GeneratedImageAlbumItem(
            path: '/tmp/missing.png',
            filename: 'demo.png',
            sizeBytes: 1536,
            modifiedAt: DateTime(2026, 7, 2, 9, 30),
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('demo.png'), findsOneWidget);
    expect(find.textContaining('1.5KB'), findsOneWidget);
    expect(find.textContaining('2026-07-02 09:30'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('生成图片相册可确认删除并刷新列表', (tester) async {
    var deletedPath = '';
    var items = [
      GeneratedImageAlbumItem(
        path: '/tmp/demo.png',
        filename: 'demo.png',
        sizeBytes: 1536,
        modifiedAt: DateTime(2026, 7, 2, 9, 30),
      ),
    ];
    await tester.pumpWidget(MaterialApp(
      home: GeneratedImageAlbumPage(
        loader: () async => items,
        deleter: (path) async {
          deletedPath = path;
          items = const [];
          return true;
        },
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('删除图片'));
    await tester.pumpAndSettle();
    expect(find.text('删除图片'), findsOneWidget);
    expect(find.text('确定删除「demo.png」吗？'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();

    expect(deletedPath, '/tmp/demo.png');
    expect(find.text('已删除「demo.png」'), findsOneWidget);
    expect(find.text('还没有保存的生成图片'), findsOneWidget);
  });
}
