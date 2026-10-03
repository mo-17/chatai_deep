import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

/// 阶段三验收的可执行版本：多 Provider 抽象 + 能力探测。
/// 覆盖核心不变量：
/// - 按 modelId 家族推断的能力位正确（image/pdf/tool/reasoning）；
/// - 远程清单的 supportsVision 能覆盖启发式打开 image 位；
/// - 能力只由「当前模型」决定，从 ChatService 暴露，切换模型/厂商即变，
///   UI 与分发层不需要改（同一个 capabilitiesFor 是唯一来源）。
void main() {
  // 激活指定预设服务商并设其生效模型；能力探测只依赖 model + providerCode。
  AISettings localSettings(String providerId, String model) {
    final s = AISettings.defaults()..activeProviderId = providerId;
    s.setActiveModel(model);
    s.activeProvider.apiKey = 'k';
    return s;
  }

  AISettings backendSettings(String model) => AISettings.defaults()
    ..mode = AIMode.backend
    ..backendModel = model;

  group('ModelCapabilities.heuristic 按家族推断', () {
    test('gpt-4o：图片 + 工具，不输出思考', () {
      final c = ModelCapabilities.heuristic('gpt-4o', providerCode: 'openai');
      expect(c.image, isTrue);
      expect(c.tool, isTrue);
      expect(c.reasoning, isFalse);
    });

    test('gpt-4o-mini：图片 + 工具', () {
      final c = ModelCapabilities.heuristic('gpt-4o-mini');
      expect(c.image, isTrue);
      expect(c.tool, isTrue);
    });

    test('gpt-3.5-turbo：工具，无图片', () {
      final c = ModelCapabilities.heuristic('gpt-3.5-turbo');
      expect(c.tool, isTrue);
      expect(c.image, isFalse);
      expect(c.reasoning, isFalse);
    });

    test('o1：推理 + 工具 + 图片', () {
      final c = ModelCapabilities.heuristic('o1');
      expect(c.reasoning, isTrue);
      expect(c.tool, isTrue);
      expect(c.image, isTrue);
    });

    test('o1-mini：推理，但无工具 / 无图片', () {
      final c = ModelCapabilities.heuristic('o1-mini');
      expect(c.reasoning, isTrue);
      expect(c.tool, isFalse);
      expect(c.image, isFalse);
    });

    test('o3-mini：推理 + 工具，但无图片（vision 与 tool 解耦）', () {
      final c = ModelCapabilities.heuristic('o3-mini');
      expect(c.reasoning, isTrue);
      expect(c.tool, isTrue);
      expect(c.image, isFalse);
    });

    test('o4-mini：推理 + 工具 + 图片（与 o1-mini/o3-mini 区分）', () {
      final c = ModelCapabilities.heuristic('o4-mini');
      expect(c.reasoning, isTrue);
      expect(c.tool, isTrue);
      expect(c.image, isTrue);
    });

    test('deepseek-reasoner（R1）：只输出思考，不支持工具 / 图片', () {
      final c =
          ModelCapabilities.heuristic('deepseek-reasoner', providerCode: 'deepseek');
      expect(c.reasoning, isTrue);
      expect(c.tool, isFalse);
      expect(c.image, isFalse);
    });

    test('deepseek-chat（V3）：支持工具，不输出思考 / 无图片', () {
      final c =
          ModelCapabilities.heuristic('deepseek-chat', providerCode: 'deepseek');
      expect(c.tool, isTrue);
      expect(c.reasoning, isFalse);
      expect(c.image, isFalse);
    });

    test('DeepSeek Flash 与兼容别名：图片 + Files API，无原生 PDF', () {
      for (final model in [
        'deepseek-flash',
        'deepseek-v4-flash',
        'deepseek-v4-flash-vision-exp',
        '  DeepSeek-Flash  ',
      ]) {
        expect(ModelCapabilities.isDeepSeekVisionModel(model), isTrue);
        final c = ModelCapabilities.heuristic(model);
        expect(c.image, isTrue, reason: model);
        expect(c.tool, isTrue, reason: model);
        expect(c.reasoning, isTrue, reason: model);
        expect(c.pdf, isFalse, reason: model);
        expect(c.largeFileUpload, isTrue, reason: model);
        expect(c.fileSizeLimitFor('image'), 64 * 1024 * 1024);
        expect(c.fileSizeLimitFor('image_inline'), 32 * 1024 * 1024);
        expect(c.fileSizeLimitFor('pdf'), isNull);
      }
    });

    test('DeepSeek Pro 与未知 Flash 后缀不误开图片 / PDF', () {
      for (final model in [
        'deepseek-v4-pro',
        'deepseek-flash-custom',
        'deepseek-v4-flash-preview',
        'custom-model',
      ]) {
        expect(ModelCapabilities.isDeepSeekVisionModel(model), isFalse);
        final c = ModelCapabilities.heuristic(model, providerCode: 'deepseek');
        expect(c.image, isFalse, reason: model);
        expect(c.pdf, isFalse, reason: model);
        expect(c.largeFileUpload, isFalse, reason: model);
      }
    });

    test('gpt-4o：原生 PDF（Chat Completions file part），上限 32MB', () {
      final c = ModelCapabilities.heuristic('gpt-4o', providerCode: 'openai');
      expect(c.pdf, isTrue);
      expect(c.fileSizeLimitFor('pdf'), 32 * 1024 * 1024);
    });

    test('gpt-4-turbo：有图片无原生 PDF（上一代 vision）', () {
      final c = ModelCapabilities.heuristic('gpt-4-turbo');
      expect(c.image, isTrue);
      expect(c.pdf, isFalse);
    });

    test('claude-3-5-sonnet：图片 + 工具 + PDF，不强制思考', () {
      final c = ModelCapabilities.heuristic('claude-3-5-sonnet-20240620');
      expect(c.image, isTrue);
      expect(c.tool, isTrue);
      expect(c.pdf, isTrue);
      expect(c.reasoning, isFalse);
    });

    test('claude-3-7-sonnet / claude-sonnet-4：带扩展思考', () {
      expect(ModelCapabilities.heuristic('claude-3-7-sonnet').reasoning, isTrue);
      expect(
          ModelCapabilities.heuristic('claude-sonnet-4-20250514').reasoning,
          isTrue);
    });

    test('gemini-1.5-pro：图片 + 工具 + PDF', () {
      final c = ModelCapabilities.heuristic('gemini-1.5-pro');
      expect(c.image, isTrue);
      expect(c.tool, isTrue);
      expect(c.pdf, isTrue);
    });

    test('未知模型：一律保守关闭（none）', () {
      final c = ModelCapabilities.heuristic('some-random-model-xyz');
      expect(c.image, isFalse);
      expect(c.pdf, isFalse);
      expect(c.tool, isFalse);
      expect(c.reasoning, isFalse);
    });
  });

  group('ChatService 暴露 capabilities（统一来源，切换即变）', () {
    test('本地 OpenAI + gpt-4o：image=true（图片入口可开）', () {
      final caps =
          ChatService.from(localSettings('openai', 'gpt-4o'))
              .capabilities;
      expect(caps.image, isTrue);
    });

    test('本地 OpenAI + gpt-3.5-turbo：image=false（图片入口关）', () {
      final caps =
          ChatService.from(localSettings('openai', 'gpt-3.5-turbo'))
              .capabilities;
      expect(caps.image, isFalse);
    });

    test('本地 DeepSeek + deepseek-reasoner：reasoning=true，tool=false', () {
      final caps = ChatService.from(
              localSettings('deepseek', 'deepseek-reasoner'))
          .capabilities;
      expect(caps.reasoning, isTrue);
      expect(caps.tool, isFalse);
    });

    test('本地与后端 DeepSeek Flash 都启用图片入口并保留 PDF 文本降级', () {
      for (final settings in [
        localSettings('deepseek', 'deepseek-flash'),
        backendSettings('deepseek-flash'),
      ]) {
        final caps = ChatService.from(settings).capabilities;
        expect(caps.image, isTrue);
        expect(caps.reasoning, isTrue);
        expect(caps.pdf, isFalse);
        expect(caps.largeFileUpload, isTrue);
        expect(caps, ChatService.capabilitiesFor(settings));
      }
    });

    test('后端模式 + gpt-4o：按 modelId 反查也得到 image=true', () {
      final caps = ChatService.from(backendSettings('gpt-4o')).capabilities;
      expect(caps.image, isTrue);
    });

    test('切换模型即改变能力：UI 只读 capabilities 无需分支', () {
      final visionCaps =
          ChatService.from(localSettings('openai', 'gpt-4o'))
              .capabilities;
      final textCaps =
          ChatService.from(localSettings('openai', 'gpt-3.5-turbo'))
              .capabilities;
      expect(visionCaps.image, isTrue);
      expect(textCaps.image, isFalse);
    });

    test('ChatService.capabilities 与静态 capabilitiesFor 同源（UI 与服务一致）', () {
      final viaService =
          ChatService.from(localSettings('openai', 'gpt-4o'))
              .capabilities;
      final viaResolver =
          ModelCatalog.capabilitiesFor('gpt-4o', providerCode: 'openai');
      expect(viaService.image, viaResolver.image);
      expect(viaService.tool, viaResolver.tool);
      expect(viaService.reasoning, viaResolver.reasoning);
      expect(viaService.pdf, viaResolver.pdf);
    });
  });

  group('阶段三遗留 2：providerCode 派生规则收口到 ChatService', () {
    test('ChatService.from(s).capabilities == ChatService.capabilitiesFor(s)（防回归）', () {
      final cases = [
        localSettings('openai', 'gpt-4o'),
        localSettings('openai', 'gpt-3.5-turbo'),
        localSettings('deepseek', 'deepseek-reasoner'),
        backendSettings('gpt-4o'),
        backendSettings('deepseek-chat'),
      ];
      for (final s in cases) {
        expect(ChatService.from(s).capabilities,
            equals(ChatService.capabilitiesFor(s)),
            reason: '同一 AISettings 两条路径必须同源: ${s.effectiveModel}');
      }
    });

    test('providerCodeFor：local 用服务商 code，backend 不传', () {
      expect(
          ChatService.providerCodeFor(
              localSettings('openai', 'gpt-4o')),
          'openai');
      expect(
          ChatService.providerCodeFor(
              localSettings('deepseek', 'deepseek-chat')),
          'deepseek');
      expect(ChatService.providerCodeFor(backendSettings('gpt-4o')), isNull);
    });
  });

  group('ModelCatalog.capabilitiesFor 合并远程 supportsVision', () {
    test('本地兜底清单提供 Flash 图片模型', () {
      final option = ModelCatalog.deepseek
          .singleWhere((model) => model.id == 'deepseek-flash');
      expect(option.supportsVision, isTrue);
      expect(option.supportsTool, isTrue);
      expect(option.supportsReasoning, isTrue);
      expect(option.supportsPdf, isFalse);
    });

    test('远程 Flash 全 false 不会关闭图片，也不会打开 PDF', () {
      ModelCatalog.applyRemote({
        'models': [
          {
            'modelId': 'deepseek-flash',
            'displayName': 'DeepSeek Flash',
            'providerCode': 'deepseek',
            'supportsVision': false,
            'supportsTool': false,
            'supportsReasoning': false,
            'supportsPdf': false,
          },
        ],
      });
      final caps = ModelCatalog.capabilitiesFor('deepseek-flash');
      expect(caps.image, isTrue);
      expect(caps.tool, isTrue);
      expect(caps.reasoning, isTrue);
      expect(caps.pdf, isFalse);
      expect(caps.largeFileUpload, isTrue);
    });

    test('远程清单标了 supportsVision=true 的自定义模型 -> image 被强制打开', () {
      // 该 id 在启发式里命中不了任何家族（基线 image=false），
      // 唯有远程清单的 supportsVision 能把 image 打开 —— 验证合并逻辑。
      ModelCatalog.applyRemote({
        'models': [
          {
            'modelId': 'acme-vision-001',
            'displayName': 'Acme Vision',
            'description': '第三方多模态',
            'providerCode': 'acme',
            'supportsVision': true,
          },
        ],
      });
      final caps = ModelCatalog.capabilitiesFor('acme-vision-001');
      expect(caps.image, isTrue, reason: '远程 supportsVision 覆盖启发式');
    });
  });

  group('遗留项 1：后端能力位下发 + 四位加法覆盖', () {
    test('远程四个能力位都能各自把启发式判不出的位强制打开', () {
      // 自定义命名（启发式命中不了任何家族，基线全 false），
      // 唯有 catalog 显式下发能把对应位打开，且彼此独立。
      ModelCatalog.applyRemote({
        'models': [
          {
            'modelId': 'acme-tool-x',
            'displayName': 'Acme Tool',
            'providerCode': 'acme',
            'supportsTool': true,
          },
          {
            'modelId': 'acme-reason-x',
            'displayName': 'Acme Reason',
            'providerCode': 'acme',
            'supportsReasoning': true,
          },
          {
            'modelId': 'acme-pdf-x',
            'displayName': 'Acme PDF',
            'providerCode': 'acme',
            'supportsPdf': true,
          },
        ],
      });

      final tool = ModelCatalog.capabilitiesFor('acme-tool-x');
      expect(tool.tool, isTrue, reason: 'supportsTool 强制打开 tool 位');
      expect(tool.image, isFalse);
      expect(tool.reasoning, isFalse);
      expect(tool.pdf, isFalse);

      expect(ModelCatalog.capabilitiesFor('acme-reason-x').reasoning, isTrue);
      expect(ModelCatalog.capabilitiesFor('acme-pdf-x').pdf, isTrue);
    });

    test('加法覆盖：catalog 全 false 不会关掉启发式已识别的能力', () {
      // gpt-4o 启发式基线为 image+tool+pdf；即便 catalog 把四位全标 false，
      // 合并也只「加位」不「减位」，避免迁移后存量模型丢能力。
      ModelCatalog.applyRemote({
        'models': [
          {
            'modelId': 'gpt-4o',
            'displayName': 'GPT-4o',
            'providerCode': 'openai',
            'supportsVision': false,
            'supportsTool': false,
            'supportsReasoning': false,
            'supportsPdf': false,
          },
        ],
      });
      final caps = ModelCatalog.capabilitiesFor('gpt-4o', providerCode: 'openai');
      expect(caps.image, isTrue, reason: 'catalog false 不应关掉启发式 image');
      expect(caps.tool, isTrue);
      expect(caps.pdf, isTrue);
    });
  });
}
