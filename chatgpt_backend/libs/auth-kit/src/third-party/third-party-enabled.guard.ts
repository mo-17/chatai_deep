import {
  Injectable,
  CanActivate,
  ExecutionContext,
  ForbiddenException,
  SetMetadata,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { AuthSettingsService } from '../settings/auth-settings.service';

export const THIRD_PARTY_KEY = 'third_party_provider';
export const HUAWEI_LOGIN_MODE_KEY = 'huawei_login_mode';
export const HuaweiLoginMode = () => SetMetadata(HUAWEI_LOGIN_MODE_KEY, true);
export const ThirdParty = (provider: 'huawei' | 'apple') =>
  SetMetadata(THIRD_PARTY_KEY, provider);

/**
 * 第三方登录守卫 —— 读取 auth_settings 当前开关，关闭时返回 403。
 * 用 @ThirdParty('huawei') 或 @ThirdParty('apple') 装饰路由方法。
 */
@Injectable()
export class ThirdPartyEnabledGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly settingsService: AuthSettingsService,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const provider = this.reflector.getAllAndOverride<'huawei' | 'apple'>(
      THIRD_PARTY_KEY,
      [context.getHandler(), context.getClass()],
    );
    if (!provider) return true; // 非第三方路由，放行

    const settings = await this.settingsService.get();
    let enabled =
      provider === 'huawei'
        ? settings.huaweiGetAuthCodeEnabled || settings.huaweiQuickLoginEnabled
        : settings.appleSignInEnabled;

    if (
      provider === 'huawei' &&
      this.reflector.getAllAndOverride<boolean>(HUAWEI_LOGIN_MODE_KEY, [
        context.getHandler(),
        context.getClass(),
      ])
    ) {
      const mode = context
        .switchToHttp()
        .getRequest<{ body?: { mode?: unknown } }>().body?.mode;
      enabled =
        mode === 'getAuthCode'
          ? settings.huaweiGetAuthCodeEnabled
          : mode === 'quickLogin'
            ? settings.huaweiQuickLoginEnabled
            : false;
    }

    if (!enabled) {
      throw new ForbiddenException({
        code: 'THIRD_PARTY_DISABLED',
        message: '该登录方式暂未开放',
      });
    }
    return true;
  }
}
