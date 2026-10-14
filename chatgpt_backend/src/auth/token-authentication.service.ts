import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import * as jwt from 'jsonwebtoken';
import { Repository } from 'typeorm';
import type { AuthenticatedPrincipal, IAccessTokenVerifier } from '@auth-kit';
import { User } from '../user/user.entity';
import { JWT_SECRET, JwtPayload } from './jwt.const';
export type CloudAuthUser = Pick<
  User,
  'id' | 'userName' | 'role' | 'banned' | 'tokenVersion'
>;

/**
 * JWT 只证明令牌曾由本服务签发；授权状态始终以当前 users 行为准。
 */
@Injectable()
export class TokenAuthenticationService implements IAccessTokenVerifier {
  constructor(
    @InjectRepository(User)
    private readonly userRepo: Repository<User>,
  ) {}

  private async authenticate(
    token: string,
    readUser?: (id: number) => Promise<CloudAuthUser | null>,
  ) {
    let payload: JwtPayload;
    try {
      payload = jwt.verify(token, JWT_SECRET, {
        algorithms: ['HS256'],
      }) as JwtPayload;
    } catch {
      return null;
    }

    if (!Number.isInteger(payload.userId) || payload.userId <= 0) return null;
    if (
      payload.tokenVersion !== undefined &&
      (!Number.isInteger(payload.tokenVersion) || payload.tokenVersion < 0)
    ) {
      return null;
    }

    const user = readUser
      ? await readUser(payload.userId)
      : await this.userRepo.findOne({ where: { id: payload.userId } });
    if (!user || user.banned) return null;

    // 兼容升级前签发的 v0 令牌；任何安全状态变更都会递增版本并使其失效。
    if ((payload.tokenVersion ?? 0) !== user.tokenVersion) return null;

    return { user, payload };
  }

  async verify(token: string): Promise<AuthenticatedPrincipal | null> {
    const verified = await this.authenticate(token);
    if (!verified) return null;
    return {
      userId: verified.user.id,
      userName: verified.user.userName,
      role: verified.user.role,
      tokenVersion: verified.payload.tokenVersion ?? 0,
      ...(Number.isSafeInteger((verified.payload as jwt.JwtPayload).exp)
        ? { expiresAt: (verified.payload as jwt.JwtPayload).exp! * 1000 }
        : {}),
    };
  }

  /** 云授权必须来自本次已验证 JWT，不能在 guard 后用新版本用户记录补签。 */
  async verifyCloud(
    token: string,
    readUser?: (id: number) => Promise<CloudAuthUser | null>,
  ): Promise<{
    userId: number;
    securityVersion: number;
    expiresAt: number;
  } | null> {
    const verified = await this.authenticate(token, readUser);
    if (!verified) return null;
    const exp = (verified.payload as JwtPayload & { exp?: number }).exp;
    if (!Number.isSafeInteger(exp) || exp! <= Date.now() / 1000) return null;
    return {
      userId: verified.user.id,
      securityVersion: verified.payload.tokenVersion ?? 0,
      expiresAt: exp! * 1000,
    };
  }
}
