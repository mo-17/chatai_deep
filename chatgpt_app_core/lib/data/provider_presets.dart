import 'package:chatgpt_app_core/model/ai_provider.dart';

/// 预设服务商目录（迁移自 Cherry Studio `SYSTEM_PROVIDERS_CONFIG`）。
///
/// 源项目内置 61 家，但本项目 [DirectChatService] 只发 OpenAI 兼容的
/// `/chat/completions`，故这里只精选 **OpenAI 兼容**的主流服务商（~17 家），
/// 保证「加 key 即可用」。Claude 等可经 OpenRouter 这类聚合服务商接入。
///
/// 每家给出：apiHost（裸主机，完整 URL 由 [AiProvider.chatCompletionsUrl] 派生）、
/// 一组常用模型、申请 Key 的链接（[apiKeyUrls]）。用户可在详情页改 key/host、
/// 增删模型，也可新建自定义服务商。
class ProviderPresets {
  ProviderPresets._();

  /// 历史上 app 默认支持的两家，迁移后默认仍启用（其余需用户配置后启用）。
  static const defaultEnabledIds = {'deepseek', 'openai'};

  /// 迁移/初始化时的默认激活服务商（沿用旧版默认 DeepSeek）。
  static const defaultActiveId = 'deepseek';

  /// 申请 API Key 的链接（详情页「去申请 API Key」）。
  static const Map<String, String> apiKeyUrls = {
    'openai': 'https://platform.openai.com/api-keys',
    'deepseek': 'https://platform.deepseek.com/api_keys',
    'siliconflow': 'https://cloud.siliconflow.cn/account/ak',
    'openrouter': 'https://openrouter.ai/keys',
    'groq': 'https://console.groq.com/keys',
    'moonshot': 'https://platform.moonshot.cn/console/api-keys',
    'zhipu': 'https://open.bigmodel.cn/usercenter/apikeys',
    'dashscope': 'https://bailian.console.aliyun.com/?tab=model#/api-key',
    'mistral': 'https://console.mistral.ai/api-keys/',
    'grok': 'https://console.x.ai',
    'perplexity': 'https://www.perplexity.ai/settings/api',
    'gemini': 'https://aistudio.google.com/app/apikey',
    'together': 'https://api.together.ai/settings/api-keys',
    'stepfun': 'https://platform.stepfun.com/interface-key',
    'baichuan': 'https://platform.baichuan-ai.com/console/apikey',
    'ollama': '',
  };

  /// 官网（用于文案/兜底）。
  static const Map<String, String> officialUrls = {
    'openai': 'https://openai.com',
    'deepseek': 'https://deepseek.com',
    'siliconflow': 'https://siliconflow.cn',
    'openrouter': 'https://openrouter.ai',
    'groq': 'https://groq.com',
    'moonshot': 'https://moonshot.cn',
    'zhipu': 'https://bigmodel.cn',
    'dashscope': 'https://dashscope.aliyun.com',
    'mistral': 'https://mistral.ai',
    'grok': 'https://x.ai',
    'perplexity': 'https://perplexity.ai',
    'gemini': 'https://ai.google.dev',
    'together': 'https://together.ai',
    'stepfun': 'https://stepfun.com',
    'baichuan': 'https://baichuan-ai.com',
    'ollama': 'https://ollama.com',
  };

  /// 全量预设（每次返回新实例，避免共享可变状态）。
  static List<AiProvider> all() => [
        _p('openai', 'OpenAI', 'https://api.openai.com', enabled: true, models: [
          _m('gpt-4o', 'GPT-4o', group: 'GPT-4o', vision: true, tool: true),
          _m('gpt-4o-mini', 'GPT-4o mini',
              group: 'GPT-4o', vision: true, tool: true),
          _m('gpt-4.1', 'GPT-4.1', group: 'GPT-4.1', vision: true, tool: true),
          _m('o3-mini', 'o3-mini', group: 'o-series', reasoning: true, tool: true),
          _m('o1', 'o1', group: 'o-series', reasoning: true, vision: true, tool: true),
        ]),
        _p('deepseek', 'DeepSeek', 'https://api.deepseek.com',
            enabled: true,
            models: [
              _m('deepseek-chat', 'DeepSeek V3', group: 'DeepSeek', tool: true),
              _m('deepseek-reasoner', 'DeepSeek R1',
                  group: 'DeepSeek', reasoning: true),
              _m('deepseek-flash', 'DeepSeek Flash（支持图片）',
                  group: 'DeepSeek', vision: true, reasoning: true, tool: true),
            ]),
        _p('siliconflow', '硅基流动', 'https://api.siliconflow.cn', models: [
          _m('deepseek-ai/DeepSeek-V3', 'DeepSeek V3', group: 'DeepSeek', tool: true),
          _m('deepseek-ai/DeepSeek-R1', 'DeepSeek R1',
              group: 'DeepSeek', reasoning: true),
          _m('Qwen/Qwen2.5-72B-Instruct', 'Qwen2.5 72B', group: 'Qwen', tool: true),
        ]),
        _p('openrouter', 'OpenRouter', 'https://openrouter.ai/api/v1', models: [
          _m('openai/gpt-4o', 'GPT-4o', group: 'OpenAI', vision: true, tool: true),
          _m('anthropic/claude-3.5-sonnet', 'Claude 3.5 Sonnet',
              group: 'Anthropic', vision: true, tool: true),
          _m('google/gemini-2.0-flash-001', 'Gemini 2.0 Flash',
              group: 'Google', vision: true, tool: true),
          _m('deepseek/deepseek-chat', 'DeepSeek V3', group: 'DeepSeek', tool: true),
        ]),
        _p('groq', 'Groq', 'https://api.groq.com/openai/v1', models: [
          _m('llama-3.3-70b-versatile', 'Llama 3.3 70B', group: 'Llama', tool: true),
          _m('llama-3.1-8b-instant', 'Llama 3.1 8B', group: 'Llama', tool: true),
        ]),
        _p('moonshot', '月之暗面 Kimi', 'https://api.moonshot.cn/v1', models: [
          _m('moonshot-v1-8k', 'moonshot-v1-8k', group: 'Moonshot', tool: true),
          _m('moonshot-v1-32k', 'moonshot-v1-32k', group: 'Moonshot', tool: true),
          _m('moonshot-v1-128k', 'moonshot-v1-128k', group: 'Moonshot', tool: true),
        ]),
        _p('zhipu', '智谱 GLM', 'https://open.bigmodel.cn/api/paas/v4', models: [
          _m('glm-4-plus', 'GLM-4-Plus', group: 'GLM-4', tool: true),
          _m('glm-4-flash', 'GLM-4-Flash', group: 'GLM-4', tool: true),
          _m('glm-4v-plus', 'GLM-4V-Plus', group: 'GLM-4', vision: true, tool: true),
        ]),
        _p('dashscope', '通义千问',
            'https://dashscope.aliyuncs.com/compatible-mode/v1', models: [
          _m('qwen-max', 'Qwen-Max', group: 'Qwen', tool: true),
          _m('qwen-plus', 'Qwen-Plus', group: 'Qwen', tool: true),
          _m('qwen-vl-max', 'Qwen-VL-Max', group: 'Qwen', vision: true, tool: true),
        ]),
        _p('mistral', 'Mistral', 'https://api.mistral.ai/v1', models: [
          _m('mistral-large-latest', 'Mistral Large', group: 'Mistral', tool: true),
          _m('mistral-small-latest', 'Mistral Small', group: 'Mistral', tool: true),
          _m('pixtral-large-latest', 'Pixtral Large',
              group: 'Mistral', vision: true, tool: true),
        ]),
        _p('grok', 'xAI Grok', 'https://api.x.ai/v1', models: [
          _m('grok-2-latest', 'Grok 2', group: 'Grok', tool: true),
          _m('grok-2-vision-latest', 'Grok 2 Vision',
              group: 'Grok', vision: true, tool: true),
        ]),
        // Perplexity 端点无 /v1，直接存完整 completions URL（派生原样透传）。
        _p('perplexity', 'Perplexity',
            'https://api.perplexity.ai/chat/completions', models: [
          _m('sonar', 'Sonar', group: 'Sonar', web: true),
          _m('sonar-pro', 'Sonar Pro', group: 'Sonar', web: true),
          _m('sonar-reasoning', 'Sonar Reasoning',
              group: 'Sonar', reasoning: true, web: true),
        ]),
        // Gemini 的 OpenAI 兼容端点路径特殊（/v1beta/openai），存完整 URL。
        _p('gemini', 'Google Gemini',
            'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
            type: 'gemini',
            models: [
              _m('gemini-2.0-flash', 'Gemini 2.0 Flash',
                  group: 'Gemini', vision: true, tool: true),
              _m('gemini-1.5-pro', 'Gemini 1.5 Pro',
                  group: 'Gemini', vision: true, tool: true),
              _m('gemini-1.5-flash', 'Gemini 1.5 Flash',
                  group: 'Gemini', vision: true, tool: true),
            ]),
        _p('together', 'Together', 'https://api.together.xyz/v1', models: [
          _m('meta-llama/Llama-3.3-70B-Instruct-Turbo', 'Llama 3.3 70B',
              group: 'Llama', tool: true),
          _m('deepseek-ai/DeepSeek-V3', 'DeepSeek V3', group: 'DeepSeek', tool: true),
        ]),
        _p('stepfun', '阶跃星辰', 'https://api.stepfun.com/v1', models: [
          _m('step-1-8k', 'Step-1 8K', group: 'Step'),
          _m('step-1v-8k', 'Step-1V 8K', group: 'Step', vision: true),
        ]),
        _p('baichuan', '百川', 'https://api.baichuan-ai.com/v1', models: [
          _m('Baichuan4', 'Baichuan4', group: 'Baichuan', tool: true),
          _m('Baichuan3-Turbo', 'Baichuan3-Turbo', group: 'Baichuan'),
        ]),
        _p('ollama', 'Ollama 本地', 'http://localhost:11434/v1', models: [
          _m('llama3.2', 'llama3.2', group: 'Ollama'),
          _m('qwen2.5', 'qwen2.5', group: 'Ollama'),
        ]),
      ];

  static AiProvider? byId(String id) {
    for (final p in all()) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 所有预设 id（用于判断「是否预设」）。
  static Set<String> get ids => all().map((p) => p.id).toSet();

  static AiProvider _p(
    String id,
    String name,
    String apiHost, {
    String type = 'openai',
    bool enabled = false,
    required List<AiModel> models,
  }) =>
      AiProvider(
        id: id,
        type: type,
        name: name,
        apiHost: apiHost,
        models: models,
        selectedModelId: models.isNotEmpty ? models.first.id : '',
        enabled: enabled,
        isSystem: true,
      );

  static AiModel _m(
    String id,
    String name, {
    String group = '',
    bool vision = false,
    bool reasoning = false,
    bool tool = false,
    bool web = false,
  }) =>
      AiModel(
        id: id,
        name: name,
        group: group,
        vision: vision,
        reasoning: reasoning,
        tool: tool,
        web: web,
      );
}
