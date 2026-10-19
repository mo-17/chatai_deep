const test = require('node:test');
const assert = require('node:assert/strict');
const load = require('./support/native_plugin_loader.cjs');
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve=a; reject=b; }); return {promise,resolve,reject}; }
function fixture(options = {}) {
  const queue = [], requests = [];
  const result = load('../account/HuaweiLoginPlugin', {
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {},
    '@kit.ArkTS': {util: {generateRandomUUID: () => 'unique-state'}},
    '@kit.AccountKit': {authentication: {
      HuaweiIDProvider: class { createLoginWithHuaweiIDRequest() { return {}; } },
      AuthenticationController: class { executeRequest(request) { requests.push(request); const d=deferred(); queue.push(d); return d.promise; } },
    }},
  }, {currentHapModuleInfo: {metadata: [{name:'client_id', value:options.clientId ?? '123456'}]}}, options);
  return {...result, queue, requests};
}
const ok = (code='single-use-code', state='unique-state') => ({state, data:{authorizationCode:code, unionID:'untrusted-id', accessToken:'must-not-return'}});
test('passes only authorization code after matching random state', async () => {
  const f=fixture(), pending=f.call('signIn');
  assert.equal(f.requests[0].forceLogin,true);
  assert.equal(f.requests[0].state,'unique-state');
  assert.equal(f.requests[0].scopes,undefined);
  f.queue[0].resolve(ok());
  const response=await pending;
  assert.deepEqual([...response], [['authCode','single-use-code']]);
  assert.equal(f.timers.size,0);
});
test('missing configuration and capability fail without invoking provider', async () => {
  for (const [options,code] of [[{clientId:''},'huawei_not_configured'],[{canIUse:()=>false},'huawei_unavailable']]) {
    const f=fixture(options);
    await assert.rejects(f.call('signIn'),{code});
    assert.equal(f.requests.length,0);
  }
});
test('parallel requests are rejected; user cancellation allows a later request', async () => {
  const f=fixture(), first=f.call('signIn');
  await assert.rejects(f.call('signIn'),{code:'huawei_busy'});
  f.queue[0].reject({code:1001502012,message:'secret'});
  await assert.rejects(first,{code:'huawei_cancelled'});
  const next=f.call('signIn'); f.queue[1].resolve(ok()); await next;
});
test('state mismatch and empty authorization code fail closed', async () => {
  for (const response of [ok('code','wrong-state'),ok(''),{state:'unique-state'}]) {
    const f=fixture(), pending=f.call('signIn'); f.queue[0].resolve(response);
    await assert.rejects(pending,{code:'huawei_invalid_response'});
  }
});
test('timeout returns once, keeps provider single flight and discards late credentials', async () => {
  const f=fixture(), pending=f.call('signIn');
  assert.equal([...f.timers.values()][0].ms,120000);
  [...f.timers.values()][0].fn();
  await assert.rejects(pending,{code:'huawei_timeout'});
  await assert.rejects(f.call('signIn'),{code:'huawei_busy'});
  f.queue[0].resolve(ok('late-code')); await Promise.resolve(); await Promise.resolve();
  const next=f.call('signIn'); f.queue[1].resolve(ok('new-code'));
  assert.equal((await next).get('authCode'),'new-code');
});
test('engine detach cancels wait and stale callback cannot complete a new request', async () => {
  const f=fixture(), old=f.call('signIn'); f.plugin.onDetachedFromEngine({});
  await assert.rejects(old,{code:'huawei_cancelled'});
  f.plugin.onAttachedToEngine({getBinaryMessenger(){}});
  const next=f.call('signIn'); f.queue[0].resolve(ok('stale'));
  await Promise.resolve();
  await assert.rejects(f.call('signIn'),{code:'huawei_busy'});
  f.queue[1].resolve(ok('new')); assert.equal((await next).get('authCode'),'new');
});
test('SDK errors expose categories without credential-bearing details', async () => {
  for (const [native,code] of [[1001502005,'huawei_network'],[1001500001,'huawei_not_configured'],[1001502001,'huawei_account_required'],[1,'huawei_authorization_failed']]) {
    const f=fixture(), pending=f.call('signIn'); f.queue[0].reject({code:native,message:'secret-code'});
    await assert.rejects(pending,e=>e.code===code&&!e.message.includes('secret-code'));
  }
});
