import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';

/// 常用模型清单，UI 下拉用。用户也可点「自定义」手填，
/// 不在清单里的模型不会被拒绝——String 字段直传上游。
///
/// 启动时优先读本地缓存（上次从后端拉取的清单），
/// 异步拉取最新清单覆盖内存；失败/未登录则用硬编码兜底。
class ModelCatalog {
  // 硬编码兜底，永远不删
  static const _hardcodedOpenai = <ModelOption>[
    ModelOption('gpt-3.5-turbo', '便宜快，适合日常对话'),
    ModelOption('gpt-4o-mini', '小模型，性价比高（推荐）',
        supportsVision: true),
    ModelOption('gpt-4o', '主力模型，多模态', supportsVision: true),
    ModelOption('gpt-4-turbo', '上一代旗舰'),
    ModelOption('o1-mini', '推理模型（小）'),
    ModelOption('o1', '推理模型（强）'),
  ];

  static const _hardcodedDeepseek = <ModelOption>[
    ModelOption('deepseek-chat', 'V3 对话模型（推荐）'),
    ModelOption('deepseek-reasoner', 'R1 推理模型，会输出思考过程'),
    ModelOption('deepseek-flash', 'Flash 多模态模型，支持图片与图片文件',
        providerCode: 'deepseek',
        supportsVision: true,
        supportsTool: true,
        supportsReasoning: true),
  ];

  static List<ModelOption> _openai = List.unmodifiable(_hardcodedOpenai);
  static List<ModelOption> _deepseek = List.unmodifiable(_hardcodedDeepseek);
  static List<ModelOption> _remoteAll = const [];
  static bool _remoteLoaded = false;

  static List<ModelOption> get openai => _openai;
  static List<ModelOption> get deepseek => _deepseek;

  /// 远程拉取的完整模型清单（仅 restarted 或从缓存加载后非空）
  static bool get remoteAvailable => _remoteLoaded && _remoteAll.isNotEmpty;

  /// 后端模式下可选模型：优先用远程拉取的清单，兜底合并本地
  static List<ModelOption> backendAll() {
    if (remoteAvailable) {
      return _remoteAll;
    }
    return [
      ..._deepseek.map((m) => m.withPrefix('🧠 DeepSeek · ')),
      ..._openai.map((m) => m.withPrefix('🤖 OpenAI · ')),
    ];
  }

  /// 根据 id 查找 label，找不到返回 id 本身
  static String labelFor(List<ModelOption> options, String id) {
    for (final o in options) {
      if (o.id == id) return o.displayLabel ?? id;
    }
    return id;
  }

  /// 跨清单按 modelId 查 [ModelOption]（远程优先，再本地兜底），找不到返回 null。
  /// 供能力探测拿 providerCode / supportsVision，不影响下拉展示。
  static ModelOption? optionFor(String modelId) {
    for (final o in _remoteAll) {
      if (o.id == modelId) return o;
    }
    for (final o in _openai) {
      if (o.id == modelId) return o;
    }
    for (final o in _deepseek) {
      if (o.id == modelId) return o;
    }
    return null;
  }

  /// 阶段三统一能力探测入口：把「按前缀/家族启发式」与「远程清单显式下发的
  /// 能力位」合并成一个 [ModelCapabilities]。UI 与 ChatService 都只调这一个
  /// 方法，从而「切换模型/厂商无需改 UI 与分发层」。
  ///
  /// - [providerCode] 已知时直接用（本地模式传 'openai'/'deepseek'）；
  ///   后端模式留空，则从清单里反查该模型的 providerCode。
  /// - 合并语义是**加法覆盖**：远程清单的 `supportsVision/Tool/Reasoning/Pdf`
  ///   为 true 时强制打开对应位（启发式判不出的非常规命名模型由管理后台兜底），
  ///   但**不会因 false 而关位**——因为列默认 false 无法区分「显式关闭」与「未标注」，
  ///   故以启发式为下限，避免迁移后存量模型丢能力。
  static ModelCapabilities capabilitiesFor(String modelId,
      {String? providerCode}) {
    final option = optionFor(modelId);
    final code = providerCode ?? option?.providerCode;
    var caps = ModelCapabilities.heuristic(modelId, providerCode: code);
    if (option == null) return caps;
    if (option.supportsVision && !caps.image) caps = caps.copyWith(image: true);
    if (option.supportsTool && !caps.tool) caps = caps.copyWith(tool: true);
    if (option.supportsReasoning && !caps.reasoning) {
      caps = caps.copyWith(reasoning: true);
    }
    if (option.supportsPdf && !caps.pdf) caps = caps.copyWith(pdf: true);
    return caps;
  }

  /// 同步从 HiCache 读取，覆盖内存清单
  static void loadFromCache() {
    final data = AiCatalogDao.loadFromCache();
    if (data == null) return;
    applyRemote(data);
  }

  /// 异步从后端拉取，失败不报错、不弹窗
  static Future<void> refreshFromBackend() async {
    final data = await AiCatalogDao.fetchRemote();
    if (data == null) return;
    applyRemote(data);
  }

  // visibleForTesting
  static void applyRemote(Map<String, dynamic> data) {
    final models = data['models'] as List?;
    if (models == null || models.isEmpty) return;

    // 按 providerCode 分组
    final openaiList = <ModelOption>[];
    final deepseekList = <ModelOption>[];
    final allList = <ModelOption>[];

    for (final m in models) {
      final code = m['providerCode'] as String? ?? '';
      final supportsVision = m['supportsVision'] as bool? ?? false;
      final supportsTool = m['supportsTool'] as bool? ?? false;
      final supportsReasoning = m['supportsReasoning'] as bool? ?? false;
      final supportsPdf = m['supportsPdf'] as bool? ?? false;
      final option = ModelOption(
        m['modelId'] as String,
        m['description'] as String?,
        displayLabel: '${m['displayName']} · ${m['modelId']}',
        providerCode: code,
        supportsVision: supportsVision,
        supportsTool: supportsTool,
        supportsReasoning: supportsReasoning,
        supportsPdf: supportsPdf,
      );
      allList.add(option);

      if (code == 'openai') {
        openaiList.add(ModelOption(
          m['modelId'] as String,
          m['description'] as String?,
          displayLabel: m['displayName'] as String?,
          providerCode: code,
          supportsVision: supportsVision,
          supportsTool: supportsTool,
          supportsReasoning: supportsReasoning,
          supportsPdf: supportsPdf,
        ));
      } else if (code == 'deepseek') {
        deepseekList.add(ModelOption(
          m['modelId'] as String,
          m['description'] as String?,
          displayLabel: m['displayName'] as String?,
          providerCode: code,
          supportsVision: supportsVision,
          supportsTool: supportsTool,
          supportsReasoning: supportsReasoning,
          supportsPdf: supportsPdf,
        ));
      }
    }

    if (openaiList.isNotEmpty) _openai = openaiList;
    if (deepseekList.isNotEmpty) _deepseek = deepseekList;
    if (allList.isNotEmpty) {
      _remoteAll = allList;
      _remoteLoaded = true;
    }
  }
}

class ModelOption {
  final String id;
  final String? hint;
  final String? displayLabel;
  final String? providerCode;

  // 后端 catalog 下发的能力位（默认 false）。与家族启发式做「加法覆盖」，
  // 详见 [ModelCatalog.capabilitiesFor]。
  final bool supportsVision;
  final bool supportsTool;
  final bool supportsReasoning;
  final bool supportsPdf;

  const ModelOption(
    this.id,
    this.hint, {
    this.displayLabel,
    this.providerCode,
    this.supportsVision = false,
    this.supportsTool = false,
    this.supportsReasoning = false,
    this.supportsPdf = false,
  });

  ModelOption withPrefix(String prefix) => ModelOption(id, hint,
      displayLabel: '$prefix$id',
      providerCode: providerCode,
      supportsVision: supportsVision,
      supportsTool: supportsTool,
      supportsReasoning: supportsReasoning,
      supportsPdf: supportsPdf);
}
