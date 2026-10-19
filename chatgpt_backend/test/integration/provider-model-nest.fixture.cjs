// 自有nonce PG/两环回Nest origins/合成upstream；不加载生产AppModule或默认DS。
const fs=require('node:fs'),path=require('node:path'),Module=require('node:module'),http=require('node:http'),assert=require('node:assert/strict');
const ts=require('typescript');require('reflect-metadata');
const root=process.cwd(),resolve=Module._resolveFilename;
Module._resolveFilename=function(id,parent,options){if(id==='@auth-kit')id=path.join(root,'libs/auth-kit/src/index.ts');else if(id.startsWith('@auth-kit/'))id=path.join(root,'libs/auth-kit/src',id.slice(10));return resolve.call(this,id,parent,options);};
require.extensions['.ts']=(m,f)=>m._compile(ts.transpileModule(fs.readFileSync(f,'utf8'),{fileName:f,compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS,experimentalDecorators:true,emitDecoratorMetadata:true,esModuleInterop:true}}).outputText,f);
const {Test}=require('@nestjs/testing'),{ValidationPipe}=require('@nestjs/common'),{getRepositoryToken}=require('@nestjs/typeorm'),{DataSource}=require('typeorm'),jwt=require('jsonwebtoken');
const src=f=>require(path.join(root,'src',f));
const {User}=src('user/user.entity.ts'),{Conversation}=src('chat/conversation.entity.ts'),{Message}=src('chat/message.entity.ts'),{Usage}=src('chat/usage.entity.ts'),{AiProvider}=src('ai/ai-provider.entity.ts'),{AiModel}=src('ai/ai-model.entity.ts'),{AiGlobalConfig}=src('ai/ai-global-config.entity.ts');
const {ChatService}=src('chat/chat.service.ts'),{ChatController}=src('chat/chat.controller.ts'),{PublicAiController}=src('ai/public-ai.controller.ts'),{ModelSelectionController}=src('ai/model-selection.controller.ts'),{TokenAuthenticationService}=src('auth/token-authentication.service.ts'),{JwtGuard}=src('auth/jwt.guard.ts'),{AdminGuard}=src('auth/admin.guard.ts'),{ProviderCacheService}=src('ai/provider-cache.service.ts'),{AllExceptionsFilter}=src('common/all-exceptions.filter.ts');
const {AdminAiProviderService}=src('ai/admin-ai-provider.service.ts'),{AdminAiModelService}=src('ai/admin-ai-model.service.ts'),{AdminAiGlobalService}=src('ai/admin-ai-global.service.ts'),{AdminUsageService}=src('admin/admin-usage.service.ts');
const {AdminAiProviderController}=src('ai/admin-ai-provider.controller.ts'),{AdminAiModelController}=src('ai/admin-ai-model.controller.ts'),{AdminAiGlobalController}=src('ai/admin-ai-global.controller.ts'),{AdminUsageController}=src('admin/admin-usage.controller.ts');
const owned=process.env.FINAL_OWNED,nonce=process.env.FINAL_NONCE;
assert(owned?.startsWith('/tmp/chatai-final-owned-')&&JSON.parse(fs.readFileSync(path.join(owned,'fixture-sentinel.json'))).nonce===nonce);
assert(process.env.JWT_SECRET?.startsWith('synthetic-final-'));
assert(process.env.FINAL_PG_SOCKET===path.join(owned,'socket')&&process.env.FINAL_PG_DATA===path.join(owned,'data'));
assert(process.env.FINAL_PG_USER==='final_'+nonce&&process.env.FINAL_PG_DATABASE==='final_'+nonce&&Number(process.env.FINAL_PG_PORT)===55697);
let app,ds,upstream,originB,closing=false,phase='setup',probeGate,upstreamGate;
let mode='normal',dropSave=false,observations=[],backendRequests=[],resources=[];
const sockets=new Set();function track(server){server.on('connection',s=>{sockets.add(s);s.on('close',()=>sockets.delete(s));});}
const gate=()=>{let resolve;return {promise:new Promise(r=>resolve=r),resolve:()=>resolve()};};
const closeServer=s=>new Promise(r=>s?s.close(()=>r()):r());
async function snapshot(){return {phase,mode,backendRequests,upstreamRequests:observations,counts:{backendCompletion:backendRequests.filter(r=>r.path.includes('/completions')).length,probes:backendRequests.filter(r=>r.path.includes('/model-selection')).length,upstream:observations.length},messages:await ds.getRepository(Message).find({order:{id:'ASC'}}),conversations:await ds.getRepository(Conversation).find({order:{id:'ASC'}}),usage:await ds.getRepository(Usage).find({order:{id:'ASC'}})};}
async function reset(){phase='setup';mode='normal';dropSave=false;probeGate?.resolve();upstreamGate?.resolve();probeGate=upstreamGate=undefined;observations=[];backendRequests=[];await ds.getRepository(AiProvider).createQueryBuilder().update().set({enabled:true}).execute();await ds.getRepository(AiModel).createQueryBuilder().update().set({enabled:true}).execute();await ds.getRepository(AiGlobalConfig).update({id:1},{catalogPublic:true,defaultProviderCode:'alpha',defaultModelId:'shared'});}
async function control(body){
 if(body.op==='reset')await reset();
 if(body.phase)phase=body.phase;
 if(body.mode)mode=body.mode;
 if(body.holdProbe)probeGate=gate();if(body.releaseProbe){probeGate?.resolve();probeGate=undefined;}
 if(body.holdUpstream)upstreamGate=gate();if(body.releaseUpstream){upstreamGate?.resolve();upstreamGate=undefined;}
 if(body.disableProvider)await ds.getRepository(AiProvider).update({code:body.disableProvider},{enabled:false});
 if(body.invalidDefault)await ds.getRepository(AiGlobalConfig).update({id:1},{defaultProviderCode:'missing',defaultModelId:'missing'});
 if(body.catalogClosed)await ds.getRepository(AiGlobalConfig).update({id:1},{catalogPublic:false});
 if(body.dropSave)dropSave=true;
 return snapshot();
}
async function cleanup(){if(closing)return;closing=true;probeGate?.resolve();upstreamGate?.resolve();for(const s of sockets)s.destroy();if(originB)await closeServer(originB);if(app)await app.close();if(upstream)await closeServer(upstream);if(ds?.isInitialized)await ds.destroy();fs.writeFileSync(path.join(owned,'nest-cleanup.json'),JSON.stringify({closed:true,pgDisconnected:!ds?.isInitialized,resources,sockets:0}));}
async function main(){
 ds=new DataSource({type:'postgres',host:process.env.FINAL_PG_SOCKET,port:Number(process.env.FINAL_PG_PORT),username:process.env.FINAL_PG_USER,database:process.env.FINAL_PG_DATABASE,entities:[User,Conversation,Message,Usage,AiProvider,AiModel,AiGlobalConfig],synchronize:false,logging:false,extra:{max:4}});await ds.initialize();
 const [identity]=await ds.query('SELECT current_database() db,current_user role,current_setting(\'data_directory\') data,current_setting(\'listen_addresses\') listen');assert(identity.db===process.env.FINAL_PG_DATABASE&&identity.role===process.env.FINAL_PG_USER&&identity.data===process.env.FINAL_PG_DATA&&identity.listen==='');await ds.synchronize();
 upstream=http.createServer(async(req,res)=>{const chunks=[];for await(const c of req)chunks.push(c);const body=JSON.parse(Buffer.concat(chunks)||'{}');const provider=req.url.includes('/alpha/')?'alpha':'beta';observations.push({phase,provider,model:body.model,stream:body.stream===true,fields:Object.keys(body),messageCount:body.messages?.length});assert(!Object.hasOwn(body,'providerCode'));if(upstreamGate)await upstreamGate.promise;
  if(mode==='http-error'){res.writeHead(400,{'content-type':'application/json'});res.end(JSON.stringify({error:{code:'unsupported_parameter',message:'synthetic-secret-provider-response'}}));return;}
  if(body.stream){res.writeHead(200,{'content-type':'text/event-stream'});res.write('data: '+JSON.stringify({choices:[{index:0,delta:{content:provider+':answer'}}]})+'\n\n');if(mode==='sse-error')res.write('data: '+JSON.stringify({error:{code:'invalid_api_key',message:'synthetic-secret-provider-response'}})+'\n\n');res.end('data: [DONE]\n\n');}
  else {res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({choices:[{message:{content:provider+':answer'}}],model:body.model,usage:{prompt_tokens:1,completion_tokens:2,total_tokens:3}}));}
 });track(upstream);await new Promise(r=>upstream.listen(0,'127.0.0.1',r));const upPort=upstream.address().port;resources.push({kind:'upstream',port:upPort});
 await ds.query('INSERT INTO users (id,"userName",role,banned,"tokenVersion") VALUES ($1,$2,$3,false,0),($4,$5,$3,false,0)',[7,'synthetic-admin-A','admin',8,'synthetic-admin-B']);
 const seededUsers=await ds.getRepository(User).find({select:['id','role','tokenVersion'],order:{id:'ASC'}});assert.deepEqual(seededUsers.map(r=>r.id),[7,8]);
 for(const [id,code]of[[1,'alpha'],[2,'beta']]){await ds.getRepository(AiProvider).save({id,code,displayName:'Synthetic '+code,enabled:true,apiKey:'synthetic-upstream-key',baseUrl:`http://127.0.0.1:${upPort}/${code}/v1`,sortOrder:0});await ds.getRepository(AiModel).save({providerId:id,modelId:'shared',displayName:'Shared '+code,enabled:true,isDefault:true,supportsTool:code==='beta',supportsVision:false,supportsPdf:false,supportsReasoning:false,sortOrder:0});}
 await ds.getRepository(AiModel).save({providerId:2,modelId:'unique-beta',displayName:'Unique beta',enabled:true,isDefault:false});await ds.getRepository(AiGlobalConfig).save({id:1,defaultProviderCode:'alpha',defaultModelId:'shared',catalogPublic:true});
 await ds.getRepository(Usage).save({userId:7,provider:'deleted-provider',model:'historical',promptTokens:1,completionTokens:1,totalTokens:2});
 const services=[ChatService,ProviderCacheService,TokenAuthenticationService,JwtGuard,AdminGuard,AdminAiProviderService,AdminAiModelService,AdminAiGlobalService,AdminUsageService];
 const module=await Test.createTestingModule({controllers:[ChatController,PublicAiController,ModelSelectionController,AdminAiProviderController,AdminAiModelController,AdminAiGlobalController,AdminUsageController],providers:[...services,{provide:DataSource,useValue:ds},...[User,Conversation,Message,Usage,AiProvider,AiModel,AiGlobalConfig].map(entity=>({provide:getRepositoryToken(entity),useValue:ds.getRepository(entity)}))]}).compile();
 app=module.createNestApplication({logger:false});app.useGlobalPipes(new ValidationPipe({transform:true,whitelist:true}));app.useGlobalFilters(new AllExceptionsFilter());
 app.use(async(req,res,next)=>{if(req.url.startsWith('/__fixture/')){if(req.headers['x-fixture-nonce']!==nonce){res.status(403).end();return;}let raw='';if(!req.body)for await(const c of req)raw+=c;try{const result=req.method==='GET'?await snapshot():await control(req.body||JSON.parse(raw||'{}'));res.json(result);}catch(e){res.status(500).json({failure:'fixture-control-failed'});}return;}
  const observed={phase,method:req.method,path:req.url.split('?')[0],originPort:req.socket.localPort};backendRequests.push(observed);res.on('finish',()=>{observed.status=res.statusCode;});if(req.url.startsWith('/uapi/ai/model-selection')&&probeGate)await probeGate.promise;
  if(req.method==='POST'&&/\/conversations\/\d+\/messages/.test(req.url)&&dropSave){dropSave=false;res.json=()=>{res.destroy();return res;};}next();
 });
 await app.listen(0,'127.0.0.1');track(app.getHttpServer());const port=app.getHttpServer().address().port;originB=http.createServer(app.getHttpAdapter().getInstance());track(originB);await new Promise(r=>originB.listen(0,'127.0.0.1',r));resources.push({kind:'NestA',port},{kind:'NestB',port:originB.address().port});
 const metadata={nonce,origin:`http://127.0.0.1:${port}`,originB:`http://127.0.0.1:${originB.address().port}`,upstreamPort:upPort,seededUsers,tokenA:jwt.sign({userId:7,tokenVersion:0},process.env.JWT_SECRET,{expiresIn:1200}),tokenB:jwt.sign({userId:8,tokenVersion:0},process.env.JWT_SECRET,{expiresIn:1200}),identity};fs.writeFileSync(path.join(owned,'nest-ready.json'),JSON.stringify(metadata),{mode:0o600});console.log('OWNED_NEST_READY',JSON.stringify({ports:resources,identity}));
}
process.on('SIGTERM',()=>void cleanup().then(()=>process.exit(0)));process.on('SIGINT',()=>void cleanup().then(()=>process.exit(0)));main().catch(e=>{console.error('FIXTURE_BOOT_FAILED',e.name,e.message);void cleanup().then(()=>process.exit(1));});
