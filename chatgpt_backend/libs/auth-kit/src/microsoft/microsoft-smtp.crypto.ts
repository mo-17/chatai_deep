import {
  createHash,
  randomBytes,
  createCipheriv,
  createDecipheriv,
  timingSafeEqual,
} from 'node:crypto';
import { requireAppSecretKey } from '../security/app-secret';
export const digest = (value: string) =>
  createHash('sha256').update(value).digest('hex');
export function equalDigest(value: string, expected: string): boolean {
  const actual = Buffer.from(digest(value), 'hex'),
    wanted = Buffer.from(expected, 'hex');
  return wanted.length === actual.length && timingSafeEqual(actual, wanted);
}
export class MicrosoftSmtpCipher {
  private readonly key: Buffer;
  constructor(secret: string) {
    this.key = createHash('sha256')
      .update(requireAppSecretKey(secret))
      .digest();
  }
  seal(
    value: string,
    providerId: number,
    purpose: string,
    context = '',
  ): string {
    const iv = randomBytes(12),
      cipher = createCipheriv('aes-256-gcm', this.key, iv);
    cipher.setAAD(
      Buffer.from(`microsoft-smtp:v1:${providerId}:${purpose}:${context}`),
    );
    const data = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
    return [
      'v1',
      iv.toString('hex'),
      cipher.getAuthTag().toString('hex'),
      data.toString('hex'),
    ].join(':');
  }
  open(
    value: string,
    providerId: number,
    purpose: string,
    context = '',
  ): string {
    const parts = value.split(':');
    if (
      parts.length !== 4 ||
      parts[0] !== 'v1' ||
      !/^[a-f0-9]{24}$/.test(parts[1]) ||
      !/^[a-f0-9]{32}$/.test(parts[2]) ||
      !/^(?:[a-f0-9]{2})*$/.test(parts[3])
    )
      throw Error('microsoft_cipher_invalid');
    const decipher = createDecipheriv(
      'aes-256-gcm',
      this.key,
      Buffer.from(parts[1], 'hex'),
    );
    decipher.setAAD(
      Buffer.from(`microsoft-smtp:v1:${providerId}:${purpose}:${context}`),
    );
    decipher.setAuthTag(Buffer.from(parts[2], 'hex'));
    return Buffer.concat([
      decipher.update(Buffer.from(parts[3], 'hex')),
      decipher.final(),
    ]).toString('utf8');
  }
}
