import {
  Controller,
  Post,
  Get,
  Body,
  Req,
  UseGuards,
  HttpCode,
  BadRequestException,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { Request } from 'express';
import * as bcrypt from 'bcryptjs';
import * as jwt from 'jsonwebtoken';
import { User } from '../user/user.entity';
import { AdminGuard } from '../auth/admin.guard';
import { JWT_SECRET, JwtPayload } from '../auth/jwt.const';

@Controller('uapi/admin')
export class AdminAuthController {
  constructor(
    @InjectRepository(User)
    private userRepo: Repository<User>,
  ) {}

  @Post('login')
  @HttpCode(200)
  async login(@Body() body: { userName?: string; password?: string }) {
    const { userName, password } = body;
    if (!userName || !password) {
      throw new BadRequestException('请输入账号和密码');
    }
    const user = await this.userRepo.findOne({ where: { userName } });
    if (!user || user.role !== 'admin') {
      throw new BadRequestException('账号或密码错误');
    }
    if (user.banned) {
      throw new BadRequestException('账号已被封禁');
    }
    const valid = await bcrypt.compare(password, user.password);
    if (!valid) {
      throw new BadRequestException('账号或密码错误');
    }
    const token = jwt.sign(
      { userId: user.id, userName: user.userName, role: user.role },
      JWT_SECRET,
      { expiresIn: '7d' },
    );
    return {
      code: 0,
      data: {
        token,
        admin: {
          id: user.id,
          userName: user.userName,
          avatar: user.avatar,
        },
      },
    };
  }

  @Get('me')
  @UseGuards(AdminGuard)
  async me(@Req() req: Request & { user: JwtPayload }) {
    const user = await this.userRepo.findOne({
      where: { id: req.user.userId },
      select: ['id', 'userName', 'avatar'],
    });
    return { code: 0, data: user };
  }

  @Post('change-password')
  @UseGuards(AdminGuard)
  @HttpCode(200)
  async changePassword(
    @Req() req: Request & { user: JwtPayload },
    @Body() body: { oldPassword?: string; newPassword?: string },
  ) {
    const { oldPassword, newPassword } = body;
    if (!oldPassword || !newPassword) {
      throw new BadRequestException('请输入旧密码和新密码');
    }
    const user = await this.userRepo.findOne({
      where: { id: req.user.userId },
    });
    if (!user) {
      throw new BadRequestException('用户不存在');
    }
    const valid = await bcrypt.compare(oldPassword, user.password);
    if (!valid) {
      throw new BadRequestException('旧密码错误');
    }
    user.password = await bcrypt.hash(newPassword, 10);
    await this.userRepo.save(user);
    return { code: 0, data: null };
  }
}
