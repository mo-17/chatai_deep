const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const root = process.env.CLOUD_ADMIN_COMPILED;
if (!root || !root.startsWith('/tmp/')) throw new Error('tests require explicit isolated compiled directory');
const m = require(path.join(root, 'lib/cloud-workflow/model.js'));
const { CloudApi, CloudHttpError, CloudSessionStale } = require(path.join(root, 'lib/cloud-workflow/api.js'));
const { CloudController } = require(path.join(root, 'lib/cloud-workflow/controller.js'));
const { CloudReceipts } = require(path.join(root, 'lib/cloud-workflow/receipts.js'));
class Memory { constructor() { this.values = new Map(); this.fail = false; } getItem(k) { return this.values.get(k) ?? null; } setItem(k,v) { if (this.fail) throw new Error('synthetic storage full'); this.values.set(k, v); } removeItem(k) { this.values.delete(k); } }
class Clock { constructor() { this.now=0; this.id=0; this.timers=new Map(); } schedule(fn,ms) { const id=++this.id;this.timers.set(id,{fn,at:this.now+ms});return id; } cancel(id) { this.timers.delete(id); } async advance(ms) { this.now+=ms; for(const [id,t] of [...this.timers]) if(t.at<=this.now){ this.timers.delete(id);t.fn(); } await flush(); } }
const deferred = () => { let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject}; };
const flush = async () => { for(let i=0;i<10;i++) await new Promise(r=>setImmediate(r)); };
const response = (v, status=200) => new Response(JSON.stringify(v),{status,headers:{'Content-Type':'application/json'}});
const profile = {providerId:1,modelRowId:2,modelId:'synthetic',providerName:'合成服务',modelName:'合成模型'};
const audits=[];
function fixture(t,{enabled=true,available=true}={}) {
 const storage=new Memory(),clock=new Clock();
 let session={origin:'https://synthetic-backend.invalid',frontendOrigin:'https://synthetic-admin.invalid',token:'synthetic-fixed-token',epoch:1};
 let logout=0,hook=null; const requests=[],tasks=new Map(),keys=new Map();
 const seed=async (payload,content='合成云成果')=>{ const id=crypto.randomUUID(), publicationId=crypto.randomUUID(),rid=crypto.randomUUID(),steps=m.CLOUD_ROLES.map(role=>({id:crypto.randomUUID(),role,state:'complete',revision:2,result_version:1}));const task={parent:{id,owner_id:7,state:'complete',revision:4,payload_hash:await m.hash(m.canonical(payload)),payload,publication_id:publicationId,final_result_id:rid,attempts_used:3,estimated_tokens:500},steps};task.result={id:rid,step_id:steps[1].id,version:1,content,content_hash:await m.hash(content),publication_id:publicationId};tasks.set(id,task);keys.set(payload.idempotencyKey,task);return task; };
 const receipt=x=>({id:x.parent.id,ownerId:7,state:x.parent.state,revision:x.parent.revision,payloadHash:x.parent.payload_hash,source:x.parent.payload.source,publicationId:x.parent.publication_id,finalResultId:x.parent.final_result_id});
 const handle=async(url,init)=>{
  const req={method:init.method,path:new URL(url).pathname,search:new URL(url).search,body:init.body?JSON.parse(init.body):null,auth:init.headers.Authorization};requests.push(req);
  assert.equal(new URL(url).origin,'https://synthetic-admin.invalid');assert.equal(req.auth,'Bearer synthetic-fixed-token'); // 旧adapter固定捕获token
  if(hook){const intercepted=await hook(req);if(intercepted)return intercepted;}
  if(req.path.endsWith('/capability'))return response({ownerId:7,available,destination:'cloud',consentVersion:m.CLOUD_CONSENT});
  if(req.path.endsWith('/profiles'))return response([profile]);
  if(req.method==='POST'&&req.path.endsWith('/cloud-workflows')) { const persisted=[...storage.values.values()].some(v=>v.includes(req.body.idempotencyKey));assert.equal(persisted,true); const normalized=await m.validatePayload(req.body);assert.equal(m.canonical(normalized),m.canonical(req.body));const x=await seed(normalized);return response(x.parent); }
  if(req.path.includes('/by-idempotency/')) { const x=keys.get(req.path.split('/').at(-1));return x?response(receipt(x)):response({},404); }
  if(req.path.endsWith('/stop')) { const x=tasks.get(req.path.split('/').at(-2));x.parent.state='cancelling';x.parent.revision++;return response({state:'cancelling'}); }
  const id=req.path.split('/').at(req.path.endsWith('/result')?-2:-1),x=tasks.get(id);
  if(x)return response(req.path.endsWith('/result')?[x.result]:{parent:x.parent,steps:x.steps});
  return response({items:[...tasks.values()].slice(0,4).map(x=>x.parent),nextCursor:null});
 };
 const send=(url,init)=>new Promise((resolve,reject)=>{const aborted=()=>reject(new DOMException('synthetic aborted','AbortError')); if(init.signal.aborted)return aborted();init.signal.addEventListener('abort',aborted,{once:true});handle(url,init).then(resolve,reject).finally(()=>init.signal.removeEventListener('abort',aborted));});
 const deps=()=>({session:{...session},current:()=>session,fetch:send,onCurrent401:()=>{logout++;session={...session,token:null,epoch:session.epoch+1};}});
 const make=(synthetic=enabled)=>{const api=synthetic?CloudApi.synthetic(deps()):new CloudApi(deps());return synthetic?CloudController.synthetic(api,storage,clock):new CloudController(api,storage,clock);};
 const c=make(); const clients=[c];t.after(()=>{clients.forEach(c=>c.close());audits.push({name:t.name,requests:requests.map(({auth,...safe})=>safe),storage:[...storage.values].filter(([k])=>k.startsWith('chatai-cloud')),timersAfterClose:clock.timers.size});});
 return {c,storage,clock,requests,tasks,keys,seed,receipt,setHook:f=>hook=f,setSession:fields=>session={...session,...fields},session:()=>session,logout:()=>logout,make:()=>{const n=make();clients.push(n);return n;}};
}
async function prepared(f){await f.c.initialize();f.c.edit(d=>{d.task='显式本人合成任务';d.inputs=[{title:'选择文本',text:'仅显式快照'}];for(const r of m.CLOUD_ROLES)d.profiles[r]=profile;});return f.c.prepare();}
const postCount=f=>f.requests.filter(r=>r.method==='POST'&&r.path.endsWith('/cloud-workflows')).length;
const stopPosts=f=>f.requests.filter(r=>r.method==='POST'&&r.path.endsWith('/stop'));

test('production controller and adapter stay disabled even mock capability true',async t=>{const f=fixture(t,{enabled:false}),p=await prepared(f);assert.equal(f.c.canCreate,false);assert.throws(()=>f.c.confirm(p),/暂未启用/);await assert.rejects(f.c.api.create(p.encoded),/暂未启用/);assert.equal(postCount(f),0);assert.equal(f.storage.values.size,0);});
test('guest/null token cannot construct authenticated adapter and sends0',()=>{let n=0;for(const token of [null,'guest-mode'])assert.throws(()=>new CloudApi({session:{origin:'https://s.invalid',frontendOrigin:'https://a.invalid',token,epoch:1},current:()=>({}),fetch:()=>{n++;}}));assert.equal(n,0);});
test('synthetic client cannot enable server unavailable',async t=>{const f=fixture(t,{available:false}),p=await prepared(f);assert.throws(()=>f.c.confirm(p),/暂未启用/);assert.equal(f.storage.values.size,0);assert.equal(postCount(f),0);});
test('profiles403 keeps reads available but no default model',async t=>{const f=fixture(t);f.setHook(async r=>r.path.endsWith('/profiles')?response({},403):null);await f.c.initialize();assert.equal(f.c.canCreate,false);assert.equal(f.c.getSnapshot().profiles.length,0);assert.equal(postCount(f),0);});
test('profiles secret/unknown field rejected',()=>assert.throws(()=>m.profile({...profile,apiKey:'NEVER_ACCEPT'}),m.CloudContractError));
test('strict DTO + byte/codepoint/4inputs/budget and forbidden fields',async t=>{const f=fixture(t),p=await prepared(f);for(const mutation of [v=>v.url='https://private.invalid',v=>v.source.cid=1,v=>v.inputs.push(...Array(4).fill(v.inputs[0])),v=>v.task='😀'.repeat(3001),v=>v.budget.attempts=9,v=>v.acceptance.outputName='with space.md',v=>v.source.revision=0]){const v=structuredClone(p.payload);mutation(v);await assert.rejects(m.validatePayload(v));}assert.equal(postCount(f),0);});
test('preparation snapshots full text + profiles, source draft/hash; no auto history/key/path',async t=>{const f=fixture(t),p=await prepared(f);assert.deepEqual(Object.keys(p.payload).sort(),['version','consentVersion','idempotencyKey','clientInstanceId','source','task','inputs','profiles','acceptance','budget','grantDurationMs'].sort());assert.deepEqual(Object.keys(p.payload.source).sort(),['kind','id','revision','contentHash'].sort());assert.equal(p.payload.source.kind,'draft');assert.equal(p.payload.source.contentHash,await m.hash(p.payload.task));assert.equal(p.encoded.includes('synthetic-fixed-token'),false);assert.equal(p.encoded.includes('history'),false);assert.equal(postCount(f),0);});
test('edit during hash invalidates preview before receipt/POST',async t=>{const f=fixture(t);await prepared(f);const pending=f.c.prepare();f.c.edit(d=>{d.task='later'});await assert.rejects(pending,/变化/);assert.equal(f.c.getSnapshot().preview,null);assert.equal(f.storage.values.size,0);});
test('receipt before one POST, double click shares intent; pure reads0extra',async t=>{const f=fixture(t),p=await prepared(f),held=deferred(),entered=deferred();f.setHook(async r=>{if(r.method==='POST'){entered.resolve();await held.promise;}return null;});const a=f.c.confirm(p),b=f.c.confirm(p);assert.equal(a,b);await entered.promise;assert.equal(postCount(f),1);assert.equal(f.c.getSnapshot().receipts[0].status,'submission_unknown');held.resolve();const r=await a;assert.equal(r.status,'accepted');assert.equal(f.c.getSnapshot().detail.state,'complete');await f.c.refresh();await f.c.loadNextPage();assert.equal(postCount(f),1);const persisted=[...f.storage.values.values()].join();for(const forbidden of ['synthetic-fixed-token','显式本人合成任务','仅显式快照'])assert.equal(persisted.includes(forbidden),false);});
test('same key changed digest/source rejected with0 extraPOST',async t=>{const f=fixture(t),p=await prepared(f);await f.c.confirm(p);assert.throws(()=>f.c.confirm({...p,digest:'1'.repeat(64)}));assert.throws(()=>f.c.confirm({...p,payload:{...p.payload,source:{...p.payload.source,revision:99}}}));assert.equal(postCount(f),1);});
test('storage failure prevents create POST',async t=>{const f=fixture(t),p=await prepared(f);f.storage.fail=true;await assert.rejects(f.c.confirm(p),/storage/);assert.equal(postCount(f),0);});
test('unknown ack + initial404; reconstruct query original key200, accepted cache; no resend',async t=>{const f=fixture(t),p=await prepared(f);let visible=false;f.setHook(async r=>{if(r.method==='POST'){await f.seed(r.body);return new Response('incomplete ack',{status:200});}if(r.path.includes('/by-idempotency/')&&!visible)return response({},404);return null;});const r=await f.c.confirm(p);assert.equal(r.status,'submission_unknown');f.c.close();const n=f.make();await n.initialize();assert.equal(n.getSnapshot().receipts[0].key,p.payload.idempotencyKey);visible=true;await n.resolveAndOpen(n.getSnapshot().receipts[0]);assert.equal(n.getSnapshot().receipts[0].status,'accepted');assert.equal(n.finalResult.content,'合成云成果');assert.equal(postCount(f),1);assert.ok(f.requests.filter(r=>r.path.includes('/by-idempotency/')).every(r=>r.path.endsWith(p.payload.idempotencyKey)));});
test('404 never permits auto or new-key resend of same unknown draft',async t=>{const f=fixture(t),p=await prepared(f);f.setHook(async r=>r.method==='POST'?response({},503):r.path.includes('/by-idempotency/')?response({},404):null);await f.c.confirm(p);await assert.rejects(f.c.prepare(),/未知/);await assert.rejects(f.c.resolve(f.c.getSnapshot().receipts[0]),e=>e.status===404);assert.equal(postCount(f),1);});
for(const change of ['accountAB','accountABA','sameToken','origin'])test(`held create late ack ${change} never binds or refreshes new scope`,async t=>{const f=fixture(t),p=await prepared(f),entered=deferred(),held=deferred();f.setHook(async r=>{if(r.method==='POST'){entered.resolve();return held.promise;}return null;});const pending=f.c.confirm(p);const rejected=assert.rejects(pending,CloudSessionStale);await entered.promise;if(change==='origin')f.setSession({origin:'https://another-backend.invalid'});else f.setSession({epoch:change==='accountABA'?3:2,token:change==='accountAB'?'synthetic-new-token':'synthetic-fixed-token'});held.resolve(response({}));await rejected;const raw=JSON.parse([...f.storage.values.values()][0]);assert.equal(raw.receipts[0].status,'submission_unknown');assert.equal(postCount(f),1);});
for(const responseStatus of [200,401])test(`old ${responseStatus} after epoch change has no logout/cache update`,async t=>{const f=fixture(t),entered=deferred(),held=deferred();f.setHook(async()=>{entered.resolve();return held.promise;});const pending=f.c.initialize();const rejected=assert.rejects(pending,CloudSessionStale);await entered.promise;f.setSession({epoch:3,token:'synthetic-new-token'});held.resolve(response({},responseStatus));await rejected;assert.equal(f.logout(),0);assert.equal(f.c.getSnapshot().capability,null);assert.equal(f.storage.values.size,0);});
test('current401 invalidates only captured session',async t=>{const f=fixture(t);f.setHook(async()=>response({},401));await assert.rejects(f.c.initialize());assert.equal(f.logout(),1);assert.equal(f.session().token,null);});
test('owner from capability not admin/cid; foreign task list rejects',async t=>{const f=fixture(t);f.setHook(async r=>r.path.endsWith('/cloud-workflows')?response({items:[{id:crypto.randomUUID(),owner_id:8,state:'running',revision:1}],nextCursor:null}):null);await assert.rejects(f.c.initialize());assert.equal(f.c.getSnapshot().tasks.length,0);});
test('strict actual list envelope, explicit small-page cursor; full inputs not retained in summary',async t=>{const f=fixture(t);const ids=Array.from({length:4},()=>crypto.randomUUID());f.setHook(async r=>r.path.endsWith('/cloud-workflows')?response(r.search.includes('cursor=')?{items:[],nextCursor:null}:{items:ids.map(id=>({id,owner_id:7,state:'paused',revision:1,payload:{private:'not in summary'}})),nextCursor:ids[3]}):null);await f.c.initialize();assert.equal(f.c.getSnapshot().tasks.length,4);assert.equal(f.c.getSnapshot().tasks[0].payload,undefined);assert.equal(f.requests.filter(r=>r.search.includes('cursor=')).length,0);await f.c.loadNextPage();assert.equal(f.requests.filter(r=>r.search.includes('cursor=')).length,1);assert.equal(f.c.getSnapshot().nextCursor,null);});
test('bare list and unknown state rejected; bounded response',async t=>{const f=fixture(t);f.setHook(async r=>r.path.endsWith('/cloud-workflows')?response([]):null);await assert.rejects(f.c.initialize());f.setHook(async()=>response({ownerId:7,available:true,destination:'cloud',consentVersion:m.CLOUD_CONSENT,padding:'x'.repeat(512*1024)}));await assert.rejects(f.c.api.capability());assert.throws(()=>m.state('totally_new_state'));});
test('6-8 historical results accepted, copy only exact final writer; bad hash rejects',async t=>{const f=fixture(t),p=await prepared(f);await f.c.confirm(p);const x=[...f.tasks.values()][0];const historic=Array.from({length:7},()=>({...x.result,id:crypto.randomUUID(),step_id:x.steps[2].id}));f.setHook(async r=>r.path.endsWith('/result')?response([...historic,x.result]):null);await f.c.refresh();let copied=null;await f.c.copyResult(async s=>{copied=s;});assert.equal(copied,x.result.content);assert.equal(postCount(f),1);f.setHook(async r=>r.path.endsWith('/result')?response([{...x.result,content_hash:'f'.repeat(64)}]):null);await assert.rejects(f.c.refresh());});
test('out of order detail revision cannot replace newer observed result',async t=>{const f=fixture(t),p=await prepared(f);await f.c.confirm(p);const x=[...f.tasks.values()][0],held=deferred(),entered=deferred();f.setHook(async r=>{if(r.path.endsWith(x.parent.id)){entered.resolve();return held.promise;}return null;});const old=f.c.refresh();await entered.promise;f.setHook(null);x.parent.revision=8;await f.c.open(x.parent.id);held.resolve(response({parent:{...x.parent,revision:3},steps:x.steps}));await old;assert.equal(f.c.getSnapshot().detail.revision,8);});
test('visible poll GET-only/singleflight; hidden/resume/close cleans timers',async t=>{const f=fixture(t),p=await prepared(f);const seeded=await f.seed(p.payload);seeded.parent.state='running';await f.c.open(seeded.parent.id);const n=f.requests.length;f.c.setVisible(false);await f.clock.advance(40000);assert.equal(f.requests.length,n);f.c.setVisible(true);await flush();assert.ok(f.requests.length>n);assert.equal(postCount(f),0);const entered=deferred(),held=deferred();f.setHook(async r=>{if(r.path.endsWith(seeded.parent.id)){entered.resolve();return held.promise;}return null;});const a=f.c.refresh(),b=f.c.refresh();assert.equal(a,b);await entered.promise;held.resolve(response({parent:seeded.parent,steps:seeded.steps}));await a;f.c.close();assert.equal(f.clock.timers.size,0);});
for(const change of ['epoch','origin'])test(`poll ${change} invalidation no uncaught error/newGET/continued timer`,async t=>{const f=fixture(t),p=await prepared(f),x=await f.seed(p.payload);x.parent.state='running';await f.c.open(x.parent.id);const n=f.requests.length;if(change==='epoch')f.setSession({epoch:2});else f.setSession({origin:'https://changed.invalid'});await f.clock.advance(20000);assert.equal(f.requests.length,n);assert.equal(f.clock.timers.size,0);});
test('stop unknown retries only explicit same op; no autoPOST/revision rewrite',async t=>{const f=fixture(t),p=await prepared(f),x=await f.seed(p.payload);x.parent.state='running';await f.c.open(x.parent.id);f.setHook(async r=>r.path.endsWith('/stop')?Promise.reject(new Error('lost stop ack')):null);await f.c.stop();const first=stopPosts(f)[0].body;await f.c.refresh();assert.equal(stopPosts(f).length,1);f.setHook(null);await f.c.stop();assert.deepEqual(stopPosts(f)[1].body,first);assert.equal(f.c.getSnapshot().detail.state,'cancelling');});
test('stop409 refresh requires new explicit intent/revision; no hidden rePOST',async t=>{const f=fixture(t),p=await prepared(f),x=await f.seed(p.payload);x.parent.state='running';await f.c.open(x.parent.id);f.setHook(async r=>{if(r.path.endsWith('/stop')){x.parent.revision++;return response({},409);}return null;});await f.c.stop();assert.equal(f.c.getSnapshot().stopNeedsNewIntent,true);const old=stopPosts(f)[0].body;await assert.rejects(f.c.stop(),/新状态/);assert.equal(stopPosts(f).length,1);f.setHook(null);await f.c.stop(true);assert.notEqual(stopPosts(f)[1].body.operationId,old.operationId);assert.equal(stopPosts(f)[1].body.expectedRevision,5);});
for(const status of [200,409])test(`stop A late${status} settles persisted A but doesn't pollute B`,async t=>{const f=fixture(t),p=await prepared(f),a=await f.seed(p.payload),b=await f.seed({...p.payload,idempotencyKey:crypto.randomUUID()});a.parent.state='running';b.parent.state='running';await f.c.open(a.parent.id);const held=deferred(),entered=deferred();f.setHook(async r=>{if(r.path.endsWith('/stop')){entered.resolve();return held.promise;}return null;});const stopping=f.c.stop();await entered.promise;await f.c.open(b.parent.id);const before=f.requests.filter(r=>r.path.includes(b.parent.id)).length;held.resolve(response({state:'cancelling'},status));await stopping;assert.equal(f.c.getSnapshot().detail.id,b.parent.id);assert.equal(f.c.getSnapshot().notice,null);assert.equal(f.requests.filter(r=>r.path.includes(b.parent.id)).length,before);const store=new CloudReceipts(f.storage,f.session().origin,7);assert.equal(store.stop(a.parent.id).status,status===409?'conflict':'acknowledged');});
test('unmount aborts local held observation, never remotely stop cloud task',async t=>{const f=fixture(t),entered=deferred(),held=deferred();f.setHook(async()=>{entered.resolve();return held.promise;});const pending=f.c.initialize(),rejected=assert.rejects(pending,CloudSessionStale);await entered.promise;f.c.close();await rejected;held.resolve(response({}));assert.equal(stopPosts(f).length,0);});
test('real authStore same token/setAuth/logout/hydrate epochs change, runtime epoch not persisted',async()=>{const storage=new Memory();global.sessionStorage=storage;const {useAuthStore}=require(path.join(root,'store/authStore.js'));const a={id:1,userName:'synthetic'};useAuthStore.getState().setAuth('synthetic-A',a);const first=useAuthStore.getState().sessionEpoch;useAuthStore.getState().setAuth('synthetic-A',a);assert.ok(useAuthStore.getState().sessionEpoch>first);const second=useAuthStore.getState().sessionEpoch;await useAuthStore.persist.rehydrate();assert.ok(useAuthStore.getState().sessionEpoch>second);assert.equal(JSON.parse(storage.getItem('admin-auth')).state.sessionEpoch,undefined);const third=useAuthStore.getState().sessionEpoch;useAuthStore.getState().logout();assert.ok(useAuthStore.getState().sessionEpoch>third);assert.equal(useAuthStore.getState().token,null);delete global.sessionStorage;});
test('actual React view uses tested controller, confirmation disabled in production and escapes text',async t=>{const f=fixture(t,{enabled:false}),p=await prepared(f);const React=require('react'),{renderToStaticMarkup}=require('react-dom/server');const {CloudTasksView}=require(path.join(root,'app/(dashboard)/cloud-tasks/CloudTasksView.js'));const html=renderToStaticMarkup(React.createElement(CloudTasksView,{controller:f.c}));assert.ok(html.includes('data-testid="cloud-confirm"'));assert.match(html,/data-testid="cloud-confirm"[^>]*disabled/);assert.equal(html.includes('saveMessages'),false);assert.equal(postCount(f),0);f.c.cancelPreview();f.c.edit(d=>{d.task='<script>globalThis.BAD_SENTINEL=1</script>';});await f.c.prepare();const escaped=renderToStaticMarkup(React.createElement(CloudTasksView,{controller:f.c}));assert.ok(escaped.includes('&lt;script&gt;'));assert.equal(escaped.includes('<script>globalThis'),false);assert.ok(p.payload.source.kind==='draft');});
test.after(()=>{fs.writeFileSync('/tmp/chatai-cloud-C2-admin-notice-node-payload.json',JSON.stringify({classification:'actual production adapter/controller with injected fetch + memory sessionStorage; no real cloud/model/PG HTTP',cases:audits},null,2));});

test('default native fetch keeps global receiver (no injected transport)',async()=>{
 const original=global.fetch;let calls=0;
 const s={origin:'https://synthetic-native.invalid',frontendOrigin:'https://synthetic-admin.invalid',token:'only-synthetic-native-token',epoch:1};let api;
 try{
  global.fetch=async function(){if(this!==globalThis)throw new Error('synthetic native receiver mismatch');calls++;return response({ownerId:7,available:false,destination:'cloud',consentVersion:m.CLOUD_CONSENT});};
  api=new CloudApi({session:s,current:()=>s});assert.equal((await api.capability()).ownerId,7);assert.equal(calls,1);
 }finally{api?.close();global.fetch=original;}
});

test('acknowledged stop then GET409 keeps acknowledged intent (read error is not mutation conflict)',async t=>{
 const f=fixture(t),p=await prepared(f),x=await f.seed(p.payload);x.parent.state='running';await f.c.open(x.parent.id);
 let acknowledged=false;f.setHook(async r=>{if(r.path.endsWith('/stop')){acknowledged=true;return response({state:'cancelling'});}if(acknowledged&&r.path.endsWith(x.parent.id))return response({},409);return null;});
 await f.c.stop();const store=new CloudReceipts(f.storage,f.session().origin,7);assert.equal(store.stop(x.parent.id).status,'acknowledged');assert.equal(f.c.getSnapshot().stopNeedsNewIntent,false);assert.match(f.c.getSnapshot().notice,/已确认/);assert.equal(stopPosts(f).length,1);
});

for(const count of [100,101,200])test(`review catalog valid ${count} profiles initializes actual adapter/controller`,async t=>{
 const f=fixture(t);const profiles=Array.from({length:count},(_,i)=>({...profile,modelRowId:i+2,modelId:`synthetic-${i}`,modelName:`合成模型${i}`}));
 f.setHook(async r=>r.path.endsWith('/profiles')?response(profiles):null);await f.c.initialize();assert.equal(f.c.getSnapshot().profiles.length,count);assert.equal(postCount(f),0);assert.equal(f.storage.values.size,0);
});
test('review catalog retains array201/object101/depth13 rejection, permits object100',()=>{
 const obj=n=>Object.fromEntries(Array.from({length:n},(_,i)=>[`field${i}`,i]));assert.doesNotThrow(()=>m.bounded(obj(100)));assert.throws(()=>m.bounded(obj(101)),m.CloudContractError);assert.throws(()=>m.bounded(Array(201).fill(0)),m.CloudContractError);
 let deep=0;for(let i=0;i<14;i++)deep={child:deep};assert.throws(()=>m.bounded(deep),m.CloudContractError);
});
test('review terms keeps editing raw text and normalizes only frozen preview payload',async t=>{
 const f=fixture(t);await prepared(f);f.c.cancelPreview();const raw='  第一项  \n\n  第二项  \n';f.c.edit(d=>{d.requiredTermsText=raw;});
 assert.equal(f.c.getSnapshot().draft.requiredTermsText,raw);const p=await f.c.prepare();assert.deepEqual(p.payload.acceptance.requiredTerms,['第一项','第二项']);assert.equal(f.c.getSnapshot().draft.requiredTermsText,raw);assert.equal(p.encoded.includes('requiredTermsText'),false);assert.equal(postCount(f),0);
 f.c.cancelPreview();f.c.edit(d=>{d.requiredTermsText='重复\n重复';});await assert.rejects(f.c.prepare(),m.CloudContractError);
});

// 调用真实View按钮的onClick；仅替代render hooks，不复制页面的异常处理逻辑。
function noticeButton(c, label) {
 const React=require('react'), originalStore=React.useSyncExternalStore,originalEffect=React.useEffect;
 let tree;
 try {
  React.useSyncExternalStore=(_subscribe,snapshot)=>snapshot();React.useEffect=()=>{};
  const {CloudTasksView}=require(path.join(root,'app/(dashboard)/cloud-tasks/CloudTasksView.js'));
  tree=CloudTasksView({controller:c});
 } finally {React.useSyncExternalStore=originalStore;React.useEffect=originalEffect;}
 const text=v=>Array.isArray(v)?v.map(text).join(''):v&&typeof v==='object'?text(v.props?.children):String(v??'');
 const walk=v=>{if(Array.isArray(v)){for(const x of v){const found=walk(x);if(found)return found;}}else if(v&&typeof v==='object'){if(v.type==='button'&&text(v.props.children)===label)return v.props.onClick;return walk(v.props?.children);}return null;};
 const handler=walk(tree);assert.equal(typeof handler,'function',`actual View button ${label}`);return handler;
}
async function noticeFixture(t) {
 const f=fixture(t),p=await prepared(f),a=await f.seed(p.payload),b=await f.seed({...p.payload,idempotencyKey:crypto.randomUUID()});
 await f.c.initialize();return{f,a,b};
}
for(const action of ['open','refresh'])test(`notice review ${action} A late failure cannot pollute opened B`,async t=>{
 const {f,a,b}=await noticeFixture(t);if(action==='refresh')await f.c.open(a.parent.id);
 const entered=deferred(),held=deferred();f.setHook(async r=>{if(r.path.endsWith(a.parent.id)){entered.resolve();return held.promise;}return null;});
 const original=f.c[action].bind(f.c);let reading;f.c[action]=(...args)=>{reading=original(...args);return reading;};
 noticeButton(f.c,action==='open'?`已完成 · 任务 ${a.parent.id}`:'刷新状态')();
 await entered.promise;const settlement=Promise.allSettled([reading]);await f.c.open(b.parent.id);
 const before=f.requests.filter(r=>r.path.includes(b.parent.id)).length;held.resolve(response({},503));await settlement;await flush();
 assert.equal(f.c.getSnapshot().detail.id,b.parent.id);assert.equal(f.c.getSnapshot().notice,null);
 assert.equal(f.requests.filter(r=>r.path.includes(b.parent.id)).length,before);assert.equal(postCount(f),0);assert.equal(stopPosts(f).length,0);
});
for(const action of ['open','refresh'])test(`notice review ${action} current B failure remains visible`,async t=>{
 const {f,b}=await noticeFixture(t);if(action==='refresh')await f.c.open(b.parent.id);
 const original=f.c[action].bind(f.c);let reading;f.c[action]=(...args)=>{reading=original(...args);return reading;};
 f.setHook(async r=>r.path.endsWith(b.parent.id)?response({},503):null);
 noticeButton(f.c,action==='open'?`已完成 · 任务 ${b.parent.id}`:'刷新状态')();
 await Promise.allSettled([reading]);await flush();assert.match(f.c.getSnapshot().notice,/HTTP 503/);
 assert.equal(postCount(f),0);assert.equal(stopPosts(f).length,0);
});
test('notice review old refresh A after A to B to A cannot pollute new generation',async t=>{
 const {f,a,b}=await noticeFixture(t);await f.c.open(a.parent.id);
 const entered=deferred(),held=deferred();f.setHook(async r=>{if(r.path.endsWith(a.parent.id)){entered.resolve();return held.promise;}return null;});
 const original=f.c.refresh.bind(f.c);let reading;f.c.refresh=()=>{reading=original();return reading;};noticeButton(f.c,'刷新状态')();await entered.promise;
 const settlement=Promise.allSettled([reading]);await f.c.open(b.parent.id);f.setHook(null);await f.c.open(a.parent.id);
 held.resolve(response({},503));await settlement;await flush();assert.equal(f.c.getSnapshot().detail.id,a.parent.id);assert.equal(f.c.getSnapshot().notice,null);assert.equal(postCount(f),0);
});
