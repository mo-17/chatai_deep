class UsageRecord {
  int? id;
  final String modelId;
  final String? providerId;
  final int? projectId;
  final int? cid;
  final int promptTokens;
  final int cachedPromptTokens;
  final int completionTokens;
  final double cost;
  final bool estimated;
  final int createdAt;

  UsageRecord({
    this.id,
    required this.modelId,
    this.providerId,
    this.projectId,
    this.cid,
    this.promptTokens = 0,
    this.cachedPromptTokens = 0,
    this.completionTokens = 0,
    this.cost = 0,
    this.estimated = false,
    required this.createdAt,
  });

  int get totalTokens => promptTokens + completionTokens;
  int get uncachedPromptTokens =>
      (promptTokens - cachedPromptTokens).clamp(0, promptTokens).toInt();

  factory UsageRecord.fromJson(Map<String, dynamic> json) => UsageRecord(
        id: json['id'],
        modelId: json['modelId'] as String,
        providerId: json['providerId'] as String?,
        projectId: json['projectId'] as int?,
        cid: json['cid'] as int?,
        promptTokens: (json['promptTokens'] ?? 0) as int,
        cachedPromptTokens: (json['cachedPromptTokens'] ?? 0) as int,
        completionTokens: (json['completionTokens'] ?? 0) as int,
        cost: (json['cost'] as num?)?.toDouble() ?? 0,
        estimated: (json['estimated'] == 1),
        createdAt: json['createdAt'] as int,
      );

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'modelId': modelId,
      'providerId': providerId,
      'projectId': projectId,
      'cid': cid,
      'promptTokens': promptTokens,
      'cachedPromptTokens': cachedPromptTokens,
      'completionTokens': completionTokens,
      'cost': cost,
      'estimated': estimated ? 1 : 0,
      'createdAt': createdAt,
    };
  }
}

class UsageAggregate {
  final String key;
  final int promptTokens;
  final int cachedPromptTokens;
  final int completionTokens;
  final double cost;
  final int calls;
  final bool estimated;

  const UsageAggregate({
    required this.key,
    required this.promptTokens,
    this.cachedPromptTokens = 0,
    required this.completionTokens,
    required this.cost,
    required this.calls,
    required this.estimated,
  });

  int get totalTokens => promptTokens + completionTokens;
  int get uncachedPromptTokens =>
      (promptTokens - cachedPromptTokens).clamp(0, promptTokens);
}
