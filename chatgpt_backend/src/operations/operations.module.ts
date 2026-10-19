import { Module } from '@nestjs/common';
import { AccessModule } from '../access/access.module';
import { OperationsController } from './operations.controller';
import { OperationsService } from './operations.service';
@Module({
  imports: [AccessModule],
  providers: [OperationsService],
  controllers: [OperationsController],
  exports: [OperationsService],
})
export class OperationsModule {}
