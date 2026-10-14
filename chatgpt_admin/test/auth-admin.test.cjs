const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const root = process.env.AUTH_ADMIN_COMPILED;
if (!root?.startsWith('/tmp/')) throw Error('isolated compiled source required');
const values = new Map(); global.sessionStorage = { getItem:k=>values.get(k)||null, setItem:(k,v)=>values.set(k,v), removeItem:k=>values.delete(k) };
global.window = { location: { origin: 'https://synthetic-admin.invalid' } };
const { useAuthStore } = require(path.join(root, 'store/authStore.js'));
const { api } = require(path.join(root, 'lib/api/client.js'));
const a = require(path.join(root, 'lib/api/auth-admin.js'));
const { AxiosError } = require('axios');
const requests = []; let hook;
const policy = { id:1, huaweiGetAuthCodeEnabled:true,huaweiQuickLoginEnabled:false,huaweiPrimaryFlow:'getAuthCode',appleSignInEnabled:true,smsMockHighlight:false,codeTtlSeconds:300,codeMaxAttempts:5,codeDailyLimitPerIdentifier:10,codeResendIntervalSeconds:60,codeHourlyLimitPerIp:30 };
const response = (config,data,status=200) => ({config,data:{code:0,data},status,statusText:'synthetic',headers:{}});
api.defaults.adapter = async config => { requests.push({ method:config.method, url:config.url, body:config.data?JSON.parse(config.data):null }); return hook ? hook(config) : response(config,config.data?JSON.parse(config.data):[]); };
const deferred = () => { let resolve; const promise=new Promise(r=>resolve=r);return {resolve,promise}; };
const flush = async () => { for(let i=0;i<5;i++) await new Promise(r=>setImmediate(r)); };
test.beforeEach(() => { requests.length=0;hook=null;window.location.origin='https://synthetic-admin.invalid';useAuthStore.getState().setAuth('synthetic-original-token',{id:7,userName:'synthetic'}); });
test('contract settings PUT uses actual whitelist fields only', async () => {
 await a.updateAuthSettings(policy);assert.equal(requests[0].method,'put');assert.equal(requests[0].url,'/admin/auth/settings');
 assert.deepEqual(Object.keys(requests[0].body).sort(),Object.keys(policy).filter(k=>k!=='id').sort());assert.equal(requests[0].body.codeResendIntervalSeconds,60);
});
test('contract templates PUT routes by key with subject/body', async () => {
 await a.updateTemplate('code-login',{subject:'标题 {{code}}',body:'<p>{{code}}</p>'});assert.equal(requests[0].method,'put');assert.equal(requests[0].url,'/admin/auth/templates/code-login');assert.deepEqual(requests[0].body,{subject:'标题 {{code}}',body:'<p>{{code}}</p>'});
});
test('contract old 401 cannot log out later account or same-token new epoch', async () => {
 const held=deferred();hook=config=>held.promise.then(()=>{throw new AxiosError('synthetic401','ERR_BAD_REQUEST',config,null,{...response(config,{},401),data:{message:'synthetic'}});});
 const pending=a.fetchProviders();await flush();useAuthStore.getState().setAuth('synthetic-original-token',{id:8,userName:'later'});held.resolve();await assert.rejects(pending);assert.equal(useAuthStore.getState().admin.id,8);assert.equal(useAuthStore.getState().token,'synthetic-original-token');
});
test('stale successful read is rejected after account change', async () => {
 const held=deferred();hook=config=>held.promise.then(()=>response(config,[{key:'generic'}]));const pending=a.fetchProviders();await flush();useAuthStore.getState().setAuth('later-token',{id:9,userName:'later'});held.resolve();await assert.rejects(pending,/会话已变化/);
});
test('current 401 logs out current epoch only', async () => {
 hook=async config=>{throw new AxiosError('401','ERR_BAD_REQUEST',config,null,response(config,{},401));};await assert.rejects(a.fetchProviders());assert.equal(useAuthStore.getState().token,null);
});
test('blank secrets preserve; explicit clear and password/OAuth mode payloads never spread projections', () => {
 const p={displayName:'SMTP',authMode:'microsoft_oauth',host:'ignored',port:587,secure:false,username:'ignored',fromName:'',fromAddress:'fixed@synthetic.invalid',microsoftClientId:'01234567-1234-4123-8123-123456789abc',microsoftClientSecretEncrypted:'synthetic-hidden',passwordEncrypted:'synthetic-hidden',enabled:true};
 const draft=a.providerDraft(p),body=a.providerPayload(draft);assert.equal('microsoftClientSecret' in body,false);assert.equal('password' in body,false);assert.equal('enabled' in body,false);assert.equal('microsoftClientSecretEncrypted' in body,false);
 assert.equal(a.providerPayload({...draft,clearMicrosoftClientSecret:true}).clearMicrosoftClientSecret,true);
 assert.equal(a.providerPayload({...draft,authMode:'password',clearPassword:true}).clearPassword,true);
});
function oauthFixture() {
 const {MicrosoftAuthorization}=require(path.join(root,'lib/microsoft-auth/controller.js'));const sessions=require(path.join(root,'lib/api/auth-session.js'));
 const popup={source:{},closed:0,navigations:[],close(){this.closed++},navigate(url){this.navigations.push(url)}};
 let flow='received',complete='connected',expired=false;
 const now=Date.now();const url=new URL('https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize');
 url.search=new URLSearchParams({client_id:'01234567-1234-4123-8123-123456789abc',response_type:'code',response_mode:'form_post',redirect_uri:window.location.origin+'/api/auth/microsoft/callback',scope:'https://outlook.office.com/SMTP.Send offline_access openid profile email',state:'a'.repeat(43),nonce:'b'.repeat(43),code_challenge:'c'.repeat(43),code_challenge_method:'S256'}).toString();
 hook=async config=>{if(config.url.endsWith('/start'))return response(config,{flowId:'01234567-1234-4123-8123-123456789abc',authorizeUrl:url.href,expiresAt:now+240000});if(config.url.includes('/flow/'))return response(config,{status:flow});if(config.url.includes('/complete/')){if(complete==='throw')throw Error('synthetic lost response');return response(config,{status:complete});}return response(config,{status:'not_connected',configured:true,emailHint:null});};
 const c=new MicrosoftAuthorization({session:sessions.captureAuthSession,current:sessions.isAuthSessionCurrent,popup:()=>popup,start:a.microsoftStart,flow:a.microsoftFlow,complete:a.microsoftComplete,status:a.microsoftStatus,disconnect:a.microsoftDisconnect,now:()=>expired?now+300000:Date.now()});
 return {c,popup,url,setFlow:s=>flow=s,setComplete:s=>complete=s,expire:()=>expired=true};
}
const completes=()=>requests.filter(r=>r.url.includes('/complete/')).length;
test('actual OAuth adapter/controller unknown exchange cannot repeat; only status query', async () => {
 const f=oauthFixture();await f.c.start();assert.equal(f.popup.navigations.length,1);await f.c.refresh();f.setComplete('throw');await f.c.complete();assert.equal(f.c.getSnapshot().flow,'unknown');f.setFlow('unknown');await f.c.refresh();await f.c.complete();assert.equal(completes(),1);assert.equal(requests.filter(r=>r.url.endsWith('/test')).length,0);f.c.close();
});
test('cancel/replay result signals never exchange; original popup and origin required', async () => {
 const f=oauthFixture();await f.c.start();const count=requests.length;f.c.returned({origin:'https://attacker.invalid',source:f.popup.source,data:'ms-smtp-returned'});f.c.returned({origin:window.location.origin,source:{},data:'ms-smtp-returned'});await flush();assert.equal(requests.length,count);
 f.setFlow('cancelled');f.c.returned({origin:window.location.origin,source:f.popup.source,data:'ms-smtp-returned'});await flush();await f.c.complete();assert.equal(f.c.getSnapshot().flow,'cancelled');assert.equal(completes(),0);f.c.close();
});
test('session epoch change or origin change or expiry prevents old flow exchange and stale disconnect', async () => {
 for(const change of ['epoch','origin','expiry']) { const f=oauthFixture();await f.c.start();await f.c.refresh();if(change==='epoch')useAuthStore.getState().setAuth('synthetic-original-token',{id:7,userName:'same'});if(change==='origin')window.location.origin='https://other.invalid';if(change==='expiry')f.expire();await f.c.complete();assert.equal(completes(),0);f.c.close();window.location.origin='https://synthetic-admin.invalid';requests.length=0; }
 const sessions=require(path.join(root,'lib/api/auth-session.js')),s=sessions.captureAuthSession();useAuthStore.getState().logout();await assert.rejects(a.microsoftDisconnect(s));assert.equal(requests.length,0);
});
test('fixed authorize URL rejects foreign host, callback origin, implicit flow, wider permissions', () => {
 const {validateAuthorize}=require(path.join(root,'lib/microsoft-auth/controller.js'));const f=oauthFixture();
 for(const mutate of [u=>u.hostname='attacker.invalid',u=>u.searchParams.set('redirect_uri','https://attacker.invalid/callback'),u=>u.searchParams.set('response_type','token'),u=>u.searchParams.set('scope','openid User.Read')]) { const u=new URL(f.url);mutate(u);assert.throws(()=>validateAuthorize({flowId:'01234567-1234-4123-8123-123456789abc',expiresAt:Date.now()+1000,authorizeUrl:u.href},window.location.origin,Date.now())); } f.c.close();
});
test('actual React OAuth view unknown disables complete; handlers read status without POST replay', async () => {
 const f=oauthFixture();await f.c.start();await f.c.refresh();f.setComplete('throw');await f.c.complete();
 const React=require('react'),old=React.useSyncExternalStore;let tree;try{React.useSyncExternalStore=(_s,g)=>g();tree=require(path.join(root,'components/auth/MicrosoftAuthorization.js')).MicrosoftAuthorizationView({controller:f.c});}finally{React.useSyncExternalStore=old;}
 const text=x=>Array.isArray(x)?x.map(text).join(''):x&&typeof x==='object'?text(x.props?.children):String(x??'');const buttons=[];const walk=x=>{if(Array.isArray(x))x.forEach(walk);else if(x&&typeof x==='object'){if(x.type==='button')buttons.push(x);walk(x.props?.children);}};walk(tree);
 const complete=buttons.find(b=>text(b.props.children)==='完成授权');assert.equal(complete.props.disabled,true);buttons.find(b=>text(b.props.children)==='刷新授权状态').props.onClick();await flush();assert.equal(completes(),1);
 const {renderToStaticMarkup}=require('react-dom/server');const html=renderToStaticMarkup(React.createElement(require(path.join(root,'components/auth/MicrosoftAuthorization.js')).MicrosoftAuthorizationView,{controller:f.c}));assert.match(html,/兑换结果未知/);assert.equal(html.includes('synthetic-original-token'),false);f.c.close();
});
test('preview only permits inert attribute-free format tags plus sandbox CSP', () => {
 const {templatePreview,validTemplate}=require(path.join(root,'lib/mail-template-preview.js'));
 const html=templatePreview('<meta http-equiv="refresh" content="0;url=https://external.invalid"><a href="https://external.invalid">go</a><img src="https://external.invalid"><script>parent.synthetic=1</script><p onclick="synthetic()">{{code}} {{purposeLabel}} {{ttlMinutes}}</p>','<svg onload=x>');
 assert.equal(html.includes('<script>'),false);assert.equal(html.includes('<img'),false);assert.equal(html.includes('<meta http-equiv="refresh"'),false);assert.equal(html.includes('href='),false);assert.equal(html.includes('onclick='),false);assert.match(html,/default-src/);assert.match(html,/123456 &lt;svg onload=x&gt; 5/);assert.equal(validTemplate('x\r\ny','ok'),false);assert.equal(validTemplate('ok','{{secret}}'),false);
});

test('code status keeps locked/expired terminal reasons ahead of legacy consumedAt marker', () => {
 const {codeState}=require(path.join(root,'app/(dashboard)/auth/codes/page.js'));
 const r={deliveryStatus:'sent',consumedAt:'2026-10-12',invalidatedAt:'2026-10-12',expiresAt:'2099-01-01'};
 assert.equal(codeState({...r,invalidationReason:'locked'}),'已锁定');assert.equal(codeState({...r,invalidationReason:'expired'}),'已过期');assert.equal(codeState({...r,invalidationReason:'consumed'}),'已核销');assert.equal(codeState({...r,invalidationReason:'superseded'}),'已被新码替代');
});
test('controller start and disconnect retain original session even before component cleanup', async () => {
 const f=oauthFixture();await f.c.start();requests.length=0;useAuthStore.getState().setAuth('later-token',{id:9,userName:'later'});
 await f.c.start();await f.c.disconnect();await f.c.refresh();assert.equal(requests.length,0);f.c.close();
});
