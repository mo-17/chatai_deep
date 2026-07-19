import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';

final class RoleCardTranslationField {
  final String id;
  final String label;
  final String source;
  final String Function(String translated) restore;

  const RoleCardTranslationField({
    required this.id,
    required this.label,
    required this.source,
    required this.restore,
  });
}

abstract final class RoleCardTranslationFields {
  static const ids = <String>[
    'name',
    'description',
    'prompt',
    'openingMessage',
    'exampleDialogs',
    'memoryBook',
  ];

  static List<RoleCardTranslationField> fromAssistant(
    AssistantModel assistant,
  ) =>
      [for (final id in ids) byId(assistant, id)];

  static RoleCardTranslationField byId(
    AssistantModel assistant,
    String field,
  ) {
    final (label, source) = switch (field) {
      'name' => ('名称', assistant.name),
      'description' => ('简介', assistant.description),
      'prompt' => ('人设', assistant.prompt),
      'openingMessage' => ('开场', assistant.openingMessage),
      'exampleDialogs' => ('示例对话', assistant.exampleDialogs),
      'memoryBook' => ('世界书', assistant.memoryBook),
      _ => throw ArgumentError.value(field, 'field', '不支持的翻译字段'),
    };
    if (field != 'memoryBook') {
      return RoleCardTranslationField(
        id: field,
        label: label,
        source: source,
        restore: _identity,
      );
    }

    final view = AssistantRoleCardService.memoryBookTranslationView(source);
    if (!view.hasRawMarker) {
      return RoleCardTranslationField(
        id: field,
        label: label,
        source: source,
        restore: _identity,
      );
    }
    return RoleCardTranslationField(
      id: field,
      label: label,
      source: view.translationSource,
      restore: view.translationSource.isEmpty ? (_) => source : view.restore,
    );
  }

  static String _identity(String translated) => translated;
}
