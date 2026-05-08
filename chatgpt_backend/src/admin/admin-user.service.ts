import { Injectable, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository, Like } from 'typeorm';
import * as bcrypt from 'bcryptjs';
import { User } from '../user/user.entity';
import { Usage } from '../chat/usage.entity';

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
      where['userName'] = Like(`%${query.keyword}%`);
    }
    if (query.role) {
      where['role'] = query.role;
    }
    if (query.banned !== undefined && query.banned !== '') {
      where['banned'] = query.banned === 'true';
    }

    const [list, total] = await this.userRepo.findAndCount({
      where,
      select: ['id', 'userName', 'avatar', 'imoocId', 'role', 'banned'],
      take: pageSize,
      skip: (page - 1) * pageSize,
      order: { id: 'DESC' },
    });

    return { list, total, page, pageSize };
  }

  async detail(id: number) {
    const user = await this.userRepo.findOne({
      where: { id },
      select: ['id', 'userName', 'avatar', 'imoocId', 'role', 'banned'],
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
    if (body.avatar !== undefined) user.avatar = body.avatar;
    if (body.role !== undefined) user.role = body.role;
    if (body.banned !== undefined) user.banned = body.banned;
    await this.userRepo.save(user);
    const { password: _password, ...rest } = user;
    return rest;
  }

  async resetPassword(id: number, password: string) {
    const user = await this.userRepo.findOne({ where: { id } });
    if (!user) throw new NotFoundException('用户不存在');
    user.password = await bcrypt.hash(password, 10);
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
}
