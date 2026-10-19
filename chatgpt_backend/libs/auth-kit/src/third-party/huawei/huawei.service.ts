import {
  Injectable,
  BadRequestException,
  BadGatewayException,
  ServiceUnavailableException,
} from '@nestjs/common';

export interface HuaweiUserInfo {
  unionId: string;
  openId: string;
}

const TOKEN_URL = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';
const INSPECT_URL =
  'https://oauth-api.cloud.huawei.com/rest.php?nsp_fmt=JSON&nsp_svc=huawei.oauth2.user.getTokenInfo';
const MAX_RESPONSE_BYTES = 64 * 1024;

/** 授权码仅兑换一次；固定官方端点，凭证不进入 URL、日志或本地持久化。 */
@Injectable()
export class HuaweiService {
  async verifyAuthCode(authCode: string): Promise<HuaweiUserInfo> {
    this.requireCredential(authCode);
    const clientId = this.clientId();
    const clientSecret =
      process.env.HUAWEI_CLIENT_SECRET ?? process.env.HUAWEI_APP_SECRET;
    if (!clientSecret?.trim()) {
      throw new ServiceUnavailableException(
        '华为账号登录尚未配置，请联系管理员',
      );
    }
    const token = await this.post(TOKEN_URL, {
      grant_type: 'authorization_code',
      client_id: clientId,
      client_secret: clientSecret,
      code: authCode,
      supportAlg: 'PS256',
    });
    if (
      token.token_type !== 'Bearer' ||
      !this.positiveSeconds(token.expires_in)
    ) {
      throw new BadRequestException('华为账号授权无效，请重新登录');
    }
    this.requireCredential(token.access_token);
    return this.inspect(token.access_token, clientId);
  }

  async verifyQuickLoginToken(accessToken: string): Promise<HuaweiUserInfo> {
    this.requireCredential(accessToken);
    return this.inspect(accessToken, this.clientId());
  }

  private clientId(): string {
    const value = process.env.HUAWEI_CLIENT_ID ?? process.env.HUAWEI_APP_ID;
    if (!value || !/^[0-9]{1,64}$/.test(value)) {
      throw new ServiceUnavailableException(
        '华为账号登录尚未配置，请联系管理员',
      );
    }
    return value;
  }

  private requireCredential(value: unknown): asserts value is string {
    if (
      typeof value !== 'string' ||
      value.length === 0 ||
      value.length > 16384 ||
      /\s/.test(value) ||
      [...value].some(
        (char) => char.charCodeAt(0) < 32 || char.charCodeAt(0) === 127,
      )
    ) {
      throw new BadRequestException('华为账号授权凭证无效，请重新登录');
    }
  }

  private positiveSeconds(value: unknown): boolean {
    return typeof value === 'number' && Number.isFinite(value) && value > 0;
  }

  private async inspect(
    accessToken: string,
    clientId: string,
  ): Promise<HuaweiUserInfo> {
    const info = await this.post(INSPECT_URL, {
      access_token: accessToken,
      open_id: 'OPENID',
    });
    // 应用级 Token 或其他应用的用户 Token 均不得用于本应用登录。
    if (
      info.type !== 0 ||
      info.client_id !== clientId ||
      !this.positiveSeconds(info.expire_in) ||
      typeof info.union_id !== 'string' ||
      info.union_id.trim().length === 0 ||
      info.union_id.length > 256 ||
      typeof info.open_id !== 'string' ||
      info.open_id.trim().length === 0 ||
      info.open_id.length > 256
    ) {
      throw new BadRequestException('华为账号授权无效，请重新登录');
    }
    return { unionId: info.union_id, openId: info.open_id };
  }

  private async post(
    url: string,
    fields: Record<string, string>,
  ): Promise<Record<string, unknown>> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8000);
    try {
      const response = await fetch(url, {
        method: 'POST',
        redirect: 'error',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams(fields).toString(),
        signal: controller.signal,
      });
      if (response.status >= 500 || response.status === 429) {
        await response.body?.cancel();
        throw new BadGatewayException('华为账号服务暂不可用，请稍后重试');
      }
      if (!response.ok || response.headers.has('NSP_STATUS')) {
        await response.body?.cancel();
        throw new BadRequestException('华为账号授权无效，请重新登录');
      }
      const reader = response.body?.getReader();
      if (!reader) throw new Error('missing response');
      const chunks: Uint8Array[] = [];
      let bytes = 0;
      try {
        while (true) {
          const chunk = await reader.read();
          if (chunk.done) break;
          bytes += chunk.value.length;
          if (bytes > MAX_RESPONSE_BYTES) {
            await reader.cancel();
            throw new Error('oversized response');
          }
          chunks.push(chunk.value);
        }
      } finally {
        reader.releaseLock();
      }
      const data: unknown = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (!data || typeof data !== 'object' || Array.isArray(data))
        throw new Error('invalid response');
      const record = data as Record<string, unknown>;
      if ('error' in record || 'error_description' in record) {
        throw new BadRequestException('华为账号授权无效，请重新登录');
      }
      return record;
    } catch (error) {
      if (
        error instanceof BadRequestException ||
        error instanceof BadGatewayException
      )
        throw error;
      // 绝不把 provider 的错误详情（可能含凭证）交给 API 异常日志。
      throw new BadGatewayException('华为账号服务暂不可用，请稍后重试');
    } finally {
      clearTimeout(timer);
    }
  }
}
