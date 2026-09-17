import { Injectable } from '@nestjs/common';
import { JwtGuard } from './jwt.guard';
import { TokenAuthenticationService } from './token-authentication.service';

@Injectable()
export class AdminGuard extends JwtGuard {
  protected requireAdmin = true;

  constructor(tokenAuthentication: TokenAuthenticationService) {
    super(tokenAuthentication);
  }
}
