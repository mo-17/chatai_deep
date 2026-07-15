import { BadRequestException } from '@nestjs/common';
import { AdminVersionService } from './admin-version.service';

describe('AdminVersionService release integrity', () => {
  const validHash = 'ab'.repeat(32);

  let repo: {
    create: jest.Mock;
    save: jest.Mock;
    findOne: jest.Mock;
  };
  let service: AdminVersionService;

  beforeEach(() => {
    repo = {
      create: jest.fn((value: Record<string, unknown>) => ({ ...value })),
      save: jest.fn((value: Record<string, unknown>) =>
        Promise.resolve({ ...value }),
      ),
      findOne: jest.fn(),
    };
    service = new AdminVersionService(repo as never);
  });

  it('normalizes an optional SHA-256 before saving', async () => {
    const hash = 'AB'.repeat(32);

    await service.create({ sha256: `  ${hash}  ` });

    expect(repo.create).toHaveBeenCalledWith({ sha256: hash.toLowerCase() });
  });

  it('stores a blank SHA-256 as null for legacy-compatible releases', async () => {
    await service.create({ sha256: '   ' });

    expect(repo.create).toHaveBeenCalledWith({ sha256: null });
  });

  it('rejects malformed SHA-256 values', async () => {
    await expect(
      service.create({ sha256: 'not-a-hash' }),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(repo.save).not.toHaveBeenCalled();
  });

  it('normalizes release channel and URL before saving', async () => {
    await service.create({
      cid: ' Android-Direct ',
      url: '  https://downloads.example.com/app.apk  ',
      sha256: validHash,
    });

    expect(repo.create).toHaveBeenCalledWith({
      cid: 'android-direct',
      url: 'https://downloads.example.com/app.apk',
      sha256: validHash,
    });
  });

  it('requires SHA-256 for a new direct release that has an APK URL', async () => {
    await expect(
      service.create({
        cid: 'direct',
        url: 'https://downloads.example.com/app.apk',
      }),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(repo.save).not.toHaveBeenCalled();
  });

  it('allows a new store release without SHA-256', async () => {
    await service.create({
      cid: 'android-store',
      url: 'https://store.example.com/app',
    });

    expect(repo.create).toHaveBeenCalledWith({
      cid: 'android-store',
      url: 'https://store.example.com/app',
    });
  });

  it('rejects release URLs with unsupported schemes', async () => {
    await expect(
      service.create({ cid: 'direct', url: 'file:///tmp/app.apk' }),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(repo.save).not.toHaveBeenCalled();
  });

  it('requires HTTPS for store release URLs', async () => {
    await expect(
      service.create({
        cid: 'android-store',
        url: 'http://store.example.com/app',
      }),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(repo.save).not.toHaveBeenCalled();
  });

  it('keeps legacy HTTP URLs valid for direct releases', async () => {
    await service.create({
      cid: '321',
      url: 'http://downloads.example.com/app.apk',
      sha256: validHash,
    });

    expect(repo.create).toHaveBeenCalledWith({
      cid: '321',
      url: 'http://downloads.example.com/app.apk',
      sha256: validHash,
    });
  });

  it('keeps a legacy direct record with null SHA-256 editable', async () => {
    repo.findOne.mockResolvedValue({
      id: 1,
      cid: '321',
      versionCode: 8,
      url: 'http://downloads.example.com/app.apk',
      sha256: null,
      description: '旧说明',
    });

    await service.edit(1, { description: '新说明' });

    expect(repo.save).toHaveBeenCalledWith(
      expect.objectContaining({
        id: 1,
        cid: '321',
        sha256: null,
        description: '新说明',
      }),
    );
  });

  it('requires a fresh SHA-256 when a direct APK URL changes', async () => {
    repo.findOne.mockResolvedValue({
      id: 1,
      cid: 'direct',
      versionCode: 8,
      url: 'https://downloads.example.com/old.apk',
      sha256: validHash,
    });

    await expect(
      service.edit(1, { url: 'https://downloads.example.com/new.apk' }),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(repo.save).not.toHaveBeenCalled();
  });

  it('requires a fresh SHA-256 when a direct versionCode changes', async () => {
    repo.findOne.mockResolvedValue({
      id: 1,
      cid: 'direct',
      versionCode: 8,
      url: 'https://downloads.example.com/app.apk',
      sha256: validHash,
    });

    await expect(service.edit(1, { versionCode: 9 })).rejects.toBeInstanceOf(
      BadRequestException,
    );
    expect(repo.save).not.toHaveBeenCalled();
  });

  it('requires SHA-256 when a legacy direct draft changes versionCode', async () => {
    repo.findOne.mockResolvedValue({
      id: 1,
      cid: '321',
      versionCode: 8,
      url: '',
      sha256: null,
    });

    await expect(service.edit(1, { versionCode: 9 })).rejects.toBeInstanceOf(
      BadRequestException,
    );
    expect(repo.save).not.toHaveBeenCalled();
  });

  it('requires SHA-256 when an existing release changes its cid to direct', async () => {
    repo.findOne.mockResolvedValue({
      id: 1,
      cid: 'store',
      versionCode: 8,
      url: 'https://store.example.com/app',
      sha256: null,
    });

    await expect(service.edit(1, { cid: 'direct' })).rejects.toBeInstanceOf(
      BadRequestException,
    );
    expect(repo.save).not.toHaveBeenCalled();
  });

  it('rejects explicitly clearing an existing direct SHA-256', async () => {
    repo.findOne.mockResolvedValue({
      id: 1,
      cid: 'direct',
      versionCode: 8,
      url: 'https://downloads.example.com/app.apk',
      sha256: validHash,
    });

    await expect(service.edit(1, { sha256: '   ' })).rejects.toBeInstanceOf(
      BadRequestException,
    );
    expect(repo.save).not.toHaveBeenCalled();
  });

  it('allows explicitly clearing a store SHA-256', async () => {
    repo.findOne.mockResolvedValue({
      id: 1,
      cid: 'store',
      versionCode: 8,
      url: 'https://store.example.com/app',
      sha256: validHash,
    });

    await service.edit(1, { sha256: '   ' });

    expect(repo.save).toHaveBeenCalledWith(
      expect.objectContaining({ cid: 'store', sha256: null }),
    );
  });

  it('accepts a direct APK change when a fresh SHA-256 is provided', async () => {
    const freshHash = 'cd'.repeat(32);
    repo.findOne.mockResolvedValue({
      id: 1,
      cid: 'direct',
      versionCode: 8,
      url: 'https://downloads.example.com/old.apk',
      sha256: validHash,
    });

    await service.edit(1, {
      versionCode: 9,
      url: 'https://downloads.example.com/new.apk',
      sha256: freshHash.toUpperCase(),
    });

    expect(repo.save).toHaveBeenCalledWith(
      expect.objectContaining({
        versionCode: 9,
        url: 'https://downloads.example.com/new.apk',
        sha256: freshHash,
      }),
    );
  });

  it('validates the existing URL when an edit changes a release to store', async () => {
    repo.findOne.mockResolvedValue({
      id: 1,
      cid: 'direct',
      url: 'http://downloads.example.com/app.apk',
      sha256: null,
    });

    await expect(service.edit(1, { cid: 'store' })).rejects.toBeInstanceOf(
      BadRequestException,
    );
    expect(repo.save).not.toHaveBeenCalled();
  });
});
