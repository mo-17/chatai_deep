import {
  Controller,
  Post,
  Body,
  HttpCode,
  BadRequestException,
  Inject,
  UseGuards,
} from '@nestjs/common';
import { AUTH_KIT_OPTIONS } from '../auth-kit.tokens';
import type { AuthKitModuleOptions } from '../auth-kit.module';
import type { IUserResolver } from '../contracts/user-resolver.interface';
import type { IJwtSigner } from '../contracts/jwt-signer.interface';
import type { AuthUser } from '../contracts/auth-user.types';
import { VerificationService } from '../verification/verification.service';
import { HuaweiService } from '../third-party/huawei/huawei.service';
import { AppleService } from '../third-party/apple/apple.service';
import {
  ThirdParty,
  ThirdPartyEnabledGuard,
} from '../third-party/third-party-enabled.guard';
import * as jwt from 'jsonwebtoken';
import { randomUUID } from 'crypto';
import { requireAppSecretKey } from '../security/app-secret';

/**
 * 第三方登录 DTOs
 */
interface HuaweiLoginBody {
  mode: 'getAuthCode' | 'quickLogin';
  authCode?: string;
  accessToken?: string;
}

interface ThirdPartyBindBody {
  bindTicket: string;
  channel: 'email' | 'sms';
  identifier: string;
  code: string;
}

interface AppleLoginBody {
  identityToken: string;
  authorizationCode?: string;
  fullName?: Record<string, string>;
}

/** 将 userId 编码为 bindTicket（短期有效 JWT） */
function encodeBindTicket(
  userId: number,
  provider: 'huawei' | 'apple',
  salt: string,
): string {
  return jwt.sign({ purpose: 'third_party_bind', provider }, salt, {
    algorithm: 'HS256',
    audience: 'auth-kit:third-party-bind',
    issuer: 'auth-kit',
    subject: String(userId),
    jwtid: randomUUID(),
    expiresIn: '10m',
  });
}

/** 解码 bindTicket 得到 userId */
function decodeBindTicket(
  ticket: string,
  provider: 'huawei' | 'apple',
  salt: string,
): number {
  const payload = jwt.verify(ticket, salt, {
    algorithms: ['HS256'],
    audience: 'auth-kit:third-party-bind',
    issuer: 'auth-kit',
  }) as jwt.JwtPayload & {
    purpose?: string;
    provider?: string;
  };
  if (
    payload.purpose !== 'third_party_bind' ||
    payload.provider !== provider ||
    typeof payload.sub !== 'string' ||
    !/^[1-9]\d*$/.test(payload.sub)
  ) {
    throw new Error('bindTicket claims invalid');
  }
  return Number(payload.sub);
}

/** E.164 解析 */
function resolveIdentifier(channel: 'email' | 'sms', identifier: string) {
  if (channel === 'email') return { email: identifier };
  const m = /^(\+\d{1,3})\s*(\d+)$/.exec(identifier);
  if (!m)
    throw new BadRequestException(
      '手机号格式错误，请使用 E.164 格式（如 +8613800000000）',
    );
  return { countryCode: m[1], phoneNumber: m[2] };
}

@Controller('uapi/auth')
export class ThirdPartyController {
  private userResolver: IUserResolver;
  private jwtSigner: IJwtSigner;
  private bindSalt: string;

  constructor(
    private readonly verificationService: VerificationService,
    private readonly huaweiService: HuaweiService,
    private readonly appleService: AppleService,
    @Inject(AUTH_KIT_OPTIONS) options: AuthKitModuleOptions,
  ) {
    this.userResolver = options.userResolver;
    this.jwtSigner = options.jwtSigner;
    this.bindSalt = requireAppSecretKey(options.appSecretKey);
  }

  private maskUser(user: AuthUser) {
    return {
      id: user.id,
      userName: user.userName,
      email: user.email,
      phone: user.phoneNumber
        ? `${user.countryCode ?? ''}${user.phoneNumber}`
        : null,
      role: user.role,
    };
  }

  // ---- 华为登录 ----

  @Post('huawei/login')
  @HttpCode(200)
  @ThirdParty('huawei')
  @UseGuards(ThirdPartyEnabledGuard)
  async huaweiLogin(@Body() body: HuaweiLoginBody) {
    const { mode, authCode, accessToken } = body;

    let userInfo: { unionId: string; openId: string };
    if (mode === 'getAuthCode' && authCode) {
      userInfo = await this.huaweiService.verifyAuthCode(authCode);
    } else if (mode === 'quickLogin' && accessToken) {
      userInfo = await this.huaweiService.verifyQuickLoginToken(accessToken);
    } else {
      throw new BadRequestException('请提供 authCode 或 accessToken');
    }

    // 查找已绑定用户
    const user = await this.userResolver.findByHuaweiUnionId(userInfo.unionId);

    if (user) {
      if (user.banned) throw new BadRequestException('账号已被封禁');
      const token = this.jwtSigner.sign({
        userId: user.id,
        userName: user.userName,
        role: user.role,
        tokenVersion: user.tokenVersion,
      });
      return { code: 0, data: token, extra: this.maskUser(user) };
    }

    // 未绑定 → 创建待绑定用户，返回 bindTicket
    const pending = await this.userResolver.createPendingThirdPartyUser({
      provider: 'huawei',
      unionId: userInfo.unionId,
      openId: userInfo.openId,
    });
    const bindTicket = encodeBindTicket(pending.id, 'huawei', this.bindSalt);
    return { code: 0, data: { needBinding: true, bindTicket }, extra: {} };
  }

  @Post('huawei/bind-and-login')
  @HttpCode(200)
  @ThirdParty('huawei')
  @UseGuards(ThirdPartyEnabledGuard)
  async huaweiBindAndLogin(@Body() body: ThirdPartyBindBody) {
    const { bindTicket, channel, identifier, code } = body;

    // 解码 bindTicket 得到待绑定用户 ID
    let userId: number;
    try {
      userId = decodeBindTicket(bindTicket, 'huawei', this.bindSalt);
    } catch {
      throw new BadRequestException('bindTicket 无效或已过期，请重新登录');
    }

    await this.verificationService.verifyCode(
      channel,
      identifier,
      'bind',
      code,
    );

    const resolved = resolveIdentifier(channel, identifier);
    const user = await this.userResolver.bindPendingThirdPartyIdentifier(
      userId,
      'huawei',
      {
        channel,
        ...resolved,
      },
    );

    const token = this.jwtSigner.sign({
      userId: user.id,
      userName: user.userName,
      role: user.role,
      tokenVersion: user.tokenVersion,
    });
    return { code: 0, data: token, extra: this.maskUser(user) };
  }

  // ---- Apple 登录 ----

  @Post('apple/login')
  @HttpCode(200)
  @ThirdParty('apple')
  @UseGuards(ThirdPartyEnabledGuard)
  async appleLogin(@Body() body: AppleLoginBody) {
    const { identityToken } = body;

    const appleInfo =
      await this.appleService.verifyIdentityToken(identityToken);

    // 查找已绑定用户
    const user = await this.userResolver.findByAppleSubject(appleInfo.subject);

    if (user) {
      if (user.banned) throw new BadRequestException('账号已被封禁');
      const token = this.jwtSigner.sign({
        userId: user.id,
        userName: user.userName,
        role: user.role,
        tokenVersion: user.tokenVersion,
      });
      return { code: 0, data: token, extra: this.maskUser(user) };
    }

    // 未绑定 → 创建待绑定用户，返回 bindTicket
    const pending = await this.userResolver.createPendingThirdPartyUser({
      provider: 'apple',
      subject: appleInfo.subject,
      emailRelay: appleInfo.email,
    });
    const bindTicket = encodeBindTicket(pending.id, 'apple', this.bindSalt);
    return { code: 0, data: { needBinding: true, bindTicket }, extra: {} };
  }

  @Post('apple/bind-and-login')
  @HttpCode(200)
  @ThirdParty('apple')
  @UseGuards(ThirdPartyEnabledGuard)
  async appleBindAndLogin(@Body() body: ThirdPartyBindBody) {
    const { bindTicket, channel, identifier, code } = body;

    let userId: number;
    try {
      userId = decodeBindTicket(bindTicket, 'apple', this.bindSalt);
    } catch {
      throw new BadRequestException('bindTicket 无效或已过期，请重新登录');
    }

    await this.verificationService.verifyCode(
      channel,
      identifier,
      'bind',
      code,
    );

    const resolved = resolveIdentifier(channel, identifier);
    const user = await this.userResolver.bindPendingThirdPartyIdentifier(
      userId,
      'apple',
      {
        channel,
        ...resolved,
      },
    );

    const token = this.jwtSigner.sign({
      userId: user.id,
      userName: user.userName,
      role: user.role,
      tokenVersion: user.tokenVersion,
    });
    return { code: 0, data: token, extra: this.maskUser(user) };
  }
}
