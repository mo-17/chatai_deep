const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const root = process.env.AUTH_ADMIN_COMPILED;
if (!root?.startsWith('/tmp/')) throw Error('isolated compiled source required');
const { providerPayload } = require(path.join(root, 'lib/api/auth-admin.js'));
const guidance = 'Microsoft Client ID 必须填写微软应用的“应用程序（客户端）ID”（UUID）';
const draft = { displayName: 'Synthetic', authMode: 'microsoft_oauth', fromName: '', fromAddress: 'fixture@example.test', microsoftClientSecret: '', clearMicrosoftClientSecret: false };
test('OAuth serializer rejects empty/non-UUID Client ID before any request can be made', () => {
  for (const id of ['', 'synthetic-not-a-client-id', '310e8e4b-b083-05da-9e1d-28d2c79f1ea1', '310e8e4b-b083-45da-1e1d-28d2c79f1ea1']) {
    assert.throws(() => providerPayload({ ...draft, microsoftClientId: id }), e => e.message === guidance);
  }
});
test('valid UUID is trimmed and blank secret preserved; payload has no enable/test/authorize action', () => {
  const body = providerPayload({ ...draft, microsoftClientId: ' 310e8e4b-b083-45da-9e1d-28d2c79f1ea1 ' });
  assert.equal(body.microsoftClientId, '310e8e4b-b083-45da-9e1d-28d2c79f1ea1');
  assert.equal('microsoftClientSecret' in body, false); assert.equal('enabled' in body, false);
  assert.deepEqual(Object.keys(body).sort(), ['authMode', 'displayName', 'fromAddress', 'fromName', 'microsoftClientId']);
});
