import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository, type EntityManager } from 'typeorm';
import { AuthSettings } from '../verification/entities/auth-settings.entity';

/**
 * 认证设置服务 —— 每次读取持久策略，避免另一实例更新后仍用旧配额。
 * 由 AuthKitModule 导出，宿主模块可直接注入。
 */
@Injectable()
export class AuthSettingsService {
  constructor(
    @InjectRepository(AuthSettings)
    private readonly repo: Repository<AuthSettings>,
  ) {}

  async get(manager?: EntityManager): Promise<AuthSettings> {
    const repo = manager ? manager.getRepository(AuthSettings) : this.repo;
    let row = await repo.findOne({ where: { id: 1 } });
    if (!row) {
      // @PrimaryGeneratedColumn 的 InsertQueryBuilder 会跳过传入 id；这里必须明确固定单行身份。
      await repo.query(
        'INSERT INTO ak_auth_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING',
      );
      row = await repo.findOneOrFail({ where: { id: 1 } });
    }
    return row;
  }

  async update(data: Partial<AuthSettings>): Promise<AuthSettings> {
    await this.repo.update(1, data);
    return this.get();
  }
}
