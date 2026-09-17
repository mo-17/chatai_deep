import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import * as jwt from 'jsonwebtoken';
import { Repository } from 'typeorm';
import type { AuthenticatedPrincipal, IAccessTokenVerifier } from '@auth-kit';
import { User } from '../user/user.entity';
import { JWT_SECRET, JwtPayload } from './jwt.const';

/**
 * JWT 只证明令牌曾由本服务签发；授权状态始终以当前 users 行为准。
 */
@Injectable()
export class TokenAuthenticationService implements IAccessTokenVerifier {
  constructor(
    @InjectRepository(User)
    private readonly userRepo: Repository<User>,
  ) {}

  async verify(token: string): Promise<AuthenticatedPrincipal | null> {
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

    const user = await this.userRepo.findOne({ where: { id: payload.userId } });
    if (!user || user.banned) return null;

    // 兼容升级前签发的 v0 令牌；任何安全状态变更都会递增版本并使其失效。
    if ((payload.tokenVersion ?? 0) !== user.tokenVersion) return null;

    return {
      userId: user.id,
      userName: user.userName,
      role: user.role,
    };
  }
}
