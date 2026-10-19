const test=require('node:test');
const assert=require('node:assert/strict');
const load=require('./support/native_plugin_loader.cjs');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function fixture({input=3,output=3,mediaOutput=output,activation}={}) {
  const listeners=new Map(),changes=[];let active=false,selected={deviceType:0},lost=0;
  const audio={DeviceType:{INVALID:0,WIRED_HEADSET:3,USB_HEADSET:22,BLUETOOTH_SCO:7},
    DeviceUsage:{CALL_INPUT_DEVICES:8},SourceType:{SOURCE_TYPE_VOICE_RECOGNITION:1},
    AudioSessionScene:{AUDIO_SESSION_SCENE_VOICE_COMMUNICATION:2,AUDIO_SESSION_SCENE_MEDIA:0},AudioConcurrencyMode:{CONCURRENCY_MIX_WITH_OTHERS:1},
    AudioSessionStateChangeHint:{AUDIO_SESSION_STATE_CHANGE_HINT_PAUSE:1,AUDIO_SESSION_STATE_CHANGE_HINT_STOP:2,AUDIO_SESSION_STATE_CHANGE_HINT_TIME_OUT_STOP:3},
    StreamUsage:{STREAM_USAGE_MUSIC:1,STREAM_USAGE_VOICE_COMMUNICATION:2}};
  const session={on:(k,fn)=>listeners.set(k,fn),off:k=>listeners.delete(k),
    setAudioSessionScene:scene=>changes.push(['scene',scene]),
    async activateAudioSession(strategy){changes.push(['activate',strategy.concurrencyMode]);if(activation)await activation;active=true;},
    async deactivateAudioSession(){active=false;changes.push(['deactivate']);},isAudioSessionActivated:()=>active,
    getAvailableDevices:()=>[{deviceType:input}],getSelectedMediaInputDevice:()=>selected,
    async selectMediaInputDevice(d){selected=d;changes.push(['input',d.deviceType]);},
    async clearSelectedMediaInputDevice(){selected={deviceType:0};changes.push(['clear']);}};
  const routing={async getPreferredInputDeviceForCapturerInfo(){return [{deviceType:input}];},
    async getPreferOutputDeviceForRendererInfo(info){return [{deviceType:info.usage===1?mediaOutput:output}];}};
  audio.getAudioManager=()=>({getRoutingManager:()=>routing,getSessionManager:()=>session});
  const f=load('../speech/VoiceAudioPlugin',{'@kit.AudioKit':{audio}});
  f.plugin.onLost=()=>lost++;
  return {...f,listeners,changes,session,get active(){return active;},get lost(){return lost;}};
}
test('有线/USB/SCO 确认三条首选路由后开放双工，释放恢复输入与焦点',async()=>{
  for(const type of [3,22,7]) {
    const f=fixture({input:type,output:type});
    assert.equal((await f.call('prepareHeadset')).safeDuplex,true);
    assert.equal(await f.call('headsetConnected'),true);
    assert.ok(f.changes.some(x=>x[0]==='activate'&&x[1]===1));
    await f.call('release');assert.equal(f.active,false);assert.equal(f.plugin.active,false);
    assert.ok(f.changes.some(x=>x[0]==='clear'));
  }
});
test('A2DP、无麦耳机、扬声器或内置麦均不能冒充安全双工',async()=>{
  for(const options of [{input:15},{output:2},{output:8},{input:4},{mediaOutput:8}]) {
    const f=fixture(options);assert.equal((await f.call('prepareHeadset')).safeDuplex,false);
    assert.equal(f.active,false);assert.equal(await f.call('headsetConnected'),false);
  }
});
test('拔出耳机或系统抢占立即停止语音并让轮询暂停会话',async()=>{
  for(const event of ['currentOutputDeviceChanged','currentInputDeviceChanged','audioSessionDeactivated','audioSessionStateChanged']) {
    const f=fixture();await f.call('prepareHeadset');
    f.listeners.get(event)({devices:[{deviceType:2}],stateChangeHint:1});
    assert.equal(f.lost,1);assert.equal(f.plugin.active,false);
    assert.equal(await f.call('headsetConnected'),false);await tick();assert.equal(f.active,false);
  }
});
test('准备期间取消不能迟到打开双工，重复释放不抢占其他会话',async()=>{
  let resume;const f=fixture({activation:new Promise(resolve=>resume=resolve)});
  const prepare=f.call('prepareHeadset');await tick();
  await f.call('release');resume();assert.equal((await prepare).safeDuplex,false);
  assert.equal(f.active,false);await f.call('release');assert.equal(f.active,false);
});

function playback({create,release}={}) {
  const events=new Map(),handles=new Set();let released=0,played=0;
  const player={on:(k,fn)=>events.set(k,fn),async release(){released++;if(release)await release();},async prepare(){},async play(){played++;}};
  const f=load('../speech/TtsPlaybackPlugin',{
    '@kit.MediaKit':{media:{async createAVPlayer(){if(create)await create;return player;}}},
    '@kit.AudioKit':{audio:{StreamUsage:{STREAM_USAGE_VOICE_COMMUNICATION:2,STREAM_USAGE_MUSIC:1},InterruptMode:{SHARE_MODE:0},InterruptHint:{INTERRUPT_HINT_PAUSE:2,INTERRUPT_HINT_STOP:3}}},
    '@kit.CoreFileKit':{fileIo:{OpenMode:{READ_ONLY:1,NOFOLLOW:2},openSync(){const file={fd:8};handles.add(file);return file;},statSync(){return {isFile:()=>true,size:100};},closeSync(file){handles.delete(file);}}},
    './VoiceAudioPlugin':{},
  },{cacheDir:'/cache'});
  f.plugin.route={active:true};
  return {...f,events,handles,player,get released(){return released;},get played(){return played;}};
}
const playArgs={id:'123_1',path:'/cache/tts_audio_cache/baker/a.wav'};
test('AVPlayer 等待实际播放完成，使用通信流并关闭文件资源',async()=>{
  const f=playback();let done=false;
  const pending=f.call('play',playArgs).then(()=>done=true);await tick();
  f.events.get('stateChange')('initialized');assert.equal(f.player.audioRendererInfo.usage,2);
  f.events.get('stateChange')('prepared');await tick();assert.equal(f.played,1);assert.equal(done,false);
  f.events.get('stateChange')('completed');await pending;
  assert.equal(f.released,1);assert.equal(f.handles.size,0);assert.equal(f.timers.size,0);
});
test('播放器错误/系统中断/超时结算失败，旧 stop 不能打断当前播放',async()=>{
  for(const mode of ['error','interrupt','timeout']) {
    const f=playback(),p=f.call('play',playArgs),reject=assert.rejects(p,{code:'playback_error'});await tick();
    await f.call('stop',{id:'old_1'});assert.equal(f.released,0);
    if(mode==='error')f.events.get('error')({});
    if(mode==='interrupt')f.events.get('audioInterrupt')({hintType:3});
    if(mode==='timeout')[...f.timers.values()][0].fn();
    await reject;assert.equal(f.released,1);assert.equal(f.handles.size,0);
  }
});
test('AVPlayer 尚未创建时停止也能撤销迟到播放，拒绝沙箱外路径',async()=>{
  let resume;const f=playback({create:new Promise(resolve=>resume=resolve)});
  const p=f.call('play',playArgs),rejected=assert.rejects(p,{code:'playback_error'});await tick();
  await f.call('stop',{id:playArgs.id});resume();await rejected;assert.equal(f.played,0);assert.equal(f.handles.size,0);
  for(const path of ['/other.wav','/cache/tts_audio_cache/../secret.wav']) {
    await assert.rejects(playback().call('play',{...playArgs,path}),{code:'playback_error'});
  }
});
test('停止等待真实释放完成，释放失败后拒绝新播放',async()=>{
  let resume;const f=playback({release:()=>new Promise(resolve=>resume=resolve)});
  const p=f.call('play',playArgs);await tick();
  let stopped=false;const stop=f.call('stop',{id:playArgs.id}).then(()=>stopped=true);await tick();
  assert.equal(stopped,false);resume();await stop;await p;assert.equal(f.handles.size,0);
  const g=playback({release:async()=>{throw new Error('release failed');}});
  const pending=g.call('play',playArgs),failed=assert.rejects(pending,{code:'playback_error'});await tick();
  await assert.rejects(g.call('stop',{id:playArgs.id}),{code:'playback_release_error'});await failed;
  await assert.rejects(g.call('play',{...playArgs,id:'124_2'}),{code:'playback_error'});
  assert.equal(g.played,0);
});
