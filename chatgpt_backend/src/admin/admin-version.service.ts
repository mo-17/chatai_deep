import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
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
    const entity = this.repo.create(this.normalizeRelease(body, body, null));
    return this.repo.save(entity);
  }

  async edit(id: number, body: Partial<AppVersion>) {
    const entity = await this.repo.findOne({ where: { id } });
    if (!entity) throw new NotFoundException('版本不存在');
    Object.assign(
      entity,
      this.normalizeRelease(body, { ...entity, ...body }, entity),
    );
    return this.repo.save(entity);
  }

  private normalizeRelease(
    body: Partial<AppVersion>,
    effective: Partial<AppVersion>,
    existing: Partial<AppVersion> | null,
  ): Partial<AppVersion> {
    const normalizedBody = { ...body };

    if (Object.prototype.hasOwnProperty.call(body, 'cid')) {
      if (typeof body.cid !== 'string' || body.cid.trim() === '') {
        throw new BadRequestException('渠道不能为空');
      }
      normalizedBody.cid = body.cid.trim().toLowerCase();
    }

    if (Object.prototype.hasOwnProperty.call(body, 'url')) {
      if (body.url != null && typeof body.url !== 'string') {
        throw new BadRequestException('更新地址格式无效');
      }
      normalizedBody.url = body.url?.trim() || '';
    }

    const effectiveCid = (normalizedBody.cid ?? effective.cid ?? 'all')
      .trim()
      .toLowerCase();
    const effectiveUrl = (normalizedBody.url ?? effective.url ?? '').trim();
    const isStore = effectiveCid === 'store' || effectiveCid.endsWith('-store');
    if (effectiveUrl) {
      let parsed: URL;
      try {
        parsed = new URL(effectiveUrl);
      } catch {
        throw new BadRequestException('更新地址格式无效');
      }
      const allowedProtocol = isStore
        ? parsed.protocol === 'https:'
        : parsed.protocol === 'http:' || parsed.protocol === 'https:';
      if (!parsed.hostname || !allowedProtocol) {
        throw new BadRequestException(
          isStore ? 'Store 更新地址必须使用 HTTPS' : '更新地址格式无效',
        );
      }
    }

    if (Object.prototype.hasOwnProperty.call(body, 'sha256')) {
      if (body.sha256 != null && typeof body.sha256 !== 'string') {
        throw new BadRequestException('SHA-256 必须是 64 位十六进制字符串');
      }
      const normalized = body.sha256?.trim().toLowerCase() || null;
      if (normalized !== null && !/^[0-9a-f]{64}$/.test(normalized)) {
        throw new BadRequestException('SHA-256 必须是 64 位十六进制字符串');
      }
      normalizedBody.sha256 = normalized;
    }

    const hasOwn = (key: keyof AppVersion): boolean => Object.hasOwn(body, key);
    const suppliedSha = normalizedBody.sha256;
    const hasValidSuppliedSha =
      hasOwn('sha256') &&
      typeof suppliedSha === 'string' &&
      /^[0-9a-f]{64}$/.test(suppliedSha);

    if (!isStore) {
      const isNewDirectRelease = existing === null && effectiveUrl !== '';
      const existingCid = (existing?.cid ?? 'all').trim().toLowerCase();
      const urlChanged =
        existing !== null &&
        hasOwn('url') &&
        effectiveUrl !== (existing.url ?? '').trim();
      const versionCodeChanged =
        existing !== null &&
        hasOwn('versionCode') &&
        body.versionCode !== existing.versionCode;
      const cidChangedToDirect =
        existing !== null && hasOwn('cid') && effectiveCid !== existingCid;
      const clearedExistingSha =
        existing !== null &&
        hasOwn('sha256') &&
        Boolean(existing.sha256?.trim()) &&
        suppliedSha == null;
      const changedDirectRelease =
        urlChanged || versionCodeChanged || cidChangedToDirect;

      if (
        (isNewDirectRelease || changedDirectRelease || clearedExistingSha) &&
        !hasValidSuppliedSha
      ) {
        throw new BadRequestException('Direct APK 发布或变更必须提供 SHA-256');
      }
    }

    return normalizedBody;
  }

  async delete(id: number) {
    const entity = await this.repo.findOne({ where: { id } });
    if (!entity) throw new NotFoundException('版本不存在');
    await this.repo.remove(entity);
    return null;
  }
}
