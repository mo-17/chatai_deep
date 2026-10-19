import { createHash } from 'node:crypto';
import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { LessThan, Repository } from 'typeorm';
import { AppVersion } from './version.entity';

const parseBuildNumber = (value?: string): number | null => {
  if (!value || !/^\d+$/.test(value.trim())) return null;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) ? parsed : null;
};

const compareSemanticVersion = (left: string, right: string): number => {
  const a = left.split('.').map((part) => Number.parseInt(part, 10) || 0);
  const b = right.split('.').map((part) => Number.parseInt(part, 10) || 0);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const delta = (a[i] ?? 0) - (b[i] ?? 0);
    if (delta !== 0) return delta;
  }
  return 0;
};

const noUpdateResponse = (cid: string) => ({
  code: 0,
  data: {
    id: '0',
    cid,
    versionName: '0.0.0',
    versionCode: '0',
    url: '',
    description: '暂无版本',
    forceUpdate: false,
    updateAvailable: false,
    downloadUrl: '',
    storeUrl: '',
    sha256: '',
  },
});

const isAllowedReleaseUrl = (value: string, store: boolean): boolean => {
  try {
    const url = new URL(value);
    if (!url.hostname) return false;
    return store
      ? url.protocol === 'https:'
      : url.protocol === 'http:' || url.protocol === 'https:';
  } catch {
    return false;
  }
};

@Injectable()
export class UpdateService {
  constructor(
    @InjectRepository(AppVersion)
    private versionRepo: Repository<AppVersion>,
  ) {}

  async checkUpdate(
    cid = 'all',
    versionName?: string,
    versionCode?: string,
    channel?: string,
    platform?: string,
    installationId?: string,
    abi?: string,
  ) {
    const normalizedChannel = channel?.trim().toLowerCase();
    const normalizedPlatform = platform?.trim().toLowerCase();
    if (
      normalizedChannel &&
      normalizedChannel !== 'direct' &&
      normalizedChannel !== 'store'
    ) {
      return noUpdateResponse(cid);
    }
    const isStoreChannel = normalizedChannel === 'store';
    // Store 包不能回退到历史 cid/all 记录：这些记录通常指向可侧载 APK，
    // 把它当应用市场地址既不可更新，也会造成跨渠道发布。未配置 store 版本时
    // 应明确返回“暂无更新”；未携带 channel 的旧客户端仍保持原回退链。
    const candidates = [
      normalizedPlatform && normalizedChannel
        ? `${normalizedPlatform}-${normalizedChannel}`
        : undefined,
      normalizedChannel,
      ...(isStoreChannel ? [] : [cid, 'all']),
    ].filter(
      (candidate, index, values): candidate is string =>
        Boolean(candidate) && values.indexOf(candidate) === index,
    );

    let latest: AppVersion | null = null;
    for (const candidate of candidates) {
      latest = await this.versionRepo.findOne({
        where: { enabled: true, cid: candidate },
        order: { versionCode: 'DESC' },
      });
      if (latest) break;
    }

    if (!latest) {
      return noUpdateResponse(cid);
    }

    // 灰度未命中或暂停的新版本不遮挡同渠道的上一全量版本。
    // 只向该渠道更低的构建号回溯，不跨渠道绕过灰度规则。
    for (
      let attempt = 0;
      !isInRollout(latest, installationId, latest.rolloutPercent ?? 100);
      attempt++
    ) {
      if (attempt >= 32) return noUpdateResponse(cid);
      const previous = await this.versionRepo.findOne({
        where: {
          enabled: true,
          cid: latest.cid,
          versionCode: LessThan(latest.versionCode),
        },
        order: { versionCode: 'DESC' },
      });
      if (!previous || previous.versionCode >= latest.versionCode)
        return noUpdateResponse(cid);
      latest = previous;
    }
    const clientBuild = parseBuildNumber(versionCode);
    const newerVersionAvailable =
      clientBuild !== null
        ? latest.versionCode > clientBuild
        : compareSemanticVersion(latest.versionName, versionName || '0.0.0') >
          0;
    const artifact =
      !isStoreChannel &&
      abi &&
      ['arm64-v8a', 'armeabi-v7a', 'x86_64'].includes(abi)
        ? latest.artifacts?.[abi]
        : undefined;
    const configuredUrl = artifact?.url?.trim() || latest.url?.trim() || '';
    const updateAvailable =
      newerVersionAvailable &&
      isAllowedReleaseUrl(configuredUrl, isStoreChannel);
    const releaseUrl = updateAvailable ? configuredUrl : '';

    return {
      code: 0,
      data: {
        id: String(latest.id),
        cid: latest.cid,
        versionName: latest.versionName,
        versionCode: String(latest.versionCode),
        url: releaseUrl,
        description: updateAvailable
          ? latest.description || ''
          : newerVersionAvailable
            ? '暂无可用更新'
            : '当前已是最新版本',
        forceUpdate: updateAvailable ? latest.forceUpdate : false,
        updateAvailable,
        downloadUrl: updateAvailable && !isStoreChannel ? releaseUrl : '',
        storeUrl: updateAvailable && isStoreChannel ? releaseUrl : '',
        sha256: updateAvailable ? artifact?.sha256 || latest.sha256 || '' : '',
      },
    };
  }
}

export function isInRollout(
  release: Pick<AppVersion, 'id' | 'versionCode' | 'rolloutSalt'>,
  installationId?: string,
  percent = 100,
): boolean {
  if (percent <= 0) return false;
  if (percent >= 100) return true;
  if (!installationId || !/^[a-zA-Z0-9-]{16,80}$/.test(installationId))
    return false;
  const bucket =
    createHash('sha256')
      .update(
        `${release.id}:${release.versionCode}:${release.rolloutSalt || ''}:${installationId}`,
      )
      .digest()
      .readUInt32BE(0) % 10000;
  return bucket < percent * 100;
}
