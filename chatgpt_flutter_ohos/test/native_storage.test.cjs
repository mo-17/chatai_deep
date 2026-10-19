const test = require('node:test');
const assert = require('node:assert/strict');
const load = require('./support/native_plugin_loader.cjs');
const DAY = 86400000, LIMIT = 512 * 1024 * 1024;
function fixture({beforeDelete} = {}) {
  const nodes = new Map(), handles = new Map(); let handleId=0, selects=0;
  const dir=p=>nodes.set(p,{kind:'dir',mtime:1});
  const file=(p,data='data',size)=>nodes.set(p,{kind:'file',data:Buffer.from(data),size,mtime:1});
  const stat=p=>{const n=nodes.get(p);if(!n)throw Error('missing');return{size:n.size??n.data?.length??0,mtime:n.mtime,isFile:()=>n.kind==='file',isDirectory:()=>n.kind==='dir',isSymbolicLink:()=>n.kind==='link'};};
  const io={OpenMode:{READ_ONLY:1,READ_WRITE:2,CREATE:4,TRUNC:8,NOFOLLOW:16},
    accessSync:p=>nodes.has(p),mkdirSync:dir,lstatSync:stat,readTextSync:p=>nodes.get(p).data.toString(),
    listFileSync:p=>[...nodes.keys()].filter(k=>k.startsWith(p+'/')&&!k.substring(p.length+1).includes('/')).map(k=>k.substring(p.length+1)),
    unlinkSync:p=>nodes.delete(p),
    async rmdir(p){if(beforeDelete)await beforeDelete;for(const key of [...nodes.keys()])if(key===p||key.startsWith(p+'/'))nodes.delete(key);},
    async open(p,mode){if(mode&4)file(p,'');const h={fd:++handleId,path:p,name:'note.txt',position:0};handles.set(h.fd,h);return h;},
    async close(h){handles.delete(h.fd);},async stat(fd){return stat(handles.get(fd).path);},
    async read(fd,buffer){const h=handles.get(fd),data=nodes.get(h.path).data,n=Math.min(2,data.length-h.position);new Uint8Array(buffer).set(data.subarray(h.position,h.position+n));h.position+=n;return n;},
    async write(fd,buffer){const node=nodes.get(handles.get(fd).path);node.data=Buffer.concat([node.data,Buffer.from(buffer)]);return buffer.byteLength;},
  };
  const deps={'@kit.CoreFileKit':{fileIo:io,picker:{DocumentSelectOptions:class{},DocumentViewPicker:class{async select(){selects++;return['content://source'];}}}},
    '@kit.ArkTS':{util:{}},'@kit.MediaLibraryKit':{},'@kit.CameraKit':{},'@kit.ImageKit':{}};
  const context={cacheDir:'/cache',filesDir:'/files'},options={modules:new Map()};
  const f=load('../files/FilePickerPlugin',deps,context,options);
  const Store=[...f.modules].find(([name])=>name.endsWith('/storage/PickerStorage.ets'))[1].exports.default;
  dir('/cache/chatai_file_picker');dir('/files/chatai_picked_images');
  const batch=(age=2*DAY,size=5)=>{const name=`${Date.now()-age}_${nodes.size}`,p='/cache/chatai_file_picker/'+name;dir(p);file(p+'/note.txt','hello',size);return p;};
  const image=(age=8*DAY)=>{const p=`/files/chatai_picked_images/image_${Date.now()-age}_${nodes.size}.jpg`;file(p);return p;};
  const clean=async(refs=[],manual=false)=>{const s=await f.call('storageInventory',{images:true});return f.call('cleanupStorage',{token:s.token,referenced:refs,manual});};
  return{...f,nodes,file,dir,batch,image,clean,Store,handles,get selects(){return selects;},
    imagePlugin:()=>load('ImagePickerPlugin',deps,context,options)};
}
test('完整核对后回收无引用文件和七天图片，保留引用、近期和未知条目',async()=>{
  const f=fixture(),unused=f.batch(),used=f.batch(),old=f.image(),kept=f.image(),fresh=f.image(DAY);
  f.dir('/cache/chatai_file_picker/unknown');f.file('/cache/chatai_file_picker/unknown/keep.txt');
  f.file('/documents/source.txt');
  const result=await f.clean([used.split('/').pop(),kept.split('/').pop()]);
  assert.equal(result.removed,2);assert.equal(result.bytes,9);
  for(const p of [used,kept,fresh,'/documents/source.txt','/cache/chatai_file_picker/unknown/keep.txt'])assert.ok(f.nodes.has(p));
  assert.equal(f.nodes.has(unused),false);assert.equal(f.nodes.has(old),false);
});
test('自动过期和手动整理区分近期文件，运行期租约与全部恢复作用域均保护',async()=>{
  const f=fixture(),fresh=f.batch(3600000),held=f.batch(),recovered=f.image(),scope='b'.repeat(64);
  const owner=f.Store.owner();f.Store.hold(owner,held);
  f.dir('/files/chatai_picker_recovery');f.file(`/files/chatai_picker_recovery/${scope}.json`,JSON.stringify({scope,id:'pending',created:Date.now(),phase:'ready',images:[recovered],files:[]}));
  assert.equal((await f.clean()).removed,0);
  assert.equal((await f.clean([],true)).removed,1);assert.equal(f.nodes.has(fresh),false);
  assert.ok(f.nodes.has(held));assert.ok(f.nodes.has(recovered));
});
test('损坏、未知或链接恢复记录在删除前拒绝，所有候选保持完整',async()=>{
  for(const bad of ['{broken',JSON.stringify({images:[]})]){
    const f=fixture(),p=f.batch();f.dir('/files/chatai_picker_recovery');f.file(`/files/chatai_picker_recovery/${'c'.repeat(64)}.json`,bad);
    await assert.rejects(f.clean(),{code:'file_picker_error'});assert.ok(f.nodes.has(p));
  }
  const f=fixture(),p=f.batch();f.nodes.set(p+'/link',{kind:'link'});
  await assert.rejects(f.call('storageInventory',{images:true}),{code:'file_picker_error'});assert.ok(f.nodes.has(p));
});
test('快照过期、文件变化和跨选择代次都拒绝删除，token 不能重放',async()=>{
  const f=fixture(),p=f.batch();let s=await f.call('storageInventory',{images:true});
  f.nodes.get(p+'/note.txt').mtime++;
  await assert.rejects(f.call('cleanupStorage',{token:s.token,referenced:[]}),{code:'file_picker_error'});assert.ok(f.nodes.has(p));
  s=await f.call('storageInventory',{images:true});const owner=f.Store.owner();f.Store.begin(owner);f.Store.end(owner);
  await assert.rejects(f.call('cleanupStorage',{token:s.token,referenced:[]}),{code:'file_picker_error'});
  s=await f.call('storageInventory',{images:true});await f.call('cleanupStorage',{token:s.token,referenced:[]});
  await assert.rejects(f.call('cleanupStorage',{token:s.token,referenced:[]}),{code:'file_picker_error'});
});
test('累计配额在选择前及复制中独立生效，超限只清理新批次',async()=>{
  const full=fixture(),p=full.batch(DAY,LIMIT);full.file('content://source','hello');
  await assert.rejects(full.call('pickFiles'),{code:'file_cache_full'});assert.equal(full.selects,0);assert.ok(full.nodes.has(p));
  const growing=fixture(),keep=growing.batch(DAY,LIMIT-2);growing.file('content://source','hello');
  await assert.rejects(growing.call('pickFiles'),{code:'file_cache_full'});assert.ok(growing.nodes.has(keep));
  assert.equal([...growing.nodes.keys()].filter(p=>p.startsWith('/cache/chatai_file_picker/')).length,2);assert.equal(growing.handles.size,0);
});
test('成功交回的文件获得租约，旧通用清理不能绕过引用扫描',async()=>{
  const f=fixture();f.file('content://source','hello');const picked=await f.call('pickFiles');
  assert.equal((await f.clean([],true)).removed,0);assert.ok(f.nodes.has(picked[0].path));
  assert.equal(await f.call('clearTemporaryFiles'),false);assert.ok(f.nodes.has(picked[0].path));
});
test('原生删除期间另一选择器及恢复通道均拒绝并发',async()=>{
  let resume;const gate=new Promise(r=>{resume=r;}),f=fixture({beforeDelete:gate});f.batch();
  const image=f.imagePlugin(),s=await f.call('storageInventory',{images:true});
  const pending=f.call('cleanupStorage',{token:s.token,referenced:[]});
  await assert.rejects(image.call('pickImage',{source:'gallery'}),{code:'picker_busy'});
  await assert.rejects(image.call('retrieveLostData',{scope:'a'.repeat(64)}),{code:'picker_busy'});
  resume();assert.equal((await pending).removed,1);
});
