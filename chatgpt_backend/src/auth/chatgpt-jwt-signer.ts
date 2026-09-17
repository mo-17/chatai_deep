import { Injectable } from '@nestjs/common';
import * as jwt from 'jsonwebtoken';
import { JWT_SECRET } from './jwt.const';
import type { IJwtSigner } from '@auth-kit';

/**
 * ChatGpt 项目的 IJwtSigner 实现。
 * 复用现有 JWT_SECRET 和 payload 结构。
 */
@Injectable()
export class ChatGptJwtSigner implements IJwtSigner {
  sign(user: {
    userId: number;
    userName: string;
    role?: string;
    tokenVersion?: number;
  }): string {
    return jwt.sign(
      {
        userId: user.userId,
        userName: user.userName,
        role: user.role ?? 'user',
        tokenVersion: user.tokenVersion ?? 0,
      },
      JWT_SECRET,
      user.role === 'admin' ? { expiresIn: '7d' } : { expiresIn: '30d' },
    );
  }
}
