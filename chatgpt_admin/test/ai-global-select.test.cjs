// 实际页面 / HeroUI Select / React Query / axios；JSDOM布局与网络仅合成。
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const { createRequire } = Module;
const project = process.cwd();
const source = process.env.GLOBAL_SELECT_SOURCE;
if (!source?.startsWith('/tmp/')) throw Error('isolated source snapshot required');
const req = createRequire(path.join(project, 'package.json'));
const { JSDOM } = req('jsdom');
const ts = req('typescript');
const dom = new JSDOM('<!doctype html><html><body></body></html>', {url: 'https://global.synthetic.invalid', pretendToBeVisual: true});
for (const key of ['window','document','navigator','HTMLElement','HTMLInputElement','HTMLSelectElement','HTMLButtonElement','HTMLIFrameElement','HTMLTextAreaElement','HTMLAnchorElement','Document','ShadowRoot','Element','Node','NodeFilter','MutationObserver','CustomEvent','Event','MouseEvent','KeyboardEvent','SVGElement','sessionStorage','localStorage','DOMRect']) {
  Object.defineProperty(global, key, {configurable: true, value: dom.window[key]});
}
global.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
global.requestAnimationFrame = dom.window.requestAnimationFrame.bind(dom.window);
global.cancelAnimationFrame = dom.window.cancelAnimationFrame.bind(dom.window);
global.PointerEvent = dom.window.MouseEvent;
global.CSS = {escape: value => String(value).replace(/[^a-zA-Z0-9_-]/g, c => '\\' + c)};
global.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
global.IntersectionObserver = class { observe() {} unobserve() {} disconnect() {} };
window.matchMedia = () => ({matches: false, media: '', addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {}, dispatchEvent() {return false;}});
HTMLElement.prototype.scrollIntoView = function () {};
global.IS_REACT_ACT_ENVIRONMENT = true;
const singleton = Object.fromEntries(['react','react/jsx-runtime','react/jsx-dev-runtime','react-dom','react-dom/client','react-dom/test-utils'].map(k => [k, req.resolve(k)]));
const resolve = Module._resolveFilename;
Module._resolveFilename = function (id, parent, options) {
  if (singleton[id]) return singleton[id];
  if (id.startsWith('@/')) id = path.join(source, 'src', id.slice(2));
  return resolve.call(this, id, parent, options);
};
for (const ext of ['.ts','.tsx']) require.extensions[ext] = (m, filename) => {
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {fileName: filename, compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX, esModuleInterop: true}});
  m._compile(result.outputText, filename);
};
const channels = new Set();
const NativeMessageChannel = global.MessageChannel;
if (NativeMessageChannel) global.MessageChannel = class extends NativeMessageChannel {
  constructor() {super(); channels.add(this);}
};
const React = req('react');
const { act } = React;
const { render, cleanup, screen, fireEvent, waitFor } = req('@testing-library/react');
const { QueryClient, QueryClientProvider } = req('@tanstack/react-query');
const { api } = require(path.join(source, 'src/lib/api/client.ts'));
const { useAuthStore } = require(path.join(source, 'src/store/authStore.ts'));
const Page = require(path.join(source, 'src/app/(dashboard)/ai/global/page.tsx')).default;
const provider = (id, code, name) => ({id, code, displayName: name, enabled: true, apiKey: '****', baseUrl: 'https://provider.synthetic.invalid', modelPrefixes: null, sortOrder: 0, createTime: '2026-10-12', updateTime: '2026-10-12'});
const model = (id, providerId, providerCode, modelId, displayName, enabled = true) => ({id, providerId, providerCode, modelId, displayName, enabled, isDefault: false, description: null, sortOrder: 0, supportsVision: false, supportsTool: false, supportsReasoning: false, supportsPdf: false, createTime: '2026-10-12', updateTime: '2026-10-12'});
const config = () => ({id: 1, defaultProviderCode: 'deepseek', defaultModelId: 'deepseek-chat', catalogPublic: true, avatarPath: null, updateTime: '2026-10-12'});
const defaults = () => ({config: config(), providers: [provider(1,'deepseek','DeepSeek'), provider(2,'provider-b','Synthetic B')], models: [model(11,1,'deepseek','deepseek-chat','DeepSeek Chat'), model(22,2,'provider-b','shared-id','Shared B')], held: {}, failures: {}});
const gate = () => {let release; const promise = new Promise(r => release = r); return {promise, release};};
let state, calls, client;
const response = (c, data) => ({config: c, data: {code: 0, data}, status: 200, statusText: 'synthetic', headers: {}});
test.beforeEach(() => {
  state = defaults(); calls = [];
  useAuthStore.getState().setAuth('synthetic-global-session', {id: 7, userName: 'Synthetic'});
  client = new QueryClient({defaultOptions: {queries: {retry: false, gcTime: 0}, mutations: {retry: false, gcTime: Infinity}}});
  api.defaults.adapter = async c => {
    const method = c.method.toLowerCase(), url = c.url;
    assert.equal(c.headers.Authorization, 'Bearer synthetic-global-session');
    calls.push({method, url, body: c.data ? JSON.parse(c.data) : undefined});
    assert.ok(['get','patch'].includes(method), 'no model/provider test/upload or POST');
    if (method === 'patch') {
      assert.equal(url, '/admin/ai/global'); state.config = {...state.config, ...JSON.parse(c.data)};
      return response(c, state.config);
    }
    const key = {'/admin/ai/global':'config','/admin/ai/providers':'providers','/admin/ai/models':'models'}[url];
    assert.ok(key, 'no external or unexpected routes');
    if (state.held[key]) await state.held[key].promise;
    if (state.failures[key]) throw Error('synthetic read failed');
    return response(c, key === 'config' ? state.config : {list: state[key]});
  };
});
test.after(() => {
  dom.window.close();
  for (const c of channels) {c.port1.close(); c.port2.close();}
  console.log('owned DOM closed; component MessageChannels closed:', channels.size);
});
test.afterEach(async () => {
  await act(async () => {for (const g of Object.values(state.held)) g.release(); cleanup();}); client.clear();
  assert.equal(calls.filter(c => c.method === 'post').length, 0);
});
async function mount() { await act(async () => {render(React.createElement(QueryClientProvider, {client}, React.createElement(Page)));}); }
const save = () => screen.getByRole('button', {name: '保存', exact: true});
const patches = () => calls.filter(c => c.method === 'patch');
const modelControl = () => screen.getByRole('button', {name: /默认模型/});
async function settled() { await waitFor(() => assert.ok(screen.queryByRole('button', {name: '保存', exact: true}))); }
async function selected() { await waitFor(() => assert.match(modelControl().textContent, /DeepSeek Chat \(deepseek-chat\)/)); }
async function press(node) { await act(async () => fireEvent.click(node)); }

test('actual HeroUI selected model has a visible stable label, without automatic PATCH', async () => {
  await mount(); await selected(); assert.equal(save().disabled, false); assert.equal(patches().length, 0);
});
test('config first, models delayed: loading is explicit and save waits for the original string model id', async () => {
  state.held.models = gate(); await mount(); await settled();
  assert.match(document.body.textContent, /模型清单加载中/); assert.equal(save().disabled, true); assert.equal(patches().length, 0);
  await act(async () => state.held.models.release()); await selected(); assert.equal(save().disabled, false); assert.equal(patches().length, 0);
});
test('models first, config delayed: eventual selected label is correct and no default is automatically written', async () => {
  state.held.config = gate(); await mount(); assert.equal(patches().length, 0);
  await act(async () => state.held.config.release()); await selected(); assert.equal(patches().length, 0);
});
for (const kind of ['disabled','deleted','missing']) test(`${kind} default is explicit and cannot be saved or replaced automatically`, async () => {
  state.models = kind === 'disabled' ? [model(11,1,'deepseek','deepseek-chat','DeepSeek Chat',false), model(33,1,'deepseek','other-id','Other')]
    : [model(33,1,'deepseek','other-id','Other')];
  if (kind === 'missing') state.config.defaultModelId = 'not-present';
  await mount(); await settled(); await waitFor(() => assert.match(document.body.textContent, /当前默认模型不可用/));
  assert.equal(save().disabled, true); await press(save()); assert.equal(patches().length, 0);
});
test('empty models are distinct from a failed request and never auto-save', async () => {
  state.models = []; await mount(); await settled(); await waitFor(() => assert.match(document.body.textContent, /暂无可用模型/));
  assert.doesNotMatch(document.body.textContent, /模型清单加载失败/); assert.equal(save().disabled, true); assert.equal(patches().length, 0);
});
test('failed model request is visible, blocks save, and explicit retry recovers with GET only', async () => {
  state.failures.models = true; await mount(); await settled(); await waitFor(() => assert.match(document.body.textContent, /模型清单加载失败/));
  assert.equal(save().disabled, true); assert.equal(patches().length, 0);
  state.failures.models = false; await press(screen.getByRole('button', {name: '重试模型清单'})); await selected();
  assert.equal(calls.filter(c => c.url === '/admin/ai/models').length, 2); assert.equal(patches().length, 0);
});
test('missing provider is explicit and prevents save', async () => {
  state.providers = [provider(2,'provider-b','Synthetic B')]; await mount(); await settled();
  await waitFor(() => assert.match(document.body.textContent, /当前默认服务商不可用/)); assert.equal(save().disabled, true); assert.equal(patches().length, 0);
});
test('actual HeroUI provider/model selection saves one correct string pair only after explicit valid choice', async () => {
  await mount(); await selected();
  await press(screen.getByRole('button', {name: /默认服务商/}));
  await press(await screen.findByRole('option', {name: 'Synthetic B', exact: true}));
  assert.equal(save().disabled, true); assert.equal(patches().length, 0);
  await press(modelControl()); await press(await screen.findByRole('option', {name: 'Shared B (shared-id)', exact: true}));
  await waitFor(() => assert.equal(save().disabled, false)); assert.equal(patches().length, 0);
  await press(save()); await waitFor(() => assert.equal(patches().length, 1));
  assert.deepEqual(patches()[0].body, {defaultProviderCode: 'provider-b', defaultModelId: 'shared-id', catalogPublic: true});
});
