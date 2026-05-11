import { Module, OnApplicationBootstrap, Injectable } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { User } from './user.entity';
import { UserService } from './user.service';
import { UserController } from './user.controller';
import * as bcrypt from 'bcryptjs';
import { BCRYPT_ROUNDS } from '../auth/bcrypt.const';

@Injectable()
export class UserSeedService implements OnApplicationBootstrap {
  constructor(
    @InjectRepository(User)
    private userRepo: Repository<User>,
  ) {}

  async onApplicationBootstrap() {
    const adminCount = await this.userRepo.count({ where: { role: 'admin' } });
    if (adminCount === 0) {
      const username = process.env.ADMIN_DEFAULT_USERNAME || 'admin';
      const password = process.env.ADMIN_DEFAULT_PASSWORD || 'admin123';
      if (
        process.env.NODE_ENV === 'production' &&
        (!process.env.ADMIN_DEFAULT_PASSWORD ||
          process.env.ADMIN_DEFAULT_PASSWORD === 'admin123')
      ) {
        throw new Error(
          '生产环境必须设置 ADMIN_DEFAULT_PASSWORD，且不能等于默认值',
        );
      }
      const hashed = await bcrypt.hash(password, BCRYPT_ROUNDS);
      await this.userRepo.save(
        this.userRepo.create({
          userName: username,
          password: hashed,
          role: 'admin',
          avatar: `https://ui-avatars.com/api/?name=${encodeURIComponent(username)}&background=0f3460&color=fff&size=128`,
          imoocId: '',
        }),
      );
      console.warn(
        `[seed] 默认管理员 ${username}/${password} 已创建，请尽快登录修改密码`,
      );
    }
  }
}

@Module({
  imports: [TypeOrmModule.forFeature([User])],
  controllers: [UserController],
  providers: [UserService, UserSeedService],
  exports: [UserService, TypeOrmModule],
})
export class UserModule {}
