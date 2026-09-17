import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import dataPreferences from '@ohos.data.preferences';
import buffer from '@ohos.buffer';

const CHANNEL = 'com.hzb.flutter_ai/secure_storage';
const PREFERENCES_NAME = 'chatai_deep_secure_values_v1';
const KEY_ALIAS = 'chatai_deep_huks_aes_gcm_v1';
const ENVELOPE_VERSION = 1;
const NONCE_BYTES = 12;
const TAG_BYTES = 16;
const AAD_PREFIX = 'chatai_deep_secure_values_v1:';

/**
 * Flutter SecureKeyValueStore 的 HarmonyOS 实现。
 *
 * Preferences 只保存 nonce + AES-GCM 密文；不可导出的 AES-256 密钥由 HUKS
 * 按应用身份隔离。AAD 绑定逻辑 key，防止不同凭据之间替换密文。
 */
export default class SecureStoragePlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private ready: Promise<dataPreferences.Preferences> | null = null;
  private queue: Promise<void> = Promise.resolve();

  getUniqueClassName(): string {
    return 'ChataiDeepSecureStoragePlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.ready = dataPreferences.getPreferences(
      binding.getApplicationContext(),
      PREFERENCES_NAME,
    );
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel !== null) {
      this.channel.setMethodCallHandler(null);
    }
    this.channel = null;
    this.ready?.then((prefs) => prefs.flush()).catch(() => {});
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'read' && call.method !== 'write' && call.method !== 'delete') {
      result.notImplemented();
      return;
    }
    this.queue = this.queue.then(async () => {
      try {
        const key = this.requiredString(call, 'key', 256);
        switch (call.method) {
          case 'read':
            result.success(await this.read(key));
            return;
          case 'write':
            const value = this.requiredString(call, 'value', 1024 * 1024);
            await this.write(key, value);
            result.success(null);
            return;
          case 'delete':
            await this.delete(key);
            result.success(null);
            return;
        }
      } catch (_) {
        // 不把 key、明文、HUKS 内部细节或堆栈送回 Dart/日志。
        result.error('secure_storage_error', 'HarmonyOS secure storage unavailable', null);
      }
    }).catch(() => {
      result.error('secure_storage_error', 'HarmonyOS secure storage unavailable', null);
    });
  }

  private requiredString(call: MethodCall, name: string, maxLength: number): string {
    const value = call.argument(name) as string;
    if (typeof value !== 'string' || value.length === 0 || value.length > maxLength) {
      throw new Error('invalid secure storage argument');
    }
    return value;
  }

  private async preferences(): Promise<dataPreferences.Preferences> {
    if (this.ready === null) {
      throw new Error('preferences unavailable');
    }
    return this.ready;
  }

  private storageKey(key: string): string {
    return `secure.${key}`;
  }

  private async read(key: string): Promise<string | null> {
    const prefs = await this.preferences();
    const raw = await prefs.get(this.storageKey(key), '') as string;
    if (raw.length === 0) return null;
    if (!await huks.hasKeyItem(KEY_ALIAS, { properties: [] })) {
      throw new Error('HUKS key missing');
    }
    const packedBuffer = buffer.from(raw, 'base64');
    const packed = new Uint8Array(
      packedBuffer.buffer,
      packedBuffer.byteOffset,
      packedBuffer.length,
    );
    if (packed.length < 1 + NONCE_BYTES + TAG_BYTES || packed[0] !== ENVELOPE_VERSION) {
      throw new Error('secure value corrupt');
    }
    const nonce = packed.slice(1, 1 + NONCE_BYTES);
    const cipher = packed.slice(1 + NONCE_BYTES);
    const plain = await this.crypt(
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT,
      nonce,
      this.utf8(`${AAD_PREFIX}${key}`),
      cipher.slice(0, cipher.length - TAG_BYTES),
      cipher.slice(cipher.length - TAG_BYTES),
    );
    return buffer.from(plain).toString('utf8');
  }

  private async write(key: string, value: string): Promise<void> {
    await this.ensureKey();
    const nonce = cryptoFramework.createRandom().generateRandomSync(NONCE_BYTES).data;
    const cipher = await this.crypt(
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT,
      nonce,
      this.utf8(`${AAD_PREFIX}${key}`),
      this.utf8(value),
      null,
    );
    const packed = new Uint8Array(1 + NONCE_BYTES + cipher.length);
    packed[0] = ENVELOPE_VERSION;
    packed.set(nonce, 1);
    packed.set(cipher, 1 + NONCE_BYTES);
    const encoded = buffer.from(packed).toString('base64');
    const prefs = await this.preferences();
    await prefs.put(this.storageKey(key), encoded);
    await prefs.flush();
  }

  private async delete(key: string): Promise<void> {
    const prefs = await this.preferences();
    await prefs.delete(this.storageKey(key));
    await prefs.flush();
  }

  private async ensureKey(): Promise<void> {
    if (await huks.hasKeyItem(KEY_ALIAS, { properties: [] })) return;
    const options: huks.HuksOptions = {
      properties: [{
        tag: huks.HuksTag.HUKS_TAG_ALGORITHM,
        value: huks.HuksKeyAlg.HUKS_ALG_AES,
      }, {
        tag: huks.HuksTag.HUKS_TAG_KEY_SIZE,
        value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256,
      }, {
        tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT |
          huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT,
      }],
    };
    await huks.generateKeyItem(KEY_ALIAS, options);
  }

  private async crypt(
    purpose: huks.HuksKeyPurpose,
    nonce: Uint8Array,
    aad: Uint8Array,
    input: Uint8Array,
    tag: Uint8Array | null,
  ): Promise<Uint8Array> {
    const properties: huks.HuksParam[] = [{
      tag: huks.HuksTag.HUKS_TAG_ALGORITHM,
      value: huks.HuksKeyAlg.HUKS_ALG_AES,
    }, {
      tag: huks.HuksTag.HUKS_TAG_KEY_SIZE,
      value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256,
    }, {
      tag: huks.HuksTag.HUKS_TAG_PURPOSE,
      value: purpose,
    }, {
      tag: huks.HuksTag.HUKS_TAG_PADDING,
      value: huks.HuksKeyPadding.HUKS_PADDING_NONE,
    }, {
      tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE,
      value: huks.HuksCipherMode.HUKS_MODE_GCM,
    }, {
      tag: huks.HuksTag.HUKS_TAG_NONCE,
      value: nonce,
    }, {
      tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA,
      value: aad,
    }];
    if (tag !== null) {
      properties.push({
        tag: huks.HuksTag.HUKS_TAG_AE_TAG,
        value: tag,
      });
    }
    const options: huks.HuksOptions = { properties, inData: input };
    const session = await huks.initSession(KEY_ALIAS, options);
    try {
      const output = await huks.finishSession(session.handle, options);
      const outData = output.outData;
      if (outData === undefined || outData === null) {
        throw new Error('HUKS returned no output');
      }
      if (purpose === huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT &&
        outData.length < TAG_BYTES) {
        throw new Error('HUKS returned an invalid GCM payload');
      }
      return outData;
    } catch (error) {
      try {
        await huks.abortSession(session.handle, options);
      } catch (_) {
      }
      throw error;
    }
  }

  private utf8(value: string): Uint8Array {
    const encoded = buffer.from(value, 'utf8');
    return new Uint8Array(encoded.buffer, encoded.byteOffset, encoded.length);
  }
}
