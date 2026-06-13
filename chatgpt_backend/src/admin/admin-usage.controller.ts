import { Controller, Get, Query, Res, UseGuards } from '@nestjs/common';
import type { Response } from 'express';
import { AdminUsageService } from './admin-usage.service';
import { AdminGuard } from '../auth/admin.guard';

/// 导出 CSV 的查询参数（全部可选，均为 query string）。
interface ExportUsageQuery {
  userId?: string;
  provider?: string;
  model?: string;
  from?: string;
  to?: string;
}

@Controller('uapi/admin/usage')
@UseGuards(AdminGuard)
export class AdminUsageController {
  constructor(private readonly svc: AdminUsageService) {}

  @Get('list')
  async list(
    @Query('userId') userId?: string,
    @Query('provider') provider?: string,
    @Query('model') model?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    const data = await this.svc.list({
      userId,
      provider,
      model,
      from,
      to,
      page: parseInt(page || '1', 10),
      pageSize: parseInt(pageSize || '10', 10),
    });
    return { code: 0, data };
  }

  @Get('summary')
  async summary() {
    const data = await this.svc.summary();
    return { code: 0, data };
  }

  @Get('series')
  async series(@Query('from') from?: string, @Query('to') to?: string) {
    const data = await this.svc.series(from, to);
    return { code: 0, data };
  }

  @Get('by-provider')
  async byProvider() {
    const data = await this.svc.byProvider();
    return { code: 0, data };
  }

  @Get('top-users')
  async topUsers(@Query('limit') limit?: string, @Query('days') days?: string) {
    const data = await this.svc.topUsers(
      parseInt(limit || '10', 10),
      parseInt(days || '7', 10),
    );
    return { code: 0, data };
  }

  @Get('export')
  async exportCsv(@Query() query: ExportUsageQuery, @Res() res: Response) {
    const { userId, provider, model, from, to } = query;
    const csv = await this.svc.exportCsv({ userId, provider, model, from, to });
    const now = new Date();
    const ts =
      now.getFullYear().toString() +
      String(now.getMonth() + 1).padStart(2, '0') +
      String(now.getDate()).padStart(2, '0') +
      '-' +
      String(now.getHours()).padStart(2, '0') +
      String(now.getMinutes()).padStart(2, '0') +
      String(now.getSeconds()).padStart(2, '0');
    res.setHeader('Content-Type', 'text/csv; charset=utf-8');
    res.setHeader(
      'Content-Disposition',
      `attachment; filename="usage-${ts}.csv"`,
    );
    res.send(csv);
  }
}
