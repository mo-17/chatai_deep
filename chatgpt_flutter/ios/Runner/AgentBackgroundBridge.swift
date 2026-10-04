import BackgroundTasks
import Flutter
import UIKit

/// 同一个 Flutter engine 继续执行请求；系统拒绝授权时保留原有断点恢复路径。
final class AgentBackgroundBridge {
  private let channel: FlutterMethodChannel
  private var controller: AnyObject?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.example.chatgpt_flutter/agent_background",
      binaryMessenger: messenger
    )
    if #available(iOS 26.0, *) {
      controller = AgentContinuedProcessingController(channel: channel)
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if #available(iOS 26.0, *),
         let controller = self.controller as? AgentContinuedProcessingController {
        controller.handle(call, result: result)
      } else {
        switch call.method {
        case "getCapabilities":
          result(["supported": false, "mode": "unsupported", "reason": "requiresIOS26"])
        case "start":
          result(["active": false, "mode": "unsupported", "reason": "requiresIOS26"])
        case "stop", "update": result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}

@available(iOS 26.0, *)
private final class AgentContinuedProcessingController {
  private final class Lease {
    let task: BGContinuedProcessingTask
    private var finished = false

    init(_ task: BGContinuedProcessingTask) { self.task = task }

    func finish(success: Bool) {
      guard !finished else { return }
      finished = true
      task.expirationHandler = nil
      task.setTaskCompleted(success: success)
    }
  }

  private let channel: FlutterMethodChannel
  private let state = AgentBackgroundRunState()
  private let identifierPrefix: String
  private let configured: Bool
  private var pendingResult: FlutterResult?
  private var launchTimeout: DispatchWorkItem?
  private var lease: Lease?
  private var title = "Agent 任务"
  private var progress = AgentBackgroundProgress(completed: 0, total: 0, status: "准备开始")
  private var backgroundObserver: NSObjectProtocol?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    identifierPrefix = (Bundle.main.bundleIdentifier ?? "com.example.chatgptFlutter1") + ".agent."
    configured = (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers")
      as? [String])?.contains(identifierPrefix + "*") ?? false
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self, let run = self.state.current, !self.state.active else { return }
      // 在 launchHandler 授权前离开前台不能被视为已取得后台执行资格。
      self.rejectPending(run, reason: "foregroundRequired")
    }
  }

  deinit {
    if let backgroundObserver = backgroundObserver {
      NotificationCenter.default.removeObserver(backgroundObserver)
    }
    launchTimeout?.cancel()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getCapabilities":
      result([
        "supported": configured,
        "mode": configured ? "iosContinued" : "unsupported",
        "reason": configured ? "" : "configurationMissing",
      ])
    case "start": start(call.arguments, result: result)
    case "update": update(call.arguments, result: result)
    case "stop": stop(call.arguments); result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func start(_ arguments: Any?, result: @escaping FlutterResult) {
    guard configured else { result(inactive("configurationMissing")); return }
    guard UIApplication.shared.applicationState == .active else {
      result(inactive("foregroundRequired")); return
    }
    guard let args = arguments as? [String: Any],
          let runId = args["runId"] as? String, !runId.isEmpty, runId.count <= 200,
          let cid = args["cid"] as? NSNumber,
          let suppliedTitle = args["title"] as? String,
          let completed = args["completed"] as? NSNumber,
          let total = args["total"] as? NSNumber else {
      result(inactive("invalidArguments")); return
    }
    if let existing = state.current {
      if existing.runId == runId && existing.cid == cid.int64Value && state.active {
        result(["active": true, "mode": "iosContinued"])
      } else { result(inactive("anotherTaskRunning")) }
      return
    }
    guard let run = state.begin(runId: runId, cid: cid.int64Value, identifierPrefix: identifierPrefix) else {
      result(inactive("anotherTaskRunning")); return
    }
    let trimmedTitle = suppliedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    title = trimmedTitle.isEmpty ? "Agent 任务" : String(trimmedTitle.prefix(80))
    progress = AgentBackgroundProgress(
      completed: completed.int64Value, total: total.int64Value, status: "准备开始"
    )
    pendingResult = result
    // Info.plist 使用 wildcard，注册和提交均使用同一个具体后缀。
    // Continued Processing 特别允许在应用启动完成后注册；每个 UUID 只注册一次。
    guard BGTaskScheduler.shared.register(
      forTaskWithIdentifier: run.requestIdentifier, using: .main,
      launchHandler: { [weak self] task in
        guard let self = self else { task.setTaskCompleted(success: false); return }
        self.launched(task)
      }
    ) else { rejectPending(run, reason: "registrationFailed"); return }
    let request = BGContinuedProcessingTaskRequest(
      identifier: run.requestIdentifier, title: title, subtitle: progress.subtitle
    )
    request.strategy = .fail
    // 默认 CPU / 网络资源，无 GPU、音频或定位伪装。
    do { try BGTaskScheduler.shared.submit(request) }
    catch {
      let code = (error as NSError).code
      let reason: String
      switch code {
      case BGTaskScheduler.Error.Code.unavailable.rawValue: reason = "unavailable"
      case BGTaskScheduler.Error.Code.notPermitted.rawValue: reason = "notPermitted"
      case BGTaskScheduler.Error.Code.tooManyPendingTaskRequests.rawValue: reason = "tooManyTasks"
      case BGTaskScheduler.Error.Code.immediateRunIneligible.rawValue: reason = "systemBusy"
      default: reason = "submissionFailed"
      }
      rejectPending(run, reason: reason)
      return
    }
    // submit 成功仍不是执行授权；只有对应的 launchHandler 才可返回 active。
    let timeout = DispatchWorkItem { [weak self] in
      self?.rejectPending(run, reason: "launchTimeout")
    }
    launchTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
  }

  private func launched(_ task: BGTask) {
    guard let continued = task as? BGContinuedProcessingTask,
          let run = state.current,
          task.identifier == run.requestIdentifier,
          pendingResult != nil,
          UIApplication.shared.applicationState == .active,
          state.grant(run) else {
      task.setTaskCompleted(success: false)
      return
    }
    let currentLease = Lease(continued)
    lease = currentLease
    continued.expirationHandler = { [weak self, weak currentLease] in
      DispatchQueue.main.async {
        guard let currentLease = currentLease else { return }
        guard let self = self else { currentLease.finish(success: false); return }
        self.interrupted(run, lease: currentLease)
      }
    }
    publishProgress()
    launchTimeout?.cancel()
    launchTimeout = nil
    let result = pendingResult
    pendingResult = nil
    result?(["active": true, "mode": "iosContinued"])
  }

  private func update(_ arguments: Any?, result: FlutterResult) {
    guard let args = arguments as? [String: Any],
          let runId = args["runId"] as? String,
          let completed = args["completed"] as? NSNumber,
          let total = args["total"] as? NSNumber,
          let status = args["status"] as? String else {
      result(FlutterError(code: "invalid_arguments", message: "Invalid task progress", details: nil))
      return
    }
    guard let run = state.current, run.runId == runId, state.active, lease != nil else {
      // Dart 不能因静默 nil 继续认为失效的许可仍可放行后台事件。
      // 对旧 run 的错误由 Dart 的 token 检查忽略，不更改当前任务。
      result(FlutterError(code: "task_inactive", message: "Task execution lease is inactive", details: nil))
      return
    }
    progress = AgentBackgroundProgress(
      completed: completed.int64Value, total: total.int64Value, status: status
    )
    publishProgress()
    result(nil)
  }

  private func publishProgress() {
    guard let task = lease?.task else { return }
    // 未知总数使用 NSProgress 的不确定状态，不构造假的百分比。
    task.progress.totalUnitCount = progress.total > 0 ? progress.total : -1
    task.progress.completedUnitCount = progress.completed
    task.updateTitle(title, subtitle: progress.subtitle)
  }

  private func stop(_ arguments: Any?) {
    guard let args = arguments as? [String: Any],
          let runId = args["runId"] as? String,
          let run = state.current, run.runId == runId else { return }
    if !state.active { rejectPending(run, reason: "cancelled"); return }
    let currentLease = lease
    lease = nil
    state.release(run)
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: run.requestIdentifier)
    currentLease?.finish(success: args["success"] as? Bool ?? false)
  }

  private func rejectPending(_ run: AgentBackgroundRunState.Run, reason: String) {
    guard state.current == run, !state.active else { return }
    state.release(run)
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: run.requestIdentifier)
    launchTimeout?.cancel()
    launchTimeout = nil
    let result = pendingResult
    pendingResult = nil
    result?(inactive(reason))
  }

  private func interrupted(_ run: AgentBackgroundRunState.Run, lease currentLease: Lease) {
    guard state.current == run else { currentLease.finish(success: false); return }
    state.release(run)
    lease = nil
    currentLease.task.expirationHandler = nil
    // expirationHandler 没有区分用户取消/资源不足的原因参数，保持如实汇报。
    // 等 Dart 保存暂停断点后释放，最多等待两秒，不能拖延系统回收。
    channel.invokeMethod("onInterrupted", arguments: ["runId": run.runId, "reason": "expired"]) { _ in
      DispatchQueue.main.async { currentLease.finish(success: false) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { currentLease.finish(success: false) }
  }

  private func inactive(_ reason: String) -> [String: Any] {
    ["active": false, "mode": "iosContinued", "reason": reason]
  }
}
