import {
  HttpException,
  Injectable,
  ServiceUnavailableException,
} from '@nestjs/common';

const errors: Record<string, string> = {
  queue_full: 'OCR 队列已满，请稍后重试',
  owner_busy: '已有 OCR 任务正在处理，请稍后重试',
  rate_limit: 'OCR 使用次数已达上限，请稍后重试',
  not_found: 'OCR 任务已过期或不可访问，请重新识别',
  job_closed: 'OCR 任务已结束，请重新识别',
  file_limit: '服务器 OCR 单个文件最多 8 MiB',
  invalid_file: 'OCR 文件无效或超过大小限制',
  invalid_pages: 'OCR 页码无效',
  invalid_request: 'OCR 请求无效',
};

@Injectable()
export class OcrService {
  async request(owner: string, path: string, method = 'GET', body?: Buffer) {
    const endpoint = process.env.OCR_WORKER_URL ?? 'http://127.0.0.1:3002';
    const token = process.env.OCR_WORKER_TOKEN;
    let base: URL;
    try {
      base = new URL(endpoint);
    } catch {
      throw new ServiceUnavailableException('服务器 OCR 尚未配置');
    }
    if (
      !token ||
      token.length < 32 ||
      base.protocol !== 'http:' ||
      base.hostname !== '127.0.0.1' ||
      base.username ||
      base.password ||
      base.pathname !== '/' ||
      base.search ||
      base.hash
    ) {
      throw new ServiceUnavailableException('服务器 OCR 尚未配置');
    }
    try {
      const response = await fetch(new URL(path, base), {
        method,
        redirect: 'error',
        signal: AbortSignal.timeout(15_000),
        headers: {
          Authorization: `Bearer ${token}`,
          'X-Ocr-Owner': owner,
          ...(body ? { 'Content-Type': 'application/octet-stream' } : {}),
        },
        ...(body ? { body: new Uint8Array(body) } : {}),
      });
      // 只接受有界 JSON，worker 异常不暴露内部路径/凭据。
      const chunks: Uint8Array[] = [];
      let size = 0;
      if (!response.body) throw new Error('empty');
      for await (const chunk of response.body) {
        size += chunk.byteLength;
        if (size > 2 * 1024 * 1024) throw new Error('result_limit');
        chunks.push(chunk);
      }
      const value = JSON.parse(
        Buffer.concat(chunks).toString('utf8'),
      ) as Record<string, unknown>;
      if (!response.ok) {
        const message = errors[String(value.error)] ?? '服务器 OCR 暂不可用';
        throw new HttpException(
          message,
          [400, 404, 409, 413, 429].includes(response.status)
            ? response.status
            : 503,
        );
      }
      return value;
    } catch (error) {
      if (error instanceof HttpException) throw error;
      throw new ServiceUnavailableException('服务器 OCR 暂不可用，请稍后重试');
    }
  }
}
