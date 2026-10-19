// 实际页面 / HeroUI Select / React Query / axios；JSDOM布局与网络仅合成。
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const { createRequire } = Module;
const project = process.cwd();
const source = process.env.R4B_SOURCE;
if (!source?.startsWith('/tmp/'))
  throw Error('isolated source snapshot required');
const req = createRequire(path.join(project, 'package.json'));
const { JSDOM } = req('jsdom');
const ts = req('typescript');
const dom = new JSDOM('<!doctype html><html><body></body></html>', {
  url: 'https://admin.synthetic.invalid',
  pretendToBeVisual: true,
});
for (const key of [
  'window',
  'document',
  'navigator',
  'HTMLElement',
  'HTMLInputElement',
  'HTMLSelectElement',
  'HTMLButtonElement',
  'HTMLIFrameElement',
  'HTMLTextAreaElement',
  'HTMLAnchorElement',
  'Document',
  'ShadowRoot',
  'Element',
  'Node',
  'NodeFilter',
  'MutationObserver',
  'CustomEvent',
  'Event',
  'MouseEvent',
  'KeyboardEvent',
  'SVGElement',
  'sessionStorage',
  'localStorage',
  'DOMRect',
]) {
  Object.defineProperty(global, key, {
    configurable: true,
    value: dom.window[key],
  });
}
global.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
global.requestAnimationFrame = dom.window.requestAnimationFrame.bind(
  dom.window,
);
global.cancelAnimationFrame = dom.window.cancelAnimationFrame.bind(dom.window);
global.PointerEvent = dom.window.MouseEvent;
global.CSS = {
  escape: (value) => String(value).replace(/[^a-zA-Z0-9_-]/g, (c) => '\\' + c),
};
global.ResizeObserver = class {
  observe() {}
  unobserve() {}
  disconnect() {}
};
global.IntersectionObserver = class {
  observe() {}
  unobserve() {}
  disconnect() {}
};
window.matchMedia = () => ({
  matches: false,
  media: '',
  addListener() {},
  removeListener() {},
  addEventListener() {},
  removeEventListener() {},
  dispatchEvent() {
    return false;
  },
});
HTMLElement.prototype.scrollIntoView = function () {};
HTMLElement.prototype.scrollTo = function () {};
global.IS_REACT_ACT_ENVIRONMENT = true;
const singleton = Object.fromEntries(
  [
    'react',
    'react/jsx-runtime',
    'react/jsx-dev-runtime',
    'react-dom',
    'react-dom/client',
    'react-dom/test-utils',
  ].map((k) => [k, req.resolve(k)]),
);
const resolve = Module._resolveFilename;
Module._resolveFilename = function (id, parent, options) {
  if (singleton[id]) return singleton[id];
  if (id.startsWith('@/')) id = path.join(source, 'src', id.slice(2));
  return resolve.call(this, id, parent, options);
};
for (const ext of ['.ts', '.tsx'])
  require.extensions[ext] = (m, filename) => {
    const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      fileName: filename,
      compilerOptions: {
        target: ts.ScriptTarget.ES2020,
        module: ts.ModuleKind.CommonJS,
        jsx: ts.JsxEmit.ReactJSX,
        esModuleInterop: true,
      },
    });
    m._compile(result.outputText, filename);
  };
const channels = new Set();
const NativeMessageChannel = global.MessageChannel;
if (NativeMessageChannel)
  global.MessageChannel = class extends NativeMessageChannel {
    constructor() {
      super();
      channels.add(this);
    }
  };
const React = req('react');
const { act } = React;
const { render, renderHook, cleanup, screen, fireEvent, waitFor } = req(
  '@testing-library/react',
);
const { QueryClient, QueryClientProvider } = req('@tanstack/react-query');
const { api } = require(path.join(source, 'src/lib/api/client.ts'));
const { useAuthStore } = require(path.join(source, 'src/store/authStore.ts'));
const hook = require(
  path.join(source, 'src/hooks/useChatService.ts'),
).useChatService;
const Page = require(
  path.join(source, 'src/app/(dashboard)/ai-chat/page.tsx'),
).default;
const chatApi = require(path.join(source, 'src/lib/api/chat.ts')).chatApi;
const gate = () => {
  let release;
  const promise = new Promise((r) => (release = r));
  return { promise, release };
};
const pair = (code = 'a', modelId = 'same') => ({
  providerCode: code,
  modelId,
});
const key = (p) => JSON.stringify([p.providerCode, p.modelId]);
const row = (id, code = 'a', model = 'same', owner = 7) => ({
  id,
  userId: owner,
  title: 'row-' + id,
  providerCode: code,
  model,
  updatedAt: '2026-10-14',
  createdAt: '2026-10-14',
});
const delta = (text) =>
  'data: ' +
  JSON.stringify({ choices: [{ delta: { content: text } }] }) +
  '\n\n';
const end = 'data: [DONE]\n\n';
const providers = () => [
  { id: 1, code: 'a', displayName: 'Provider A', enabled: true },
  { id: 2, code: 'b', displayName: 'Provider B', enabled: true },
];
const models = () => [
  {
    id: 1,
    providerId: 1,
    providerCode: 'a',
    modelId: 'same',
    displayName: 'Same A',
    enabled: true,
  },
  {
    id: 2,
    providerId: 2,
    providerCode: 'b',
    modelId: 'same',
    displayName: 'Same B',
    enabled: true,
  },
];
let state, calls, gates, clients;
const later = () => new Promise((r) => setTimeout(r, 0));
const envelope = (data, ownerId, conversationId) => ({
  code: 0,
  data,
  ...(ownerId === undefined ? {} : { ownerId }),
  ...(conversationId === undefined ? {} : { conversationId }),
});
async function server(url, init, axiosConfig) {
  const pathname = new URL(
    url,
    'https://admin.synthetic.invalid/api',
  ).pathname.replace(/^\/api/, '');
  const method = (init.method || 'GET').toUpperCase();
  const body = init.body ? JSON.parse(init.body) : undefined;
  const token = init.headers.Authorization?.replace('Bearer ', '');
  const owner = token === 'token-b' ? 8 : 7;
  const call = { path: pathname, method, body, token, owner };
  call.query = axiosConfig
    ? new URLSearchParams(
        Object.entries(axiosConfig.params || {})
          .filter(([, v]) => v !== undefined)
          .map(([k, v]) => [k, String(v)]),
      ).toString()
    : new URL(
        url,
        'https://admin.synthetic.invalid/api',
      ).searchParams.toString();
  calls.push(call);
  const capturedRows = structuredClone([...state.rows.values()]);
  const readSnapshot = structuredClone({
    providers: state.providers,
    models: state.models,
    config: state.config,
  });
  const response = (data, status = 200) =>
    axiosConfig
      ? {
          status,
          statusText: 'synthetic',
          data,
          headers: {},
          config: axiosConfig,
        }
      : new Response(JSON.stringify(data), {
          status,
          headers: { 'content-type': 'application/json' },
        });
  if (state.held[pathname + ':' + method])
    await state.held[pathname + ':' + method].promise;
  if (state.fail[pathname + ':' + method]) {
    const f = state.fail[pathname + ':' + method];
    if (f === 'network') throw Error('SQL password=synthetic-secret');
    if (axiosConfig)
      throw Object.assign(Error('synthetic raw secret'), {
        config: axiosConfig,
        response: response(f.payload, f.status),
      });
    return response(f.payload, f.status);
  }
  if (pathname === '/admin/ai/providers')
    return response(envelope({ list: readSnapshot.providers }));
  if (pathname === '/admin/ai/models')
    return response(envelope({ list: readSnapshot.models }));
  if (pathname === '/admin/usage/by-provider')
    return response(
      envelope({
        list: [
          { provider: 'deleted-code', tokens: 3, calls: 1 },
          { provider: 'b', tokens: 2, calls: 1 },
        ],
      }),
    );
  if (pathname === '/admin/usage/list') {
    call.query = axiosConfig
      ? new URLSearchParams(
          Object.entries(axiosConfig.params || {})
            .filter(([, v]) => v !== undefined)
            .map(([k, v]) => [k, String(v)]),
        ).toString()
      : new URL(
          url,
          'https://admin.synthetic.invalid/api',
        ).searchParams.toString();
    return response(
      envelope({
        list: state.usageRows || [],
        total: (state.usageRows || []).length,
        page: 1,
        pageSize: 10,
      }),
    );
  }
  if (pathname === '/admin/usage/export') {
    return new Response('synthetic CSV', {
      headers: { 'content-type': 'text/csv' },
    });
  }
  if (pathname === '/admin/ai/global')
    return response(envelope(readSnapshot.config));
  if (pathname === '/chat/conversations' && method === 'GET')
    return response(
      envelope(
        capturedRows.filter((r) => r.userId === owner),
        state.unowned ? undefined : owner,
      ),
    );
  if (pathname === '/chat/conversations' && method === 'POST') {
    const r = row(++state.counter, body.providerCode, body.model, owner);
    r.title = '';
    state.rows.set(r.id, r);
    state.saved.set(r.id, []);
    if (state.createUnknown) throw Error('synthetic unknown create ACK');
    return response(envelope(r));
  }
  const target = /^\/chat\/conversations\/(\d+)(\/messages)?$/.exec(pathname);
  if (target) {
    const id = Number(target[1]);
    if (!state.rows.has(id) || state.rows.get(id).userId !== owner)
      return response({ code: -1, safeCode: 'conversation_unavailable' }, 404);
    if (target[2]) {
      if (method === 'GET')
        return response(
          envelope(
            state.saved.get(id) || [],
            owner,
            state.wrongTarget ? 999 : id,
          ),
        );
      assert.equal(method, 'POST');
      state.saved.set(id, [...(state.saved.get(id) || []), ...body.messages]);
      if (state.saveUnknown) throw Error('synthetic unknown save ACK');
      return response(envelope(null, owner, id));
    }
    if (method === 'PATCH') {
      Object.assign(state.rows.get(id), body);
      return response(envelope(null));
    }
    if (method === 'DELETE') {
      state.rows.delete(id);
      return response(envelope(null));
    }
  }
  if (pathname === '/ai/model-selection')
    return response(
      envelope(
        pair(state.resolvedProvider, new URL(url).searchParams.get('modelId')),
      ),
    );
  if (pathname === '/chat/completions')
    return response(envelope({ content: 'synthetic completion' }));
  if (pathname === '/chat/completions/stream') {
    const text = state.sse,
      streamGate = state.streamGate,
      prefix = state.prefix;
    return new Response(
      new ReadableStream({
        async start(c) {
          if (prefix) c.enqueue(new TextEncoder().encode(prefix));
          if (streamGate) await streamGate.promise;
          c.enqueue(new TextEncoder().encode(text));
          c.close();
        },
      }),
      { headers: { 'content-type': 'text/event-stream' } },
    );
  }
  throw Error('unexpected synthetic route ' + pathname);
}
test.beforeEach(() => {
  calls = [];
  gates = [];
  clients = [];
  state = {
    providers: providers(),
    models: models(),
    config: { defaultProviderCode: 'a', defaultModelId: 'same' },
    rows: new Map(),
    saved: new Map(),
    counter: 100,
    held: {},
    fail: {},
    sse: delta('answer') + end,
    resolvedProvider: 'b',
  };
  dom.reconfigure({ url: 'https://admin.synthetic.invalid' });
  process.env.NEXT_PUBLIC_BACKEND = 'https://backend.synthetic.invalid';
  localStorage.clear();
  sessionStorage.clear();
  useAuthStore.getState().setAuth('token-a', { id: 7, userName: 'A' });
  api.defaults.baseURL = '/api';
  global.fetch = (url, init = {}) => server(url, init);
  api.defaults.adapter = (c) =>
    server(
      'https://admin.synthetic.invalid/api' + c.url,
      { method: c.method, headers: c.headers, body: c.data },
      c,
    );
});
test.afterEach(async () => {
  await act(async () => {
    for (const g of gates) g.release();
    cleanup();
    await later();
  });
  for (const client of clients) client.clear();
  api.defaults.baseURL = '/api';
});
test.after(() => {
  dom.window.close();
  for (const c of channels) {
    c.port1.close();
    c.port2.close();
  }
  console.log(
    'synthetic DOM/channel closed; SUT HTTP injected; real model/SMTP requests=0',
  );
});
const posts = (p) =>
  calls.filter((c) => c.method === 'POST' && (!p || c.path === p));
const hold = (p, method = 'GET') => {
  const g = gate();
  gates.push(g);
  state.held[p + ':' + method] = g;
  return g;
};
async function mountHook() {
  const h = renderHook(() => hook(), { wrapper: React.StrictMode });
  await waitFor(() => assert.ok(h.result.current.conversations));
  await act(later);
  return h;
}
async function existing(code = 'a', model = 'same') {
  state.rows.set(1, row(1, code, model));
  state.saved.set(1, []);
  const h = await mountHook();
  await waitFor(() =>
    assert.ok(h.result.current.conversations.some((c) => c.id === '1')),
  );
  await act(async () => h.result.current.selectConversation('1'));
  return h;
}
async function send(
  h,
  text = 'hello',
  k = h.result.current.selection?.kind === 'legacy' ? undefined : key(pair()),
  id,
) {
  await act(async () => h.result.current.sendMessage(text, k, id));
  await waitFor(() => assert.equal(h.result.current.isLoading, false));
  await act(later);
}
const modelPosts = () =>
  posts().filter((c) => c.path.startsWith('/chat/completions'));

// 两个引用/版本交错：实际hook/controller/合成API，不需要模型发送。
async function listed() {
  state.rows.set(1, row(1));
  state.saved.set(1, [
    { role: 'user', content: 'history user' },
    { role: 'assistant', content: 'history answer' },
  ]);
  const h = await mountHook();
  await waitFor(() =>
    assert.ok(h.result.current.conversations.some((c) => c.id === '1')),
  );
  return h;
}
const listCalls = () =>
  calls.filter((c) => c.path === '/chat/conversations' && c.method === 'GET');
const selectionPatches = () =>
  calls.filter(
    (c) =>
      c.path === '/chat/conversations/1' &&
      c.method === 'PATCH' &&
      c.body.providerCode,
  );
test('pending history GET keeps its Entry through a completed list refresh', async () => {
  const h = await listed(),
    g = hold('/chat/conversations/1/messages');
  let pending;
  await act(async () => {
    pending = h.result.current.selectConversation('1');
  });
  await waitFor(() =>
    assert.equal(
      calls.filter((c) => c.path === '/chat/conversations/1/messages').length,
      1,
    ),
  );
  state.rows.get(1).title = 'fresh title';
  await act(async () => h.result.current.refreshConversations());
  assert.equal(h.result.current.conversations[0].title, 'fresh title');
  await act(async () => {
    g.release();
    await pending;
  });
  assert.deepEqual(h.result.current.messages, state.saved.get(1));
  assert.equal(h.result.current.canSend, true);
  assert.equal(modelPosts().length, 0);
});
test('pending selection PATCH preserves the operation Entry while list refresh completes', async () => {
  const h = await listed();
  await act(async () => h.result.current.selectConversation('1'));
  const g = hold('/chat/conversations/1', 'PATCH');
  let pending;
  await act(async () => {
    pending = h.result.current.chooseSelection(key(pair('b')));
  });
  await waitFor(() => assert.equal(selectionPatches().length, 1));
  await act(async () => h.result.current.refreshConversations());
  assert.equal(state.rows.get(1).providerCode, 'a');
  await act(async () => {
    g.release();
    await pending;
  });
  assert.equal(state.rows.get(1).providerCode, 'b');
  assert.equal(h.result.current.selection.pair.providerCode, 'b');
  assert.equal(h.result.current.selectionKey, key(pair('b')));
  assert.equal(modelPosts().length, 0);
});
test('list snapshot captured during PATCH cannot overwrite the acknowledged B selection afterward', async () => {
  const h = await listed();
  await act(async () => h.result.current.selectConversation('1'));
  const patchGate = hold('/chat/conversations/1', 'PATCH');
  let pending;
  await act(async () => {
    pending = h.result.current.chooseSelection(key(pair('b')));
  });
  await waitFor(() => assert.equal(selectionPatches().length, 1));
  const before = listCalls().length,
    listGate = hold('/chat/conversations');
  let refresh;
  await act(async () => {
    refresh = h.result.current.refreshConversations();
  });
  await waitFor(() => assert.equal(listCalls().length, before + 1));
  await act(async () => {
    patchGate.release();
    await pending;
  });
  assert.equal(state.rows.get(1).providerCode, 'b');
  assert.equal(h.result.current.selection.pair.providerCode, 'b');
  await act(async () => {
    listGate.release();
    await refresh;
  });
  assert.equal(h.result.current.selection.pair.providerCode, 'b');
  assert.equal(modelPosts().length, 0);
});
test('normal history, explicit selection and subsequent authoritative list refresh still agree', async () => {
  const h = await listed();
  await act(async () => h.result.current.selectConversation('1'));
  assert.deepEqual(h.result.current.messages, state.saved.get(1));
  await act(async () => h.result.current.refreshConversations());
  assert.deepEqual(h.result.current.messages, state.saved.get(1));
  await act(async () => h.result.current.chooseSelection(key(pair('b'))));
  await act(async () => h.result.current.refreshConversations());
  assert.equal(h.result.current.selection.pair.providerCode, 'b');
  assert.equal(state.rows.get(1).providerCode, 'b');
  assert.equal(h.result.current.canSend, true);
  assert.equal(selectionPatches().length, 1);
  assert.equal(modelPosts().length, 0);
});
test('list begun before selection mutation remains fenced and fresh list after acknowledgment reconciles', async () => {
  const h = await listed();
  await act(async () => h.result.current.selectConversation('1'));
  const before = listCalls().length,
    g = hold('/chat/conversations');
  let refresh;
  await act(async () => {
    refresh = h.result.current.refreshConversations();
  });
  await waitFor(() => assert.equal(listCalls().length, before + 1));
  await act(async () => h.result.current.chooseSelection(key(pair('b'))));
  await act(async () => {
    g.release();
    await refresh;
  });
  assert.equal(h.result.current.selection.pair.providerCode, 'b');
  delete state.held['/chat/conversations:GET'];
  await act(async () => h.result.current.refreshConversations());
  assert.equal(h.result.current.selection.pair.providerCode, 'b');
  assert.equal(modelPosts().length, 0);
});
async function mountUsage() {
  const load = Module._load;
  Module._load = function (id, ...args) {
    if (id === 'next/navigation')
      return {
        useRouter: () => ({ replace() {} }),
        useSearchParams: () => new URLSearchParams('provider=deleted-code'),
      };
    return load.call(this, id, ...args);
  };
  let Usage;
  try {
    Usage = require(
      path.join(source, 'src/app/(dashboard)/usage/page.tsx'),
    ).default;
  } finally {
    Module._load = load;
  }
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 } },
  });
  clients.push(client);
  await act(async () =>
    render(
      React.createElement(
        QueryClientProvider,
        { client },
        React.createElement(Usage),
      ),
    ),
  );
  await waitFor(() =>
    assert.equal(calls.filter((c) => c.path === '/admin/usage/list').length, 1),
  );
}
const usageReads = () => calls.filter((c) => c.path === '/admin/usage/list');
const optionReads = () =>
  calls.filter(
    (c) =>
      c.path === '/admin/ai/providers' || c.path === '/admin/usage/by-provider',
  );
const usageRow = () => ({
  id: 901,
  userId: 7,
  userName: 'recovered-user',
  provider: 'deleted-code',
  model: 'same',
  promptTokens: 1,
  completionTokens: 2,
  totalTokens: 3,
  createdAt: '2026-10-14T00:00:00Z',
});
test('actual UsagePage list failure retry requests original scoped list and filter, without refetching successful options', async () => {
  state.fail['/admin/usage/list:GET'] = {
    status: 503,
    payload: { message: 'SQL synthetic-secret' },
  };
  await mountUsage();
  await screen.findByRole('alert');
  await waitFor(() => assert.equal(optionReads().length, 2));
  delete state.fail['/admin/usage/list:GET'];
  state.usageRows = [usageRow()];
  const beforeOptions = optionReads().length;
  const retry =
    screen.queryByRole('button', { name: '重试用量列表', exact: true }) ||
    screen.getByRole('button', { name: '重试', exact: true });
  await act(async () => fireEvent.click(retry));
  await waitFor(() => assert.equal(usageReads().length, 2));
  await screen.findByText('recovered-user');
  assert.equal(optionReads().length, beforeOptions);
  assert.equal(
    usageReads().every((c) => c.token === 'token-a'),
    true,
  );
  for (const c of usageReads()) {
    const q = new URLSearchParams(c.query);
    assert.equal(q.get('provider'), 'deleted-code');
    assert.equal(q.get('page'), '1');
  }
  assert.doesNotMatch(document.body.textContent, /synthetic-secret/);
  assert.equal(modelPosts().length, 0);
});
test('actual UsagePage export failure has a separate explicit retry and never retries automatically', async () => {
  let clicks = 0,
    revoke = 0;
  const oldCreate = URL.createObjectURL,
    oldRevoke = URL.revokeObjectURL,
    oldClick = HTMLAnchorElement.prototype.click;
  URL.createObjectURL = () => 'blob:synthetic-export';
  URL.revokeObjectURL = () => {
    revoke++;
  };
  HTMLAnchorElement.prototype.click = function () {
    clicks++;
  };
  try {
    state.fail['/admin/usage/export:GET'] = {
      status: 500,
      payload: { message: 'synthetic-secret' },
    };
    await mountUsage();
    await act(async () =>
      fireEvent.click(
        screen.getByRole('button', { name: '导出 CSV', exact: true }),
      ),
    );
    await screen.findByRole('alert');
    assert.equal(
      calls.filter((c) => c.path === '/admin/usage/export').length,
      1,
    );
    assert.equal(clicks, 0);
    const before = usageReads().length,
      beforeOptions = optionReads().length;
    delete state.fail['/admin/usage/export:GET'];
    const retry =
      screen.queryByRole('button', { name: '重试导出', exact: true }) ||
      screen.getByRole('button', { name: '重试', exact: true });
    await act(async () => fireEvent.click(retry));
    await waitFor(() =>
      assert.equal(
        calls.filter((c) => c.path === '/admin/usage/export').length,
        2,
      ),
    );
    assert.equal(clicks, 1);
    assert.equal(revoke, 1);
    assert.equal(usageReads().length, before);
    assert.equal(optionReads().length, beforeOptions);
    assert.doesNotMatch(document.body.textContent, /synthetic-secret/);
    assert.equal(modelPosts().length, 0);
  } finally {
    URL.createObjectURL = oldCreate;
    URL.revokeObjectURL = oldRevoke;
    HTMLAnchorElement.prototype.click = oldClick;
  }
});
