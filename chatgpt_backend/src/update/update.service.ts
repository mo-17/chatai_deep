import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { AppVersion } from './version.entity';

@Injectable()
export class UpdateService {
  constructor(
    @InjectRepository(AppVersion)
    private versionRepo: Repository<AppVersion>,
  ) {}

  async checkUpdate(cid = 'all', version?: string) {
    const latest = await this.versionRepo.findOne({
      where: { enabled: true, cid },
      order: { versionCode: 'DESC' },
    });

    if (!latest) {
      return {
        code: 0,
        data: {
          id: '0',
          cid,
          versionName: '0.0.0',
          versionCode: '0',
          url: '',
          description: '暂无版本',
        },
      };
    }

    const clientCode = parseInt(version || '0', 10) || 0;
    if (latest.versionCode <= clientCode) {
      return {
        code: 0,
        data: {
          id: String(latest.id),
          cid: latest.cid,
          versionName: latest.versionName,
          versionCode: String(latest.versionCode),
          url: '',
          description: '当前已是最新版本',
        },
      };
    }

    return {
      code: 0,
      data: {
        id: String(latest.id),
        cid: latest.cid,
        versionName: latest.versionName,
        versionCode: String(latest.versionCode),
        url: latest.url || '',
        description: latest.description || '',
        forceUpdate: latest.forceUpdate,
      },
    };
  }
}
