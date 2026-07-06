import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';

enum ConversationModelPickerFilter { all, available, image, tool, reasoning }

/// 会话模型选择器的纯展示逻辑：搜索、能力过滤、最近使用排序。
class ConversationModelPickerPresenter {
  const ConversationModelPickerPresenter._();

  static List<AiModel> visibleModels(
    AiProvider provider, {
    String query = '',
    ConversationModelPickerFilter filter = ConversationModelPickerFilter.all,
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    final models = [
      for (final model in provider.models)
        if (matches(provider, model, normalizedQuery, filter)) model,
    ];
    models.sort((a, b) => (b.lastUsedAt ?? 0).compareTo(a.lastUsedAt ?? 0));
    return models;
  }

  static bool matches(
    AiProvider provider,
    AiModel model,
    String query,
    ConversationModelPickerFilter filter,
  ) {
    if (query.isNotEmpty) {
      final text = '${provider.name} ${provider.id} ${model.name} ${model.id}'
          .toLowerCase();
      if (!text.contains(query.toLowerCase())) return false;
    }
    final caps = capabilities(provider, model);
    return switch (filter) {
      ConversationModelPickerFilter.all => true,
      ConversationModelPickerFilter.available =>
        model.lastTestStatus == 'success',
      ConversationModelPickerFilter.image => caps.image,
      ConversationModelPickerFilter.tool => caps.tool,
      ConversationModelPickerFilter.reasoning => caps.reasoning,
    };
  }

  static ModelCapabilities capabilities(AiProvider provider, AiModel model) {
    final base = ModelCapabilities.heuristic(
      model.id,
      providerCode: provider.providerCode,
    );
    return base.copyWith(
      image: base.image || model.vision,
      tool: base.tool || model.tool,
      reasoning: base.reasoning || model.reasoning,
    );
  }
}
