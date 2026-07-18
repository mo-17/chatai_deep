abstract final class StoryTemplateTranslationTaskKind {
  static const templateCopy = 'templateCopy';
  static const tavernRoomImport = 'tavernRoomImport';
}

abstract final class StoryTemplateTranslationTaskStatus {
  static const queued = 'queued';
  static const running = 'running';
  static const retryable = 'retryable';
  static const completed = 'completed';
  static const needsConfiguration = 'needsConfiguration';
  static const completedWithWarnings = 'completedWithWarnings';
  static const failed = 'failed';
  static const cancelled = 'cancelled';

  static bool canRetry(String status) =>
      status == retryable || status == failed || status == cancelled;

  static bool isTerminal(String status) =>
      status == completed ||
      status == completedWithWarnings ||
      status == failed ||
      status == cancelled;

  static String labelOf(String status) {
    switch (status) {
      case queued:
        return '等待中';
      case running:
        return '运行中';
      case retryable:
        return '可重试';
      case completed:
        return '已完成';
      case needsConfiguration:
        return '需要配置';
      case completedWithWarnings:
        return '部分翻译完成';
      case failed:
        return '失败';
      case cancelled:
        return '已取消';
      default:
        return '未知状态';
    }
  }
}

/// 酒馆模板中文副本任务。源模板快照与逐角色检查点都保存在本地，避免页面或 App
/// 重启后丢失任务上下文。
class StoryTemplateTranslationTaskModel {
  int? id;
  int? templateId;
  String sourceTitle;
  String sourcePayload;
  String outputTitle;
  int? outputTemplateId;
  String taskKind;
  String requestProfile;
  String chunkPayload;
  int? outputRoomId;
  int checkpointVersion;
  String status;
  double progress;
  String stage;
  String detail;
  String log;
  String error;
  int roleIndex;
  int roleTotal;
  String roleName;
  int fieldIndex;
  int fieldTotal;
  String fieldLabel;
  double fieldProgress;
  String fieldPayload;
  String partialPayload;
  String? leaseOwner;
  int? leaseUntil;
  int attempts;
  int? nextRunAt;
  int createdAt;
  int updatedAt;

  StoryTemplateTranslationTaskModel({
    this.id,
    this.templateId,
    required this.sourceTitle,
    required this.sourcePayload,
    this.outputTitle = '',
    this.outputTemplateId,
    this.taskKind = StoryTemplateTranslationTaskKind.templateCopy,
    this.requestProfile = '',
    this.chunkPayload = '',
    this.outputRoomId,
    this.checkpointVersion = 0,
    this.status = StoryTemplateTranslationTaskStatus.queued,
    this.progress = 0,
    this.stage = '等待生成中文副本',
    this.detail = '',
    this.log = '',
    this.error = '',
    this.roleIndex = 0,
    this.roleTotal = 0,
    this.roleName = '',
    this.fieldIndex = 0,
    this.fieldTotal = 0,
    this.fieldLabel = '',
    this.fieldProgress = 0,
    this.fieldPayload = '',
    this.partialPayload = '',
    this.leaseOwner,
    this.leaseUntil,
    this.attempts = 0,
    this.nextRunAt,
    int? createdAt,
    int? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory StoryTemplateTranslationTaskModel.fromJson(
    Map<String, dynamic> json,
  ) =>
      StoryTemplateTranslationTaskModel(
        id: _intOrNull(json['id']),
        templateId: _intOrNull(json['templateId']),
        sourceTitle: json['sourceTitle'] as String? ?? '未命名酒馆模板',
        sourcePayload: json['sourcePayload'] as String? ?? '{}',
        outputTitle: json['outputTitle'] as String? ?? '',
        outputTemplateId: _intOrNull(json['outputTemplateId']),
        taskKind: _nonBlankString(
          json['taskKind'],
          StoryTemplateTranslationTaskKind.templateCopy,
        ),
        requestProfile: json['requestProfile'] as String? ?? '',
        chunkPayload: json['chunkPayload'] as String? ?? '',
        outputRoomId: _intOrNull(json['outputRoomId']),
        checkpointVersion: _intOrNull(json['checkpointVersion']) ?? 0,
        status: json['status'] as String? ??
            StoryTemplateTranslationTaskStatus.failed,
        progress: _double(json['progress']),
        stage: json['stage'] as String? ?? '',
        detail: json['detail'] as String? ?? '',
        log: json['log'] as String? ?? '',
        error: json['error'] as String? ?? '',
        roleIndex: _intOrNull(json['roleIndex']) ?? 0,
        roleTotal: _intOrNull(json['roleTotal']) ?? 0,
        roleName: json['roleName'] as String? ?? '',
        fieldIndex: _intOrNull(json['fieldIndex']) ?? 0,
        fieldTotal: _intOrNull(json['fieldTotal']) ?? 0,
        fieldLabel: json['fieldLabel'] as String? ?? '',
        fieldProgress: _double(json['fieldProgress']),
        fieldPayload: json['fieldPayload'] as String? ?? '',
        partialPayload: json['partialPayload'] as String? ?? '',
        leaseOwner: json['leaseOwner'] as String?,
        leaseUntil: _intOrNull(json['leaseUntil']),
        attempts: _intOrNull(json['attempts']) ?? 0,
        nextRunAt: _intOrNull(json['nextRunAt']),
        createdAt: _intOrNull(json['createdAt']),
        updatedAt: _intOrNull(json['updatedAt']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'templateId': templateId,
        'sourceTitle': sourceTitle,
        'sourcePayload': sourcePayload,
        'outputTitle': outputTitle,
        'outputTemplateId': outputTemplateId,
        'taskKind': taskKind,
        'requestProfile': requestProfile,
        'chunkPayload': chunkPayload,
        'outputRoomId': outputRoomId,
        'checkpointVersion': checkpointVersion,
        'status': status,
        'progress': progress.clamp(0, 1),
        'stage': stage,
        'detail': detail,
        'log': log,
        'error': error,
        'roleIndex': roleIndex,
        'roleTotal': roleTotal,
        'roleName': roleName,
        'fieldIndex': fieldIndex,
        'fieldTotal': fieldTotal,
        'fieldLabel': fieldLabel,
        'fieldProgress': fieldProgress.clamp(0, 1),
        'fieldPayload': fieldPayload,
        'partialPayload': partialPayload,
        'leaseOwner': leaseOwner,
        'leaseUntil': leaseUntil,
        'attempts': attempts,
        'nextRunAt': nextRunAt,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  bool get canRetry => StoryTemplateTranslationTaskStatus.canRetry(status);
  bool get isRunning => status == StoryTemplateTranslationTaskStatus.running;
  bool get isTerminal => StoryTemplateTranslationTaskStatus.isTerminal(status);

  static String _nonBlankString(Object? value, String fallback) {
    if (value is! String || value.trim().isEmpty) return fallback;
    return value;
  }

  static int? _intOrNull(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }

  static double _double(Object? value) {
    if (value is num) return value.toDouble().clamp(0, 1).toDouble();
    return (double.tryParse('$value') ?? 0).clamp(0, 1).toDouble();
  }
}
