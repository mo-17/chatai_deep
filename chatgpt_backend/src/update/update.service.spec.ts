import { UpdateService } from './update.service';
import { AppVersion } from './version.entity';

const version = (overrides: Partial<AppVersion> = {}): AppVersion => ({
  id: 1,
  versionName: '1.0.4',
  versionCode: 8,
  url: 'https://example.com/app.apk',
  sha256: null,
  description: 'Release notes',
  cid: 'all',
  forceUpdate: false,
  enabled: true,
  createTime: new Date('2026-07-14T00:00:00.000Z'),
  updateTime: new Date('2026-07-14T00:00:00.000Z'),
  ...overrides,
});

describe('UpdateService', () => {
  let repo: { findOne: jest.Mock };
  let service: UpdateService;

  beforeEach(() => {
    repo = { findOne: jest.fn() };
    service = new UpdateService(repo as never);
  });

  it('uses numeric versionCode instead of parsing semantic versionName', async () => {
    repo.findOne.mockResolvedValue(
      version({ versionName: '1.0.4', versionCode: 8 }),
    );

    const result = await service.checkUpdate('all', '1.0.4', '8');

    expect(result.data.updateAvailable).toBe(false);
    expect(result.data.url).toBe('');
  });

  it('compares legacy semantic versions without treating 1.0.4 as build 1', async () => {
    repo.findOne.mockResolvedValue(
      version({ versionName: '1.0.4', versionCode: 8 }),
    );

    const result = await service.checkUpdate('all', '1.0.4');

    expect(result.data.updateAvailable).toBe(false);
  });

  it('falls back from android-direct to all', async () => {
    repo.findOne
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce(version({ cid: 'all', versionCode: 9 }));

    const result = await service.checkUpdate(
      '321',
      '1.0.4',
      '8',
      'direct',
      'android',
    );

    expect(result.data.updateAvailable).toBe(true);
    expect(result.data.downloadUrl).toBe('https://example.com/app.apk');
    expect(result.data.url).toBe(result.data.downloadUrl);
    expect(repo.findOne).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({
        where: { cid: 'android-direct', enabled: true },
      }),
    );
    expect(repo.findOne).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({ where: { cid: 'direct', enabled: true } }),
    );
    expect(repo.findOne).toHaveBeenNthCalledWith(
      3,
      expect.objectContaining({ where: { cid: '321', enabled: true } }),
    );
    expect(repo.findOne).toHaveBeenNthCalledWith(
      4,
      expect.objectContaining({ where: { cid: 'all', enabled: true } }),
    );
  });

  it('does not fall back from store to legacy direct/all releases', async () => {
    repo.findOne
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce(
        version({
          cid: 'all',
          versionCode: 9,
          url: 'https://example.com/app.apk',
        }),
      );

    const result = await service.checkUpdate(
      'all',
      '1.0.4',
      '8',
      'store',
      'android',
    );

    expect(result.data.updateAvailable).toBe(false);
    expect(result.data.url).toBe('');
    expect(result.data.storeUrl).toBe('');
    expect(repo.findOne).toHaveBeenCalledTimes(2);
    expect(repo.findOne).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({
        where: { cid: 'android-store', enabled: true },
      }),
    );
    expect(repo.findOne).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({ where: { cid: 'store', enabled: true } }),
    );
  });

  it('fails closed for an unknown explicit channel', async () => {
    repo.findOne.mockImplementation(({ where }: { where: { cid: string } }) =>
      Promise.resolve(where.cid === 'all' ? version({ versionCode: 9 }) : null),
    );

    const result = await service.checkUpdate(
      'all',
      '1.0.4',
      '8',
      'stroe',
      'android',
    );

    expect(result.data.updateAvailable).toBe(false);
    expect(result.data.url).toBe('');
    expect(repo.findOne).not.toHaveBeenCalled();
  });

  it('fails closed when a newer direct release has an invalid URL', async () => {
    repo.findOne.mockResolvedValue(
      version({ versionCode: 9, url: 'file:///tmp/app.apk' }),
    );

    const { data } = await service.checkUpdate(
      '321',
      '1.0.4',
      '8',
      'direct',
      'android',
    );

    expect(data.updateAvailable).toBe(false);
    expect(data.downloadUrl).toBe('');
    expect(data.url).toBe('');
  });

  it('requires HTTPS for store release URLs', async () => {
    repo.findOne.mockResolvedValue(
      version({
        cid: 'store',
        versionCode: 9,
        url: 'http://store.example.com/app',
      }),
    );

    const { data } = await service.checkUpdate(
      'all',
      '1.0.4',
      '8',
      'store',
      'android',
    );

    expect(data.updateAvailable).toBe(false);
    expect(data.storeUrl).toBe('');
    expect(data.url).toBe('');
  });

  it('keeps legacy HTTP download URLs compatible for direct clients', async () => {
    repo.findOne.mockResolvedValue(
      version({ versionCode: 9, url: 'http://downloads.example.com/app.apk' }),
    );

    const { data } = await service.checkUpdate(
      '321',
      '1.0.4',
      '8',
      'direct',
      'android',
    );

    expect(data.updateAvailable).toBe(true);
    expect(data.downloadUrl).toBe('http://downloads.example.com/app.apk');
  });

  it('keeps legacy fields when no update is available', async () => {
    repo.findOne.mockResolvedValue(
      version({ versionCode: 8, forceUpdate: true }),
    );

    const { data } = await service.checkUpdate('all', '1.0.4', '8');

    expect(data).toMatchObject({
      id: '1',
      cid: 'all',
      versionName: '1.0.4',
      versionCode: '8',
      url: '',
      description: '当前已是最新版本',
      forceUpdate: false,
      updateAvailable: false,
    });
  });

  it('returns the configured APK SHA-256 for an available direct release', async () => {
    const hash = 'a'.repeat(64);
    repo.findOne.mockResolvedValue(
      Object.assign(version({ versionCode: 9 }), { sha256: hash }),
    );

    const { data } = await service.checkUpdate(
      'all',
      '1.0.4',
      '8',
      'direct',
      'android',
    );

    expect(data.updateAvailable).toBe(true);
    expect(data.sha256).toBe(hash);
  });
});
