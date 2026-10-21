import {
  BadRequestException,
  Body,
  Controller,
  Get,
  Header,
  Patch,
  Req,
  UseGuards,
} from '@nestjs/common';
import { AdminGuard } from '../auth/admin.guard';
import type { AuthenticatedRequest } from '../auth/jwt.guard';
import { OcrService } from './ocr.service';

export function validateOcrSettings(value: unknown) {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    throw new BadRequestException('OCR 配置格式无效');
  const body = value as Record<string, unknown>;
  if (
    Object.keys(body).sort().join(',') !==
    'globalHourly,ownerHourly,ownerOverrides'
  )
    throw new BadRequestException('OCR 配置字段无效');
  if (
    !Number.isInteger(body.ownerHourly) ||
    (body.ownerHourly as number) < 0 ||
    (body.ownerHourly as number) > 200 ||
    !Number.isInteger(body.globalHourly) ||
    (body.globalHourly as number) < 1 ||
    (body.globalHourly as number) > 1000
  ) {
    throw new BadRequestException(
      '账号每小时限额为 0～200，全局每小时限额为 1～1000',
    );
  }
  const overrides = body.ownerOverrides;
  if (
    !overrides ||
    typeof overrides !== 'object' ||
    Array.isArray(overrides) ||
    Object.keys(overrides).length > 100
  )
    throw new BadRequestException('最多设置 100 个账号额度');
  for (const [owner, limit] of Object.entries(overrides)) {
    if (
      !/^(user|admin):[1-9][0-9]{0,15}$/.test(owner) ||
      !Number.isInteger(limit) ||
      (limit as number) < 0 ||
      (limit as number) > 200
    )
      throw new BadRequestException(
        '账号格式应为 user:用户ID 或 admin:管理员ID，限额为 0～200',
      );
  }
  return {
    ownerHourly: body.ownerHourly as number,
    globalHourly: body.globalHourly as number,
    ownerOverrides: { ...overrides },
  };
}

@Controller('uapi/admin/ocr')
@UseGuards(AdminGuard)
export class OcrAdminController {
  constructor(private readonly service: OcrService) {}
  private owner(req: AuthenticatedRequest) {
    return `admin:${req.user!.userId}`;
  }
  @Get('overview')
  @Header('Cache-Control', 'no-store')
  async overview(@Req() req: AuthenticatedRequest) {
    return {
      code: 0,
      data: await this.service.request(this.owner(req), '/admin/overview'),
    };
  }
  @Patch('settings')
  @Header('Cache-Control', 'no-store')
  async configure(@Req() req: AuthenticatedRequest, @Body() body: unknown) {
    const settings = validateOcrSettings(body);
    return {
      code: 0,
      data: await this.service.request(
        this.owner(req),
        '/admin/settings',
        'PUT',
        Buffer.from(JSON.stringify(settings)),
      ),
    };
  }
}
