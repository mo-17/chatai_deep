import {
  CanActivate,
  ExecutionContext,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import type { Request } from 'express';
import { extractBearer } from '../auth/bearer';
import { TokenAuthenticationService } from '../auth/token-authentication.service';
import type { CloudAuthorization } from './cloud-workflow.contract';

export interface CloudRequest extends Request {
  cloudAuthorization: CloudAuthorization;
}
@Injectable()
export class CloudWorkflowGuard implements CanActivate {
  constructor(private readonly authentication: TokenAuthenticationService) {}
  async canActivate(context: ExecutionContext) {
    const req = context.switchToHttp().getRequest<CloudRequest>();
    const token = extractBearer(req.headers.authorization);
    const authorization = token
      ? await this.authentication.verifyCloud(token)
      : null;
    if (!authorization)
      throw new UnauthorizedException('云任务需要具有有效期限的登录授权');
    req.cloudAuthorization = authorization;
    return true;
  }
}
