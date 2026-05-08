import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { UpdateController } from './update.controller';
import { UpdateService } from './update.service';
import { AppVersion } from './version.entity';

@Module({
  imports: [TypeOrmModule.forFeature([AppVersion])],
  controllers: [UpdateController],
  providers: [UpdateService],
  exports: [TypeOrmModule],
})
export class UpdateModule {}
