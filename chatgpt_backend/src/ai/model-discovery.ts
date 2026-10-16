import { HttpException, Injectable } from '@nestjs/common';
import { lookup } from 'node:dns/promises';
import { BlockList, isIP } from 'node:net';
import { request } from 'node:https';

export const SYNC_MESSAGES = {
  model_sync_failed: '模型目录获取失败，请检查服务商配置后重新预览',
  model_sync_unavailable: '服务商未配置有效密钥或安全目录地址',
  model_sync_invalid: '模型同步参数无效',
  model_sync_expired: '预览已过期或不属于当前会话，请重新预览',
  model_sync_changed: '服务商配置已变化，请重新预览',
  model_sync_busy: '模型预览正在进行，请稍后再试',
  model_sync_limit: '模型目录超出安全限制，未生成预览',
  model_sync_import_unknown: '导入结果未确认，请刷新模型列表核对后重新预览',
} as const;
export type SyncCode = keyof typeof SYNC_MESSAGES;
export class ModelSyncError extends HttpException {
  constructor(code: SyncCode = 'model_sync_failed', status = 400) {
    super({ message: SYNC_MESSAGES[code], safeCode: code }, status);
  }
}
export interface DiscoveredModel {
  modelId: string;
  displayName: string;
  description?: string;
  supportsVision?: boolean;
  supportsTool?: boolean;
  supportsReasoning?: boolean;
  supportsPdf?: boolean;
  contextWindow?: number;
  maxOutputTokens?: number;
}
export type CatalogFormat = 'openai' | 'anthropic' | 'gemini';
const blocked = new BlockList();
for (const [ip, bits] of [
  ['0.0.0.0', 8],
  ['10.0.0.0', 8],
  ['100.64.0.0', 10],
  ['127.0.0.0', 8],
  ['169.254.0.0', 16],
  ['172.16.0.0', 12],
  ['192.0.0.0', 24],
  ['192.0.2.0', 24],
  ['192.88.99.0', 24],
  ['192.168.0.0', 16],
  ['198.18.0.0', 15],
  ['198.51.100.0', 24],
  ['203.0.113.0', 24],
  ['224.0.0.0', 4],
  ['240.0.0.0', 4],
] as const)
  blocked.addSubnet(ip, bits, 'ipv4');
for (const [ip, bits] of [
  ['2001::', 23],
  ['2001:db8::', 32],
  ['2002::', 16],
  ['3fff::', 20],
] as const)
  blocked.addSubnet(ip, bits, 'ipv6');
const globalV6 = new BlockList();
globalV6.addSubnet('2000::', 3, 'ipv6');
export function isCatalogPublicAddress(address: string): boolean {
  const family = isIP(address);
  return family === 4
    ? !blocked.check(address, 'ipv4')
    : family === 6 &&
        globalV6.check(address, 'ipv6') &&
        !blocked.check(address, 'ipv6');
}
function containsControl(value: string, includeSpace = false): boolean {
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code <= (includeSpace ? 32 : 31) || code === 127) return true;
  }
  return false;
}
function secureUrl(raw: string): URL {
  try {
    if (
      typeof raw !== 'string' ||
      raw.length > 4096 ||
      containsControl(raw, true)
    )
      throw Error();
    const url = new URL(raw);
    if (
      url.protocol !== 'https:' ||
      (url.port && url.port !== '443') ||
      url.username ||
      url.password ||
      url.hash
    )
      throw Error();
    return url;
  } catch {
    throw new ModelSyncError('model_sync_unavailable');
  }
}
export function catalogEndpoint(baseUrl: string): {
  url: URL;
  format: CatalogFormat;
} {
  const url = secureUrl(baseUrl);
  if (url.search) throw new ModelSyncError('model_sync_unavailable');
  let path = url.pathname.replace(/\/+$/, '');
  let format: CatalogFormat = 'openai';
  if (url.hostname === 'api.anthropic.com') {
    format = 'anthropic';
    if (!path) path = '/v1';
    if (path !== '/v1') throw new ModelSyncError('model_sync_unavailable');
  } else if (url.hostname === 'generativelanguage.googleapis.com') {
    format = 'gemini';
    if (!path || path === '/v1beta/openai') path = '/v1beta';
    if (!['/v1beta', '/v1'].includes(path))
      throw new ModelSyncError('model_sync_unavailable');
  }
  url.pathname = `${path}/models`;
  return { url, format };
}

/** 仅目录 GET：无代理环境变量、无重定向、公共 DNS 全量验证并固定实际连接地址。 */
@Injectable()
export class ModelCatalogTransport {
  async get(
    raw: URL,
    headers: Record<string, string>,
    signal: AbortSignal,
  ): Promise<unknown> {
    const url = secureUrl(raw.href);
    signal.throwIfAborted();
    const hostname = url.hostname.replace(/^\[|\]$/g, '');
    const addresses = await new Promise<
      Array<{ address: string; family: number }>
    >((resolve, reject) => {
      const abort = () => reject(new ModelSyncError());
      signal.addEventListener('abort', abort, { once: true });
      lookup(hostname, { all: true, verbatim: true })
        .then(resolve, reject)
        .finally(() => signal.removeEventListener('abort', abort));
      if (signal.aborted) abort();
    });
    signal.throwIfAborted();
    if (
      !addresses.length ||
      addresses.some((a) => !isCatalogPublicAddress(a.address))
    )
      throw new ModelSyncError('model_sync_unavailable');
    const pinned = addresses[0];
    return new Promise((resolve, reject) => {
      const req = request(
        url,
        {
          method: 'GET',
          headers: { Accept: 'application/json', ...headers },
          agent: false,
          signal,
          maxHeaderSize: 16384,
          family: pinned.family,
          lookup: (_hostname, _options, done) =>
            done(null, pinned.address, pinned.family),
        },
        (res) => {
          if (
            res.statusCode !== 200 ||
            !/\bjson\b/i.test(res.headers['content-type'] ?? '')
          ) {
            res.destroy();
            req.destroy();
            reject(new ModelSyncError());
            return;
          }
          let size = 0;
          const chunks: Buffer[] = [];
          res.on('data', (chunk: Buffer) => {
            size += chunk.length;
            if (size > 1024 * 1024) {
              res.destroy();
              req.destroy();
              reject(new ModelSyncError('model_sync_limit'));
            } else chunks.push(chunk);
          });
          res.on('error', () => reject(new ModelSyncError()));
          res.on('end', () => {
            try {
              resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
            } catch {
              reject(new ModelSyncError());
            } finally {
              req.destroy();
            }
          });
        },
      );
      req.on('error', () => reject(new ModelSyncError()));
      req.end();
    });
  }
}
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    throw new ModelSyncError();
  return value as Record<string, unknown>;
}
function text(value: unknown, max: number): string {
  if (
    typeof value !== 'string' ||
    !/\S/.test(value) ||
    value.length > max ||
    containsControl(value)
  )
    throw new ModelSyncError();
  return value;
}
function number(value: unknown): number | undefined {
  return Number.isSafeInteger(value) && (value as number) > 0
    ? (value as number)
    : undefined;
}
function supported(value: unknown): boolean | undefined {
  if (!value || typeof value !== 'object') return undefined;
  const result = (value as Record<string, unknown>).supported;
  return typeof result === 'boolean' ? result : undefined;
}
export function catalogPage(
  value: unknown,
  format: CatalogFormat,
): { models: DiscoveredModel[]; next?: string } {
  const body = object(value);
  const rows = format === 'gemini' ? body.models : body.data;
  if (!Array.isArray(rows)) throw new ModelSyncError();
  if (rows.length > 1000) throw new ModelSyncError('model_sync_limit');
  const models: DiscoveredModel[] = [];
  for (const raw of rows) {
    const row = object(raw);
    if (format === 'gemini') {
      if (!Array.isArray(row.supportedGenerationMethods))
        throw new ModelSyncError();
      if (!row.supportedGenerationMethods.includes('generateContent')) continue;
    }
    const id = text(format === 'gemini' ? row.name : row.id, 255);
    if (format === 'gemini' && !/^models\/[^/]+$/.test(id))
      throw new ModelSyncError();
    const label =
      format === 'anthropic'
        ? row.display_name
        : format === 'gemini'
          ? row.displayName
          : row.name;
    const model: DiscoveredModel = {
      // Gemini 的资源前缀按官方格式移除；其余标识保持原文，绝不 trim/split 猜路由。
      modelId: format === 'gemini' ? id.slice(7) : id,
      displayName:
        label == null || label === ''
          ? format === 'gemini'
            ? id.slice(7)
            : id
          : text(label, 255),
    };
    if (row.description != null && row.description !== '')
      model.description = text(row.description, 4000);
    if (format === 'openai') {
      if (Array.isArray(row.input_modalities)) {
        model.supportsVision = row.input_modalities.includes('image');
        // text/image 列表不证明 PDF 不可用；未明确提供时保持未知。
        if (row.input_modalities.includes('pdf')) model.supportsPdf = true;
      }
      if (row.effort && typeof row.effort === 'object') {
        const levels = (row.effort as Record<string, unknown>).supported_levels;
        if (Array.isArray(levels) && levels.length > 0)
          model.supportsReasoning = true;
      }
      model.contextWindow = number(row.context_window);
      model.maxOutputTokens = number(row.max_output_tokens);
    } else if (format === 'anthropic') {
      const caps =
        row.capabilities && typeof row.capabilities === 'object'
          ? (row.capabilities as Record<string, unknown>)
          : {};
      model.supportsVision = supported(caps.image_input);
      model.supportsPdf = supported(caps.pdf_input);
      model.supportsReasoning = supported(caps.thinking);
      model.contextWindow = number(row.max_input_tokens);
      model.maxOutputTokens = number(row.max_tokens);
    } else {
      if (typeof row.thinking === 'boolean')
        model.supportsReasoning = row.thinking;
      model.contextWindow = number(row.inputTokenLimit);
      model.maxOutputTokens = number(row.outputTokenLimit);
    }
    models.push(model);
  }
  let next: string | undefined;
  if (format === 'anthropic') {
    if (typeof body.has_more !== 'boolean') throw new ModelSyncError();
    if (body.has_more) next = text(body.last_id, 1000);
  } else if (format === 'gemini') {
    if (body.nextPageToken !== undefined && body.nextPageToken !== '')
      next = text(body.nextPageToken, 2000);
  } else if (body.has_more === true)
    throw new ModelSyncError('model_sync_limit');
  return { models, next };
}
