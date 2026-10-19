const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const load = require('./support/native_plugin_loader.cjs');

function fixture({ stored = new Map(), failFinish = false } = {}) {
  const key = crypto.randomBytes(32), sessions = new Map();
  let exists = false, generated = 0, aborted = 0, next = 0;
  const tag = { HUKS_TAG_ALGORITHM: 1, HUKS_TAG_KEY_SIZE: 2, HUKS_TAG_PURPOSE: 3,
    HUKS_TAG_PADDING: 4, HUKS_TAG_BLOCK_MODE: 5, HUKS_TAG_NONCE: 6,
    HUKS_TAG_ASSOCIATED_DATA: 7, HUKS_TAG_AE_TAG: 8 };
  const huks = {
    HuksTag: tag, HuksKeyAlg: { HUKS_ALG_AES: 1 }, HuksKeySize: { HUKS_AES_KEY_SIZE_256: 256 },
    HuksKeyPurpose: { HUKS_KEY_PURPOSE_ENCRYPT: 1, HUKS_KEY_PURPOSE_DECRYPT: 2 },
    HuksKeyPadding: { HUKS_PADDING_NONE: 0 }, HuksCipherMode: { HUKS_MODE_GCM: 1 },
    async hasKeyItem() { return exists; },
    async generateKeyItem() { exists = true; generated++; },
    async initSession(alias, options) { const handle = ++next; sessions.set(handle, options); return { handle }; },
    async finishSession(handle, options) {
      if (failFinish) throw new Error('native failure with private implementation details');
      const params = new Map(options.properties.map(p => [p.tag, p.value]));
      const nonce = params.get(tag.HUKS_TAG_NONCE), aad = params.get(tag.HUKS_TAG_ASSOCIATED_DATA);
      assert.equal(nonce.length, 12);
      let result;
      if (params.get(tag.HUKS_TAG_PURPOSE) === 1) {
        const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce); cipher.setAAD(aad);
        result = Buffer.concat([cipher.update(options.inData), cipher.final(), cipher.getAuthTag()]);
      } else {
        const cipher = crypto.createDecipheriv('aes-256-gcm', key, nonce); cipher.setAAD(aad);
        cipher.setAuthTag(params.get(tag.HUKS_TAG_AE_TAG));
        result = Buffer.concat([cipher.update(options.inData), cipher.final()]);
      }
      sessions.delete(handle); return { outData: new Uint8Array(result) };
    },
    async abortSession(handle) { sessions.delete(handle); aborted++; },
  };
  const f = load('../security/SecureStoragePlugin', {
    '@kit.UniversalKeystoreKit': { huks },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createRandom: () => ({ generateRandomSync: n => ({ data: new Uint8Array(crypto.randomBytes(n)) }) }) } },
    '@ohos.data.preferences': { default: { async getPreferences() { return {
      async get(k, fallback) { return stored.get(k) ?? fallback; }, async put(k, value) { stored.set(k, value); },
      async delete(k) { stored.delete(k); }, async flush() {},
    }; } } },
    '@kit.ArkTS': { util: {
      TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
      TextDecoder: class { constructor(encoding, options) { this.decoder = new TextDecoder(encoding, options); } decodeToString(bytes) { return this.decoder.decode(bytes); } },
      Base64Helper: class { decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); } encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } },
    } },
    // 真机 Buffer.buffer 已按视图裁切；原实现再次叠加 byteOffset 会 RangeError。
    '@ohos.buffer': { default: { from(value, encoding) { const bytes = new Uint8Array(Buffer.from(value, encoding)); return {
      buffer: bytes.buffer, byteOffset: 4096, length: bytes.length, toString: type => Buffer.from(bytes).toString(type),
    }; } } },
  });
  return { ...f, stored, sessions, get generated() { return generated; }, get aborted() { return aborted; } };
}

test('真实 AES-GCM 验证中文/emoji 往返，不依赖 Buffer 视图偏移且不明文持久化', async () => {
  const f = fixture(), value = '鸿蒙语音 🎧，私有测试数据'.repeat(30);
  await f.call('write', { key: 'probe', value });
  const envelope = f.stored.get('secure.probe');
  assert.equal(Buffer.from(envelope, 'base64')[0], 1); assert.ok(!envelope.includes(value));
  assert.equal(await f.call('read', { key: 'probe' }), value);
  assert.equal(f.generated, 1); assert.equal(f.sessions.size, 0);
  await f.call('write', { key: 'probe', value });
  assert.notEqual(f.stored.get('secure.probe'), envelope, '每次生成新 nonce');
  assert.equal(f.generated, 1);
  await f.call('delete', { key: 'probe' }); assert.equal(await f.call('read', { key: 'probe' }), null);
});
test('保留 v1 密文格式，重新创建插件后仍能读回已有密文', async () => {
  const f = fixture(); await f.call('write', { key: 'legacy', value: '旧格式数据' });
  f.plugin.onDetachedFromEngine({}); f.plugin.onAttachedToEngine({ getApplicationContext() {}, getBinaryMessenger() {} });
  assert.equal(await f.call('read', { key: 'legacy' }), '旧格式数据');
  assert.equal(f.generated, 1);
});
test('AAD 阻止密文移到另一个逻辑 key，篡改 tag 失败并取消会话', async () => {
  const f = fixture(); await f.call('write', { key: 'one', value: '测试' });
  f.stored.set('secure.two', f.stored.get('secure.one'));
  await assert.rejects(f.call('read', { key: 'two' }), { code: 'secure_storage_error' });
  const tampered = Buffer.from(f.stored.get('secure.one'), 'base64'); tampered[tampered.length - 1] ^= 1;
  f.stored.set('secure.one', tampered.toString('base64'));
  await assert.rejects(f.call('read', { key: 'one' }), { code: 'secure_storage_error' });
  assert.equal(f.aborted, 2); assert.equal(f.sessions.size, 0);
});
test('原生失败不回退明文、不泄漏内部错误，队列在无效参数后仍可工作', async () => {
  const failed = fixture({ failFinish: true });
  await assert.rejects(failed.call('write', { key: 'probe', value: '测试' }), error =>
    error.code === 'secure_storage_error' && !error.message.includes('private'));
  assert.equal(failed.stored.size, 0); assert.equal(failed.aborted, 1);
  const f = fixture(); await assert.rejects(f.call('write', { key: '', value: '测试' }), { code: 'secure_storage_error' });
  await f.call('write', { key: 'probe', value: '重试' }); assert.equal(await f.call('read', { key: 'probe' }), '重试');
});
