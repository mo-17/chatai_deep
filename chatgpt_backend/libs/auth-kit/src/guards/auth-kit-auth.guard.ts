import {
  CanActivate,
  ExecutionContext,
  ForbiddenException,
  Inject,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import type { Request } from 'express';
import { AUTH_KIT_OPTIONS } from '../auth-kit.tokens';
import type { AuthKitModuleOptions } from '../auth-kit.module';
import type { AuthenticatedPrincipal } from '../contracts/access-token-verifier.interface';

interface AuthenticatedRequest extends Request {
  user?: AuthenticatedPrincipal;
}

function extractBearer(header?: string): string | null {
  if (!header) return null;
  const match = /^Bearer\s+(\S+)\s*$/i.exec(header);
  return match ? match[1] : null;
}

@Injectable()
export class AuthKitJwtGuard implements CanActivate {
  protected requireAdmin = false;
  private readonly options: AuthKitModuleOptions;

  constructor(@Inject(AUTH_KIT_OPTIONS) options: AuthKitModuleOptions) {
    this.options = options;
  }

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest<AuthenticatedRequest>();
    const token = extractBearer(request.headers.authorization);
    if (!token) throw new UnauthorizedException('未提供有效的认证令牌');

    const principal = await this.options.accessTokenVerifier.verify(token);
    if (!principal) throw new UnauthorizedException('令牌无效或已过期');
    if (this.requireAdmin && principal.role !== 'admin') {
      throw new ForbiddenException('需要管理员权限');
    }

    request.user = principal;
    return true;
  }
}

@Injectable()
export class AuthKitAdminGuard extends AuthKitJwtGuard {
  protected requireAdmin = true;

  constructor(@Inject(AUTH_KIT_OPTIONS) options: AuthKitModuleOptions) {
    super(options);
  }
}
