import 'package:chatgpt_app_core/capability/model_picker_presenter.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AiProvider provider({
    String id = 'openai',
    String name = 'OpenAI',
    String type = 'openai',
    required List<AiModel> models,
  }) =>
      AiProvider(
        id: id,
        name: name,
        type: type,
        enabled: true,
        models: models,
      );

  test('模型选择器按最近使用时间优先展示', () {
    final p = provider(models: [
      AiModel(id: 'gpt-4o-mini', lastUsedAt: 20),
      AiModel(id: 'gpt-4o', lastUsedAt: 100),
      AiModel(id: 'gpt-3.5-turbo'),
    ]);

    final visible = ConversationModelPickerPresenter.visibleModels(p);

    expect(
        visible.map((m) => m.id), ['gpt-4o', 'gpt-4o-mini', 'gpt-3.5-turbo']);
  });

  test('模型选择器搜索同时匹配服务商名称、服务商 id、模型名称和模型 id', () {
    final p = provider(
      id: 'moonshot',
      name: 'Moonshot AI',
      models: [
        AiModel(id: 'kimi-k2', name: 'Kimi K2'),
        AiModel(id: 'other-model', name: 'Other'),
      ],
    );

    expect(
      ConversationModelPickerPresenter.visibleModels(p, query: 'moonshot')
          .map((m) => m.id),
      ['kimi-k2', 'other-model'],
    );
    expect(
      ConversationModelPickerPresenter.visibleModels(p, query: 'K2')
          .map((m) => m.id),
      ['kimi-k2'],
    );
  });

  test('模型选择器按可用状态与能力位过滤', () {
    final p = provider(models: [
      AiModel(id: 'gpt-4o', lastTestStatus: 'success'),
      AiModel(id: 'custom-vision', vision: true),
      AiModel(id: 'custom-tool', tool: true),
      AiModel(id: 'deepseek-reasoner'),
      AiModel(id: 'plain-custom'),
    ]);

    expect(
      ConversationModelPickerPresenter.visibleModels(
        p,
        filter: ConversationModelPickerFilter.available,
      ).map((m) => m.id),
      ['gpt-4o'],
    );
    expect(
      ConversationModelPickerPresenter.visibleModels(
        p,
        filter: ConversationModelPickerFilter.image,
      ).map((m) => m.id),
      ['gpt-4o', 'custom-vision'],
    );
    expect(
      ConversationModelPickerPresenter.visibleModels(
        p,
        filter: ConversationModelPickerFilter.tool,
      ).map((m) => m.id),
      ['gpt-4o', 'custom-tool'],
    );
    expect(
      ConversationModelPickerPresenter.visibleModels(
        p,
        filter: ConversationModelPickerFilter.reasoning,
      ).map((m) => m.id),
      ['deepseek-reasoner'],
    );
  });

  test('默认列表保留健康检查失败模型并继续按最近使用排序', () {
    final p = provider(models: [
      AiModel(
        id: 'failed-fast',
        lastTestStatus: 'failure',
        lastUsedAt: 200,
      ),
      AiModel(
        id: 'healthy-slow',
        lastTestStatus: 'success',
        lastUsedAt: 100,
      ),
    ]);

    expect(
      ConversationModelPickerPresenter.visibleModels(p).map((m) => m.id),
      ['failed-fast', 'healthy-slow'],
    );
  });
}
