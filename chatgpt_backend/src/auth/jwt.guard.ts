import {
  Injectable,
  CanActivate,
  ExecutionContext,
  UnauthorizedException,
  ForbiddenException,
} from '@nestjs/common';
import { Request } from 'express';
import * as jwt from 'jsonwebtoken';
import { JWT_SECRET, JwtPayload } from './jwt.const';
import { extractBearer } from './bearer';

export interface AuthenticatedRequest extends Request {
  user?: JwtPayload;
}

@Injectable()
export class JwtGuard implements CanActivate {
  protected requireAdmin = false;

  canActivate(context: ExecutionContext): boolean {
    const request = context.switchToHttp().getRequest<AuthenticatedRequest>();
    const token = extractBearer(request.headers.authorization);
    if (!token) {
      throw new UnauthorizedException('未提供有效的认证令牌');
    }
    try {
      const payload = jwt.verify(token, JWT_SECRET) as JwtPayload;
      if (this.requireAdmin && payload.role !== 'admin') {
        throw new ForbiddenException('需要管理员权限');
      }
      request.user = {
        userId: payload.userId,
        userName: payload.userName,
        role: payload.role,
      };
      return true;
    } catch (err) {
      if (err instanceof ForbiddenException) throw err;
      throw new UnauthorizedException('令牌无效或已过期');
    }
  }
}
