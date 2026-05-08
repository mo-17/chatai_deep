import { Injectable, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { AppVersion } from '../update/version.entity';

@Injectable()
export class AdminVersionService {
  constructor(
    @InjectRepository(AppVersion)
    private repo: Repository<AppVersion>,
  ) {}

  async list(query: { page?: number; pageSize?: number }) {
    const page = query.page || 1;
    const pageSize = query.pageSize || 10;
    const [list, total] = await this.repo.findAndCount({
      order: { versionCode: 'DESC' },
      take: pageSize,
      skip: (page - 1) * pageSize,
    });
    return { list, total, page, pageSize };
  }

  async detail(id: number) {
    const entity = await this.repo.findOne({ where: { id } });
    if (!entity) throw new NotFoundException('版本不存在');
    return entity;
  }

  async create(body: Partial<AppVersion>) {
    const entity = this.repo.create(body);
    return this.repo.save(entity);
  }

  async edit(id: number, body: Partial<AppVersion>) {
    const entity = await this.repo.findOne({ where: { id } });
    if (!entity) throw new NotFoundException('版本不存在');
    Object.assign(entity, body);
    return this.repo.save(entity);
  }

  async delete(id: number) {
    const entity = await this.repo.findOne({ where: { id } });
    if (!entity) throw new NotFoundException('版本不存在');
    await this.repo.remove(entity);
    return null;
  }
}
