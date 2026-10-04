import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
  precondition(value(), message)
}

let state = AgentBackgroundRunState()
let first = state.begin(runId: "one", cid: 1, identifierPrefix: "bundle.agent.")!
expect(!state.active, "submission must not imply activation")
expect(state.begin(runId: "two", cid: 2, identifierPrefix: "bundle.agent.") == nil, "only one pending run")
expect(state.grant(first), "matching launch grants lease")
expect(state.active, "launch activates")
expect(state.release(first), "matching stop releases lease")
let second = state.begin(runId: "two", cid: 2, identifierPrefix: "bundle.agent.")!
expect(!state.grant(first), "late launch cannot activate new run")
expect(!state.release(first), "old stop cannot release new run")
expect(state.current == second, "new run remains intact")
expect(first.requestIdentifier != second.requestIdentifier, "request generation is unique")
expect(state.release(second), "pending cancellation releases")
expect(!state.grant(second), "cancelled pending launch is rejected")
let sameTokenAgain = state.begin(runId: "two", cid: 2, identifierPrefix: "bundle.agent.")!
expect(!state.release(second), "older generation with reused runId remains harmless")
expect(state.current == sameTokenAgain, "generation prevents ABA callback")
expect(AgentBackgroundProgress(completed: 500, total: 0, status: "读取文件").subtitle == "读取文件", "unknown progress has no fake count")
expect(AgentBackgroundProgress(completed: 50, total: 8, status: "验收").completed == 8, "progress clamps malformed count")
expect(AgentBackgroundProgress(completed: -4, total: 8, status: "  ").subtitle == "0/8 · 正在执行任务", "negative count and empty status normalize")
expect(AgentBackgroundProgress(completed: 0, total: 0, status: "verifying").subtitle == "正在验收成果", "phase codes have readable system UI text")
print("Agent background native state: 17 checks passed")
