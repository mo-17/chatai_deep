// 实际 React/HeroUI 页面及弹窗，axios 仅合成适配器；不连接真实后台或服务商。
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const Module = require('node:module');
const project = process.cwd();
const req = Module.createRequire(path.join(project, 'package.json'));
const { JSDOM } = req('jsdom');
const ts = req('typescript');
const dom = new JSDOM('<!doctype html><html><body></body></html>', {url:'https://sync.synthetic.invalid',pretendToBeVisual:true});
for (const key of ['window','document','navigator','HTMLElement','HTMLInputElement','HTMLSelectElement','HTMLButtonElement','HTMLIFrameElement','HTMLTextAreaElement','HTMLAnchorElement','Document','ShadowRoot','Element','Node','NodeFilter','MutationObserver','CustomEvent','Event','MouseEvent','KeyboardEvent','SVGElement','sessionStorage','localStorage','DOMRect'])
  Object.defineProperty(global,key,{configurable:true,value:dom.window[key]});
global.getComputedStyle=dom.window.getComputedStyle.bind(dom.window);
global.requestAnimationFrame=dom.window.requestAnimationFrame.bind(dom.window);
global.cancelAnimationFrame=dom.window.cancelAnimationFrame.bind(dom.window);
global.PointerEvent=dom.window.MouseEvent;
global.CSS={escape:v=>String(v).replace(/[^a-zA-Z0-9_-]/g,c=>'\\'+c)};
global.ResizeObserver=class{observe(){}unobserve(){}disconnect(){}};
global.IntersectionObserver=class{observe(){}unobserve(){}disconnect(){}};
window.matchMedia=()=>({matches:false,media:'',addListener(){},removeListener(){},addEventListener(){},removeEventListener(){},dispatchEvent(){return false;}});
HTMLElement.prototype.scrollIntoView=function(){};
global.IS_REACT_ACT_ENVIRONMENT=true;
const singletons=Object.fromEntries(['react','react/jsx-runtime','react/jsx-dev-runtime','react-dom','react-dom/client','react-dom/test-utils'].map(k=>[k,req.resolve(k)]));
const resolve=Module._resolveFilename;
Module._resolveFilename=function(id,parent,options){
  if(singletons[id])return singletons[id];
  if(id.startsWith('@/'))id=path.join(project,'src',id.slice(2));
  return resolve.call(this,id,parent,options);
};
for(const ext of ['.ts','.tsx'])require.extensions[ext]=(m,filename)=>{
  const result=ts.transpileModule(fs.readFileSync(filename,'utf8'),{fileName:filename,compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS,jsx:ts.JsxEmit.ReactJSX,esModuleInterop:true}});
  m._compile(result.outputText,filename);
};
const channels=new Set();const NativeMessageChannel=global.MessageChannel;
if(NativeMessageChannel)global.MessageChannel=class extends NativeMessageChannel{constructor(){super();channels.add(this);}};
const React=req('react');const {act}=React;
const {render,cleanup,screen,fireEvent,waitFor}=req('@testing-library/react');
const {QueryClient,QueryClientProvider}=req('@tanstack/react-query');
const {AxiosError}=req('axios');
const {api}=require(path.join(project,'src/lib/api/client.ts'));
const {useAuthStore}=require(path.join(project,'src/store/authStore.ts'));
const {ModelSyncDialog}=require(path.join(project,'src/components/ai/ModelSyncDialog.tsx'));
const Page=require(path.join(project,'src/app/(dashboard)/ai/models/page.tsx')).default;
const provider={id:1,code:'synthetic-a',displayName:'Synthetic A',apiKey:'****',baseUrl:'https://catalog.synthetic.invalid/v1',enabled:true};
const gate=()=>{let release;const promise=new Promise(r=>release=r);return{promise,release};};
let calls,held,failures,client,refreshes;
const preview=()=>({previewId:'a'.repeat(48),expiresAt:Date.now()+300000,providerId:1,providerCode:provider.code,format:'openai',rows:[
  {modelId:'new/model-a',displayName:'Official A',status:'new',changes:[],supportsVision:true,contextWindow:1000},
  {modelId:'existing',displayName:'Upstream name',status:'changed',changes:['displayName']},
  {modelId:'unchanged',displayName:'Unchanged',status:'existing',changes:[]},
]});
test.beforeEach(()=>{
  dom.reconfigure({url:'https://sync.synthetic.invalid'});calls=[];held={};failures={};refreshes=0;
  useAuthStore.getState().setAuth('synthetic-admin-original',{id:7,userName:'Synthetic'});
  client=new QueryClient({defaultOptions:{queries:{retry:false,gcTime:0},mutations:{retry:false,gcTime:0}}});
  api.defaults.adapter=async c=>{
    const method=c.method.toLowerCase(),url=c.url;
    calls.push({method,url,body:c.data?JSON.parse(c.data):undefined,authorization:c.headers.Authorization});
    let data;
    if(method==='get'){
      assert.ok(['/admin/ai/providers','/admin/ai/models'].includes(url),'no real model/config/test routes');
      data={list:url.endsWith('/providers')?[provider]:[]};
    }else{
      assert.equal(method,'post');assert.match(url,/^\/admin\/ai\/providers\/1\/model-sync\/(preview|import)$/);
      data=url.endsWith('/preview')?preview():{providerId:1,imported:['new/model-a'],skipped:[]};
    }
    const stage=url.endsWith('/preview')?'preview':url.endsWith('/import')?'import':null;
    if(held[stage])await held[stage].promise;
    if(failures[stage]){
      const response={config:c,status:failures[stage].status||503,statusText:'synthetic',headers:{},data:{message:failures[stage].message}};
      throw new AxiosError('synthetic request failed','ERR_BAD_RESPONSE',c,{},response);
    }
    return{config:c,data:{code:0,data},status:200,statusText:'synthetic',headers:{}};
  };
});
test.afterEach(async()=>{
  await act(async()=>{for(const g of Object.values(held))g.release();cleanup();});client.clear();
  assert.ok(calls.every(c=>c.url.startsWith('/admin/ai/')));
});
test.after(()=>{dom.window.close();for(const c of channels){c.port1.close();c.port2.close();}console.log('owned JSDOM/MessageChannels closed; external requests 0; model POST 0');});
const post=stage=>calls.filter(c=>c.method==='post'&&c.url.endsWith('/'+stage));
const press=async node=>act(async()=>fireEvent.click(node));
async function mountDialog(){await act(async()=>render(React.createElement(ModelSyncDialog,{provider,onClose:cleanup,onRefresh:()=>refreshes++})));}
async function discover(){await press(screen.getByRole('button',{name:'获取目录预览'}));await waitFor(()=>assert.ok(screen.queryByRole('table',{name:'模型同步预览'})));}
async function choose(){await press(screen.getByRole('checkbox',{name:'新增 new/model-a'}));}
const confirm=()=>screen.getByRole('button',{name:/确认导入所选新增模型/});

test('actual models page requires one provider and explicit preview; opening never imports',async()=>{
  await act(async()=>render(React.createElement(QueryClientProvider,{client},React.createElement(Page))));
  await waitFor(()=>assert.ok(screen.getByRole('button',{name:'同步模型'}).disabled));
  assert.equal(post('preview').length,0);assert.equal(post('import').length,0);
  await press(screen.getByRole('button',{name:/服务商/}));await press(await screen.findByRole('option',{name:'Synthetic A',exact:true}));
  await waitFor(()=>assert.equal(screen.getByRole('button',{name:'同步模型'}).disabled,false));
  await press(screen.getByRole('button',{name:'同步模型'}));await discover();
  assert.equal(post('preview').length,1);assert.equal(post('import').length,0);
  assert.match(document.body.textContent,/新增 1 · 已有 1 · 信息有变化 1/);
  assert.equal(screen.getByRole('checkbox',{name:'新增 existing'}).disabled,true);
  assert.match(document.body.textContent,/保留现值：名称/);assert.match(document.body.textContent,/价格：未知/);
});
test('actual dialog sends raw model ID only after selection+confirm, once, with original session',async()=>{
  await mountDialog();await discover();assert.equal(confirm().disabled,true);await choose();
  const g=gate();held.import=g;
  await act(async()=>{fireEvent.click(confirm());fireEvent.click(confirm());});
  await waitFor(()=>assert.equal(post('import').length,1));assert.equal(refreshes,0);
  g.release();await waitFor(()=>assert.equal(refreshes,1));
  assert.deepEqual(post('import')[0].body,{previewId:'a'.repeat(48),modelIds:['new/model-a']});
  assert.equal(post('import')[0].authorization,'Bearer synthetic-admin-original');
  assert.match(document.body.textContent,/已新增 1 个停用模型/);assert.equal(post('preview').length,1);
});
test('closing while preview is pending ignores late response and cannot import',async()=>{
  held.preview=gate();await mountDialog();await press(screen.getByRole('button',{name:'获取目录预览'}));
  await press(screen.getByRole('button',{name:'关闭',exact:true}));held.preview.release();
  await act(async()=>{});assert.equal(screen.queryByRole('table',{name:'模型同步预览'}),null);assert.equal(post('import').length,0);assert.equal(refreshes,0);
});
test('new epoch during preview cannot display old result or refresh new account',async()=>{
  held.preview=gate();await mountDialog();await press(screen.getByRole('button',{name:'获取目录预览'}));
  await act(async()=>useAuthStore.getState().setAuth('synthetic-admin-original',{id:7,userName:'Synthetic'}));held.preview.release();
  await act(async()=>{});assert.equal(screen.queryByRole('table',{name:'模型同步预览'}),null);assert.equal(post('import').length,0);assert.equal(refreshes,0);
});
test('late import 401 does not log out newer account, refresh, or replay POST',async()=>{
  await mountDialog();await discover();await choose();held.import=gate();
  await press(confirm());await waitFor(()=>assert.equal(post('import').length,1));
  await act(async()=>useAuthStore.getState().setAuth('synthetic-admin-new',{id:8,userName:'Other'}));
  failures.import={status:401,message:'synthetic-private-secret'};held.import.release();await act(async()=>{});
  assert.equal(useAuthStore.getState().token,'synthetic-admin-new');assert.equal(refreshes,0);assert.equal(post('import').length,1);assert.doesNotMatch(document.body.textContent,/synthetic-private-secret/);
});
test('origin change before confirm sends zero import and requests reopening',async()=>{
  await mountDialog();await discover();await choose();dom.reconfigure({url:'https://other.synthetic.invalid'});
  await press(confirm());assert.equal(post('import').length,0);assert.match(document.body.textContent,/会话已变化/);assert.equal(refreshes,0);
});
test('unknown provider errors remain generic; no automatic preview or import retry',async()=>{
  failures.preview={status:503,message:'SQL token=synthetic-private-secret'};
  await mountDialog();await press(screen.getByRole('button',{name:'获取目录预览'}));
  await waitFor(()=>assert.match(document.body.textContent,/操作结果未确认/));
  assert.doesNotMatch(document.body.textContent,/synthetic-private-secret|SQL/);assert.equal(post('preview').length,1);assert.equal(post('import').length,0);
});
test('unknown import result clears pending selection; reconciliation button performs no POST',async()=>{
  await mountDialog();await discover();await choose();failures.import={status:503,message:'upstream raw token=synthetic-private-secret'};
  await press(confirm());await waitFor(()=>assert.match(document.body.textContent,/操作结果未确认/));
  assert.equal(confirm().disabled,true);assert.equal(post('import').length,1);assert.equal(refreshes,0);
  await press(screen.getByRole('button',{name:'刷新列表核对'}));assert.equal(refreshes,1);assert.equal(post('import').length,1);assert.equal(post('preview').length,1);
});
