import { Injectable, BadRequestException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { User } from '../user/user.entity';
import type {
  IUserResolver,
  AuthUser,
  CreateUserInput,
  AuthChannel,
  ThirdPartyProvider,
} from '@auth-kit';

function toAuthUser(user: User): AuthUser {
  return {
    id: user.id,
    userName: user.userName,
    email: user.email,
    emailVerifiedAt: user.emailVerifiedAt,
    countryCode: user.countryCode,
    phoneNumber: user.phoneNumber,
    phoneVerifiedAt: user.phoneVerifiedAt,
    huaweiUnionId: user.huaweiUnionId,
    huaweiOpenId: user.huaweiOpenId,
    appleSubject: user.appleSubject,
    appleEmailRelay: user.appleEmailRelay,
    password: user.password,
    role: user.role,
    banned: user.banned,
    tokenVersion: user.tokenVersion,
  };
}

function defaultAvatar(name: string) {
  return `https://ui-avatars.com/api/?name=${encodeURIComponent(name)}&background=0f3460&color=fff&size=128`;
}

/**
 * ChatGpt 项目的 IUserResolver 实现。
 * 这是 auth-kit lib 与宿主 User 表的桥接点。
 */
@Injectable()
export class ChatGptUserResolver implements IUserResolver {
  constructor(
    @InjectRepository(User)
    private readonly userRepo: Repository<User>,
  ) {}

  async findByEmail(email: string): Promise<AuthUser | null> {
    const user = await this.userRepo.findOne({ where: { email } });
    return user ? toAuthUser(user) : null;
  }

  async findByPhone(
    countryCode: string,
    phoneNumber: string,
  ): Promise<AuthUser | null> {
    const user = await this.userRepo.findOne({
      where: { countryCode, phoneNumber },
    });
    return user ? toAuthUser(user) : null;
  }

  async findByHuaweiUnionId(unionId: string): Promise<AuthUser | null> {
    const user = await this.userRepo.findOne({
      where: { huaweiUnionId: unionId },
    });
    return user ? toAuthUser(user) : null;
  }

  async findByAppleSubject(subject: string): Promise<AuthUser | null> {
    const user = await this.userRepo.findOne({
      where: { appleSubject: subject },
    });
    return user ? toAuthUser(user) : null;
  }

  async findByUserName(userName: string): Promise<AuthUser | null> {
    const user = await this.userRepo.findOne({ where: { userName } });
    return user ? toAuthUser(user) : null;
  }

  async findById(id: number): Promise<AuthUser | null> {
    const user = await this.userRepo.findOne({ where: { id } });
    return user ? toAuthUser(user) : null;
  }

  async createUser(input: CreateUserInput): Promise<AuthUser> {
    const user = this.userRepo.create({
      userName: input.userName ?? `u_${nanoid()}`,
      email: input.email ?? null,
      countryCode: input.countryCode ?? null,
      phoneNumber: input.phoneNumber ?? null,
      password: input.password ?? null,
      role: input.role ?? 'user',
      avatar: defaultAvatar(input.userName ?? 'user'),
    });
    await this.userRepo.save(user);
    return toAuthUser(user);
  }

  async createPendingThirdPartyUser(params: {
    provider: ThirdPartyProvider;
    unionId?: string;
    openId?: string;
    subject?: string;
    emailRelay?: string;
  }): Promise<AuthUser> {
    const user = this.userRepo.create({
      userName: `u_${nanoid()}`,
      password: null,
      avatar: defaultAvatar('user'),
      role: 'user',
      huaweiUnionId:
        params.provider === 'huawei' ? (params.unionId ?? null) : null,
      huaweiOpenId:
        params.provider === 'huawei' ? (params.openId ?? null) : null,
      appleSubject:
        params.provider === 'apple' ? (params.subject ?? null) : null,
      appleEmailRelay:
        params.provider === 'apple' ? (params.emailRelay ?? null) : null,
    });
    await this.userRepo.save(user);
    return toAuthUser(user);
  }

  async bindIdentifier(
    userId: number,
    params: {
      channel?: AuthChannel;
      email?: string;
      countryCode?: string;
      phoneNumber?: string;
      provider?: ThirdPartyProvider;
      unionId?: string;
      openId?: string;
      subject?: string;
      emailRelay?: string;
    },
  ): Promise<AuthUser> {
    const user = await this.userRepo.findOne({ where: { id: userId } });
    if (!user) throw new BadRequestException('用户不存在');

    if (params.email !== undefined) user.email = params.email;
    if (params.countryCode !== undefined) user.countryCode = params.countryCode;
    if (params.phoneNumber !== undefined) user.phoneNumber = params.phoneNumber;
    if (params.provider === 'huawei') {
      if (params.unionId) user.huaweiUnionId = params.unionId;
      if (params.openId) user.huaweiOpenId = params.openId;
    }
    if (params.provider === 'apple') {
      if (params.subject) user.appleSubject = params.subject;
      if (params.emailRelay) user.appleEmailRelay = params.emailRelay;
    }
    await this.userRepo.save(user);
    return toAuthUser(user);
  }

  async bindPendingThirdPartyIdentifier(
    userId: number,
    provider: ThirdPartyProvider,
    params: {
      channel: AuthChannel;
      email?: string;
      countryCode?: string;
      phoneNumber?: string;
    },
  ): Promise<AuthUser> {
    return this.userRepo.manager.transaction(async (manager) => {
      const repo = manager.getRepository(User);
      const user = await repo.findOne({
        where: { id: userId },
        lock: { mode: 'pessimistic_write' },
      });
      if (!user || user.banned) {
        throw new BadRequestException('bindTicket 无效或已过期，请重新登录');
      }

      const providerMatches =
        provider === 'huawei' ? !!user.huaweiUnionId : !!user.appleSubject;
      if (
        !providerMatches ||
        user.email !== null ||
        user.phoneNumber !== null
      ) {
        throw new BadRequestException('bindTicket 已使用或与登录方式不匹配');
      }

      if (params.channel === 'email') {
        if (!params.email) throw new BadRequestException('邮箱不能为空');
        const existing = await repo.findOne({
          where: { email: params.email },
        });
        if (existing && existing.id !== userId) {
          throw new BadRequestException('该邮箱已被其他账号绑定');
        }
        user.email = params.email;
        user.emailVerifiedAt = new Date();
      } else {
        if (!params.countryCode || !params.phoneNumber) {
          throw new BadRequestException('手机号不能为空');
        }
        const existing = await repo.findOne({
          where: {
            countryCode: params.countryCode,
            phoneNumber: params.phoneNumber,
          },
        });
        if (existing && existing.id !== userId) {
          throw new BadRequestException('该手机号已被其他账号绑定');
        }
        user.countryCode = params.countryCode;
        user.phoneNumber = params.phoneNumber;
        user.phoneVerifiedAt = new Date();
      }

      await repo.save(user);
      return toAuthUser(user);
    });
  }

  async unbindThirdParty(
    userId: number,
    provider: ThirdPartyProvider,
  ): Promise<void> {
    if (provider === 'huawei') {
      await this.userRepo
        .createQueryBuilder()
        .update(User)
        .set({
          huaweiUnionId: null,
          huaweiOpenId: null,
          tokenVersion: () => '"tokenVersion" + 1',
        })
        .where('id = :userId', { userId })
        .execute();
    } else {
      await this.userRepo
        .createQueryBuilder()
        .update(User)
        .set({
          appleSubject: null,
          appleEmailRelay: null,
          tokenVersion: () => '"tokenVersion" + 1',
        })
        .where('id = :userId', { userId })
        .execute();
    }
  }

  async unbindEmail(userId: number): Promise<void> {
    await this.userRepo
      .createQueryBuilder()
      .update(User)
      .set({
        email: null,
        emailVerifiedAt: null,
        tokenVersion: () => '"tokenVersion" + 1',
      })
      .where('id = :userId', { userId })
      .execute();
  }

  async unbindPhone(userId: number): Promise<void> {
    await this.userRepo
      .createQueryBuilder()
      .update(User)
      .set({
        countryCode: null,
        phoneNumber: null,
        phoneVerifiedAt: null,
        tokenVersion: () => '"tokenVersion" + 1',
      })
      .where('id = :userId', { userId })
      .execute();
  }

  async updatePassword(userId: number, newPasswordHash: string): Promise<void> {
    await this.userRepo
      .createQueryBuilder()
      .update(User)
      .set({
        password: newPasswordHash,
        tokenVersion: () => '"tokenVersion" + 1',
      })
      .where('id = :userId', { userId })
      .execute();
  }

  async markEmailVerified(userId: number): Promise<void> {
    await this.userRepo.update(userId, { emailVerifiedAt: new Date() });
  }

  async markPhoneVerified(userId: number): Promise<void> {
    await this.userRepo.update(userId, { phoneVerifiedAt: new Date() });
  }
}

function nanoid(length = 10): string {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  let id = '';
  for (let i = 0; i < length; i++) {
    id += chars[Math.floor(Math.random() * chars.length)];
  }
  return id;
}
