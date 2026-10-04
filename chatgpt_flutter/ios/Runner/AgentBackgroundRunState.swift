import Foundation

/// 与系统 API 分开，便于验证迟到的回调不会释放下一次运行。
final class AgentBackgroundRunState {
  struct Run: Equatable {
    let runId: String
    let cid: Int64
    let requestIdentifier: String
  }

  private(set) var current: Run?
  private(set) var active = false

  func begin(runId: String, cid: Int64, identifierPrefix: String) -> Run? {
    guard current == nil, !runId.isEmpty else { return nil }
    let run = Run(
      runId: runId, cid: cid,
      requestIdentifier: identifierPrefix + UUID().uuidString
    )
    current = run
    active = false
    return run
  }

  @discardableResult
  func grant(_ run: Run) -> Bool {
    guard current == run else { return false }
    active = true
    return true
  }

  @discardableResult
  func release(_ run: Run) -> Bool {
    guard current == run else { return false }
    current = nil
    active = false
    return true
  }
}

struct AgentBackgroundProgress {
  let completed: Int64
  let total: Int64
  let status: String

  init(completed: Int64, total: Int64, status: String) {
    self.total = max(0, total)
    self.completed = self.total > 0 ? min(max(0, completed), self.total) : 0
    let text = String(status.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    switch text {
    case "generating": self.status = "正在生成回答"
    case "tool": self.status = "正在处理任务步骤"
    case "verifying": self.status = "正在验收成果"
    case "reading": self.status = "正在读取资料"
    default: self.status = text.isEmpty ? "正在执行任务" : text
    }
  }

  var subtitle: String {
    total > 0 ? "\(completed)/\(total) · \(status)" : status
  }
}
