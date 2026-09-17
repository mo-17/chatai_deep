import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/stream_dispatcher.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// 阶段四验收的可执行版本：文件解析 + 图片多模态。
/// 覆盖核心不变量（对照指南 §5「能原生喂就喂、不能就降级抽文本」）：
/// - 图片 MIME 修正（jpg -> jpeg 收敛）；
/// - PDF：caps.pdf 且未超限 -> 原生 file part；否则 syncfusion 抽文本降级；
/// - 文本文件直读拼 prompt（超长截断）；
/// - buildUserContent：无附件退化为纯字符串（与旧行为一致），
///   有附件组装 OpenAI 多模态 content 数组；
/// - StreamDispatcher.onImage：图片流事件 -> success 态 ImageBlock。
void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('phase4_test');
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${tmpDir.path}/managed');
  });

  tearDown(() async {
    ManagedAttachmentStore.debugRootDirectory = null;
    await tmpDir.delete(recursive: true);
  });

  /// 用 syncfusion 生成一个含已知文本的真实 PDF 文件。
  Future<File> createPdf(String text, {String name = 'doc.pdf'}) async {
    final doc = PdfDocument();
    doc.pages
        .add()
        .graphics
        .drawString(text, PdfStandardFont(PdfFontFamily.helvetica, 12));
    final bytes = await doc.save();
    doc.dispose();
    final f = File('${tmpDir.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  group('图片编码 + MIME 修正', () {
    test('jpg 收敛为 image/jpeg（Anthropic 不认 image/jpg）', () {
      expect(FileProcessor.imageMimeFor('/a/photo.jpg'), 'image/jpeg');
      expect(FileProcessor.imageMimeFor('/a/photo.JPEG'), 'image/jpeg');
      expect(FileProcessor.imageMimeFor('/a/pic.png'), 'image/png');
      expect(FileProcessor.imageMimeFor('/a/pic.webp'), 'image/webp');
      expect(FileProcessor.imageMimeFor('/a/unknown.bin'), 'image/jpeg');
    });

    test('encodeImage 产出带修正 MIME 的 data URI', () async {
      final f = File('${tmpDir.path}/img.jpg');
      await f.writeAsBytes([1, 2, 3]);
      final uri = await FileProcessor.encodeImage(f.path);
      expect(uri, startsWith('data:image/jpeg;base64,'));
      expect(uri.split(',')[1], base64Encode([1, 2, 3]));
    });
  });

  group('PDF：原生 vs 降级（决策按能力位）', () {
    test('caps.pdf 且未超限 -> 原生 file part，不抽文本', () async {
      final f = await createPdf('NativePath');
      const caps = ModelCapabilities(
          pdf: true, fileSizeLimits: {'pdf': 32 * 1024 * 1024});
      final r = await FileProcessor.process([f.path], caps);
      expect(r.nativeFiles, hasLength(1));
      expect(r.nativeFiles.first.filename, 'doc.pdf');
      expect(r.nativeFiles.first.dataUri,
          startsWith('data:application/pdf;base64,'));
      expect(r.extraText, isEmpty);
      expect(r.metas.single.mime, 'application/pdf');
      // 原生直发无降级文本，故 extractedText 为 null（不会跨轮重建文本）。
      expect(r.metas.single.extractedText, isNull);
    });

    test('caps.pdf=false -> syncfusion 抽文本降级（对用户透明）', () async {
      final f = await createPdf('DegradedContent42');
      final r =
          await FileProcessor.process([f.path], const ModelCapabilities.none());
      expect(r.nativeFiles, isEmpty);
      expect(r.extraText, contains('DegradedContent42'));
      expect(r.extraText, contains('doc.pdf')); // 带文件名包裹标记
    });

    test('超过 fileSizeLimit -> 即使 caps.pdf=true 也降级抽文本', () async {
      final f = await createPdf('OversizeFallback');
      const caps = ModelCapabilities(pdf: true, fileSizeLimits: {'pdf': 10});
      final r = await FileProcessor.process([f.path], caps);
      expect(r.nativeFiles, isEmpty);
      expect(r.extraText, contains('OversizeFallback'));
    });
  });

  group('文本文件直读', () {
    test('txt 内容拼进 extraText，并产出 FileBlock 元数据', () async {
      final f = File('${tmpDir.path}/note.txt');
      await f.writeAsString('plain note content');
      final r =
          await FileProcessor.process([f.path], const ModelCapabilities.none());
      expect(r.extraText, contains('plain note content'));
      expect(r.metas.single.name, 'note.txt');
      expect(r.metas.single.size, greaterThan(0));
      // 遗留项 6：降级文本随 meta 落库，且与当前轮 extraText 同一份。
      expect(r.metas.single.extractedText, contains('plain note content'));
      expect(r.metas.single.extractedText, r.extraText);
      final managedRoot = await ManagedAttachmentStore.ensureRootDirectory();
      expect(r.metas.single.path,
          startsWith('${managedRoot.path}${Platform.pathSeparator}'));
    });

    test('超长文本截断并加提示', () async {
      final f = File('${tmpDir.path}/big.txt');
      await f.writeAsString('x' * (FileProcessor.maxTextChars + 100));
      final r =
          await FileProcessor.process([f.path], const ModelCapabilities.none());
      expect(r.extraText, contains('已截断'));
      expect(r.extraText.length,
          lessThan(FileProcessor.maxTextChars + 200)); // 没把全文塞进去
    });

    test('managed attachment 读取拒绝超限文件与符号链接来源', () async {
      final source = File('${tmpDir.path}/bounded.txt');
      await source.writeAsString('12345');
      final managed = await ManagedAttachmentStore.importFile(source);

      expect(await ManagedAttachmentStore.readManagedBytes(managed),
          utf8.encode('12345'));
      expect(
        await ManagedAttachmentStore.readManagedBytes(managed, maxBytes: 4),
        isNull,
      );
      if (!Platform.isWindows) {
        final link = Link('${tmpDir.path}/source-link.txt');
        await link.create(source.path);
        await expectLater(
          ManagedAttachmentStore.importFile(File(link.path)),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('managed attachment 不沿目标目录项中的符号链接写文件', () async {
      if (Platform.isWindows) return;
      final source = File('${tmpDir.path}/unique-target.txt');
      final bytes = utf8.encode(
        'target-${DateTime.now().microsecondsSinceEpoch}',
      );
      await source.writeAsBytes(bytes);
      final sentinel = File('${tmpDir.path}/write-sentinel.txt');
      await sentinel.writeAsString('unchanged');
      final root = await ManagedAttachmentStore.ensureRootDirectory();
      final target = Link('${root.path}/${sha256.convert(bytes)}.txt');
      await target.create(sentinel.path);
      addTearDown(() async {
        if (await target.exists()) await target.delete();
      });

      await expectLater(
        ManagedAttachmentStore.importFile(source),
        throwsA(isA<FormatException>()),
      );
      expect(await sentinel.readAsString(), 'unchanged');
    });
  });

  group('ChatAttachments.buildUserContent', () {
    test('无附件 -> 纯字符串（与旧行为一致）', () {
      expect(const ChatAttachments().buildUserContent('hi'), 'hi');
    });

    test('图片 + 文件 + 降级文本 -> OpenAI 多模态 content 数组', () {
      const att = ChatAttachments(
        images: ['data:image/jpeg;base64,AAA'],
        nativeFiles: [
          NativeFilePart(
              filename: 'a.pdf', dataUri: 'data:application/pdf;base64,BBB'),
        ],
        extraText: '[附件「n.txt」内容开始]\nhello\n[附件「n.txt」内容结束]',
      );
      final content = att.buildUserContent('问题') as List;
      expect(content, hasLength(3));
      final text = content[0] as Map<String, dynamic>;
      expect(text['type'], 'text');
      expect(text['text'], contains('问题'));
      expect(text['text'], contains('hello')); // 降级文本拼在 prompt 之后
      final img = content[1] as Map<String, dynamic>;
      expect(img['type'], 'image_url');
      expect(img['image_url'], {'url': 'data:image/jpeg;base64,AAA'});
      final file = content[2] as Map<String, dynamic>;
      expect(file['type'], 'file');
      expect(file['file'], {
        'filename': 'a.pdf',
        'file_data': 'data:application/pdf;base64,BBB'
      });
    });
  });

  group('StreamDispatcher.onImage（模型生成图片 -> ImageBlock）', () {
    test('占位块变身为 success 态 ImageBlock', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, 'msg_1', modelId: 'gpt-4o')..start();
      d.onImage('https://img.example/a.png');
      final blocks = store.blocksFor('msg_1');
      expect(blocks, hasLength(1));
      final img = blocks.single as ImageBlock;
      expect(img.url, 'https://img.example/a.png');
      expect(img.status, MessageBlockStatus.success);
    });

    test('正文流式中图片到达：按顺序追加，正文块不被打断', () {
      final store = ChatBlockStore();
      final d = StreamDispatcher(store, 'msg_2')..start();
      d.onTextChunk('前文');
      d.onImage('data:image/png;base64,CCC');
      d.onTextChunk('后文');
      d.finish();
      final blocks = store.blocksFor('msg_2');
      expect(blocks.map((b) => b.type).toList(),
          [MessageBlockType.mainText, MessageBlockType.image]);
      // 图片不打断正文块：前后增量进同一个 mainText 块
      expect((blocks.first as MainTextBlock).content, '前文后文');
    });
  });

  group('用户消息的 ImageBlock/FileBlock 落库回读', () {
    test('encodeList/decodeList round-trip 保留文件元数据与图片路径', () {
      final blocks = <MessageBlock>[
        const ImageBlock(
          id: 'b1',
          messageId: 'msg_3',
          createdAt: 1,
          status: MessageBlockStatus.success,
          filePath: '/tmp/p.jpg',
        ),
        const FileBlock(
          id: 'b2',
          messageId: 'msg_3',
          createdAt: 1,
          status: MessageBlockStatus.success,
          file: FileMetadata(
              name: 'r.pdf',
              path: '/tmp/r.pdf',
              mime: 'application/pdf',
              size: 9,
              extractedText: '[附件「r.pdf」内容开始]\n正文\n[附件「r.pdf」内容结束]'),
        ),
        const MainTextBlock(
          id: 'b3',
          messageId: 'msg_3',
          createdAt: 1,
          status: MessageBlockStatus.success,
          content: '看下这个文件',
        ),
      ];
      final restored = MessageBlock.decodeList(MessageBlock.encodeList(blocks));
      expect(restored, hasLength(3));
      expect((restored[0] as ImageBlock).filePath, '/tmp/p.jpg');
      final file = restored[1] as FileBlock;
      expect(file.file.name, 'r.pdf');
      expect(file.file.mime, 'application/pdf');
      expect(file.file.size, 9);
      // 遗留项 6：extractedText 随 FileBlock 落库回读，供重开会话重建文件上下文。
      expect(file.file.extractedText, contains('正文'));
      expect((restored[2] as MainTextBlock).content, '看下这个文件');
    });
  });
}
