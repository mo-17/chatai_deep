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
    ModelOption('gpt-4o-mini', '小模型，性价比高（推荐）'),
    ModelOption('gpt-4o', '主力模型，多模态'),
    ModelOption('gpt-4-turbo', '上一代旗舰'),
    ModelOption('o1-mini', '推理模型（小）'),
    ModelOption('o1', '推理模型（强）'),
  ];

  static const _hardcodedDeepseek = <ModelOption>[
    ModelOption('deepseek-chat', 'V3 对话模型（推荐）'),
    ModelOption('deepseek-reasoner', 'R1 推理模型，会输出思考过程'),
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

  /// 同步从 HiCache 读取，覆盖内存清单
  static void loadFromCache() {
    final data = AiCatalogDao.loadFromCache();
    if (data == null) return;
    _applyRemote(data);
  }

  /// 异步从后端拉取，失败不报错、不弹窗
  static Future<void> refreshFromBackend() async {
    final data = await AiCatalogDao.fetchRemote();
    if (data == null) return;
    _applyRemote(data);
  }

  static void _applyRemote(Map<String, dynamic> data) {
    final models = data['models'] as List?;
    if (models == null || models.isEmpty) return;

    // 按 providerCode 分组
    final openaiList = <ModelOption>[];
    final deepseekList = <ModelOption>[];
    final allList = <ModelOption>[];

    for (final m in models) {
      final code = m['providerCode'] as String? ?? '';
      final option = ModelOption(
        m['modelId'] as String,
        m['description'] as String?,
        displayLabel: '${m['displayName']} · ${m['modelId']}',
        providerCode: code,
      );
      allList.add(option);

      if (code == 'openai') {
        openaiList.add(ModelOption(
          m['modelId'] as String,
          m['description'] as String?,
          displayLabel: m['displayName'] as String?,
        ));
      } else if (code == 'deepseek') {
        deepseekList.add(ModelOption(
          m['modelId'] as String,
          m['description'] as String?,
          displayLabel: m['displayName'] as String?,
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

  const ModelOption(this.id, this.hint, {this.displayLabel, this.providerCode});

  ModelOption withPrefix(String prefix) =>
      ModelOption(id, hint, displayLabel: '$prefix$id');
}
