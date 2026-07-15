/// 当前账号的 AI 可用状态。
///
/// 该状态只约束发起 AI 请求，不应被用来阻止历史记录、知识库、备份等
/// 离线功能。
enum AIReadyStatus {
  loading,
  needsSetup,
  configuredUnverified,
  ready,
  temporarilyUnavailable,
  backendRequiresLogin,
}

/// 可稳定比较、记录和测试的 AI 可用状态快照。
final class AIReadyState {
  final AIReadyStatus status;

  /// 稳定、非本地化的原因码。展示层负责把它映射成用户文案。
  final String reasonCode;
  final String? providerId;
  final String? modelId;

  const AIReadyState({
    required this.status,
    required this.reasonCode,
    this.providerId,
    this.modelId,
  });

  const AIReadyState.loading()
      : status = AIReadyStatus.loading,
        reasonCode = 'loading',
        providerId = null,
        modelId = null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AIReadyState &&
          status == other.status &&
          reasonCode == other.reasonCode &&
          providerId == other.providerId &&
          modelId == other.modelId;

  @override
  int get hashCode => Object.hash(status, reasonCode, providerId, modelId);

  @override
  String toString() => 'AIReadyState(status: $status, reasonCode: $reasonCode, '
      'providerId: $providerId, modelId: $modelId)';
}
