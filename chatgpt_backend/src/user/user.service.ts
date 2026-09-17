import { Injectable, BadRequestException, GoneException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { User } from './user.entity';
import * as bcrypt from 'bcryptjs';
import * as jwt from 'jsonwebtoken';
import { JWT_SECRET } from '../auth/jwt.const';
import { BCRYPT_ROUNDS } from '../auth/bcrypt.const';

function defaultAvatar(name: string) {
  return `https://ui-avatars.com/api/?name=${encodeURIComponent(name)}&background=0f3460&color=fff&size=128`;
}

@Injectable()
export class UserService {
  constructor(
    @InjectRepository(User)
    private userRepo: Repository<User>,
  ) {}

  async register(userName: string, password: string) {
    const existing = await this.userRepo.findOne({ where: { userName } });
    if (existing) {
      throw new BadRequestException('用户名已存在');
    }
    const hashedPassword = await bcrypt.hash(password, BCRYPT_ROUNDS);
    const user = this.userRepo.create({
      userName,
      password: hashedPassword,
      avatar: defaultAvatar(userName),
      imoocId: '',
    });
    await this.userRepo.save(user);
    const token = jwt.sign(
      {
        userId: user.id,
        userName,
        role: user.role,
        tokenVersion: user.tokenVersion,
      },
      JWT_SECRET,
      { expiresIn: '30d' },
    );
    return {
      code: 0,
      data: token,
      extra: {
        userName: user.userName,
        avatar: user.avatar,
        imoocId: user.imoocId,
      },
    };
  }

  async login(userName: string, password: string) {
    const user = await this.userRepo.findOne({ where: { userName } });
    if (!user) {
      throw new BadRequestException('用户名或密码错误');
    }
    if (user.banned) {
      throw new BadRequestException('账号已被封禁');
    }
    if (!user.password) {
      throw new BadRequestException('该账号未设置密码，请使用验证码登录');
    }
    const valid = await bcrypt.compare(password, user.password);
    if (!valid) {
      throw new BadRequestException('用户名或密码错误');
    }
    const token = jwt.sign(
      {
        userId: user.id,
        userName,
        role: user.role,
        tokenVersion: user.tokenVersion,
      },
      JWT_SECRET,
      user.role === 'admin' ? { expiresIn: '7d' } : { expiresIn: '30d' },
    );
    const avatar = user.avatar || defaultAvatar(user.userName);
    return {
      code: 0,
      data: token,
      extra: {
        userName: user.userName,
        avatar,
        imoocId: user.imoocId,
      },
    };
  }

  requestPasswordReset(_userName: string): Promise<never> {
    return Promise.reject(
      new GoneException(
        '旧版密码重置接口已停用，请使用 /uapi/auth/reset-password',
      ),
    );
  }

  confirmPasswordReset(
    _userName: string,
    _code: string,
    _newPassword: string,
  ): Promise<never> {
    return Promise.reject(
      new GoneException(
        '旧版密码重置接口已停用，请使用 /uapi/auth/reset-password',
      ),
    );
  }
}
