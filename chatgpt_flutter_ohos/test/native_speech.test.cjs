const test = require('node:test');
const assert = require('node:assert/strict');
const load = require('./support/native_plugin_loader.cjs');
const tick = () => new Promise(resolve => setImmediate(resolve));
function recognizer({ allowed = true, create, permission } = {}) {
  let listener, started, params;
  const cancelled = [], finished = [], shutdown = [];
  const engine = { setListener(value) { listener = value; }, startListening(value) { started = value; },
    cancel(id) { cancelled.push(id); }, finish(id) { finished.push(id); }, shutdown() { shutdown.push(true); },
    async listLanguages() { return ['zh-CN', 'en-US']; } };
  const native = load('../speech/SpeechRecognizerPlugin', {
    '@kit.AbilityKit': { abilityAccessCtrl: { createAtManager() { return {
      async checkAccessToken() { return permission ? permission : allowed ? 0 : -1; },
      async requestPermissionsFromUser() { return { authResults: [allowed ? 0 : -1] }; },
    }; } } },
    '@kit.CoreSpeechKit': { speechRecognizer: { async createEngine(value) { params = value; if (create) await create; return engine; } } },
  }, { applicationInfo: { accessTokenId: 5 } });
  return { ...native, engine, cancelled, finished, shutdown,
    get listener() { return listener; }, get started() { return started; }, get params() { return params; } };
}
test('识别权限拒绝不会创建引擎；启用时明确使用离线系统服务', async () => {
  const denied = recognizer({ allowed: false });
  assert.equal(await denied.call('initialize'), false); assert.equal(await denied.call('listen'), false);
  assert.equal(denied.params, undefined);
  const f = recognizer(); assert.equal(await f.call('initialize'), true);
  assert.equal(f.params.online, 1); assert.equal(f.params.language, 'zh-CN');
  assert.deepEqual(Array.from(await f.call('locales')), ['zh-CN:zh-CN', 'en-US:en-US']);
});
test('分段结果累计，结束关闭录音；取消后的旧回调不会污染新会话', async () => {
  const f = recognizer(); await f.call('listen', { localeId: 'zh_CN' });
  const first = f.started.sessionId;
  f.listener.onStart(first);
  f.listener.onResult(first, { result: '你好', isFinal: true, isLast: false });
  f.listener.onResult(first, { result: '世界', isFinal: true, isLast: true });
  let texts = f.events.filter(e => e.method === 'textRecognition').map(e => JSON.parse(e.value));
  assert.equal(texts.at(-1).alternates[0].recognizedWords, '你好世界'); assert.equal(texts.at(-1).finalResult, true);
  assert.ok(f.cancelled.includes(first)); assert.equal(f.timers.size, 0);
  await f.call('listen'); const second = f.started.sessionId, count = f.events.length;
  f.listener.onResult(first, { result: '旧数据', isFinal: true, isLast: true });
  assert.equal(f.events.length, count);
  await f.call('stop'); assert.deepEqual(f.finished, [second]);
  f.listener.onComplete(second); assert.equal(f.timers.size, 0);
});
test('识别错误、后台及超时均结束会话；后台取消延迟初始化', async () => {
  const f = recognizer(); await f.call('listen');
  f.listener.onError(f.started.sessionId, 100);
  assert.equal(JSON.parse(f.events.find(e => e.method === 'notifyError').value).permanent, true);
  await f.call('listen'); [...f.timers.values()][0].fn(); assert.equal(f.timers.size, 0);
  await f.call('listen'); f.plugin.suspend(); assert.equal(f.timers.size, 0);
  let resume; const delayed = recognizer({ create: new Promise(r => { resume = r; }) });
  const pending = delayed.call('listen'); await tick(); delayed.plugin.suspend(); resume();
  assert.equal(await pending, false); assert.equal(delayed.started, undefined); assert.equal(delayed.shutdown.length, 1);
});
test('等待麦克风权限时取消，不会启动稍后到达的会话', async () => {
  let resume; const f = recognizer({ permission: new Promise(r => { resume = r; }) });
  const pending = f.call('listen'); f.plugin.suspend(); resume(0);
  assert.equal(await pending, false); assert.equal(f.started, undefined); assert.equal(f.params, undefined);
});
function tts({ create } = {}) {
  let listener, spoken, params;
  let stopped = 0, shutdown = 0;
  const engine = { setListener(value) { listener = value; }, speak(text, options) { spoken = { text, ...options }; },
    stop() { stopped++; }, shutdown() { shutdown++; },
    async listVoices() { return [{ person: 3, language: 'zh-CN', gender: 'female' }]; } };
  const native = load('../speech/TtsPlugin', { '@kit.CoreSpeechKit': { textToSpeech: {
    async createEngine(value) { params = value; if (create) await create; return engine; },
  } } });
  const speak = (options = {}) => native.call('speak', { text: '测试', language: 'zh-CN', person: 0, speed: 1, pitch: 1, volume: 1, ...options });
  return { ...native, speak, get listener() { return listener; }, get spoken() { return spoken; },
    get params() { return params; }, get stopped() { return stopped; }, get shutdown() { return shutdown; } };
}
test('朗读只在播放结束时完成，合成结束仍保持等待', async () => {
  const f = tts(); let complete = false; const pending = f.speak().then(v => { complete = true; return v; }); await tick();
  assert.equal(f.params.online, 1);
  f.listener.onComplete(f.spoken.requestId, { type: 0 }); await tick(); assert.equal(complete, false);
  f.listener.onComplete(f.spoken.requestId, { type: 1 }); assert.equal(await pending, 1); assert.equal(f.timers.size, 0);
  const voices = await f.call('voices'); assert.equal(voices[0].identifier, '3'); assert.equal(voices[0].locale, 'zh-CN');
});
test('停止、后台和旧朗读回调不会结束新朗读', async () => {
  const f = tts(); const first = f.speak(); await tick(); const old = f.spoken.requestId;
  await f.call('stop'); assert.equal(await first, 0);
  let complete = false; const second = f.speak().then(v => { complete = true; return v; }); await tick();
  f.listener.onComplete(old, { type: 1 }); await tick(); assert.equal(complete, false);
  f.plugin.suspend(); assert.equal(await second, 0); assert.equal(f.timers.size, 0); assert.ok(f.stopped > 0);
});
test('朗读初始化取消、无效参数、错误和超时有明确结果', async () => {
  let resume; const f = tts({ create: new Promise(r => { resume = r; }) });
  const delayed = f.speak(); await tick(); await f.call('stop'); resume();
  await assert.rejects(delayed, { code: 'tts_error' }); assert.equal(f.spoken, undefined); assert.equal(f.shutdown, 1);
  const g = tts(); await assert.rejects(g.speak({ speed: 9 }), { code: 'tts_error' });
  const error = g.speak(); await tick(); const errorCheck = assert.rejects(error, { code: 'tts_error' });
  g.listener.onError(g.spoken.requestId); await errorCheck;
  const timeout = g.speak(); await tick(); const timeoutCheck = assert.rejects(timeout, { code: 'tts_error' });
  [...g.timers.values()][0].fn(); await timeoutCheck; assert.equal(g.timers.size, 0);
});
