const nativeFetch = global.fetch;
// 实际页面 / HeroUI Select / React Query / axios；JSDOM布局与网络仅合成。
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const { createRequire } = Module;
const project = process.cwd();
const source = process.env.FINAL_ADMIN_SOURCE;
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
const useChatService=require(path.join(source,'src/hooks/useChatService.ts')).useChatService;
const chatApi=require(path.join(source,'src/lib/api/chat.ts')).chatApi;
const owned=process.env.FINAL_OWNED,nonce=process.env.FINAL_NONCE,meta=JSON.parse(fs.readFileSync(path.join(owned,'nest-ready.json')));
assert.equal(JSON.parse(fs.readFileSync(path.join(owned,'fixture-sentinel.json'))).nonce,nonce);
const records=[],clients=[];
const pair=code=>JSON.stringify([code,'shared']);
async function control(body={}){const r=await nativeFetch(meta.origin+'/__fixture/control',{method:'POST',headers:{'Content-Type':'application/json','x-fixture-nonce':nonce},body:JSON.stringify(body)});assert.equal(r.status,200);return r.json();}
const hook=()=>renderHook(()=>useChatService(),{wrapper:React.StrictMode});
test.beforeEach(async()=>{await control({op:'reset',phase:'react'});localStorage.clear();sessionStorage.clear();process.env.NEXT_PUBLIC_BACKEND=meta.origin;api.defaults.baseURL=meta.origin+'/uapi';global.fetch=nativeFetch;useAuthStore.getState().setAuth(meta.tokenA,{id:7,userName:'A'});});
test.afterEach(async()=>{await control({releaseUpstream:true,releaseProbe:true});await act(async()=>cleanup());for(const c of clients)c.clear();records.push(await control());});
test.after(()=>{fs.writeFileSync(path.join(owned,'react-live-evidence.json'),JSON.stringify(records));dom.window.close();for(const c of channels){c.port1.close();c.port2.close();}console.log('FINAL_REACT_DOM_CLOSED; actual Nest HTTP, synthetic upstream only');});
async function ready(h){await waitFor(()=>assert.equal(h.result.current.metadataStatus,'ready'),{timeout:5000});}
async function send(h,content,key,id){await act(async()=>h.result.current.sendMessage(content,key,id));await waitFor(()=>assert.equal(h.result.current.isLoading,false));}
async function waitUpstream(n){await waitFor(async()=>assert.equal((await control()).counts.upstream,n));}
test('R1 actual hook/Nest/PG two rounds four rows, exact A/B and two admin owner isolation',async()=>{
 const h=hook();await ready(h);let target;await act(async()=>{target=h.result.current.newConversation();});await send(h,'round A',pair('alpha'),target);const id=Number(h.result.current.activeId);assert.ok(id>0);
 await act(async()=>h.result.current.chooseSelection(pair('beta')));await send(h,'round B',pair('beta'));
 const state=await control();assert.deepEqual(state.upstreamRequests.map(r=>r.provider),['alpha','beta']);assert.equal(state.messages.filter(r=>r.conversationId===id).length,4);assert.equal(h.result.current.messages.length,4);
 await act(async()=>useAuthStore.getState().setAuth(meta.tokenB,{id:8,userName:'B'}));await assert.rejects(()=>chatApi.listMessages(id),e=>e.safeCode==='conversation_unavailable');await assert.rejects(()=>chatApi.saveMessages(id,[{role:'user',content:'foreign'}]),e=>e.safeCode==='conversation_unavailable');await assert.rejects(()=>chatApi.deleteConversation(id),e=>e.safeCode==='conversation_unavailable');
 const own=await chatApi.createConversation({providerCode:'beta',modelId:'shared'});await chatApi.saveMessages(own.id,[{role:'user',content:'owner B'},{role:'assistant',content:'B result'}]);assert.equal((await chatApi.listMessages(own.id)).length,2);
 const final=await control();assert.equal(final.messages.filter(r=>r.conversationId===id).length,4);assert.equal(final.conversations.find(r=>r.id===id).userId,7);assert.equal(final.conversations.find(r=>r.id===own.id).userId,8);
});
test('R2 fixed run choice and stale account result; unknown save ACK never replays',async()=>{
 const h=hook();await ready(h);let target;await act(async()=>{target=h.result.current.newConversation();});await send(h,'seed',pair('alpha'),target);const id=Number(h.result.current.activeId);
 await control({holdUpstream:true});await act(async()=>h.result.current.sendMessage('fixed A',pair('alpha')));await waitUpstream(2);
 await control({invalidDefault:true});await act(async()=>h.result.current.refreshMetadata());await control({releaseUpstream:true});await waitFor(()=>assert.equal(h.result.current.isLoading,false));assert.equal((await control()).upstreamRequests.at(-1).provider,'alpha');assert.equal(h.result.current.selection.pair.providerCode,'alpha');
 await control({dropSave:true});await send(h,'unknown save',pair('alpha'));assert.match(h.result.current.error,/保存结果未确认/);const count=(await control()).counts.upstream;await send(h,'no auto replay',pair('alpha'));assert.equal((await control()).counts.upstream,count);await act(async()=>h.result.current.selectConversation(String(id)));assert.match(h.result.current.error,/保存结果未确认/);
 // New explicit target; scope switch while upstream pending may not write A output in B view.
 await control({op:'reset',phase:'react-late'});let draft;await act(async()=>{draft=h.result.current.newConversation();});await act(async()=>h.result.current.chooseSelection(pair('alpha')));await control({holdUpstream:true});await act(async()=>h.result.current.sendMessage('old A',pair('alpha'),draft));await waitUpstream(1);await act(async()=>useAuthStore.getState().setAuth(meta.tokenB,{id:8,userName:'B'}));await control({releaseUpstream:true});await act(async()=>new Promise(r=>setTimeout(r,30)));assert.equal(useAuthStore.getState().token,meta.tokenB);assert.deepEqual(h.result.current.messages,[]);assert.equal(h.result.current.activeId,null);
});
test('R3 real SSE finite error settles once and actual UsagePage includes deleted historical provider',async()=>{
 const h=hook();await ready(h);let target;await act(async()=>{target=h.result.current.newConversation();});await control({mode:'sse-error'});await send(h,'SSE failure',pair('alpha'),target);assert.ok(h.result.current.error);assert.doesNotMatch(h.result.current.error,/synthetic-secret/);assert.equal((await control()).counts.upstream,1);assert.equal(useAuthStore.getState().token,meta.tokenA);
 const load=Module._load;Module._load=function(id,...args){if(id==='next/navigation')return {useRouter:()=>({replace(){}}),useSearchParams:()=>new URLSearchParams('provider=deleted-provider')};return load.call(this,id,...args);};let Usage;try{Usage=require(path.join(source,'src/app/(dashboard)/usage/page.tsx')).default;}finally{Module._load=load;}
 const client=new QueryClient({defaultOptions:{queries:{retry:false,gcTime:0}}});clients.push(client);await act(async()=>render(React.createElement(QueryClientProvider,{client},React.createElement(Usage))));const selector=screen.getByRole('button',{name:/Provider/});await waitFor(()=>assert.match(selector.textContent,/deleted-provider/));await act(async()=>fireEvent.click(selector));assert.ok(await screen.findByRole('option',{name:/deleted-provider/}));assert.ok(await screen.findByRole('option',{name:/Synthetic alpha/}));assert.ok(await screen.findByRole('option',{name:/Synthetic beta/}));
});
