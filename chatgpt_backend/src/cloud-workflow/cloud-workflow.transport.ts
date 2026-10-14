import { Injectable } from '@nestjs/common';
import { hashText } from './cloud-workflow.contract';
import {
  boundedOutput,
  CLOUD_ENVELOPE_BYTES,
  type KnownOutput,
  type SendPermit,
  type WireRequest,
} from './cloud-workflow.execution';

export class CloudTransportFailure extends Error {
  constructor(
    readonly code: string,
    readonly known: boolean,
    readonly status: number | null = null,
  ) {
    super(code); // 不携带上游错误正文、端点或凭据。
  }
}
@Injectable()
export class CloudWorkflowTransport {
  /** 调用即同步启动唯一 fetch；这里没有权限之后的异步准备、hook 或重试。 */
  send(
    permit: SendPermit,
    wire: WireRequest,
    signal: AbortSignal,
  ): Promise<KnownOutput> {
    if (
      signal.aborted ||
      Date.now() >= permit.deadline ||
      wire.digest !== permit.digest ||
      hashText(wire.body) !== permit.digest
    )
      return Promise.reject(new CloudTransportFailure('not_sent', true));
    const request = fetch(permit.endpoint, {
      method: 'POST',
      redirect: 'error',
      signal,
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${permit.key}`,
      },
      body: wire.body,
    });
    return this.read(request, signal);
  }
  private async read(
    request: Promise<Response>,
    signal: AbortSignal,
  ): Promise<KnownOutput> {
    try {
      const response = await request;
      if (!response.body)
        throw new CloudTransportFailure(
          'incomplete_response',
          false,
          response.status,
        );
      const reader = response.body.getReader();
      const chunks: Uint8Array[] = [];
      let bytes = 0;
      try {
        while (true) {
          const part = await reader.read();
          if (part.done) break;
          bytes += part.value.byteLength;
          if (bytes > CLOUD_ENVELOPE_BYTES) {
            await reader.cancel();
            // 截断体不是完整结果，即使 HTTP 200 也不能宣称已知可重放。
            throw new CloudTransportFailure(
              'envelope_limit',
              false,
              response.status,
            );
          }
          chunks.push(part.value);
        }
      } finally {
        reader.releaseLock();
      }
      if (signal.aborted) throw new CloudTransportFailure('interrupted', false);
      if (!response.ok)
        throw new CloudTransportFailure('http_error', true, response.status);
      let payload: Record<string, unknown>;
      try {
        const joined = Buffer.concat(chunks);
        const text = new TextDecoder('utf-8', { fatal: true }).decode(joined);
        const value: unknown = JSON.parse(text);
        if (!value || typeof value !== 'object' || Array.isArray(value))
          throw Error();
        payload = value as Record<string, unknown>;
      } catch {
        throw new CloudTransportFailure(
          'invalid_response',
          true,
          response.status,
        );
      }
      const choices = payload.choices;
      if (!Array.isArray(choices) || choices.length !== 1)
        throw new CloudTransportFailure('invalid_response', true);
      const choice = choices[0] as {
        message?: {
          role?: string;
          content?: unknown;
          tool_calls?: unknown;
          function_call?: unknown;
        };
        finish_reason?: string;
      };
      const message = choice?.message;
      if (
        !message ||
        message.role !== 'assistant' ||
        choice.finish_reason !== 'stop' ||
        message.tool_calls !== undefined ||
        message.function_call !== undefined ||
        !boundedOutput(message.content)
      )
        throw new CloudTransportFailure('invalid_output', true);
      let usage: KnownOutput['usage'] = null;
      if (payload.usage !== undefined) {
        const u = payload.usage as {
          prompt_tokens?: unknown;
          completion_tokens?: unknown;
        };
        if (
          !u ||
          ![u.prompt_tokens, u.completion_tokens].every(
            (n) =>
              Number.isSafeInteger(n) &&
              (n as number) >= 0 &&
              (n as number) <= 1000000,
          )
        )
          throw new CloudTransportFailure('invalid_usage', true);
        usage = {
          input: u.prompt_tokens as number,
          output: u.completion_tokens as number,
        };
      }
      return { content: message.content, usage };
    } catch (error) {
      if (error instanceof CloudTransportFailure) throw error;
      throw new CloudTransportFailure(
        signal.aborted ? 'interrupted' : 'connection_unknown',
        false,
      );
    }
  }
}
