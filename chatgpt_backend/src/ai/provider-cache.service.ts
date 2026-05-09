import { Injectable } from '@nestjs/common';
import { AiProvider } from './ai-provider.entity';

@Injectable()
export class ProviderCacheService {
  private cache = new Map<string, { provider: AiProvider; expireAt: number }>();
  private TTL = 30_000;

  get(key: string): AiProvider | null {
    const v = this.cache.get(key);
    if (!v) return null;
    if (v.expireAt < Date.now()) {
      this.cache.delete(key);
      return null;
    }
    return v.provider;
  }

  set(key: string, p: AiProvider) {
    this.cache.set(key, { provider: p, expireAt: Date.now() + this.TTL });
  }

  invalidate() {
    this.cache.clear();
  }
}
