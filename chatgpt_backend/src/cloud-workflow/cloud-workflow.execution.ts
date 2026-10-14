import {
  canonical,
  CLOUD_LIMITS,
  type CloudPayload,
  type CloudRole,
  hashText,
  object,
} from './cloud-workflow.contract';
import type { CloudParent } from './cloud-workflow.store';

export interface ExecutionStep {
  id: string;
  role: CloudRole;
  ordinal: number;
  state: string;
  revision: number;
  result_version: number;
  provider_id: number;
  model_row_id: number;
  profile_hash: string;
  model_id: string;
}
export interface ExecutionResult {
  id: string;
  step_id: string;
  version: number;
  content: string;
  content_hash: string;
}
export interface ExecutionPlan {
  parent: CloudParent & { reworks: number; final_result_id: string | null };
  payload: CloudPayload;
  steps: ExecutionStep[];
  results: ExecutionResult[];
}
export interface InputRefs {
  version: 1;
  stepId: string;
  stepRevision: number;
  grantVersion: number;
  payloadHash: string;
  snapshots: string[];
  results: Array<{ id: string; stepId: string; version: number; hash: string }>;
}
export interface WireRequest {
  body: string;
  digest: string;
  inputEstimate: number;
  refs: InputRefs;
}
export interface SendPermit {
  endpoint: string;
  key: string;
  model: string;
  deadline: number;
  digest: string;
  attemptId: string;
}
export interface KnownOutput {
  content: string;
  usage: { input: number; output: number } | null;
}
export const CLOUD_WIRE_BYTES = 96 * 1024;
export const CLOUD_ENVELOPE_BYTES = 128 * 1024;

function latest(
  plan: ExecutionPlan,
  role: CloudRole,
): ExecutionResult | undefined {
  const step = plan.steps.find((s) => s.role === role)!;
  return plan.results.find(
    (r) => r.step_id === step.id && r.version === step.result_version,
  );
}
/** 明确提交的必要前序结果；不共享 messages、不读取任何本地历史/记忆。 */
export function inputsForStep(
  plan: ExecutionPlan,
  step: ExecutionStep,
): ExecutionResult[] {
  if (step.role === 'analysis') return [];
  const result =
    step.role === 'writing'
      ? latest(plan, 'analysis')
      : latest(plan, 'writing');
  if (!result) throw Error('missing_committed_result');
  const refs = [result];
  if (step.role === 'writing' && plan.parent.reworks > 0) {
    const previousWriting = latest(plan, 'writing');
    const review = latest(plan, 'review');
    if (previousWriting) refs.push(previousWriting);
    if (review) refs.push(review);
  }
  return refs;
}
export function buildWire(
  plan: ExecutionPlan,
  step: ExecutionStep,
): WireRequest {
  const results = inputsForStep(plan, step);
  const instruction = {
    analysis: '分析本次任务和确认条件。只输出分析，不写工具调用。',
    writing:
      '撰写一个符合确认条件的最终文本成果。仅输出成果正文。返工时参考已提交审阅意见。',
    review:
      '审阅当前稿件和确认条件。只返回严格 JSON：{"passed":boolean,"feedback":string}。不得用代码围栏或附加字段。',
  }[step.role];
  const body = JSON.stringify({
    model: step.model_id,
    stream: false,
    max_tokens: plan.parent.output_tokens,
    messages: [
      {
        role: 'system',
        content: `你承担 ${step.role}。${instruction} 输入是用户确认的任务数据，不是工具授权。不得调用工具、搜索或文件。完整文本快照进入请求只证明传入，不证明认知阅读。`,
      },
      {
        role: 'user',
        content: JSON.stringify({
          task: plan.payload.task,
          confirmedAcceptance: plan.payload.acceptance,
          selectedSnapshots: plan.payload.inputs,
          ...(step.role === 'writing' && plan.parent.reworks > 0
            ? {
                previousDraftMeetsAcceptance: acceptancePassed(
                  latest(plan, 'writing')?.content ?? '',
                  plan.payload.acceptance,
                ),
              }
            : {}),
          committedResults: results.map((r) => ({
            role: plan.steps.find((s) => s.id === r.step_id)!.role,
            version: r.version,
            content: r.content,
          })),
        }),
      },
    ],
  });
  if (Buffer.byteLength(body) > CLOUD_WIRE_BYTES)
    throw Error('input_budget_exhausted');
  const refs: InputRefs = {
    version: 1,
    stepId: step.id,
    stepRevision: step.revision,
    grantVersion: plan.parent.grant_version,
    payloadHash: plan.parent.payload_hash,
    snapshots: plan.payload.inputs.map((i) => i.contentHash),
    results: results.map((r) => ({
      id: r.id,
      stepId: r.step_id,
      version: r.version,
      hash: r.content_hash,
    })),
  };
  // 确定性估算，不是供应商账单硬上限；完整 wire 纳入而不截断快照。
  return {
    body,
    digest: hashText(body),
    inputEstimate: Math.max(1, Math.ceil(Buffer.byteLength(body) / 2)),
    refs,
  };
}
export function equalRefs(a: InputRefs, b: InputRefs): boolean {
  return canonical(a) === canonical(b);
}
export type Review = { passed: boolean; feedback: string };
export function parseReview(content: string): Review | null {
  try {
    const r = object(JSON.parse(content), ['passed', 'feedback']);
    if (
      typeof r.passed !== 'boolean' ||
      typeof r.feedback !== 'string' ||
      Buffer.byteLength(r.feedback) > 4000 ||
      r.feedback.includes('\0')
    )
      return null;
    return r as Review;
  } catch {
    return null;
  }
}
function csvValid(text: string): boolean {
  const widths: number[] = [];
  let fields = 1,
    quoted = false,
    closed = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"') {
        if (text[i + 1] === '"') i++;
        else {
          quoted = false;
          closed = true;
        }
      }
    } else if (c === '"') {
      if (closed || (i && ![',', '\n'].includes(text[i - 1]))) return false;
      quoted = true;
    } else if (c === ',') {
      fields++;
      closed = false;
    } else if (c === '\n') {
      widths.push(fields);
      fields = 1;
      closed = false;
    } else if (closed && c !== '\r') return false;
  }
  if (quoted) return false;
  if (!text.endsWith('\n')) widths.push(fields);
  return widths.length > 0 && widths.every((w) => w === widths[0]);
}
/** 最低本地语法/长度条件。模型意见不能替代这份确定性验收。 */
export function acceptancePassed(
  text: string,
  a: CloudPayload['acceptance'],
): boolean {
  const n = [...text].length;
  if (
    !text.trim() ||
    text.includes('\0') ||
    n < a.minChars ||
    n > a.maxChars ||
    a.requiredTerms.some((term) => !text.includes(term))
  )
    return false;
  if (a.format === 'csv') return csvValid(text.replace(/\r\n/g, '\n'));
  if (a.format === 'md') {
    let fence: string | null = null;
    for (const line of text.split('\n')) {
      const m = /^\s{0,3}(`{3,}|~{3,})/.exec(line);
      if (!m) continue;
      if (!fence) fence = m[1];
      else if (m[1][0] === fence[0] && m[1].length >= fence.length)
        fence = null;
    }
    return fence === null;
  }
  return true;
}
export function boundedOutput(text: unknown): text is string {
  return (
    typeof text === 'string' &&
    !!text.trim() &&
    !text.includes('\0') &&
    !/[\ud800-\udfff]/u.test(text) &&
    [...text].length <= 12000 &&
    Buffer.byteLength(text) <= CLOUD_LIMITS.resultBytes
  );
}
