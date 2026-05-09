import { Injectable } from '@nestjs/common';
import { JwtGuard } from './jwt.guard';

@Injectable()
export class AdminGuard extends JwtGuard {
  protected requireAdmin = true;
}
