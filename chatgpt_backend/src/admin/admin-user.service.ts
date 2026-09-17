import { Injectable, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository, Like } from 'typeorm';
import * as bcrypt from 'bcryptjs';
import { User } from '../user/user.entity';
import { Usage } from '../chat/usage.entity';
import { BCRYPT_ROUNDS } from '../auth/bcrypt.const';

@Injectable()
export class AdminUserService {
  constructor(
    @InjectRepository(User)
    private userRepo: Repository<User>,
  ) {}

  async list(query: {
    keyword?: string;
    page?: number;
    pageSize?: number;
    role?: string;
    banned?: string;
  }) {
    const page = query.page || 1;
    const pageSize = query.pageSize || 10;
    const where: Record<string, unknown> = {};
    if (query.keyword) {
      const kw = query.keyword.replace(/[\\%_]/g, (c) => '\\' + c);
      where['userName'] = Like(`%${kw}%`);
    }
    if (query.role) {
      where['role'] = query.role;
    }
    if (query.banned !== undefined && query.banned !== '') {
      where['banned'] = query.banned === 'true';
    }

    const [list, total] = await this.userRepo.findAndCount({
      where,
      select: [
        'id',
        'userName',
        'avatar',
        'imoocId',
        'role',
        'banned',
        'email',
        'emailVerifiedAt',
        'countryCode',
        'phoneNumber',
        'phoneVerifiedAt',
        'huaweiUnionId',
        'huaweiOpenId',
        'appleSubject',
        'appleEmailRelay',
      ],
      take: pageSize,
      skip: (page - 1) * pageSize,
      order: { id: 'DESC' },
    });

    return { list, total, page, pageSize };
  }

  async detail(id: number) {
    const user = await this.userRepo.findOne({
      where: { id },
      select: [
        'id',
        'userName',
        'avatar',
        'imoocId',
        'role',
        'banned',
        'email',
        'emailVerifiedAt',
        'countryCode',
        'phoneNumber',
        'phoneVerifiedAt',
        'huaweiUnionId',
        'huaweiOpenId',
        'appleSubject',
        'appleEmailRelay',
      ],
    });
    if (!user) throw new NotFoundException('用户不存在');
    return user;
  }

  async edit(
    id: number,
    body: { avatar?: string; role?: string; banned?: boolean },
  ) {
    const user = await this.userRepo.findOne({ where: { id } });
    if (!user) throw new NotFoundException('用户不存在');
    const securityStateChanged =
      (body.role !== undefined && body.role !== user.role) ||
      (body.banned !== undefined && body.banned !== user.banned);
    if (body.avatar !== undefined) user.avatar = body.avatar;
    if (body.role !== undefined) user.role = body.role;
    if (body.banned !== undefined) user.banned = body.banned;
    if (securityStateChanged) user.tokenVersion = (user.tokenVersion ?? 0) + 1;
    await this.userRepo.save(user);
    const { password: _password, ...rest } = user;
    return rest;
  }

  async resetPassword(id: number, password: string) {
    const user = await this.userRepo.findOne({ where: { id } });
    if (!user) throw new NotFoundException('用户不存在');
    user.password = await bcrypt.hash(password, BCRYPT_ROUNDS);
    user.tokenVersion = (user.tokenVersion ?? 0) + 1;
    await this.userRepo.save(user);
    return null;
  }

  async delete(id: number) {
    const user = await this.userRepo.findOne({ where: { id } });
    if (!user) throw new NotFoundException('用户不存在');
    // 事务删除 usage 记录和用户
    await this.userRepo.manager.transaction(async (manager) => {
      await manager.delete(Usage, { userId: id });
      await manager.delete(User, { id });
    });
    return null;
  }

  async unbindEmail(id: number) {
    const user = await this.userRepo.findOne({ where: { id } });
    if (!user) throw new NotFoundException('用户不存在');
    user.email = null;
    user.emailVerifiedAt = null;
    user.tokenVersion = (user.tokenVersion ?? 0) + 1;
    await this.userRepo.save(user);
    return null;
  }

  async unbindPhone(id: number) {
    const user = await this.userRepo.findOne({ where: { id } });
    if (!user) throw new NotFoundException('用户不存在');
    user.countryCode = null;
    user.phoneNumber = null;
    user.phoneVerifiedAt = null;
    user.tokenVersion = (user.tokenVersion ?? 0) + 1;
    await this.userRepo.save(user);
    return null;
  }

  async unbindHuawei(id: number) {
    const user = await this.userRepo.findOne({ where: { id } });
    if (!user) throw new NotFoundException('用户不存在');
    user.huaweiUnionId = null;
    user.huaweiOpenId = null;
    user.tokenVersion = (user.tokenVersion ?? 0) + 1;
    await this.userRepo.save(user);
    return null;
  }

  async unbindApple(id: number) {
    const user = await this.userRepo.findOne({ where: { id } });
    if (!user) throw new NotFoundException('用户不存在');
    user.appleSubject = null;
    user.appleEmailRelay = null;
    user.tokenVersion = (user.tokenVersion ?? 0) + 1;
    await this.userRepo.save(user);
    return null;
  }
}
