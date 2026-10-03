import { PayloadTooLargeException } from '@nestjs/common';
import { json, type RequestHandler } from 'express';

export const chatJsonBodyLimit = 48 * 1024 * 1024;
const ordinaryJsonBodyLimit = 5 * 1024 * 1024;

// 只有对话接口接收内联图片；其余接口保持原有 JSON 上限。
export function createJsonBodyParser(): RequestHandler {
  const chatParser = json({ limit: chatJsonBodyLimit });
  const ordinaryParser = json({ limit: ordinaryJsonBodyLimit });
  return (req, res, next) => {
    const isChatCompletion =
      req.method === 'POST' &&
      /^\/uapi\/chat\/completions(?:\/stream)?\/?$/.test(req.path);
    const parser = isChatCompletion ? chatParser : ordinaryParser;
    parser(req, res, (error?: unknown) => {
      if (
        error !== null &&
        typeof error === 'object' &&
        'type' in error &&
        error.type === 'entity.too.large'
      ) {
        next(new PayloadTooLargeException('请求内容过大，请减少附件后重试'));
      } else {
        next(error);
      }
    });
  };
}
