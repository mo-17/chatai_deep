import 'package:chatgpt_app_core/data/provider_presets.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AiProvider.buildChatCompletionsUrl 规则', () {
    test('裸主机补 /v1/chat/completions', () {
      expect(AiProvider.buildChatCompletionsUrl('https://api.openai.com'),
          'https://api.openai.com/v1/chat/completions');
    });
    test('含 /v1 只补 /chat/completions', () {
      expect(AiProvider.buildChatCompletionsUrl('https://api.x.ai/v1'),
          'https://api.x.ai/v1/chat/completions');
    });
    test('含 /v4 只补 /chat/completions', () {
      expect(
          AiProvider.buildChatCompletionsUrl(
              'https://open.bigmodel.cn/api/paas/v4'),
          'https://open.bigmodel.cn/api/paas/v4/chat/completions');
    });
    test('末尾斜杠被规整', () {
      expect(AiProvider.buildChatCompletionsUrl('https://api.openai.com/'),
          'https://api.openai.com/v1/chat/completions');
    });
    test('已是完整 completions URL 原样透传', () {
      const full = 'https://api.perplexity.ai/chat/completions';
      expect(AiProvider.buildChatCompletionsUrl(full), full);
    });
    test('# 后缀强制不补版本', () {
      expect(AiProvider.buildChatCompletionsUrl('https://my.host/foo#'),
          'https://my.host/foo/chat/completions');
    });
    test('空串返回空', () {
      expect(AiProvider.buildChatCompletionsUrl(''), '');
    });
  });

  group('DeepSeek Flash 升级补充', () {
    test('已有账号仅补 Flash，保留模型自定义、选择与服务配置', () {
      final custom = AiModel(
        id: 'my-proxy-model',
        name: '我的模型',
        group: '私人分组',
        tool: true,
      );
      final previous = AiProvider(
        id: 'deepseek',
        type: 'openai',
        name: 'DeepSeek 私有代理',
        apiKey: 'account-key',
        apiHost: 'https://my-proxy.example/chat/completions',
        models: [custom],
        selectedModelId: custom.id,
        enabled: true,
        isSystem: true,
      );
      final source = {
        'providers': [previous.toJson()],
        'activeProviderId': 'deepseek',
        'backendModel': 'my-backend-model',
        'temperature': 0.4,
      };

      final settings = AISettings.fromJson(source);
      final provider = settings.activeProvider;
      expect(provider.models.map((model) => model.id),
          ['my-proxy-model', 'deepseek-flash']);
      expect(provider.models.first.toJson(), custom.toJson());
      expect(provider.selectedModelId, custom.id);
      expect(settings.effectiveModel, custom.id);
      expect(provider.apiKey, previous.apiKey);
      expect(provider.apiHost, previous.apiHost);
      expect(provider.name, previous.name);
      expect(provider.enabled, isTrue);
      expect(settings.backendModel, 'my-backend-model');
      expect(settings.temperature, 0.4);
      expect((source['providers'] as List).single, previous.toJson());

      final reloaded = AISettings.fromJson(settings.toJson());
      expect(reloaded.activeProvider.toJson(), provider.toJson(),
          reason: '重复加载不应重复补充或改写任何模型配置');
    });

    test('已配置 Flash 保留用户标注，也不重新启用服务商', () {
      final flash = AiModel(id: 'deepseek-flash', name: '自定义 Flash 名称');
      final previous = AiProvider(
        id: 'deepseek',
        type: 'openai',
        name: 'DeepSeek',
        models: [flash],
        selectedModelId: flash.id,
        enabled: false,
        isSystem: true,
      );
      final settings = AISettings.fromJson({
        'providers': [previous.toJson()],
        'activeProviderId': 'deepseek',
      });
      expect(settings.activeProvider.toJson(), previous.toJson());
    });

    test('不会补回其他服务商已移除的默认模型', () {
      final previous = AiProvider(
        id: 'openai',
        type: 'openai',
        name: 'OpenAI',
        models: [AiModel(id: 'only-my-model')],
        selectedModelId: 'only-my-model',
      );
      final settings = AISettings.fromJson({
        'providers': [previous.toJson()],
        'activeProviderId': 'openai',
      });
      expect(settings.activeProvider.toJson(), previous.toJson());
    });

    test('旧版 DeepSeek 配置迁移仍保留选择，同时提供 Flash', () {
      final settings = AISettings.fromJson({
        'localProvider': 'deepseek',
        'deepseek': {
          'apiKey': 'legacy-key',
          'model': 'legacy-proxy-model',
          'baseUrl': 'https://legacy.example/chat/completions',
        },
      });
      expect(settings.activeProvider.selectedModelId, 'legacy-proxy-model');
      expect(settings.activeProvider.apiKey, 'legacy-key');
      expect(settings.activeProvider.apiHost,
          'https://legacy.example/chat/completions');
      expect(settings.activeProvider.models.map((model) => model.id),
          contains('deepseek-flash'));
    });
  });

  group('预设目录：每家派生的 URL 都可用', () {
    test('全部预设的 completions URL 形态正确', () {
      for (final p in ProviderPresets.all()) {
        final url = p.chatCompletionsUrl;
        expect(url.endsWith('/chat/completions'), isTrue,
            reason: '${p.id} -> $url 应以 /chat/completions 结尾');
        expect(url.contains('/v1/v1'), isFalse, reason: '${p.id} 重复 v1: $url');
        expect(url.contains('/chat/completions/chat/completions'), isFalse,
            reason: '${p.id} 重复路径: $url');
        expect(url.startsWith('http'), isTrue, reason: '${p.id} 非法 URL: $url');
      }
    });

    test('代表性服务商的完整 URL 精确匹配', () {
      String urlOf(String id) => ProviderPresets.byId(id)!.chatCompletionsUrl;
      expect(urlOf('openai'), 'https://api.openai.com/v1/chat/completions');
      expect(urlOf('deepseek'), 'https://api.deepseek.com/v1/chat/completions');
      expect(urlOf('openrouter'),
          'https://openrouter.ai/api/v1/chat/completions');
      expect(urlOf('groq'), 'https://api.groq.com/openai/v1/chat/completions');
      expect(urlOf('zhipu'),
          'https://open.bigmodel.cn/api/paas/v4/chat/completions');
      expect(urlOf('dashscope'),
          'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions');
      expect(urlOf('gemini'),
          'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions');
      expect(urlOf('perplexity'), 'https://api.perplexity.ai/chat/completions');
      expect(urlOf('ollama'), 'http://localhost:11434/v1/chat/completions');
    });

    test('默认启用 deepseek + openai；其余默认禁用', () {
      final all = ProviderPresets.all();
      expect(all.firstWhere((p) => p.id == 'deepseek').enabled, isTrue);
      expect(all.firstWhere((p) => p.id == 'openai').enabled, isTrue);
      expect(all.firstWhere((p) => p.id == 'groq').enabled, isFalse);
    });

    test('每个预设都有 selectedModelId 且在模型清单内', () {
      for (final p in ProviderPresets.all()) {
        expect(p.models, isNotEmpty, reason: '${p.id} 应有默认模型');
        expect(p.models.any((m) => m.id == p.effectiveModelId), isTrue,
            reason: '${p.id} 生效模型不在清单');
      }
    });

    test('DeepSeek 提供 Flash 图片模型，并保持既有默认选择', () {
      final provider = ProviderPresets.byId('deepseek')!;
      final flash =
          provider.models.singleWhere((model) => model.id == 'deepseek-flash');
      expect(flash.vision, isTrue);
      expect(flash.tool, isTrue);
      expect(flash.reasoning, isTrue);
      expect(provider.effectiveModelId, 'deepseek-chat');
      expect(provider.models.map((model) => model.id),
          containsAll(['deepseek-chat', 'deepseek-reasoner']));
    });

    test('providerCode 映射：gemini->gemini, deepseek->deepseek, 其余->openai', () {
      expect(ProviderPresets.byId('gemini')!.providerCode, 'gemini');
      expect(ProviderPresets.byId('deepseek')!.providerCode, 'deepseek');
      expect(ProviderPresets.byId('groq')!.providerCode, 'openai');
    });
  });
}
