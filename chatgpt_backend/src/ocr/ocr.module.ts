import { Module } from '@nestjs/common';
import { OcrController, OcrUploadInterceptor } from './ocr.controller';
import { OcrService } from './ocr.service';
import { OcrAdminController } from './ocr-admin.controller';

@Module({
  controllers: [OcrController, OcrAdminController],
  providers: [OcrService, OcrUploadInterceptor],
})
export class OcrModule {}
