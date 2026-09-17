import {
  Injectable,
  CanActivate,
  ExecutionContext,
  UnauthorizedException,
  ForbiddenException,
} from '@nestjs/common';
import { Request } from 'express';
import { JwtPayload } from './jwt.const';
import { extractBearer } from './bearer';
import { TokenAuthenticationService } from './token-authentication.service';

export interface AuthenticatedRequest extends Request {
  user?: JwtPayload;
}

@Injectable()
export class JwtGuard implements CanActivate {
  protected requireAdmin = false;

  constructor(
    protected readonly tokenAuthentication: TokenAuthenticationService,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest<AuthenticatedRequest>();
    const token = extractBearer(request.headers.authorization);
    if (!token) {
      throw new UnauthorizedException('未提供有效的认证令牌');
    }
    const principal = await this.tokenAuthentication.verify(token);
    if (!principal) {
      throw new UnauthorizedException('令牌无效或已过期');
    }
    if (this.requireAdmin && principal.role !== 'admin') {
      throw new ForbiddenException('需要管理员权限');
    }
    request.user = principal;
    return true;
  }
}
