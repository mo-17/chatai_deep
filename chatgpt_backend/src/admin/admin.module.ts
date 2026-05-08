import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { User } from '../user/user.entity';
import { Banner } from '../notice/banner.entity';
import { AppVersion } from '../update/version.entity';
import { Usage } from '../chat/usage.entity';
import { AdminAuthController } from './admin-auth.controller';
import { AdminUserController } from './admin-user.controller';
import { AdminUserService } from './admin-user.service';
import { AdminBannerController } from './admin-banner.controller';
import { AdminBannerService } from './admin-banner.service';
import { AdminVersionController } from './admin-version.controller';
import { AdminVersionService } from './admin-version.service';
import { AdminUsageController } from './admin-usage.controller';
import { AdminUsageService } from './admin-usage.service';

@Module({
  imports: [TypeOrmModule.forFeature([User, Banner, AppVersion, Usage])],
  controllers: [
    AdminAuthController,
    AdminUserController,
    AdminBannerController,
    AdminVersionController,
    AdminUsageController,
  ],
  providers: [
    AdminUserService,
    AdminBannerService,
    AdminVersionService,
    AdminUsageService,
  ],
})
export class AdminModule {}
