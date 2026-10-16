import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';

enum WorkflowState {
  queued,
  running,
  paused,
  waitingConfirmation,
  budgetExhausted,
  needsConfiguration,
  failed,
  complete,
  cancelled,
}

enum WorkflowRole { analysis, writing, review }

enum WorkflowAttemptState { dispatched, succeeded, failed, unknown }

String workflowHash(String text) =>
    sha256.convert(utf8.encode(text)).toString();

/// 只保存配置引用，禁止把客户端、端点、密钥或 AISettings 放进执行记录。
class WorkflowModelProfile {
  final String mode;
  final String providerId;
  final String modelId;
  final BackendSelection? backendSelection;
  const WorkflowModelProfile(this.mode, this.providerId, this.modelId)
      : backendSelection = null;
  WorkflowModelProfile.backend(BackendSelection selection)
      : mode = 'backend',
        providerId = 'backend',
        modelId = selection.modelId ?? '',
        backendSelection = selection {
    if (!selection.isPair) throw const FormatException('协作后端模型选择无效');
  }
  String? get providerCode => backendSelection?.providerCode;
  String get selectionKey => jsonEncode(backendSelection == null
      ? [mode, providerId, modelId]
      : [mode, backendSelection!.pairKey]);
  Map<String, dynamic> toJson() => backendSelection != null
      ? {
          'version': 1,
          'mode': 'backend',
          'backendSelection': backendSelection!.toSafeJson(),
        }
      : {
          'mode': mode,
          'providerId': providerId,
          'modelId': modelId,
        };
  factory WorkflowModelProfile.fromJson(Map<String, dynamic> value) {
    if (value.containsKey('version') || value.containsKey('backendSelection')) {
      if (value.length != 3 ||
          value['version'] != 1 ||
          value['mode'] != 'backend' ||
          !value.keys.every({'version', 'mode', 'backendSelection'}.contains)) {
        throw const FormatException('协作后端模型配置版本或字段无效');
      }
      final selection = BackendSelection.fromStorage(value['backendSelection']);
      if (selection == null || !selection.isPair) {
        throw const FormatException('协作后端模型选择无效');
      }
      return WorkflowModelProfile.backend(selection);
    }
    if (value.keys
            .toSet()
            .difference({'mode', 'providerId', 'modelId'}).isNotEmpty ||
        !const ['local', 'backend'].contains(value['mode']) ||
        value['providerId'] is! String ||
        value['modelId'] is! String ||
        (value['providerId'] as String).isEmpty ||
        (value['providerId'] as String).length > 200 ||
        (value['modelId'] as String).trim().isEmpty ||
        (value['modelId'] as String).length > 200) {
      throw const FormatException('模型配置引用无效');
    }
    return WorkflowModelProfile(
        value['mode'], value['providerId'], value['modelId']);
  }
}

class WorkflowInputRef {
  final int fileId, revision;
  final String fileHash, textHash;
  const WorkflowInputRef(
      this.fileId, this.revision, this.fileHash, this.textHash);
  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'revision': revision,
        'fileHash': fileHash,
        'textHash': textHash,
      };
  factory WorkflowInputRef.fromJson(Map<String, dynamic> value) {
    if (value.length != 4 ||
        value['fileId'] is! int ||
        value['revision'] is! int ||
        value['fileId'] <= 0 ||
        value['revision'] <= 0 ||
        !_hash(value['fileHash']) ||
        !_hash(value['textHash'])) {
      throw const FormatException('输入版本引用无效');
    }
    return WorkflowInputRef(value['fileId'], value['revision'],
        value['fileHash'], value['textHash']);
  }
}

bool _hash(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

/// 32000 是本地累计估算限额；不会被称为供应商账单硬上限。
class WorkflowBudget {
  static const outputTokens = 2048;
  static const outputCharacters = 12000;
  static const toolRoundsPerStep = 2;
  final int maxDispatches, estimatedTokens, durationMs;
  const WorkflowBudget(
      {this.maxDispatches = 8,
      this.estimatedTokens = 32000,
      this.durationMs = 600000});
  void validate() {
    if (maxDispatches < 1 ||
        maxDispatches > 64 ||
        estimatedTokens < outputTokens ||
        estimatedTokens > 256000 ||
        durationMs < 1 ||
        durationMs > 3600000) {
      throw const FormatException('任务预算超出本机安全范围');
    }
  }
}

class AgentWorkflow {
  final Map<String, Object?> _row;
  AgentWorkflow(Map<String, Object?> row) : _row = Map.unmodifiable(row);
  String get id => _row['parentId'] as String;
  int get cid => _row['cid'] as int;
  int get revision => _row['revision'] as int;
  WorkflowState get state =>
      WorkflowState.values.byName(_row['state'] as String);
  String? get reason => _row['reason'] as String?;
  String? get leaseId => _row['leaseId'] as String?;
  String get task => _row['task'] as String;
  String get publicationId => _row['publicationId'] as String;
  int get dispatches => _row['dispatches'] as int;
  int get reservedTokens => _row['reservedTokens'] as int;
  int get reworks => _row['reworks'] as int;
  int get maxDispatches => _row['maxDispatches'] as int;
  int get estimatedTokenLimit => _row['estimatedTokenLimit'] as int;
  int? get deadlineAt => _row['deadlineAt'] as int?;
  bool get usageUnknown => _row['usageUnknown'] == 1;
  int get actualInputTokens => _row['actualInputTokens'] as int;
  int get actualOutputTokens => _row['actualOutputTokens'] as int;
  double? get estimatedCost => (_row['estimatedCost'] as num?)?.toDouble();
  bool get backgroundEnabled => _row['backgroundEnabled'] == 1;
  Map<String, dynamic> get acceptance =>
      (jsonDecode(_row['acceptanceJson'] as String? ?? '{}') as Map)
          .cast<String, dynamic>();
  Map<String, dynamic>? get verification => _row['verificationJson'] == null
      ? null
      : (jsonDecode(_row['verificationJson'] as String) as Map)
          .cast<String, dynamic>();
  List<WorkflowInputRef> get inputs => List.unmodifiable([
        for (final item in jsonDecode(_row['inputs'] as String) as List)
          WorkflowInputRef.fromJson((item as Map).cast<String, dynamic>())
      ]);
  Map<String, Object?> toRow() => Map.from(_row);
}

class WorkflowStep {
  final Map<String, Object?> _row;
  WorkflowStep(Map<String, Object?> row) : _row = Map.unmodifiable(row);
  String get id => _row['stepId'] as String;
  String get parentId => _row['parentId'] as String;
  int get revision => _row['revision'] as int;
  WorkflowRole get role => WorkflowRole.values.byName(_row['role'] as String);
  WorkflowState get state =>
      WorkflowState.values.byName(_row['state'] as String);
  String get result => _row['result'] as String;
  int get toolRounds => _row['toolRounds'] as int;
  int get cycles => _row['cycles'] as int;
  WorkflowModelProfile get profile => WorkflowModelProfile.fromJson(
      (jsonDecode(_row['profile'] as String) as Map).cast<String, dynamic>());
  List<String> get tools =>
      (jsonDecode(_row['tools'] as String) as List).cast<String>();
  Map<String, dynamic>? get checkpoint => _row['checkpoint'] == null
      ? null
      : (jsonDecode(_row['checkpoint'] as String) as Map)
          .cast<String, dynamic>();
  Map<String, Object?> toRow() => Map.from(_row);
}

class WorkflowFence {
  final String parentId, leaseId;
  final int revision;
  const WorkflowFence(this.parentId, this.leaseId, this.revision);
  factory WorkflowFence.of(AgentWorkflow workflow) =>
      WorkflowFence(workflow.id, workflow.leaseId!, workflow.revision);
}

class WorkflowReservation {
  final AgentWorkflow workflow;
  final String? attemptId;
  const WorkflowReservation(this.workflow, this.attemptId);
  bool get allowed => attemptId != null;
}

class WorkflowStale implements Exception {
  final String reason;
  const WorkflowStale([this.reason = '任务身份、输入版本或运行状态已变化']);
  @override
  String toString() => reason;
}
