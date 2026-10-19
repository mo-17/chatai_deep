const test = require('node:test');
const assert = require('node:assert/strict');
const load = require('./support/native_plugin_loader.cjs');
const tick = () => new Promise(resolve => setImmediate(resolve));
function pdfFixture(options = {}) {
  const released = [], handles = new Set(), renders = [];
  const native = load('KnowledgePdfPlugin', {
    '@kit.AbilityKit': {},
    '@kit.CoreFileKit': {fileIo: {OpenMode:{READ_ONLY:1,NOFOLLOW:2},
      async lstat(path) {return {isSymbolicLink:()=>options.symlink && path.endsWith('link')};},
      async open() {const file={fd:1}; handles.add(file); return file;},
      async stat() {return {isFile:()=>!options.directory,size:options.size??100};},
      async close(file) {handles.delete(file);},
    }},
    '@kit.PDFKit': {pdfService:{ParseResult:{PARSE_SUCCESS:0},PdfMatrix:class{},PdfDocument:class {
      loadDocument() {return options.parseFailure ? 1 : 0;}
      getPageCount() {return 3;}
      getPage(index) {return {getWidth:()=>options.width??1000,getHeight:()=>2000,
        getAreaPixelMap(matrix,width,height) {renders.push({index,width,height});return {async release(){released.push('pixels');}};},
        release(){released.push('page');}};}
      releaseDocument(){released.push('document');}
    }}},
    '@kit.ImageKit': {image:{createImagePacker(){return {
      async packing() {if(options.packing) await options.packing; if(options.failPacking)throw new Error('packing'); return new Uint8Array(options.outputBytes??8).buffer;},
      async release(){released.push('packer');if(options.releaseFailure)throw new Error('release');},
    };}}},
  }, {filesDir:'/files',cacheDir:'/cache',tempDir:'/temp'});
  return {...native,released,handles,renders,render:(args={})=>native.call('render',{path:'/files/original.pdf',page:1,...args})};
}
test('PDF previews only the cited page within a bounded raster and releases every resource',async()=>{
  const f=pdfFixture();const bytes=await f.render();
  assert.equal(bytes.length,8);assert.deepEqual(f.renders,[{index:1,width:1536,height:3072}]);
  assert.deepEqual(f.released,['packer','pixels','page','document']);assert.equal(f.handles.size,0);
});
test('PDF rejects traversal, links, large files and invalid page numbers',async()=>{
  for(const path of ['/outside/a.pdf','/cache/../a.pdf','/cache//a.pdf','/cache/link/a.pdf']) {
    const f=pdfFixture({symlink:true});await assert.rejects(f.render({path}),{code:'pdf_render_error'});assert.equal(f.handles.size,0);
  }
  for(const options of [{size:0},{size:67108865},{directory:true},{width:Infinity},{width:20001},{parseFailure:true}]) {
    const f=pdfFixture(options);await assert.rejects(f.render(),{code:'pdf_render_error'});assert.equal(f.handles.size,0);
  }
  for(const page of [-1,0.5,3,1000]) await assert.rejects(pdfFixture().render({page}),{code:'pdf_render_error'});
});
test('PDF packing failures, output bounds and release failures never leak resources or return partial images',async()=>{
  for(const options of [{failPacking:true},{outputBytes:0},{outputBytes:33554433},{releaseFailure:true}]) {
    const f=pdfFixture(options);await assert.rejects(f.render(),{code:'pdf_render_error'});
    assert.equal(f.handles.size,0);assert.deepEqual(f.released,['packer','pixels','page','document']);
  }
});
test('PDF rejects concurrent calls and discards background/engine-stale raster results',async()=>{
  for(const detach of [false,true]) {
    let resume;const f=pdfFixture({packing:new Promise(resolve=>{resume=resolve;})});
    const pending=f.render();await tick();await assert.rejects(f.render(),{code:'pdf_busy'});
    if(detach){f.plugin.onDetachedFromEngine({});f.plugin.onAttachedToEngine({getBinaryMessenger(){}});}else f.plugin.suspend();
    resume();await assert.rejects(pending,{code:'pdf_render_error'});assert.equal(f.handles.size,0);
    assert.equal((await f.render()).length,8);
  }
});
function packageFixture(options={}) {
  return load('PackageInfoPlugin',{'@kit.AbilityKit':{
    bundleManager:{BundleFlag:{GET_BUNDLE_INFO_WITH_APPLICATION:1},async getBundleInfoForSelf(flag){
      assert.equal(flag,1);if(options.pending)await options.pending;if(options.fail)throw new Error('private-detail');
      return {name:'com.hzb.flutter_ai',versionName:options.version??'1.0.0',versionCode:options.code??1000000,appInfo:{labelId:42}};
    }},
  }},{resourceManager:{async getStringValue(id){assert.equal(id,42);if(options.missingLabel)throw new Error();return '艾普';}}});
}
test('package_info standard channel returns installed bundle identity and localized label without signing data',async()=>{
  const f=packageFixture();const info=await f.call('getAll');
  assert.deepEqual([...info], [['appName','艾普'],['packageName','com.hzb.flutter_ai'],['version','1.0.0'],['buildNumber','1000000'],['buildSignature','']]);
  assert.equal((await packageFixture({missingLabel:true}).call('getAll')).get('appName'),'com.hzb.flutter_ai');
});
test('package metadata errors and stale engine reads fail without fabricated versions or raw details',async()=>{
  for(const options of [{fail:true},{version:''},{code:-1}]) await assert.rejects(packageFixture(options).call('getAll'),{code:'package_info_error'});
  let resume;const f=packageFixture({pending:new Promise(resolve=>{resume=resolve;})}),pending=f.call('getAll');
  f.plugin.onDetachedFromEngine({});f.plugin.onAttachedToEngine({getBinaryMessenger(){}});resume();
  await assert.rejects(pending,{code:'package_info_error'});
});
