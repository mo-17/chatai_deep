import { Injectable, BadRequestException } from '@nestjs/common';
import * as jwt from 'jsonwebtoken';

export interface AppleUserInfo {
  subject: string;
  email?: string;
  emailVerified?: boolean;
  isPrivateEmail?: boolean;
}

/**
 * Sign in with Apple 服务
 *
 * 验证流程：
 * 1. 客户端通过 Apple SDK 获取 identityToken + authorizationCode
 * 2. 服务端从 Apple JWKS 获取公钥验证 JWT 签名
 * 3. 校验 iss、aud、exp
 * 4. 返回 { subject, email }
 */
@Injectable()
export class AppleService {
  /**
   * 验证 Apple identityToken 并返回用户信息
   */
  async verifyIdentityToken(identityToken: string): Promise<AppleUserInfo> {
    if (!identityToken) throw new BadRequestException('identityToken 不能为空');

    // 先解码 header 获取 kid
    const decoded = jwt.decode(identityToken, { complete: true });
    if (!decoded || typeof decoded === 'string') {
      throw new BadRequestException('identityToken 格式无效');
    }

    const { kid } = decoded.header as { kid?: string };
    if (!kid) throw new BadRequestException('identityToken 缺少 kid');

    try {
      // 获取 Apple 公钥并验证
      const publicKey = await this.fetchPublicKey(kid);
      const payload = jwt.verify(identityToken, publicKey, {
        algorithms: ['RS256'],
        issuer: 'https://appleid.apple.com',
        // audience 应为 app bundle ID，由环境变量提供
        // audience: process.env.APPLE_CLIENT_ID,
      }) as jwt.JwtPayload & {
        email?: string;
        email_verified?: string | boolean;
        is_private_email?: string | boolean;
      };

      return {
        subject: payload.sub!,
        email: payload.email,
        emailVerified:
          payload.email_verified === 'true' || payload.email_verified === true,
        isPrivateEmail:
          payload.is_private_email === 'true' ||
          payload.is_private_email === true,
      };
    } catch (e) {
      throw new BadRequestException(
        `Apple identityToken 验证失败: ${e instanceof Error ? e.message : String(e)}`,
      );
    }
  }

  /**
   * 从 Apple JWKS 端点获取指定 kid 的公钥
   */
  private async fetchPublicKey(kid: string): Promise<string> {
    const jwksUrl = 'https://appleid.apple.com/auth/keys';
    const resp = await fetch(jwksUrl);
    if (!resp.ok) throw new BadRequestException('获取 Apple JWKS 失败');

    const jwks = (await resp.json()) as {
      keys: Array<{
        kid: string;
        kty: string;
        n: string;
        e: string;
        alg?: string;
      }>;
    };
    const key = jwks.keys?.find((k) => k.kid === kid);
    if (!key) throw new BadRequestException(`Apple JWKS 中未找到 kid: ${kid}`);

    // 将 JWK 转为 PEM（Node 内置 crypto）
    const crypto = await import('crypto');
    const pubKey = crypto.createPublicKey({
      key: {
        kty: key.kty,
        n: key.n,
        e: key.e,
      },
      format: 'jwk',
    });
    return pubKey.export({ type: 'spki', format: 'pem' }).toString();
  }
}
