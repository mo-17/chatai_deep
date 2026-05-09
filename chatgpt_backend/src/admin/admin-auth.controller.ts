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
import { BCRYPT_ROUNDS } from '../auth/bcrypt.const';
import { LoginDto } from '../user/dto/login.dto';
import { ChangePasswordDto } from './dto/change-password.dto';

@Controller('uapi/admin')
export class AdminAuthController {
  constructor(
    @InjectRepository(User)
    private userRepo: Repository<User>,
  ) {}

  @Post('login')
  @HttpCode(200)
  async login(@Body() body: LoginDto) {
    const { userName, password } = body;
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
    @Body() body: ChangePasswordDto,
  ) {
    const { oldPassword, newPassword } = body;
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
    user.password = await bcrypt.hash(newPassword, BCRYPT_ROUNDS);
    await this.userRepo.save(user);
    return { code: 0, data: null };
  }
}
