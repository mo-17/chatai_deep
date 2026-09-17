import {
  Controller,
  Post,
  Get,
  Body,
  Req,
  HttpCode,
  BadRequestException,
  Inject,
  UseGuards,
} from '@nestjs/common';
import type { Request } from 'express';
import * as bcrypt from 'bcryptjs';
import { VerificationService } from '../verification/verification.service';
import { AuthSettingsService } from '../settings/auth-settings.service';
import { SendCodeDto } from '../verification/dto/send-code.dto';
import { VerifyCodeLoginDto } from '../verification/dto/verify-code-login.dto';
import { LoginPasswordDto } from '../verification/dto/login-password.dto';
import { AuthRegisterDto } from '../verification/dto/register.dto';
import { ResetPasswordDto } from '../verification/dto/reset-password.dto';
import { BindDto } from '../verification/dto/bind.dto';
import { AUTH_KIT_OPTIONS } from '../auth-kit.tokens';
import type { AuthKitModuleOptions } from '../auth-kit.module';
import type { IUserResolver } from '../contracts/user-resolver.interface';
import type { IJwtSigner } from '../contracts/jwt-signer.interface';
import type {
  AuthUser,
  AuthChannel,
  CreateUserInput,
} from '../contracts/auth-user.types';
import { AuthKitJwtGuard } from '../guards/auth-kit-auth.guard';

const BCRYPT_ROUNDS = 10;

function getClientIp(req: Request): string {
  const forwarded = req.headers['x-forwarded-for'];
  if (typeof forwarded === 'string') return forwarded.split(',')[0].trim();
  return req.ip ?? req.socket.remoteAddress ?? '127.0.0.1';
}

/** 从标识中提取邮箱或手机号，用于 UserResolver */
function resolveIdentifier(
  channel: AuthChannel,
  identifier: string,
): { email?: string; countryCode?: string; phoneNumber?: string } {
  if (channel === 'email') return { email: identifier };
  // E.164 格式: +86 13800000000 -> countryCode='+86', phoneNumber='13800000000'
  const match = /^(\+\d{1,3})\s*(\d+)$/.exec(identifier);
  if (!match)
    throw new BadRequestException(
      '手机号格式错误，请使用 E.164 格式（如 +8613800000000）',
    );
  return { countryCode: match[1], phoneNumber: match[2] };
}

@Controller('uapi/auth')
export class AuthController {
  private userResolver: IUserResolver;
  private jwtSigner: IJwtSigner;

  constructor(
    private readonly verificationService: VerificationService,
    private readonly settingsService: AuthSettingsService,
    @Inject(AUTH_KIT_OPTIONS) options: AuthKitModuleOptions,
  ) {
    this.userResolver = options.userResolver;
    this.jwtSigner = options.jwtSigner;
  }

  /** 用户信息脱敏输出 */
  private maskUser(user: AuthUser, meta?: Record<string, unknown>) {
    return {
      id: user.id,
      userName: user.userName,
      email: user.email,
      emailVerified: !!user.emailVerifiedAt,
      phone: user.phoneNumber
        ? `${user.countryCode ?? ''}${user.phoneNumber}`
        : null,
      phoneVerified: !!user.phoneVerifiedAt,
      avatar: user.avatar,
      role: user.role,
      ...meta,
    };
  }

  // ---- 发送验证码 ----

  @Post('code/send')
  @HttpCode(200)
  async sendCode(@Body() body: SendCodeDto, @Req() req: Request) {
    const { channel, identifier, purpose } = body;
    await this.verificationService.generateAndSendCode(
      channel,
      identifier,
      purpose,
      getClientIp(req),
    );
    return { code: 0, data: null };
  }

  // ---- 验证码登录 ----

  @Post('login/code')
  @HttpCode(200)
  async loginByCode(@Body() body: VerifyCodeLoginDto) {
    const { channel, identifier, code } = body;
    await this.verificationService.verifyCode(
      channel,
      identifier,
      'login',
      code,
    );

    // 查用户 or 创建
    let user: AuthUser | null;
    if (channel === 'email') {
      user = await this.userResolver.findByEmail(identifier);
      if (!user) {
        user = await this.userResolver.createUser({
          email: identifier,
          userName: `u_${generateShortId()}`,
        });
        await this.userResolver.markEmailVerified(user.id);
      }
    } else {
      const { countryCode, phoneNumber } = resolveIdentifier(
        channel,
        identifier,
      );
      user = await this.userResolver.findByPhone(countryCode!, phoneNumber!);
      if (!user) {
        user = await this.userResolver.createUser({
          countryCode: countryCode!,
          phoneNumber: phoneNumber!,
          userName: `u_${generateShortId()}`,
        });
        await this.userResolver.markPhoneVerified(user.id);
      }
    }

    if (user.banned) throw new BadRequestException('账号已被封禁');

    const token = this.jwtSigner.sign({
      userId: user.id,
      userName: user.userName,
      role: user.role,
      tokenVersion: user.tokenVersion,
    });
    return { code: 0, data: token, extra: this.maskUser(user) };
  }

  // ---- 密码登录 ----

  @Post('login/password')
  @HttpCode(200)
  async loginByPassword(@Body() body: LoginPasswordDto) {
    const { channel, identifier, password } = body;
    let user: AuthUser | null;
    if (channel === 'email') {
      user = await this.userResolver.findByEmail(identifier);
    } else {
      const { countryCode, phoneNumber } = resolveIdentifier(
        channel,
        identifier,
      );
      user = await this.userResolver.findByPhone(countryCode!, phoneNumber!);
    }
    if (!user) throw new BadRequestException('账号或密码错误');
    if (!user.password)
      throw new BadRequestException('该账号未设置密码，请使用验证码登录');
    if (user.banned) throw new BadRequestException('账号已被封禁');

    const valid = await bcrypt.compare(password, user.password);
    if (!valid) throw new BadRequestException('账号或密码错误');

    const token = this.jwtSigner.sign({
      userId: user.id,
      userName: user.userName,
      role: user.role,
      tokenVersion: user.tokenVersion,
    });
    return { code: 0, data: token, extra: this.maskUser(user) };
  }

  // ---- 注册 ----

  @Post('register')
  @HttpCode(200)
  async register(@Body() body: AuthRegisterDto) {
    const { channel, identifier, code, password } = body;
    await this.verificationService.verifyCode(
      channel,
      identifier,
      'register',
      code,
    );

    // 检查是否已存在
    let existing: AuthUser | null;
    if (channel === 'email') {
      existing = await this.userResolver.findByEmail(identifier);
    } else {
      const { countryCode, phoneNumber } = resolveIdentifier(
        channel,
        identifier,
      );
      existing = await this.userResolver.findByPhone(
        countryCode!,
        phoneNumber!,
      );
    }
    if (existing) throw new BadRequestException('该账号已注册');

    const hashedPassword = password
      ? await bcrypt.hash(password, BCRYPT_ROUNDS)
      : undefined;
    const userData: CreateUserInput = { userName: `u_${generateShortId()}` };
    if (channel === 'email') {
      userData.email = identifier;
    } else {
      const { countryCode, phoneNumber } = resolveIdentifier(
        channel,
        identifier,
      );
      userData.countryCode = countryCode;
      userData.phoneNumber = phoneNumber;
    }
    if (hashedPassword) userData.password = hashedPassword;

    const user = await this.userResolver.createUser(userData);
    if (channel === 'email') {
      await this.userResolver.markEmailVerified(user.id);
    } else {
      await this.userResolver.markPhoneVerified(user.id);
    }

    const token = this.jwtSigner.sign({
      userId: user.id,
      userName: user.userName,
      role: user.role,
      tokenVersion: user.tokenVersion,
    });
    return { code: 0, data: token, extra: this.maskUser(user) };
  }

  // ---- 绑定通道 ----

  @Post('bind')
  @HttpCode(200)
  @UseGuards(AuthKitJwtGuard)
  async bind(
    @Body() body: BindDto,
    @Req() req: Request & { user?: { userId: number } },
  ) {
    const { channel, identifier, code } = body;
    await this.verificationService.verifyCode(
      channel,
      identifier,
      'bind',
      code,
    );

    const userId = req.user?.userId;
    if (!userId) throw new BadRequestException('未登录');

    const bindParams: {
      email?: string;
      countryCode?: string;
      phoneNumber?: string;
    } = {};
    if (channel === 'email') {
      bindParams.email = identifier;
    } else {
      const { countryCode, phoneNumber } = resolveIdentifier(
        channel,
        identifier,
      );
      bindParams.countryCode = countryCode;
      bindParams.phoneNumber = phoneNumber;
    }
    await this.userResolver.bindIdentifier(userId, { channel, ...bindParams });

    const user = await this.userResolver.findById(userId);
    if (!user) throw new BadRequestException('用户不存在');
    return { code: 0, data: this.maskUser(user) };
  }

  // ---- 重置密码 ----

  @Post('reset-password')
  @HttpCode(200)
  async resetPassword(@Body() body: ResetPasswordDto) {
    const { channel, identifier, code, newPassword } = body;
    await this.verificationService.verifyCode(
      channel,
      identifier,
      'reset_password',
      code,
    );

    let user: AuthUser | null;
    if (channel === 'email') {
      user = await this.userResolver.findByEmail(identifier);
    } else {
      const { countryCode, phoneNumber } = resolveIdentifier(
        channel,
        identifier,
      );
      user = await this.userResolver.findByPhone(countryCode!, phoneNumber!);
    }
    if (!user) throw new BadRequestException('账号不存在');

    const hashed = await bcrypt.hash(newPassword, BCRYPT_ROUNDS);
    await this.userResolver.updatePassword(user.id, hashed);
    return { code: 0, data: null };
  }

  // ---- 公开配置 ----

  @Get('public-config')
  async publicConfig() {
    const settings = await this.settingsService.get();
    return {
      code: 0,
      data: {
        huaweiGetAuthCodeEnabled: settings.huaweiGetAuthCodeEnabled,
        huaweiQuickLoginEnabled: settings.huaweiQuickLoginEnabled,
        huaweiPrimaryFlow: settings.huaweiPrimaryFlow,
        appleSignInEnabled: settings.appleSignInEnabled,
        supportedCountryCodes: getSupportedCountryCodes(),
      },
    };
  }
}

/** 生成短 ID */
function generateShortId(): string {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  let id = '';
  for (let i = 0; i < 10; i++) {
    id += chars[Math.floor(Math.random() * chars.length)];
  }
  return id;
}

/** 国际区号列表 */
function getSupportedCountryCodes(): Array<{
  code: string;
  dialCode: string;
  nameZh: string;
  nameEn: string;
}> {
  return [
    { code: 'CN', dialCode: '+86', nameZh: '中国大陆', nameEn: 'China' },
    { code: 'US', dialCode: '+1', nameZh: '美国', nameEn: 'United States' },
    { code: 'HK', dialCode: '+852', nameZh: '中国香港', nameEn: 'Hong Kong' },
    { code: 'TW', dialCode: '+886', nameZh: '中国台湾', nameEn: 'Taiwan' },
    { code: 'SG', dialCode: '+65', nameZh: '新加坡', nameEn: 'Singapore' },
    { code: 'GB', dialCode: '+44', nameZh: '英国', nameEn: 'United Kingdom' },
    { code: 'JP', dialCode: '+81', nameZh: '日本', nameEn: 'Japan' },
    { code: 'KR', dialCode: '+82', nameZh: '韩国', nameEn: 'South Korea' },
    { code: 'MY', dialCode: '+60', nameZh: '马来西亚', nameEn: 'Malaysia' },
    { code: 'ID', dialCode: '+62', nameZh: '印度尼西亚', nameEn: 'Indonesia' },
    { code: 'TH', dialCode: '+66', nameZh: '泰国', nameEn: 'Thailand' },
    { code: 'IN', dialCode: '+91', nameZh: '印度', nameEn: 'India' },
    { code: 'AU', dialCode: '+61', nameZh: '澳大利亚', nameEn: 'Australia' },
    { code: 'CA', dialCode: '+1', nameZh: '加拿大', nameEn: 'Canada' },
    { code: 'DE', dialCode: '+49', nameZh: '德国', nameEn: 'Germany' },
    { code: 'FR', dialCode: '+33', nameZh: '法国', nameEn: 'France' },
    { code: 'IT', dialCode: '+39', nameZh: '意大利', nameEn: 'Italy' },
    { code: 'RU', dialCode: '+7', nameZh: '俄罗斯', nameEn: 'Russia' },
    { code: 'BR', dialCode: '+55', nameZh: '巴西', nameEn: 'Brazil' },
    { code: 'VN', dialCode: '+84', nameZh: '越南', nameEn: 'Vietnam' },
    { code: 'PH', dialCode: '+63', nameZh: '菲律宾', nameEn: 'Philippines' },
    { code: 'AE', dialCode: '+971', nameZh: '阿联酋', nameEn: 'UAE' },
    {
      code: 'SA',
      dialCode: '+966',
      nameZh: '沙特阿拉伯',
      nameEn: 'Saudi Arabia',
    },
    { code: 'NL', dialCode: '+31', nameZh: '荷兰', nameEn: 'Netherlands' },
    { code: 'SE', dialCode: '+46', nameZh: '瑞典', nameEn: 'Sweden' },
    { code: 'CH', dialCode: '+41', nameZh: '瑞士', nameEn: 'Switzerland' },
    { code: 'NZ', dialCode: '+64', nameZh: '新西兰', nameEn: 'New Zealand' },
    { code: 'MX', dialCode: '+52', nameZh: '墨西哥', nameEn: 'Mexico' },
    { code: 'ES', dialCode: '+34', nameZh: '西班牙', nameEn: 'Spain' },
    { code: 'PT', dialCode: '+351', nameZh: '葡萄牙', nameEn: 'Portugal' },
  ];
}
