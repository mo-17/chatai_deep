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
  calls.push(call);
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
  if (pathname === '/admin/usage/list')
    return response(envelope({ list: [], total: 0, page: 1, pageSize: 10 }));
  if (pathname === '/admin/ai/global')
    return response(envelope(readSnapshot.config));
  if (pathname === '/chat/conversations' && method === 'GET')
    return response(
      envelope(
        [...state.rows.values()].filter((r) => r.userId === owner),
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

test('actual hook explicit A/B same model creates and sends distinct pairs, two rounds store only four messages under StrictMode', async () => {
  const h = await existing();
  await send(h);
  await send(h, 'second');
  assert.deepEqual(
    modelPosts().map((c) => [c.body.providerCode, c.body.model]),
    [
      ['a', 'same'],
      ['a', 'same'],
    ],
  );
  assert.equal(state.saved.get(1).length, 4);
  assert.deepEqual(
    posts('/chat/conversations/1/messages').map((c) => c.body.messages.length),
    [2, 2],
  );
  assert.equal(typeof h.result.current.chooseSelection, 'function');
  await act(async () => h.result.current.chooseSelection(key(pair('b'))));
  await send(h, 'B', key(pair('b')));
  assert.equal(modelPosts().at(-1).body.providerCode, 'b');
  assert.equal(state.rows.get(1).providerCode, 'b');
});
test('new target returned synchronously is used after create, without stale activeId', async () => {
  const h = await mountHook();
  let id;
  await act(async () => {
    id = h.result.current.newConversation();
    await h.result.current.sendMessage('first', key(pair()), id);
  });
  await waitFor(() => assert.equal(modelPosts().length, 1));
  await waitFor(() =>
    assert.equal(posts('/chat/conversations/101/messages').length, 1),
  );
  assert.equal(h.result.current.activeId, '101');
  assert.deepEqual(posts('/chat/conversations')[0].body, {
    model: 'same',
    providerCode: 'a',
  });
});
for (const kind of ['ambiguous', 'closed'])
  test(`owned legacy ${kind} is authoritative GET only, zero model POST and no logout`, async () => {
    state.fail['/ai/model-selection:GET'] = {
      status: kind === 'closed' ? 403 : 409,
      payload: {
        code: 'upstream_error',
        safeCode: kind === 'closed' ? 'catalog_not_public' : 'model_ambiguous',
        message: 'SQL token=synthetic-secret',
      },
    };
    const h = await existing(null);
    await send(h, 'legacy', undefined);
    assert.equal(modelPosts().length, 0);
    assert.equal(useAuthStore.getState().token, 'token-a');
    assert.match(
      h.result.current.error,
      kind === 'closed' ? /清单未开放/ : /多个服务商/,
    );
    assert.doesNotMatch(h.result.current.error, /synthetic-secret/);
  });
test('owned unique legacy resolves once, stores pair and later requests reuse exact pair', async () => {
  const h = await existing(null);
  await send(h, 'legacy', undefined);
  await send(h, 'second', key(pair('b')));
  assert.equal(calls.filter((c) => c.path === '/ai/model-selection').length, 1);
  assert.equal(state.rows.get(1).providerCode, 'b');
  assert.deepEqual(
    modelPosts().map((c) => c.body.providerCode),
    ['b', 'b'],
  );
});
test('unowned old last choice does not acquire current identity or fall through to global', async () => {
  localStorage.setItem('ai-chat-model', 'private-old-model');
  const h = await mountHook();
  let id;
  await act(async () => {
    id = h.result.current.newConversation();
  });
  await send(h, 'try', undefined, id);
  assert.equal(modelPosts().length, 0);
  assert.equal(posts('/chat/conversations').length, 0);
  assert.doesNotMatch(JSON.stringify(h.result.current), /private-old-model/);
});
test('invalid global never selects first enabled model', async () => {
  state.config.defaultModelId = 'deleted';
  const h = await mountHook();
  let id;
  await act(async () => {
    id = h.result.current.newConversation();
  });
  await send(h, 'try', undefined, id);
  assert.equal(modelPosts().length, 0);
  assert.equal(posts('/chat/conversations').length, 0);
});
test('unowned conversation response and wrong target history cannot be stamped as current data', async () => {
  state.unowned = true;
  state.rows.set(1, row(1));
  const h = await mountHook();
  assert.equal(h.result.current.conversations.length, 0);
  state.unowned = false;
  state.wrongTarget = true;
  await act(async () => h.result.current.refreshConversations());
  await act(async () => h.result.current.selectConversation('1'));
  await send(h);
  assert.equal(modelPosts().length, 0);
  assert.match(h.result.current.error, /归属/);
});
for (const change of [
  'account',
  'ABA',
  'origin',
  'token',
  'backend-origin',
  'admin-origin',
])
  test(`late create after ${change} cannot POST model or overwrite new scope`, async () => {
    const g = hold('/chat/conversations', 'POST'),
      h = await mountHook();
    let id;
    await act(async () => {
      id = h.result.current.newConversation();
    });
    await act(async () => {
      void h.result.current.sendMessage('first', key(pair()), id);
    });
    await waitFor(() => assert.equal(posts('/chat/conversations').length, 1));
    await act(async () => {
      if (change === 'account')
        useAuthStore.getState().setAuth('token-b', { id: 8, userName: 'B' });
      else if (change === 'ABA')
        useAuthStore.getState().setAuth('token-a', { id: 7, userName: 'A' });
      else if (change === 'token')
        useAuthStore.getState().setAuth('token-new', { id: 7, userName: 'A' });
      else if (change === 'backend-origin') {
        process.env.NEXT_PUBLIC_BACKEND =
          'https://other-backend.synthetic.invalid';
        h.rerender();
      } else if (change === 'admin-origin') {
        dom.reconfigure({ url: 'https://other-admin.synthetic.invalid' });
        h.rerender();
      } else {
        api.defaults.baseURL = 'https://other.synthetic.invalid/api';
        h.rerender();
      }
    });
    await act(async () => g.release());
    await act(later);
    assert.equal(modelPosts().length, 0);
    assert.equal(h.result.current.activeId, null);
  });
test('late A history never overwrites B target', async () => {
  state.rows.set(1, row(1));
  state.rows.set(2, row(2, 'b'));
  state.saved.set(1, [{ role: 'assistant', content: 'private A' }]);
  state.saved.set(2, [{ role: 'assistant', content: 'visible B' }]);
  const g = hold('/chat/conversations/1/messages'),
    h = await mountHook();
  await act(async () => {
    void h.result.current.selectConversation('1');
  });
  await act(async () => h.result.current.selectConversation('2'));
  await act(async () => g.release());
  await act(later);
  assert.deepEqual(h.result.current.messages, [
    { role: 'assistant', content: 'visible B' },
  ]);
});
test('late stream tokens do not enter a newly selected conversation and original partial/user save settles once', async () => {
  state.rows.set(2, row(2, 'b'));
  const g = gate();
  gates.push(g);
  state.streamGate = g;
  state.prefix = delta('partial A');
  const h = await existing();
  await act(async () => h.result.current.sendMessage('A', key(pair())));
  await waitFor(() =>
    assert.equal(h.result.current.messages.at(-1).content, 'partial A'),
  );
  await act(async () => h.result.current.selectConversation('2'));
  await act(async () => g.release());
  await act(later);
  assert.equal(h.result.current.activeId, '2');
  assert.deepEqual(h.result.current.messages, []);
  assert.equal(posts('/chat/conversations/1/messages').length, 1);
  assert.equal(posts('/chat/conversations/2/messages').length, 0);
  assert.equal(state.saved.get(1)[1].content, 'partial A');
});
for (const kind of ['sse-error', 'embedded-error', 'truncated'])
  test(`${kind} fails once, retains actual content only and never replays`, async () => {
    state.sse =
      delta('partial') +
      (kind === 'truncated'
        ? ''
        : (kind === 'sse-error' ? 'event: error\n' : '') +
          'data: ' +
          JSON.stringify({
            safeCode: 'model_unavailable',
            error: { message: 'SQL secret=synthetic-secret' },
            statusCode: 409,
          }) +
          '\n\n' +
          end);
    const h = await existing();
    await send(h);
    assert.ok(h.result.current.error);
    assert.doesNotMatch(h.result.current.error, /synthetic-secret/);
    assert.equal(posts('/chat/conversations/1/messages').length, 1);
    assert.equal(modelPosts().length, 1);
    assert.equal(state.saved.get(1)[1].content, 'partial');
  });
test('unknown create and save are not retried or matched by content, explicit GET reconciliation only', async () => {
  state.createUnknown = true;
  const h = await mountHook();
  let id;
  await act(async () => {
    id = h.result.current.newConversation();
  });
  await send(h, 'first', key(pair()), id);
  await send(h, 'first', key(pair()), id);
  assert.equal(posts('/chat/conversations').length, 1);
  assert.equal(modelPosts().length, 0);
  state.createUnknown = false;
  await act(async () => h.result.current.refreshConversations());
  await act(async () => h.result.current.selectConversation('101'));
  state.saveUnknown = true;
  await send(h, 'second');
  await send(h, 'second');
  assert.equal(posts('/chat/conversations/101/messages').length, 1);
  await act(async () => h.result.current.selectConversation('101'));
  assert.match(h.result.current.error, /保存结果未确认/);
  assert.equal(posts('/chat/conversations/101/messages').length, 1);
});
test('late old 401 never logs out a new admin; upstream 401 is safe but not session logout', async () => {
  const g = hold('/chat/conversations/1/messages');
  state.fail['/chat/conversations/1/messages:GET'] = {
    status: 401,
    payload: { code: -1, safeCode: 'authentication_error' },
  };
  state.rows.set(1, row(1));
  const h = await mountHook();
  await act(async () => {
    void h.result.current.selectConversation('1');
  });
  await act(async () =>
    useAuthStore.getState().setAuth('token-b', { id: 8, userName: 'B' }),
  );
  await act(async () => g.release());
  await act(later);
  assert.equal(useAuthStore.getState().token, 'token-b');
  state.fail = {};
  useAuthStore.getState().setAuth('token-a', { id: 7, userName: 'A' });
  state.fail['/chat/completions/stream:POST'] = {
    status: 401,
    payload: {
      safeCode: 'authentication_error',
      message: 'secret=synthetic-secret',
    },
  };
  const a = await existing();
  await send(a);
  assert.equal(useAuthStore.getState().token, 'token-a');
  assert.doesNotMatch(a.result.current.error, /synthetic-secret/);
});
test('HTTP guard 401 with explicit source marker only logs out original current session', async () => {
  state.fail['/chat/completions/stream:POST'] = {
    status: 401,
    payload: { safeCode: 'authentication_error', authError: true },
  };
  const h = await existing();
  await act(async () => h.result.current.sendMessage('hello', key(pair())));
  await waitFor(() => assert.equal(useAuthStore.getState().token, null));
});
test('nonstream sends raw exact pair and safe configuration failure never exposes payload', async () => {
  const reply = await chatApi.complete({
    model: 'same',
    providerCode: 'b',
    messages: [{ role: 'user', content: 'test' }],
  });
  assert.equal(reply.content, 'synthetic completion');
  assert.equal(posts('/chat/completions')[0].body.providerCode, 'b');
  state.fail['/chat/completions:POST'] = {
    status: 409,
    payload: {
      safeCode: 'provider_unavailable',
      message: 'key=synthetic-secret',
    },
  };
  await assert.rejects(
    () => chatApi.complete({ model: 'same', providerCode: 'b', messages: [] }),
    (e) =>
      e.safeCode === 'provider_unavailable' &&
      !e.message.includes('synthetic-secret'),
  );
  assert.equal(useAuthStore.getState().token, 'token-a');
});
test('actual page/HeroUI labels distinguish same-name providers, explicit B selection and first send carry B', async () => {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 } },
  });
  clients.push(client);
  await act(async () =>
    render(
      React.createElement(
        React.StrictMode,
        null,
        React.createElement(
          QueryClientProvider,
          { client },
          React.createElement(Page),
        ),
      ),
    ),
  );
  const control = screen.getByRole('button', { name: /选择模型/ });
  await waitFor(() => assert.match(control.textContent, /Provider A.*a.*same/));
  await act(async () => fireEvent.click(control));
  await act(async () =>
    fireEvent.click(await screen.findByRole('option', { name: /Provider B/ })),
  );
  await waitFor(() => assert.match(control.textContent, /Provider B/));
  await act(async () =>
    fireEvent.change(screen.getByPlaceholderText('输入消息...'), {
      target: { value: 'page first' },
    }),
  );
  await act(async () =>
    fireEvent.submit(
      screen.getByPlaceholderText('输入消息...').closest('form'),
    ),
  );
  await waitFor(() => assert.equal(modelPosts().length, 1));
  await waitFor(() =>
    assert.equal(posts('/chat/conversations/101/messages').length, 1),
  );
  assert.equal(modelPosts()[0].body.providerCode, 'b');
  assert.equal(state.rows.get(101).providerCode, 'b');
});
test('tuple collision preserves raw provider and model without slash parsing', async () => {
  state.providers = [
    { id: 1, code: 'a/b', displayName: 'AB', enabled: true },
    { id: 2, code: 'a', displayName: 'A', enabled: true },
  ];
  state.models = [
    { id: 1, providerId: 1, providerCode: 'a/b', modelId: 'c', enabled: true },
    { id: 2, providerId: 2, providerCode: 'a', modelId: 'b/c', enabled: true },
  ];
  state.config = { defaultProviderCode: 'a/b', defaultModelId: 'c' };
  const h = await mountHook();
  await waitFor(() => assert.equal(h.result.current.choices?.length, 2));
  assert.equal(new Set(h.result.current.choices.map((c) => c.key)).size, 2);
  let id;
  await act(async () => {
    id = h.result.current.newConversation();
  });
  await send(h, 'raw', key(pair('a/b', 'c')), id);
  assert.equal(modelPosts()[0].body.providerCode, 'a/b');
  assert.equal(modelPosts()[0].body.model, 'c');
});
test('original pair stays fixed during stream and global metadata refresh never replaces it', async () => {
  const h = await existing('b');
  const g = gate();
  gates.push(g);
  state.streamGate = g;
  state.prefix = delta('B partial');
  await act(async () =>
    h.result.current.sendMessage('running', key(pair('b'))),
  );
  await waitFor(() => assert.equal(modelPosts().length, 1));
  state.config = { defaultProviderCode: 'a', defaultModelId: 'same' };
  await act(async () => h.result.current.refreshMetadata());
  await act(async () => g.release());
  await waitFor(() => assert.equal(h.result.current.isLoading, false));
  assert.equal(modelPosts()[0].body.providerCode, 'b');
  assert.equal(h.result.current.selection.pair.providerCode, 'b');
  assert.equal(state.rows.get(1).providerCode, 'b');
});
test('personal owned choice survives same-owner reload, invalid pair remains visible and never falls back', async () => {
  let h = await mountHook();
  await act(async () => h.result.current.chooseSelection(key(pair('b'))));
  h.unmount();
  h = await mountHook();
  await waitFor(() =>
    assert.equal(h.result.current.selectionKey, key(pair('b'))),
  );
  state.models = state.models.filter((m) => m.providerCode !== 'b');
  await act(async () => h.result.current.refreshMetadata());
  assert.match(h.result.current.selectionLabel, /b.*same/);
  assert.equal(h.result.current.canSend, false);
  let id;
  await act(async () => {
    id = h.result.current.newConversation();
  });
  state.fail['/chat/completions/stream:POST'] = {
    status: 409,
    payload: { safeCode: 'model_unavailable' },
  };
  await send(h, 'try', key(pair('b')), id);
  assert.equal(modelPosts()[0].body.providerCode, 'b');
  assert.match(h.result.current.error, /原模型/);
});
test('late metadata never overwrites newer refresh and read failure is explicit', async () => {
  const h = await mountHook();
  const g = hold('/admin/ai/models');
  await act(async () => {
    void h.result.current.refreshMetadata();
  });
  delete state.held['/admin/ai/models:GET'];
  state.models = [state.models[1]];
  await act(async () => h.result.current.refreshMetadata());
  await act(async () => g.release());
  assert.equal(h.result.current.choices.length, 1);
  assert.equal(h.result.current.choices[0].providerCode, 'b');
  state.fail['/admin/ai/models:GET'] = 'network';
  await act(async () => h.result.current.refreshMetadata());
  assert.equal(h.result.current.metadataStatus, 'failed');
  assert.doesNotMatch(h.result.current.metadataError, /synthetic-secret/);
});
test('original scope changes during authoritative probe prohibit binding and dispatch', async () => {
  const h = await existing(null),
    g = hold('/ai/model-selection');
  await act(async () => {
    void h.result.current.sendMessage('legacy');
  });
  await waitFor(() =>
    assert.equal(
      calls.filter((c) => c.path === '/ai/model-selection').length,
      1,
    ),
  );
  await act(async () =>
    useAuthStore.getState().setAuth('token-a', { id: 7, userName: 'A' }),
  );
  await act(async () => g.release());
  await act(later);
  assert.equal(modelPosts().length, 0);
  assert.equal(calls.filter((c) => c.method === 'PATCH').length, 0);
});
test('old save failure after identity changes cannot expose error/content to new user or repeat save', async () => {
  const h = await existing();
  const g = hold('/chat/conversations/1/messages', 'POST');
  state.fail['/chat/conversations/1/messages:POST'] = 'network';
  await act(async () => h.result.current.sendMessage('private A', key(pair())));
  await waitFor(() =>
    assert.equal(posts('/chat/conversations/1/messages').length, 1),
  );
  await act(async () =>
    useAuthStore.getState().setAuth('token-b', { id: 8, userName: 'B' }),
  );
  await act(async () => g.release());
  await act(later);
  assert.deepEqual(h.result.current.messages, []);
  assert.equal(h.result.current.error, null);
  assert.equal(posts('/chat/conversations/1/messages').length, 1);
});
test('multi-line CRLF SSE and trailing decoder data finish once; malformed unknown values remain fixed', async () => {
  state.sse =
    'data: {"choices":\r\ndata: [{"delta":{"content":"你好"}}]}\r\n\r\ndata: [DONE]';
  let done = 0,
    fail = 0,
    tokens = '';
  await new Promise((resolve) =>
    chatApi.streamComplete(
      { model: 'same', providerCode: 'b', messages: [] },
      (t) => (tokens += t),
      () => {
        done++;
        resolve();
      },
      () => {
        fail++;
        resolve();
      },
    ),
  );
  assert.equal(done, 1);
  assert.equal(fail, 0);
  assert.equal(tokens, '你好');
  state.sse =
    'event: error\ndata: {"safeCode":"model_unavailable extra synthetic-secret","message":"raw SQL secret"}\n\n' +
    end;
  let error;
  await new Promise((resolve) =>
    chatApi.streamComplete(
      { model: 'same', providerCode: 'a', messages: [] },
      () => {},
      () => {
        done++;
        resolve();
      },
      (e) => {
        error = e;
        resolve();
      },
    ),
  );
  assert.equal(done, 1);
  assert.equal(error.safeCode, 'request_failed');
  assert.doesNotMatch(error.message, /SQL|secret/);
});
test('configured and deleted historical provider codes appear in actual usage Select and preserve unknown URL filter', async () => {
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
  const control = screen.getByRole('button', { name: /Provider/ });
  await waitFor(() => assert.match(control.textContent, /deleted-code/));
  await act(async () => fireEvent.click(control));
  await screen.findByRole('option', { name: /deleted-code/ });
  assert.ok(screen.getByRole('option', { name: /Provider A/ }));
  assert.ok(screen.getByRole('option', { name: /Provider B/ }));
  assert.equal(
    calls.filter((c) => c.path === '/admin/usage/by-provider').length,
    1,
  );
  assert.equal(modelPosts().length, 0);
});
