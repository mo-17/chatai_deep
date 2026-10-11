import 'package:chatgpt_app_core/chat/domain/composer_reference.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';

/// 首次发送、重开和重试共同使用的用户资料转换，不读取可变来源。
String userMessageExtraText(Iterable<MessageBlock> blocks) => [
      ...blocks
          .whereType<FileBlock>()
          .map((b) => b.file.extractedText)
          .whereType<String>()
          .where((text) => text.isNotEmpty),
      historyReferencesExtraText(
          blocks.whereType<ReferenceBlock>().map((b) => b.reference)),
    ].where((text) => text.isNotEmpty).join('\n\n');
