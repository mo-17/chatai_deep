import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { AuthSettings } from '../verification/entities/auth-settings.entity';

/**
 * 认证设置服务 —— 带 30 秒内存缓存读取 ak_auth_settings。
 * 由 AuthKitModule 导出，宿主模块可直接注入。
 */
@Injectable()
export class AuthSettingsService {
  private cache: { data: AuthSettings; ts: number } | null = null;
  private readonly cacheTtlMs = 30_000;

  constructor(
    @InjectRepository(AuthSettings)
    private readonly repo: Repository<AuthSettings>,
  ) {}

  async get(): Promise<AuthSettings> {
    if (this.cache && Date.now() - this.cache.ts < this.cacheTtlMs) {
      return this.cache.data;
    }
    let row = await this.repo.findOne({ where: { id: 1 } });
    if (!row) {
      row = this.repo.create({ id: 1 });
      await this.repo.save(row);
    }
    this.cache = { data: row, ts: Date.now() };
    return row;
  }

  async update(data: Partial<AuthSettings>): Promise<AuthSettings> {
    await this.repo.update(1, data);
    this.cache = null; // 清除缓存
    return this.get();
  }
}
