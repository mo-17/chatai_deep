import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { NoticeController } from './notice.controller';
import { NoticeService } from './notice.service';
import { Banner } from './banner.entity';

@Module({
  imports: [TypeOrmModule.forFeature([Banner])],
  controllers: [NoticeController],
  providers: [NoticeService],
  exports: [TypeOrmModule],
})
export class NoticeModule {}
