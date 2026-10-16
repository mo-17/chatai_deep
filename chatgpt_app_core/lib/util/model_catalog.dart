import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';

/// 常用模型清单，UI 下拉用。用户也可点「自定义」手填，
/// 不在清单里的模型不会被拒绝——String 字段直传上游。
///
/// 启动时优先读本地缓存（上次从后端拉取的清单），
/// 异步拉取最新清单覆盖内存；失败/未登录则用硬编码兜底。
class ModelCatalog {
  /// 目录展示单独通知，不把缓存或加载状态当作执行许可。
  static final displayChanges = ValueNotifier<int>(0);
  static AiCatalogIdentity? _displayIdentity;
  static CatalogDisplayStatus _displayStatus = CatalogDisplayStatus.initial;
  static List<ModelOption> _displayModels = const [];
  static bool _displayHasSnapshot = false;
  static Future<void>? _inFlight;
  static AiCatalogIdentity? _inFlightIdentity;

  /// 普通运行的执行撤权通知；不改变模型能力的加法覆盖规则。
  static final executionChanges = ValueNotifier<int>(0);
  static AiCatalogIdentity? _executionIdentity;
  static Set<String>? _executionModels;
  static Set<String>? _executionPairs;
  static List<ModelOption>? _backendExecutionOptions;
  static int _refreshRevision = 0;

  /// 未取得当前身份目录时继续沿旧代理契约，由服务端核模型；UI 缓存不授予或撤销许可。
  static bool backendProfileAvailable(String id,
      {required String account, String? providerCode}) {
    final identity = _executionIdentity;
    return identity == null ||
        !identity.current ||
        identity.account != account ||
        _executionModels == null ||
        (providerCode == null
            ? _executionModels!.contains(id)
            : _executionPairs!.contains(jsonEncode([providerCode, id])));
  }

  @visibleForTesting
  static void resetExecutionForTest() {
    AiCatalogIdentity.resetForTest();
    _executionIdentity = null;
    _executionModels = null;
    _executionPairs = null;
    _backendExecutionOptions = null;
    _refreshRevision++;
    _displayIdentity = null;
    _displayModels = const [];
    _displayHasSnapshot = false;
    _displayStatus = CatalogDisplayStatus.initial;
    _inFlight = null;
    _inFlightIdentity = null;
  }

  // 硬编码兜底，永远不删
  static const _hardcodedOpenai = <ModelOption>[
    ModelOption('gpt-3.5-turbo', '便宜快，适合日常对话'),
    ModelOption('gpt-4o-mini', '小模型，性价比高（推荐）', supportsVision: true),
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

  /// 仅设置页使用的当前身份快照；旧账号/地址数据不混入当前下拉。
  static CatalogDisplaySnapshot get displaySnapshot {
    final identity = _displayIdentity;
    final current = AiCatalogIdentity.capture();
    final fallback = [
      ..._hardcodedDeepseek.map((m) => m.withPrefix('🧠 DeepSeek · ')),
      ..._hardcodedOpenai.map((m) => m.withPrefix('🤖 OpenAI · ')),
    ];
    if (!current.authenticated) {
      return CatalogDisplaySnapshot(
          CatalogDisplayStatus.notAuthenticated, fallback, false);
    }
    if (identity == null || !identity.current) {
      return CatalogDisplaySnapshot(
          CatalogDisplayStatus.initial, fallback, false);
    }
    return CatalogDisplaySnapshot(_displayStatus,
        _displayHasSnapshot ? _displayModels : fallback, _displayHasSnapshot);
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
  static ModelOption? optionFor(String modelId, {String? providerCode}) {
    final remote = _remoteAll
        .where((o) =>
            o.id == modelId &&
            (providerCode == null || o.providerCode == providerCode))
        .toList();
    if (remote.isNotEmpty) return remote.length == 1 ? remote.single : null;
    final local = [..._openai, ..._deepseek]
        .where((o) =>
            o.id == modelId &&
            (providerCode == null ||
                o.providerCode == null ||
                o.providerCode == providerCode))
        .toList();
    return local.length == 1 ? local.single : null;
  }

  /// 后端仅从当前身份成功快照叠加 exact pair；缓存/未解析 legacy 不借位。
  static ModelCapabilities backendCapabilitiesFor(String modelId,
      {String? providerCode, String? accountHash, String? origin}) {
    final caps =
        ModelCapabilities.heuristic(modelId, providerCode: providerCode);
    final identity = _executionIdentity;
    if (providerCode == null ||
        identity == null ||
        !identity.current ||
        accountHash != identity.account ||
        origin != identity.endpoint.origin ||
        _backendExecutionOptions == null) {
      return caps;
    }
    final options = _backendExecutionOptions!
        .where((o) => o.id == modelId && o.providerCode == providerCode)
        .toList();
    if (options.length != 1) return caps;
    final option = options.single;
    return caps.copyWith(
        image: caps.image || option.supportsVision,
        tool: caps.tool || option.supportsTool,
        reasoning: caps.reasoning || option.supportsReasoning,
        pdf: caps.pdf || option.supportsPdf);
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
    final option = optionFor(modelId, providerCode: providerCode);
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
    // 无账号/地址归属的旧缓存只供既有兼容用途，不能认作当前 UI 清单。
    if (AiCatalogDao.loadFromCache(scopedOnly: true) == null) return;
    _displayIdentity = AiCatalogIdentity.capture();
    _displayModels = List.unmodifiable(_remoteAll);
    _displayHasSnapshot = true;
    _displayStatus = CatalogDisplayStatus.cached;
    displayChanges.value++;
  }

  /// 默认仍建立新 revision；页面可加入同身份在途 GET，避免重复请求。
  static Future<void> refreshFromBackend({bool joinOngoing = false}) {
    final identity = AiCatalogIdentity.capture();
    final active = _inFlight;
    if (joinOngoing &&
        active != null &&
        _inFlightIdentity?.sameAs(identity) == true &&
        _inFlightIdentity!.current) {
      return active;
    }
    final revision = ++_refreshRevision;
    late final Future<void> task;
    task = _refresh(identity, revision).whenComplete(() {
      if (identical(_inFlight, task)) {
        _inFlight = null;
        _inFlightIdentity = null;
      }
    });
    _inFlight = task;
    _inFlightIdentity = identity;
    return task;
  }

  static Future<void> _refresh(AiCatalogIdentity identity, int revision) async {
    bool current() => identity.current && revision == _refreshRevision;
    if (_displayIdentity?.sameAs(identity) != true) {
      _displayModels = const [];
      _displayHasSnapshot = false;
    }
    _displayIdentity = identity;
    _displayStatus = CatalogDisplayStatus.loading;
    displayChanges.value++;
    final result = await AiCatalogDao.fetchRemoteResult(
        identity: identity, stillCurrent: current);
    if (!current()) return;
    final data = result.data;
    if (result.status != CatalogFetchStatus.success || data == null) {
      _displayStatus = switch (result.status) {
        CatalogFetchStatus.notAuthenticated =>
          CatalogDisplayStatus.notAuthenticated,
        CatalogFetchStatus.forbidden => CatalogDisplayStatus.forbidden,
        CatalogFetchStatus.timeout => CatalogDisplayStatus.timeout,
        CatalogFetchStatus.invalid => CatalogDisplayStatus.invalid,
        _ => CatalogDisplayStatus.failed,
      };
      displayChanges.value++;
      return;
    }
    final models = data['models'];
    if (!_validBackendRows(models)) {
      _displayStatus = CatalogDisplayStatus.invalid;
      displayChanges.value++;
      return;
    }
    applyRemote(data);
    if (!current()) return;
    _executionIdentity = identity;
    _executionModels = {
      for (final model in models as List) model['modelId'] as String
    };
    _executionPairs = {
      for (final model in models)
        jsonEncode([model['providerCode'], model['modelId']])
    };
    _backendExecutionOptions = List.unmodifiable(_remoteAll);
    executionChanges.value++;
    if (!current()) return;
    _displayModels = List.unmodifiable(_remoteAll);
    _displayHasSnapshot = true;
    _displayStatus = models.isEmpty
        ? CatalogDisplayStatus.empty
        : CatalogDisplayStatus.success;
    displayChanges.value++;
  }

  static bool _validBackendRows(Object? raw) {
    if (raw is! List) return false;
    final seen = <String>{};
    for (final row in raw) {
      if (row is! Map ||
          row['modelId'] is! String ||
          (row['modelId'] as String).trim().isEmpty ||
          row['providerCode'] is! String ||
          (row['providerCode'] as String).trim().isEmpty) {
        return false;
      }
      for (final key in ['description', 'displayName']) {
        if (row[key] != null && row[key] is! String) return false;
      }
      for (final key in [
        'supportsVision',
        'supportsTool',
        'supportsReasoning',
        'supportsPdf'
      ]) {
        if (row[key] != null && row[key] is! bool) return false;
      }
      if (!seen.add(jsonEncode([row['providerCode'], row['modelId']]))) {
        return false;
      }
    }
    return true;
  }

  // visibleForTesting
  static void applyRemote(Map<String, dynamic> data) {
    final models = data['models'] as List?;
    if (models == null) return;
    if (models.isEmpty) {
      // 明确成功取得空目录意味着后端没有可用模型；UI 本地兜底照旧，
      // 但已有运行不能把它误认为网络失败并保留执行许可。
      _remoteAll = const [];
      _remoteLoaded = true;
      return;
    }

    final providerNames = <String, String>{};
    final providers = data['providers'];
    if (providers is List) {
      for (final p in providers) {
        if (p is Map && p['code'] is String && p['displayName'] is String) {
          providerNames[p['code'] as String] = p['displayName'] as String;
        }
      }
    }
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
        providerDisplayName: providerNames[code],
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

enum CatalogDisplayStatus {
  initial,
  cached,
  loading,
  success,
  empty,
  notAuthenticated,
  forbidden,
  timeout,
  failed,
  invalid,
}

class CatalogDisplaySnapshot {
  final CatalogDisplayStatus status;
  final List<ModelOption> options;
  final bool hasSnapshot;
  const CatalogDisplaySnapshot(this.status, this.options, this.hasSnapshot);
  bool get loading => status == CatalogDisplayStatus.loading;
  String get message {
    final label = switch (status) {
      CatalogDisplayStatus.initial => '尚未获取后端模型目录',
      CatalogDisplayStatus.cached => '已缓存的模型清单，请刷新核对',
      CatalogDisplayStatus.loading => '正在获取后端模型清单',
      CatalogDisplayStatus.success => '清单来自后端',
      CatalogDisplayStatus.empty => '服务器当前没有可用模型',
      CatalogDisplayStatus.notAuthenticated => '请登录后获取后端模型目录',
      CatalogDisplayStatus.forbidden => '服务器未开放模型目录，请联系管理员',
      CatalogDisplayStatus.timeout => '获取模型目录超时，请重试',
      CatalogDisplayStatus.failed => '获取模型目录失败，请重试',
      CatalogDisplayStatus.invalid => '服务器模型目录格式无效，请重试',
    };
    if ([
      CatalogDisplayStatus.success,
      CatalogDisplayStatus.empty,
      CatalogDisplayStatus.notAuthenticated
    ].contains(status)) {
      return label;
    }
    return '$label · ${hasSnapshot ? "当前显示上次清单" : "当前显示本地兜底清单"}';
  }
}

class ModelOption {
  final String id;
  final String? hint;
  final String? displayLabel;
  final String? providerCode;
  final String? providerDisplayName;
  String get backendLabel =>
      '${providerDisplayName ?? providerCode ?? "未知服务商"} ($providerCode) · $id';
  String get pairKey => jsonEncode([providerCode, id]);

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
    this.providerDisplayName,
    this.supportsVision = false,
    this.supportsTool = false,
    this.supportsReasoning = false,
    this.supportsPdf = false,
  });

  ModelOption withPrefix(String prefix) => ModelOption(id, hint,
      displayLabel: '$prefix$id',
      providerCode: providerCode,
      providerDisplayName: providerDisplayName,
      supportsVision: supportsVision,
      supportsTool: supportsTool,
      supportsReasoning: supportsReasoning,
      supportsPdf: supportsPdf);
}
