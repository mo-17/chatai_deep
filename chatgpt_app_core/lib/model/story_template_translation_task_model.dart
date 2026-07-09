class StoryTemplateTranslationTaskStatus {
  static const queued = 'queued';
  static const running = 'running';
  static const retryable = 'retryable';
  static const completed = 'completed';
  static const failed = 'failed';
  static const cancelled = 'cancelled';

  static bool canRetry(String status) =>
      status == retryable || status == failed || status == cancelled;

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
  String partialPayload;
  int createdAt;
  int updatedAt;

  StoryTemplateTranslationTaskModel({
    this.id,
    this.templateId,
    required this.sourceTitle,
    required this.sourcePayload,
    this.outputTitle = '',
    this.outputTemplateId,
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
    this.partialPayload = '',
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
        partialPayload: json['partialPayload'] as String? ?? '',
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
        'partialPayload': partialPayload,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  bool get canRetry => StoryTemplateTranslationTaskStatus.canRetry(status);
  bool get isRunning => status == StoryTemplateTranslationTaskStatus.running;
  bool get isTerminal =>
      status == StoryTemplateTranslationTaskStatus.completed ||
      status == StoryTemplateTranslationTaskStatus.failed ||
      status == StoryTemplateTranslationTaskStatus.cancelled;

  static int? _intOrNull(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }

  static double _double(Object? value) {
    if (value is num) return value.toDouble().clamp(0, 1).toDouble();
    return (double.tryParse('$value') ?? 0).clamp(0, 1).toDouble();
  }
}
