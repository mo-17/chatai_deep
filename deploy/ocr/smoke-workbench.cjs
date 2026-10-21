// 真实 HTTPS、JWT 与数据库授权。只使用临时账号和合成材料；不输出凭据/原文。
const {createRequire}=require('node:module');
const {resolve}=require('node:path');
const {readFileSync}=require('node:fs');
const {randomBytes}=require('node:crypto');
const appRequire=createRequire(resolve('package.json'));
const {Client}=appRequire('pg'), jwt=appRequire('jsonwebtoken');
const origin=process.env.OCR_SMOKE_ORIGIN||'https://kushui.shop';
const fixtures=process.env.OCR_SMOKE_FIXTURES;
if(!fixtures||!process.env.JWT_SECRET) throw new Error('Smoke environment required');
const db=new Client({host:process.env.DB_HOST,port:Number(process.env.DB_PORT||5432),user:process.env.DB_USER,password:process.env.DB_PASSWORD,database:process.env.DB_NAME});
const users=[],jobs=[];
let originalSettings;
const evidence={origin,startedAt:new Date().toISOString(),checks:[]};
async function request(token,method,path,body,json=false) {
  const response=await fetch(origin+'/uapi/'+path,{method,redirect:'error',signal:AbortSignal.timeout(30000),
    headers:{Authorization:'Bearer '+token,...(body?{'Content-Type':json?'application/json':'application/octet-stream'}:{})},...(body?{body:json?JSON.stringify(body):body}:{})});
  const value=await response.json();
  return {status:response.status,data:value.data,cache:response.headers.get('cache-control')};
}
function check(value,label) { if(!value) throw new Error(label); }
async function create(token,kind,filename,extra='') {
  const id=randomBytes(16).toString('hex');jobs.push([token,id]);
  const response=await request(token,'POST',`ocr/jobs/${id}?kind=${kind}&preview=true${extra}`,readFileSync(resolve(fixtures,filename)));
  check([200,201].includes(response.status),'create_'+response.status);return id;
}
async function complete(token,id) {
  for(let n=0;n<100;n++) {
    const response=await request(token,'GET','ocr/jobs/'+id);check(response.status===200,'poll');
    if(response.data.state==='completed') return response.data.result;
    check(!['failed','cancelled'].includes(response.data.state),'job_'+response.data.state);
    await new Promise(resolve=>setTimeout(resolve,1500));
  }
  throw new Error('timeout');
}
async function main() {
  await db.connect();
  try {
    for(const role of ['admin','user','user']) {
      const userName='ocr-workbench-smoke-'+randomBytes(10).toString('hex');
      const row=(await db.query('INSERT INTO users ("userName",role,banned,"tokenVersion") VALUES ($1,$2,false,0) RETURNING id',[userName,role])).rows[0];
      users.push({id:row.id,token:jwt.sign({userId:row.id,userName,role,tokenVersion:0},process.env.JWT_SECRET,{expiresIn:'10m',algorithm:'HS256'})});
    }
    const [admin,user,other]=users;
    check((await request(user.token,'GET','admin/ocr/overview')).status===403,'admin_guard');
    const overview=await request(admin.token,'GET','admin/ocr/overview');
    check(overview.status===200&&overview.cache==='no-store','admin_overview');
    originalSettings=overview.data.settings;
    check(Number.isFinite(overview.data.workerRssBytes),'worker_memory');
    check(!JSON.stringify(overview.data).includes('token'),'overview_privacy');
    evidence.checks.push('real admin role guard, no-store overview and worker RSS');
    const settings={...originalSettings,ownerOverrides:{...originalSettings.ownerOverrides,['user:'+other.id]:0}};
    check((await request(admin.token,'PATCH','admin/ocr/settings',settings,true)).status===200,'settings_save');
    const denied=randomBytes(16).toString('hex');jobs.push([other.token,denied]);
    check((await request(other.token,'POST',`ocr/jobs/${denied}?kind=image`,readFileSync(resolve(fixtures,'preview.png')))).status===429,'owner_quota');
    check((await request(admin.token,'GET','admin/ocr/overview')).data.settings.ownerOverrides['user:'+other.id]===0,'quota_readback');
    evidence.checks.push('per-owner quota blocks only the configured temporary account');
    const imageId=await create(user.token,'image','preview.png');
    check((await request(other.token,'GET','ocr/jobs/'+imageId)).status===404,'owner_isolation');
    const image=await complete(user.token,imageId);
    check(image.pages[0].text.includes('2026'),'real_image_text');
    const preview=Buffer.from(image.pages[0].preview,'base64');
    check(preview.length<=24*1024&&preview[0]===255&&preview[1]===216,'image_preview');
    check(image.pages[0].lines.some(line=>line.box.length===4&&line.confidence>=0&&line.confidence<=1),'geometry_confidence');
    evidence.previewBytes=preview.length;
    await request(user.token,'DELETE','ocr/jobs/'+imageId);
    evidence.checks.push('real HTTPS OCR image, bounded JPEG preview, geometry and confidence');
    const pdfId=await create(user.token,'pdf','preview.pdf','&pages=2');
    const pdf=await complete(user.token,pdfId);
    check(pdf.totalPages===2&&pdf.pages.length===1&&pdf.pages[0].page===2&&pdf.pages[0].text.includes('PAGE 2'),'selected_page');
    check(Buffer.from(pdf.pages[0].preview,'base64').length<=24*1024,'pdf_preview');
    await request(user.token,'DELETE','ocr/jobs/'+pdfId);
    evidence.checks.push('selected page 2 keeps original PDF number and preview');
    const after=(await request(admin.token,'GET','admin/ocr/overview')).data;
    check(after.counts.completed>=overview.data.counts.completed+2&&after.completedPages>=overview.data.completedPages+2,'metrics_count');
    check(after.running===0&&after.queueDepth===0,'queue_settled');
    evidence.checks.push('completion/page metrics survive client result DELETE and queue settles');
    evidence.workerRssBytes=after.workerRssBytes;evidence.averageSeconds=after.averageSeconds;
    check((await fetch(origin+'/ocr',{signal:AbortSignal.timeout(10000)})).ok,'admin_page');
    evidence.checks.push('deployed admin OCR route responds over HTTPS');
    console.log(JSON.stringify(evidence));
  } finally {
    for(const [token,id] of jobs) {try {await request(token,'DELETE','ocr/jobs/'+id);}catch{}}
    if(originalSettings&&users[0]) await request(users[0].token,'PATCH','admin/ocr/settings',originalSettings,true);
    for(const user of users) await db.query('DELETE FROM users WHERE id=$1',[user.id]);
    await db.end();
  }
}
main().catch(error=>{console.error('OCR workbench smoke failed: '+error.message);process.exitCode=1;});
