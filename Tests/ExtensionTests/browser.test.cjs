const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
function environment() {
  const listeners = {};
  const event = name => ({addListener(fn) { listeners[name] = fn; }});
  const c = vm.createContext({console,crypto:crypto.webcrypto,setTimeout,clearTimeout,setInterval,clearInterval,URL,
    chrome: {runtime:{onMessage:event('message')}, downloads:{onCreated:event('created'),onChanged:event('changed')},
      tabs:{onRemoved:event('removed'),sendMessage:async()=>{}},webNavigation:{onCommitted:event('navigation')}}});
  vm.runInContext(fs.readFileSync('Extension/browser-transfer.js','utf8'),c); return {c,listeners};
}
test('exact URL proof excludes unrelated, duplicate, stale and asynchronous downloads',()=>{
  const {c}=environment(); const pick=(intents,items)=>c.exactDownload(intents,items);
  assert.equal(pick(['blob:chosen'],[{id:4,url:'blob:other'}]),null);
  assert.equal(pick([], [{id:4,url:'blob:chosen'}]),null);
  assert.equal(pick(['blob:chosen'],[{id:4,url:'blob:chosen'},{id:5,url:'blob:chosen'}]),null);
  assert.equal(pick(['blob:chosen'],[{id:4,url:'blob:chosen'},{id:5,url:'blob:other'}]).id,4);
});
test('selected synchronous Save captures only its action and restores hooks',()=>{
  const {c}=environment();
  class Anchor {constructor(href) {this.href=href;} click() {}}
  class Frame {get src(){return this._src;} set src(v){this._src=v;}}
  const original=Anchor.prototype.click; let selected={src:'blob:player'};
  const save={disabled:false,closest:()=>null,click(){new Anchor('blob:selected-file').click();}};
  Object.assign(c,{HTMLAnchorElement:Anchor,HTMLIFrameElement:Frame,window:{open(){}},document:{querySelector:s=>s.includes('selected')?selected:save},location:{href:'https://web.telegram.org/k/'}});
  const result=c.triggerBrowserSave('test','blob:player'); assert.deepEqual(Array.from(result.intents),['blob:selected-file']);
  assert.equal(Anchor.prototype.click,original);
  selected.src='blob:new'; assert.equal(c.triggerBrowserSave('test','blob:player').error,'source_changed');
});
test('asynchronous Save supplies no automatic proof',async()=>{
  const {c}=environment(); class Anchor {constructor(href){this.href=href;} click(){}}
  class Frame {get src(){return this._src;} set src(v){this._src=v;}}
  const save={closest:()=>null,click(){setTimeout(()=>new Anchor('blob:later').click(),0);}};
  Object.assign(c,{HTMLAnchorElement:Anchor,HTMLIFrameElement:Frame,window:{open(){}},document:{querySelector:s=>s.includes('selected')?{src:'blob:player'}:save},location:{href:'https://web.telegram.org/k/'}});
  assert.deepEqual(Array.from(c.triggerBrowserSave('test','blob:player').intents),[]);
  await new Promise(r=>setTimeout(r,5));
});
test('native host errors propagate; success=false is never acceptance',async()=>{
  const {c}=environment(); let receive;
  c.chrome.runtime.connectNative=()=>({onMessage:{addListener(f){receive=f;}},onDisconnect:{addListener(){}},postMessage(payload){receive({requestId:payload.requestId,success:false,message:'App refused',extra:{code:'protocol_mismatch'}});}});
  await assert.rejects(c.browserNative({action:'hello'}),/App refused/);
});
test('missing taskId/token and incompatible app version reject the widget request',async()=>{
  for(const mode of ['missing','old']) {
    const {c}=environment(); let receive;
    c.chrome.scripting={executeScript:async()=>[{result:true}]};
    c.chrome.runtime.connectNative=()=>({onMessage:{addListener(f){receive=f;}},onDisconnect:{addListener(){}},postMessage(payload){
      const extra=payload.action==='hello'?{appVersion:mode==='old'?'1.0.0':'1.1.0',protocolVersion:'2'}:{};
      receive({requestId:payload.requestId,success:true,extra});
    }});
    await assert.rejects(c.startBrowserJob({selection:{handle:crypto.randomUUID(),mediaKind:'video'}},{tab:{id:7},frameId:0}), mode==='old'?/cùng phiên bản/:/taskId\/token/);
  }
});
test('HTTP toast waits for actual app acceptance with taskId',()=>{
  const source=fs.readFileSync('Extension/background.js','utf8');
  for(const response of [{success:false,message:'Rejected'},{success:true},{success:true,taskId:'id'}]) {
    let notifications=0,reply;
    const c=vm.createContext({HOST_NAME:'host',navigator:{userAgent:'test'},notifyTabOfDownload(){notifications++;},chrome:{runtime:{sendNativeMessage(host,payload,callback){callback(response);}}}});
    vm.runInContext(source.slice(source.indexOf('function sendDownloadToHost(')),c);
    c.sendDownloadToHost({url:'https://example.com/file.mp4'},r=>reply=r,1);
    assert.equal(reply.success,!!(response.success&&response.taskId)); assert.equal(notifications,response.taskId?1:0);
  }
});
test('no debugger permission; version and existing extension identity preserved',()=>{
  const manifest=JSON.parse(fs.readFileSync('Extension/manifest.json','utf8'));
  assert.equal(manifest.version,'1.3.0'); assert(!manifest.permissions.includes('debugger'));
  const digest=crypto.createHash('sha256').update(Buffer.from(manifest.key,'base64')).digest('hex').slice(0,32);
  const id=digest.split('').map(x=>String.fromCharCode(97+parseInt(x,16))).join('');
  assert.equal(id,'nljinpcahdihnlhidjdacnhlchlpblnk');
  assert.deepEqual(manifest.content_scripts[0].js,['telegram.js','content.js']);
});
function pageEnvironment({restricted=false,album=false}={}) {
  let number=0;const map=new Map();
  const scope={className:restricted?'no-forwards':'',getAttribute:()=>null,parentElement:null,closest:s=>s.includes('no-forwards')&&restricted?scope:null,
    querySelector:s=>s.includes('no-forwards')&&restricted?scope:null,querySelectorAll:s=>s==='video,audio,img'?[video]:restricted?[]:[save]};
  const common={isConnected:true,parentElement:null,getBoundingClientRect:()=>({width:300,height:200,bottom:200,top:0}),getAttribute:()=>null,
    setAttribute(k,v){map.set(k,v);},querySelectorAll:()=>[],querySelector:()=>null,closest:s=>s.includes('no-forwards')&&restricted?scope:s.includes('MediaViewer')&&!album?scope:s.includes('data-mid')?scope:null};
  const video={...common,src:'blob:selected',duration:6,matches:s=>s.split(',').includes('video')};
  const save={...common,title:'',className:'btn-icon',disabled:false,matches:()=>false,querySelectorAll:()=>[{className:'tgico-download'}]};
  const c=vm.createContext({window:{},crypto:{randomUUID:()=>String(++number)},innerHeight:1000,location:{hostname:'web.telegram.org',href:'https://web.telegram.org/k/#test'},
    getComputedStyle:()=>({display:'block',visibility:'visible',opacity:'1'}),document:{querySelectorAll:()=>[video,save]}});
  vm.runInContext(fs.readFileSync('Extension/telegram.js','utf8'),c);
  return {api:c.window.__idmBrowser,video,save,scope,map};
}
test('Telegram K glyph Save is detected; permission gate and changed player are rejected',()=>{
  const page=pageEnvironment(); const picked=page.api.prepare(page.video); assert.equal(picked.mediaKind,'video'); assert(page.api.check(picked.handle));
  page.video.src='blob:changed'; assert.equal(page.api.check(picked.handle),false);
  const blocked=pageEnvironment({restricted:true});assert.throws(()=>blocked.api.prepare(blocked.video),/website_save_unavailable/);
});
test('message Save requires explicit file confirmation; loading UI cannot masquerade as Save',()=>{
  const page=pageEnvironment({album:true}); const picked=page.api.prepare(page.save); assert.equal(picked.requiresConfirmation,true);
  assert.throws(()=>page.api.prepare(page.video),/attachment_viewer_required/);
  page.save.querySelector=s=>s.includes('progress')?{}:null;
  assert.equal(page.api.check(picked.handle),false);
});
test('Telegram K nested media content uses the whole viewer containing the Save toolbar',()=>{
  const page=pageEnvironment();
  const inner={...page.scope,querySelectorAll:s=>s==='video,audio,img'?[page.video]:[]};
  page.video.closest=s=>s==='.media-viewer-whole'?page.scope:s.includes('MediaViewer')?inner:null;
  assert.equal(page.api.prepare(page.video).mediaKind,'video');
});
test('missing or busy Save is not reported as a Telegram permission restriction',()=>{
  const page=pageEnvironment();
  page.scope.querySelectorAll=s=>s==='video,audio,img'?[page.video]:[];
  assert.throws(()=>page.api.prepare(page.video),/^Error: website_save_not_found$/);
  page.scope.querySelectorAll=s=>s==='video,audio,img'?[page.video]:[page.save];
  page.save.disabled=true;
  assert.throws(()=>page.api.prepare(page.video),/^Error: website_save_not_ready$/);
  assert(!page.api.errorMessage('website_save_not_found').includes('hạn chế'));
  assert(page.api.errorMessage('website_save_unavailable').includes('hạn chế'));
});
test('restriction applies to the selected viewer, not an unrelated descendant',()=>{
  const page=pageEnvironment();
  page.scope.querySelector=s=>s==='.no-forwards'?{}:null;
  const picked=page.api.prepare(page.video); assert(page.api.check(picked.handle));
  page.scope.closest=s=>s==='.no-forwards'?page.scope:null;
  page.scope.querySelectorAll=s=>s==='video,audio,img'?[page.video]:[];
  assert.equal(page.api.check(picked.handle),false);
  assert.throws(()=>page.api.prepare(page.video),/website_save_unavailable/);
});
test('Telegram Save button in a restricted-forwarding chat is allowed when native Save is available',()=>{
  const page=pageEnvironment();
  page.scope.closest=s=>s==='.no-forwards'?page.scope:null;
  const picked=page.api.prepare(page.video);
  assert.equal(picked.mediaKind,'video');
  assert(page.api.check(picked.handle));
});
test('own Save progress is allowed, but selected media changes remain invalid',()=>{
  const page=pageEnvironment(); const picked=page.api.prepare(page.video); assert(page.api.markSaving(picked.handle));
  page.save.disabled=true; assert(page.api.check(picked.handle)); page.video.src='blob:next'; assert.equal(page.api.check(picked.handle),false);
});
test('Save As blocking script still reaches needs_confirmation at the 16 second deadline',async()=>{
  const {c}=environment();let clock=0,calls=[];
  c.Date={now:()=>{const now=clock;clock+=16001;return now;}};
  c.setTimeout=(fn,ms)=>setTimeout(fn,ms===16000?1:ms);
  c.browserNative=async payload=>{calls.push(payload);return {success:true};};
  c.chrome.downloads.search=async()=>[];
  c.chrome.runtime.sendMessage=async()=>{};
  c.chrome.scripting={executeScript:async options=>options.world==='MAIN'?await new Promise(()=>{}):[{result:true}]};
  const job={tabId:1,frameId:0,handle:'selected',source:'blob:player',sessionId:'session',taskId:'id',token:'token',observed:new Map()};
  await c.observeBrowserSave(job);
  assert.equal(job.phase,'needs_confirmation');
  assert(calls.some(x=>x.action==='browser_failure'&&x.browser.errorCode==='needs_confirmation'));
});
test('sendDownloadToHost retrieves and attaches session cookies from chrome.cookies',()=>{
  const source=fs.readFileSync('Extension/background.js','utf8');
  let capturedPayload;
  const c=vm.createContext({
    HOST_NAME:'host',
    navigator:{userAgent:'test-agent'},
    notifyTabOfDownload(){},
    chrome:{
      cookies:{
        getAll(query,cb){
          assert.equal(query.url,'https://example.com/video.mp4');
          cb([{name:'session_id',value:'abc123xyz'},{name:'token',value:'secret'}]);
        }
      },
      runtime:{
        sendNativeMessage(host,payload,callback){
          capturedPayload=payload;
          callback({success:true,taskId:'task-123'});
        }
      }
    }
  });
  vm.runInContext(source.slice(source.indexOf('function sendDownloadToHost(')),c);
  let result;
  c.sendDownloadToHost({url:'https://example.com/video.mp4'},r=>{result=r;},1);
  assert.equal(result.success,true);
  assert.equal(capturedPayload.cookies,'session_id=abc123xyz; token=secret');
  assert.equal(capturedPayload.url,'https://example.com/video.mp4');
});
test('sendDownloadToHost falls back to referrer cookies when cdn cookies are empty',()=>{
  const source=fs.readFileSync('Extension/background.js','utf8');
  let capturedPayload;
  const c=vm.createContext({
    HOST_NAME:'host',
    navigator:{userAgent:'test-agent'},
    notifyTabOfDownload(){},
    chrome:{
      cookies:{
        getAll(query,cb){
          if(query.url==='https://cdn.example.com/stream.mp4') cb([]);
          else if(query.url==='https://example.com/watch') cb([{name:'session',value:'auth_token'}]);
          else cb([]);
        }
      },
      runtime:{
        sendNativeMessage(host,payload,callback){
          capturedPayload=payload;
          callback({success:true,taskId:'task-456'});
        }
      }
    }
  });
  vm.runInContext(source.slice(source.indexOf('function isSameBaseDomain(')),c);
  let result;
  c.sendDownloadToHost({url:'https://cdn.example.com/stream.mp4',referrer:'https://example.com/watch'},r=>{result=r;},1);
  assert.equal(result.success,true);
  assert.equal(capturedPayload.cookies,'session=auth_token');
});
test('isSameBaseDomain correctly verifies domain matching and cross-origin boundaries',()=>{
  const source=fs.readFileSync('Extension/background.js','utf8');
  const c=vm.createContext({ URL });
  const fnCode=source.slice(source.indexOf('function isSameBaseDomain('),source.indexOf('// Gửi request tới Native Messaging Host'));
  vm.runInContext(fnCode,c);

  assert.equal(c.isSameBaseDomain('https://cdn.example.com/stream.mp4', 'https://example.com/watch'), true);
  assert.equal(c.isSameBaseDomain('https://sub.video.example.com/stream.m3u8', 'https://example.com/'), true);
  assert.equal(c.isSameBaseDomain('https://recordplay.biz/stream.m3u8', 'https://sexbjcam.com/post'), false);
  assert.equal(c.isSameBaseDomain('https://cv9fqnu812v.cdn-centaurus.com/stream.m3u8', 'https://sexbjcam.com/post'), false);
  assert.equal(c.isSameBaseDomain('', 'https://example.com'), false);
  assert.equal(c.isSameBaseDomain(null, 'https://example.com'), false);
  assert.equal(c.isSameBaseDomain('not-a-url', 'https://example.com'), false);
});
test('sendDownloadToHost does not attach cross-origin cookies from referrer or tabUrl to third-party cdn',()=>{
  const source=fs.readFileSync('Extension/background.js','utf8');
  let capturedPayload;
  const queriedUrls = [];
  const c=vm.createContext({
    HOST_NAME:'host',
    URL,
    navigator:{userAgent:'test-agent'},
    notifyTabOfDownload(){},
    tabUrls: { 1: 'https://sexbjcam.com/post' },
    chrome:{
      cookies:{
        getAll(query,cb){
          queriedUrls.push(query.url);
          if (query.url.includes('recordplay.biz')) cb([]);
          else if (query.url.includes('sexbjcam.com')) cb([{name:'tsn',value:'7'}]);
          else cb([]);
        }
      },
      runtime:{
        sendNativeMessage(host,payload,callback){
          capturedPayload=payload;
          callback({success:true,taskId:'task-789'});
        }
      }
    }
  });
  vm.runInContext(source.slice(source.indexOf('function isSameBaseDomain(')),c);
  let result;
  c.sendDownloadToHost({
    url: 'https://recordplay.biz/stream/master.m3u8',
    referrer: 'https://sexbjcam.com/post'
  }, r => { result = r; }, 1);
  assert.equal(result.success, true);
  assert.equal(capturedPayload.cookies, '', 'Must not leak foreign cookies from sexbjcam.com to recordplay.biz');
  assert.equal(queriedUrls.includes('https://sexbjcam.com/post'), false, 'Must not query cookies for cross-origin referrer');
});
test('content script getBestStreamFromRecent prioritizes master playlist over child variant playlists',()=>{
  const source=fs.readFileSync('Extension/content.js','utf8');
  const c=vm.createContext({});
  const fnCode=source.slice(source.indexOf('function getBestStreamFromRecent('),source.indexOf('function createFloatingBar('));
  vm.runInContext(fnCode,c);
  const streams=[
    {url:'https://recordplay.biz/stream/index-f3-v1-a1.m3u8',isPlaylist:true},
    {url:'https://recordplay.biz/stream/master.m3u8',isPlaylist:true}
  ];
  assert.equal(c.getBestStreamFromRecent(streams),'https://recordplay.biz/stream/master.m3u8');
});
test('content script getBestStreamFromRecent prioritizes m3u8 playlist over ts segments',()=>{
  const source=fs.readFileSync('Extension/content.js','utf8');
  const c=vm.createContext({});
  const fnCode=source.slice(source.indexOf('function getBestStreamFromRecent('),source.indexOf('function createFloatingBar('));
  vm.runInContext(fnCode,c);
  const streams=[
    {url:'https://cdn.example.com/seg_001.ts',isChunk:true},
    {url:'https://cdn.example.com/master.m3u8',isPlaylist:true},
    {url:'https://cdn.example.com/seg_002.ts',isChunk:true}
  ];
  assert.equal(c.getBestStreamFromRecent(streams),'https://cdn.example.com/master.m3u8');
});
test('content script getBestStreamItem retrieves full stream object with referrer',()=>{
  const source=fs.readFileSync('Extension/content.js','utf8');
  const c=vm.createContext({});
  const fnCode=source.slice(source.indexOf('function getBestStreamFromRecent('),source.indexOf('function createFloatingBar('));
  vm.runInContext(fnCode,c);
  const streams=[
    {url:'https://cdn.example.com/seg_001.ts',isChunk:true,referrer:'https://iframe.example.com/embed'},
    {url:'https://cdn.example.com/master.m3u8',isPlaylist:true,referrer:'https://iframe.example.com/embed'},
    {url:'https://cdn.example.com/seg_002.ts',isChunk:true,referrer:'https://iframe.example.com/embed'}
  ];
  const item=c.getBestStreamItem(streams);
  assert.equal(item.url,'https://cdn.example.com/master.m3u8');
  assert.equal(item.referrer,'https://iframe.example.com/embed');
});
test('webRequest preserves iframe documentUrl and initiator over top window url',()=>{
  const source=fs.readFileSync('Extension/background.js','utf8');
  assert(source.includes('const isFrameRequest = details.documentUrl && details.documentUrl !== tabUrls[details.tabId];'));
  assert(source.includes('referrer: effectiveRef'));

  function resolveMediaReferrer(details, tabUrl) {
    const isFrameRequest = details.documentUrl && details.documentUrl !== tabUrl;
    return (isFrameRequest && details.documentUrl.startsWith("http"))
      ? details.documentUrl
      : (tabUrl
          ? tabUrl
          : (details.initiator && details.initiator.startsWith("http") && details.initiator !== "null"
              ? details.initiator
              : ""));
  }
  const topUrl = 'https://sexbjcam.com/2026/10/10/kbj26101056_yoy12345_20260828/';
  const iframeDetails = {
    tabId: 10,
    url: 'https://recordplay.biz/stream/master.m3u8',
    documentUrl: 'https://recordplay.biz/e/vcvjcfonw7lp',
    initiator: 'https://recordplay.biz'
  };
  assert.equal(resolveMediaReferrer(iframeDetails, topUrl), 'https://recordplay.biz/e/vcvjcfonw7lp');

  const directDetails = {
    tabId: 10,
    url: 'https://sexbjcam.com/wp-content/video.mp4',
    documentUrl: topUrl,
    initiator: 'https://sexbjcam.com'
  };
  assert.equal(resolveMediaReferrer(directDetails, topUrl), topUrl);
});
test('content script recognizes iframe video player in getMediaDetails and findCandidateMedia',()=>{
  const source=fs.readFileSync('Extension/content.js','utf8');
  const c=vm.createContext({
    window: { location: { href: 'https://sexbjcam.com/video-page/' } },
    document: {}
  });
  // Extract helper functions and getMediaDetails
  const fnCode = source.slice(source.indexOf('function isVideoIframe('), source.indexOf('function createFloatingBar('));
  vm.runInContext(fnCode, c);

  const iframeEl = {
    tagName: 'IFRAME',
    src: 'https://recordplay.biz/e/vcvjcfonw7lp',
    id: '',
    className: '',
    getBoundingClientRect: () => ({ width: 956, height: 538, top: 194, right: 980, bottom: 732, left: 24 })
  };
  const details = c.getMediaDetails(iframeEl);
  assert(details, 'getMediaDetails should return media object for video iframe');
  assert.equal(details.type, 'video');
  assert.equal(details.label, 'Tải video này');
  assert.equal(details.url, 'https://recordplay.biz/e/vcvjcfonw7lp');

  const root = {
    querySelector: (sel) => null,
    querySelectorAll: (sel) => sel === 'iframe' ? [iframeEl] : []
  };
  const candidate = c.findCandidateMedia(root);
  assert.equal(candidate, iframeEl, 'findCandidateMedia should detect iframe when video element is absent');
});
test('positionBar places floating bar above media when top space is available and flips inside when space is constrained',()=>{
  const source=fs.readFileSync('Extension/content.js','utf8');
  const c=vm.createContext({
    document: { documentElement: { clientWidth: 1200 }, activeElement: null },
    window: { innerHeight: 900 }
  });
  const fnCode = source.slice(source.indexOf('function positionBar('), source.indexOf('function removeFloatingBar('));
  vm.runInContext(fnCode, c);

  const bar = {
    offsetWidth: 140,
    offsetHeight: 28,
    style: {},
    classList: {
      classes: new Set(),
      toggle(cls, val) { if (val) this.classes.add(cls); else this.classes.delete(cls); },
      contains(cls) { return this.classes.has(cls); },
      add(cls) { this.classes.add(cls); },
      remove(cls) { this.classes.delete(cls); }
    },
    matches: () => false,
    getBoundingClientRect: () => ({ top: 160, bottom: 188, left: 840, right: 980 })
  };

  // Case 1: Room above (top = 194, barHeight = 28, gap = 6 -> top = 160)
  const targetAbove = {
    tagName: 'IFRAME',
    getBoundingClientRect: () => ({ width: 956, height: 538, top: 194, right: 980, bottom: 732, left: 24 })
  };
  const pos1 = c.positionBar(bar, targetAbove);
  assert.equal(pos1, true);
  assert.equal(bar.style.top, '160px'); // 194 - 28 - 6 = 160
  assert.equal(bar.style.left, '840px'); // 980 - 140 = 840
  assert(bar.classList.contains('idm-positionable'));

  // Case 2: No room above (e.g. top = 0 in fullscreen or inside iframe)
  const targetConstrained = {
    tagName: 'VIDEO',
    getBoundingClientRect: () => ({ width: 800, height: 450, top: 0, right: 800, bottom: 450, left: 0 })
  };
  const pos2 = c.positionBar(bar, targetConstrained);
  assert.equal(pos2, true, 'positionBar must remain positionable when media is at top of viewport');
  assert.equal(bar.style.top, '6px'); // Flips inside: 0 + gap(6) = 6
  assert(bar.classList.contains('idm-positionable'));
});
test('content script suppresses floating bar inside embedded iframe (window.self !== window.top)',()=>{
  const source=fs.readFileSync('Extension/content.js','utf8');
  let appended = false;
  const c=vm.createContext({
    window: {
      self: { isFrame: true },
      top: { isTop: true },
      innerHeight: 800,
      innerWidth: 1000
    },
    document: {
      body: { appendChild: () => { appended = true; } },
      documentElement: { clientWidth: 1000 },
      activeElement: null,
      createElement: () => ({
        setAttribute: () => {},
        addEventListener: () => {},
        style: {},
        classList: { add: () => {}, remove: () => {}, toggle: () => {}, contains: () => false }
      })
    },
    showFloatingBarEnabled: true,
    recentStreams: [],
    currentBar: null,
    currentTargetEl: null,
    hideTimeout: null,
    barResizeObserver: null,
    lastPointer: null,
    removeFloatingBar: () => {},
    positionBar: () => true,
    updateBarVisibility: () => {},
    chrome: { runtime: { onMessage: { addListener: () => {} } } }
  });
  const fnCode = source.slice(source.indexOf('function createFloatingBar('), source.indexOf('function positionBar('));
  vm.runInContext(fnCode, c);

  const media = { url: 'https://recordplay.biz/stream.m3u8', type: 'video', label: 'Tải video này' };
  const targetEl = { tagName: 'VIDEO', getBoundingClientRect: () => ({ top: 0, right: 800, bottom: 450, left: 0 }) };

  c.createFloatingBar(targetEl, media);
  assert.equal(appended, false, 'Should not append bar inside embedded iframe');
  assert.equal(c.currentBar, null, 'currentBar must remain null inside embedded iframe');
});
test('notifyTabOfDownload sends message exclusively to main frame with frameId 0',()=>{
  const source=fs.readFileSync('Extension/background.js','utf8');
  let capturedOptions = null;
  let capturedTabId = null;
  let capturedMessage = null;
  const c=vm.createContext({
    chrome: {
      tabs: {
        sendMessage(tabId, message, options) {
          capturedTabId = tabId;
          capturedMessage = message;
          capturedOptions = options;
          return Promise.resolve();
        }
      }
    }
  });
  const fnCode = source.slice(source.indexOf('function notifyTabOfDownload('), source.indexOf('function sendDownloadToHost('));
  vm.runInContext(fnCode, c);

  c.notifyTabOfDownload(12, 'video.mp4', 'https://example.com/video.mp4');
  assert.equal(capturedTabId, 12);
  assert.equal(capturedMessage.action, 'show_download_toast');
  assert(capturedOptions && capturedOptions.frameId === 0, 'notifyTabOfDownload must target frameId: 0 to avoid duplicate popups in iframes');
});
test('content script showDownloadToast suppresses toast inside embedded iframe and deduplicates rapid identical toasts',()=>{
  const source=fs.readFileSync('Extension/content.js','utf8');
  let appendCount = 0;
  const mockContainer = {
    appendChild: () => { appendCount++; }
  };
  const mockDoc = {
    getElementById: (id) => id === 'idm-toast-container' ? mockContainer : null,
    createElement: () => ({
      className: '',
      innerHTML: '',
      querySelector: () => ({
        textContent: '',
        title: '',
        addEventListener: () => {}
      })
    })
  };
  const c=vm.createContext({
    window: {
      self: { isFrame: true },
      top: { isTop: true }
    },
    document: mockDoc,
    setTimeout: (fn) => {}
  });
  const fnCode = source.slice(source.indexOf('function showDownloadToast('), source.indexOf('function isVideoIframe('));
  vm.runInContext(fnCode, c);

  // Case 1: Inside embedded iframe (window.self !== window.top) -> Must NOT append any toast
  c.showDownloadToast('test.mp4', 'https://example.com/test.mp4');
  assert.equal(appendCount, 0, 'showDownloadToast must not create or append toast when inside embedded iframe');

  // Case 2: In top window (window.self === window.top) -> Appends 1 toast, but deduplicates rapid identical calls
  c.window.self = c.window.top;
  c.showDownloadToast('video1.mp4', 'https://example.com/video1.mp4');
  assert.equal(appendCount, 1, 'Top window should append 1 toast');

  // Immediate duplicate call for same file/url -> Must be debounced
  c.showDownloadToast('video1.mp4', 'https://example.com/video1.mp4');
  assert.equal(appendCount, 1, 'Duplicate toast within debounce window must be suppressed');
});
test('getMediaDetails tags IFRAME with isIframeEmbed and floating bar prioritizes sniffed stream over embed src',()=>{
  const source = fs.readFileSync('Extension/content.js', 'utf8');
  const c = vm.createContext({
    window: { location: { href: 'https://sexkbj.com/video-page/' } },
    document: { title: 'Test Video Page' }
  });
  const fnCode = source.slice(source.indexOf('function isVideoIframe('), source.indexOf('function findMediaUnderPointer('));
  vm.runInContext(fnCode, c);

  const mockIframe = {
    tagName: 'IFRAME',
    src: 'https://sexkbj.top/embed/iq0hq7l2oq8c',
    className: 'player-iframe',
    getBoundingClientRect: () => ({ width: 800, height: 450, top: 100, left: 100 })
  };

  const details = c.getMediaDetails(mockIframe);
  assert(details, 'Should return media details for video iframe');
  assert.equal(details.isIframeEmbed, true, 'Must tag iframe as isIframeEmbed');
  assert.equal(details.embedSrc, 'https://sexkbj.top/embed/iq0hq7l2oq8c');
});
test('dispatchDownload prioritizes media.embedSrc when downloading iframe embed media',()=>{
  const source = fs.readFileSync('Extension/content.js', 'utf8');
  let capturedMessage = null;
  const c = vm.createContext({
    media: { isIframeEmbed: true, embedSrc: 'https://recordplay.biz/e/vcvjcfonw7lp' },
    filename: 'test.mp4',
    window: { location: { href: 'https://sexbjcam.com/post' } },
    chrome: {
      runtime: {
        sendMessage: (msg, cb) => {
          capturedMessage = msg;
          cb({ success: true, taskId: 'task-123' });
        }
      }
    },
    setStatus: () => {}
  });

  // Extract dispatchDownload
  const fnCode = source.slice(source.indexOf('function dispatchDownload('), source.indexOf('// 1. Nền tảng video trực tuyến'));
  vm.runInContext(fnCode, c);

  c.dispatchDownload('https://recordplay.biz/stream/master.m3u8', null);
  assert(capturedMessage, 'Must send message to runtime');
  assert.equal(capturedMessage.url, 'https://recordplay.biz/stream/master.m3u8');
  assert.equal(capturedMessage.referrer, 'https://recordplay.biz/e/vcvjcfonw7lp', 'Must use media.embedSrc as referrer instead of top window url');
});

test('getBestStreamFromRecent strictly excludes .webmanifest and non-media files', () => {
  const source = fs.readFileSync('Extension/content.js', 'utf8');
  const c = vm.createContext({});
  const fnCode = source.slice(source.indexOf('function getBestStreamFromRecent('), source.indexOf('function createFloatingBar('));
  vm.runInContext(fnCode, c);

  const streamsWithManifest = [
    { url: 'https://www.youtube.com/manifest.webmanifest', mime: 'application/manifest+json' },
    { url: 'https://example.com/subtitles.vtt', mime: 'text/vtt' },
    { url: 'https://example.com/config.json', mime: 'application/json' }
  ];
  assert.equal(c.getBestStreamFromRecent(streamsWithManifest), null, 'Must ignore webmanifest and non-media json/vtt');

  const streamsWithRealVideo = [
    { url: 'https://www.youtube.com/manifest.webmanifest', mime: 'application/manifest+json' },
    { url: 'https://example.com/video.mp4', mime: 'video/mp4' }
  ];
  assert.equal(c.getBestStreamFromRecent(streamsWithRealVideo), 'https://example.com/video.mp4', 'Must pick genuine video over webmanifest');
});

test('isVideoPlatform correctly identifies YouTube and click handler prioritizes window.location.href', () => {
  const source = fs.readFileSync('Extension/content.js', 'utf8');
  let capturedMessage = null;
  const c = vm.createContext({
    window: { location: { hostname: 'www.youtube.com', href: 'https://www.youtube.com/watch?v=FVnhw0mVH_Q' } },
    document: { title: 'Test YouTube Video' },
    media: { url: 'blob:https://www.youtube.com/1234-abcd', type: 'video', label: 'Tải video này' },
    recentStreams: [
      { url: 'https://www.youtube.com/manifest.webmanifest', mime: 'application/manifest+json' }
    ],
    chrome: {
      runtime: {
        sendMessage: (msg, cb) => {
          capturedMessage = msg;
          if (cb) cb({ success: true, taskId: 'yt-task-1' });
        }
      }
    },
    setStatus: () => {}
  });

  const isVideoPlatformCode = source.slice(source.indexOf('function isVideoPlatform('), source.indexOf('function getBestStreamFromRecent('));
  vm.runInContext(isVideoPlatformCode, c);
  assert.equal(c.isVideoPlatform(), true, 'YouTube must be identified as video platform');

  // Verify click handler logic for video platforms
  if (c.isVideoPlatform()) {
    c.chrome.runtime.sendMessage({
      action: 'download_media',
      url: c.window.location.href,
      filename: 'Test YouTube Video.mp4',
      referrer: c.window.location.href
    });
  }
  assert(capturedMessage, 'Must dispatch message for video platform');
  assert.equal(capturedMessage.url, 'https://www.youtube.com/watch?v=FVnhw0mVH_Q', 'Must dispatch YouTube watch page URL, never webmanifest or blob');
});

test('onResponseStarted ignores HTTP status codes >= 400 like 403 Forbidden', () => {
  const source = fs.readFileSync('Extension/background.js', 'utf8');
  let captured = [];
  const c = vm.createContext({
    chrome: {
      webRequest: {
        onResponseStarted: {
          addListener: (fn) => { c.handler = fn; }
        }
      },
      action: { setBadgeText: () => {}, setBadgeBackgroundColor: () => {} },
      tabs: { sendMessage: () => Promise.resolve() }
    },
    capturedMediaByTab: {},
    tabUrls: {}
  });

  const startIdx = source.indexOf('if (chrome.webRequest && chrome.webRequest.onResponseStarted)');
  const endIdx = source.indexOf('// Xóa danh sách khi đóng tab');
  const code = source.slice(startIdx, endIdx);
  vm.runInContext(code, c);

  assert(typeof c.handler === 'function', 'Listener must be registered');

  // Case 1: Status 403 Forbidden probe (e.g. recordplay.biz/stream/.../master.m3u8)
  c.handler({
    tabId: 1,
    url: 'https://recordplay.biz/stream/IDVZ1cGa7ftP7s69MKP_Zg/kjhhiuahiuhgihdf/1791749639/75629209/master.m3u8',
    statusCode: 403,
    responseHeaders: [{ name: 'Content-Type', value: 'application/vnd.apple.mpegurl' }]
  });
  assert.equal(c.capturedMediaByTab[1]?.length || 0, 0, 'Must NOT capture 403 Forbidden stream');

  // Case 2: Status 200 OK genuine stream (e.g. cdn-centaurus.com)
  c.handler({
    tabId: 1,
    url: 'https://vwyn3lxe5fv5.cdn-centaurus.com/hls2/01/15125/20enthat5erf_,l,n,h,.urlset/master.m3u8',
    statusCode: 200,
    responseHeaders: [{ name: 'Content-Type', value: 'application/vnd.apple.mpegurl' }]
  });
  assert.equal(c.capturedMediaByTab[1]?.length, 1, 'Must capture 200 OK genuine stream');
  assert.equal(c.capturedMediaByTab[1][0].url, 'https://vwyn3lxe5fv5.cdn-centaurus.com/hls2/01/15125/20enthat5erf_,l,n,h,.urlset/master.m3u8');
});

test('getBestStreamFromRecent avoids recordplay.biz/stream/ probe and picks working CDN stream', () => {
  const source = fs.readFileSync('Extension/content.js', 'utf8');
  const c = vm.createContext({});
  const fnCode = source.slice(source.indexOf('function getBestStreamFromRecent('), source.indexOf('function createFloatingBar('));
  vm.runInContext(fnCode, c);

  const streams = [
    { url: 'https://recordplay.biz/stream/IDVZ1cGa7ftP7s69MKP_Zg/kjhhiuahiuhgihdf/1791749639/75629209/master.m3u8', isPlaylist: true },
    { url: 'https://vwyn3lxe5fv5.cdn-centaurus.com/hls2/01/15125/20enthat5erf_,l,n,h,.urlset/master.m3u8', isPlaylist: true }
  ];

  const selected = c.getBestStreamFromRecent(streams);
  assert.equal(selected, 'https://vwyn3lxe5fv5.cdn-centaurus.com/hls2/01/15125/20enthat5erf_,l,n,h,.urlset/master.m3u8', 'Must pick cdn-centaurus.com over recordplay.biz/stream/ honeypot');
});

test('downloads.onCreated and onDeterminingFilename cancel browser download synchronously to prevent native Save As dialog', () => {
  const source = fs.readFileSync('Extension/background.js', 'utf8');
  let onCreatedHandler = null;
  let onDeterminingFilenameHandler = null;
  const cancelledIds = [];
  const erasedIds = [];
  const sentToHost = [];

  const c = vm.createContext({
    importScripts: () => {},
    browserJobs: new Map(),
    URL,
    navigator: { userAgent: 'Mozilla/5.0' },
    setTimeout: () => { throw new Error('Must NOT use setTimeout delay before cancelling download'); },
    clearTimeout: () => {},
    chrome: {
      runtime: {
        onInstalled: { addListener: () => {} },
        onMessage: { addListener: () => {} },
        sendNativeMessage: (host, payload, cb) => {
          sentToHost.push(payload);
          if (cb) cb({ success: true, taskId: 'task-dmg-1' });
        }
      },
      storage: {
        local: {
          // Simulate async storage.local.get that does NOT resolve synchronously
          get: () => {}
        },
        onChanged: { addListener: () => {} }
      },
      contextMenus: {
        create: () => {},
        onClicked: { addListener: () => {} }
      },
      downloads: {
        onCreated: { addListener: (fn) => { onCreatedHandler = fn; } },
        onDeterminingFilename: { addListener: (fn) => { onDeterminingFilenameHandler = fn; } },
        onChanged: { addListener: () => {}, removeListener: () => {} },
        cancel: (id, cb) => { cancelledIds.push(id); if (cb) cb(); },
        erase: (query, cb) => { erasedIds.push(query.id); if (cb) cb(); }
      },
      webRequest: {
        onBeforeSendHeaders: { addListener: () => {} },
        onBeforeRedirect: { addListener: () => {} },
        onResponseStarted: { addListener: () => {} }
      },
      tabs: {
        onRemoved: { addListener: () => {} },
        onUpdated: { addListener: () => {} },
        sendMessage: () => Promise.resolve()
      },
      webNavigation: {
        onHistoryStateUpdated: { addListener: () => {} }
      },
      action: {
        setBadgeText: () => {},
        setBadgeBackgroundColor: () => {}
      }
    }
  });

  vm.runInContext(source, c);
  assert(typeof onCreatedHandler === 'function', 'onCreated listener must be registered');
  assert(typeof onDeterminingFilenameHandler === 'function', 'onDeterminingFilename listener must be registered');

  // Simulate clicking a website download button where initial filename is empty and URL is opaque redirect
  const downloadItem = {
    id: 42,
    url: 'https://example.com/download/latest',
    finalUrl: 'https://cdn.example.com/releases/ArtCraft_0.41.0_universal.dmg',
    filename: '',
    referrer: 'https://example.com/'
  };

  onCreatedHandler(downloadItem);

  // Must cancel and erase synchronously on the exact same tick (before Save As dialog can open)
  assert.deepEqual(cancelledIds, [42], 'Must cancel download synchronously in onCreated');
  assert.deepEqual(erasedIds, [42], 'Must erase download synchronously in onCreated');
  assert.equal(sentToHost.length, 1, 'Must send intercepted download to native host immediately');
  assert.equal(sentToHost[0].filename, 'ArtCraft_0.41.0_universal.dmg');

  // If onDeterminingFilename also fires for the same download id, it must return true without calling suggest()
  // and must NOT duplicate sendDownloadToHost
  let suggestCalled = false;
  const held = onDeterminingFilenameHandler(
    { ...downloadItem, filename: 'ArtCraft_0.41.0_universal.dmg' },
    () => { suggestCalled = true; }
  );
  assert.equal(held, true, 'onDeterminingFilename must return true to hold DownloadTargetDeterminer and block native Save As');
  assert.equal(suggestCalled, false, 'onDeterminingFilename must not call suggest() when intercepting');
  assert.equal(sentToHost.length, 1, 'Must not send duplicate download to native host for same download id');

  // Non-interceptable blob: download must call suggest() and return false so browser handles it normally
  let blobSuggestCalled = false;
  const blobHeld = onDeterminingFilenameHandler(
    { id: 43, url: 'blob:https://example.com/123', filename: 'file.bin' },
    () => { blobSuggestCalled = true; }
  );
  assert.equal(blobHeld, false, 'Non-interceptable blob download must return false');
  assert.equal(blobSuggestCalled, true, 'Non-interceptable blob download must call suggest()');
});

test('content.js isInterceptableDownloadAnchor intercepts <a download> and binary links while ignoring navigation links', () => {
  const source = fs.readFileSync('Extension/content.js', 'utf8');
  const start = source.indexOf('const DIRECT_DOWNLOAD_EXT_REGEX =');
  const end = source.indexOf('document.addEventListener("pointerdown"', start);
  assert(start > 0 && end > start, 'isInterceptableDownloadAnchor block must exist in content.js');

  const snippet = source.slice(start, end);
  function makeSandbox(hostname = 'artcraft.example.com', interceptEnabled = true) {
    const c = vm.createContext({
      URL,
      decodeURIComponent,
      interceptDownloadsEnabled: interceptEnabled,
      location: {
        hostname,
        href: `https://${hostname}/download`
      }
    });
    vm.runInContext(snippet, c);
    return c;
  }

  function makeAnchor({ href, resolvedHref, downloadAttr = null }) {
    return {
      href: resolvedHref || href,
      closest: () => null,
      getAttribute: (name) => {
        if (name === 'href') return href;
        if (name === 'download') return downloadAttr;
        return null;
      },
      hasAttribute: (name) => name === 'download' && downloadAttr !== null
    };
  }

  const sb = makeSandbox();
  // 1. Direct .dmg link without download attribute
  const dmgInfo = sb.isInterceptableDownloadAnchor(makeAnchor({
    href: 'https://cdn.example.com/releases/ArtCraft_0.41.0_universal.dmg?token=abc'
  }));
  assert.equal(dmgInfo?.url, 'https://cdn.example.com/releases/ArtCraft_0.41.0_universal.dmg?token=abc');
  assert.equal(dmgInfo?.filename, 'ArtCraft_0.41.0_universal.dmg');

  // 2. Opaque URL with explicit download attribute
  const attrInfo = sb.isInterceptableDownloadAnchor(makeAnchor({
    href: '/api/v1/release/latest',
    resolvedHref: 'https://artcraft.example.com/api/v1/release/latest',
    downloadAttr: 'ArtCraft_0.41.0_universal.dmg'
  }));
  assert.equal(attrInfo?.url, 'https://artcraft.example.com/api/v1/release/latest');
  assert.equal(attrInfo?.filename, 'ArtCraft_0.41.0_universal.dmg');

  // 3. Regular HTML navigation link must NOT be intercepted
  const navInfo = sb.isInterceptableDownloadAnchor(makeAnchor({
    href: 'https://artcraft.example.com/docs/getting-started'
  }));
  assert.equal(navInfo, null);

  // 4. blob: link must NOT be intercepted
  const blobInfo = sb.isInterceptableDownloadAnchor(makeAnchor({
    href: 'blob:https://artcraft.example.com/uuid-123',
    downloadAttr: 'file.dmg'
  }));
  assert.equal(blobInfo, null);

  // 5. Disabled interceptDownloadsEnabled must NOT intercept
  const sbDisabled = makeSandbox('artcraft.example.com', false);
  assert.equal(sbDisabled.isInterceptableDownloadAnchor(makeAnchor({
    href: 'https://cdn.example.com/ArtCraft.dmg'
  })), null);
});

test('multi-hop redirects, opaque onCreated -> onDeterminingFilename upgrade, and content.js click deduplication', () => {
  const source = fs.readFileSync('Extension/background.js', 'utf8');
  const sentToHost = [];
  let onCreatedHandler = null;
  let onDeterminingFilenameHandler = null;
  let onBeforeRedirectHandler = null;
  let onResponseStartedHandler = null;
  let onMessageHandler = null;

  const c = vm.createContext({
    URL,
    Date,
    Set,
    Map,
    Promise,
    navigator: { userAgent: 'Mozilla/5.0 Test' },
    importScripts: () => {},
    chrome: {
      runtime: {
        onInstalled: { addListener: () => {} },
        onMessage: { addListener: (fn) => { onMessageHandler = fn; } },
        sendNativeMessage: (_host, payload, cb) => {
          sentToHost.push(payload);
          if (cb) cb({ success: true, taskId: 'task-1' });
        }
      },
      storage: {
        local: { get: (_keys, cb) => cb({ interceptDownloads: true }) },
        onChanged: { addListener: () => {} }
      },
      contextMenus: {
        create: () => {},
        onClicked: { addListener: () => {} }
      },
      downloads: {
        onCreated: { addListener: (fn) => { onCreatedHandler = fn; } },
        onDeterminingFilename: { addListener: (fn) => { onDeterminingFilenameHandler = fn; } },
        onChanged: { addListener: () => {}, removeListener: () => {} },
        cancel: (_id, cb) => { if (cb) cb(); },
        erase: (_query, cb) => { if (cb) cb(); }
      },
      webRequest: {
        onBeforeSendHeaders: { addListener: () => {} },
        onBeforeRedirect: { addListener: (fn) => { onBeforeRedirectHandler = fn; } },
        onResponseStarted: { addListener: (fn) => { onResponseStartedHandler = fn; } }
      },
      tabs: {
        onRemoved: { addListener: () => {} },
        onUpdated: { addListener: () => {} },
        sendMessage: () => Promise.resolve()
      },
      webNavigation: {
        onHistoryStateUpdated: { addListener: () => {} }
      },
      action: {
        setBadgeText: () => {},
        setBadgeBackgroundColor: () => {}
      }
    }
  });

  vm.runInContext(source, c);

  // 1. Multi-hop redirect A -> B -> C where C is an opaque UUID URL with Content-Disposition
  const urlA = 'https://artcraft.example.com/download';
  const urlB = 'https://auth.artcraft.example.com/Hop2';
  const urlC = 'https://storage.example.com/blobs/9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d';
  onBeforeRedirectHandler({ url: urlA, redirectUrl: urlB });
  onBeforeRedirectHandler({ url: urlB, redirectUrl: urlC });
  onResponseStartedHandler({
    url: urlC,
    tabId: 1,
    statusCode: 200,
    responseHeaders: [
      { name: 'Content-Disposition', value: 'attachment; filename="ArtCraft_0.41.0_universal.dmg"' }
    ]
  });

  onCreatedHandler({ id: 100, url: urlA, finalUrl: '', filename: '', referrer: 'https://artcraft.example.com/' });
  assert.equal(sentToHost.length, 1);
  assert.equal(sentToHost[0].url, urlC, 'Must follow multi-hop redirect chain A -> B -> C');
  assert.equal(sentToHost[0].filename, 'ArtCraft_0.41.0_universal.dmg', 'Must resolve Content-Disposition from final hop C');

  // 2. Opaque URL in onCreated (without Content-Disposition yet) followed by real filename in onDeterminingFilename
  const opaqueUrl = 'https://storage.example.com/blobs/11111111-2222-3333-4444-555555555555';
  onCreatedHandler({ id: 101, url: opaqueUrl, finalUrl: opaqueUrl, filename: '', referrer: 'https://artcraft.example.com/' });
  assert.equal(sentToHost.length, 2);
  assert.equal(sentToHost[1].filename, '');

  onDeterminingFilenameHandler(
    { id: 101, url: opaqueUrl, finalUrl: opaqueUrl, filename: '/Users/test/Downloads/ArtCraft_0.41.0_universal.dmg', referrer: 'https://artcraft.example.com/' },
    () => {}
  );
  assert.equal(sentToHost.length, 3, 'Must upgrade opaque onCreated handoff when onDeterminingFilename provides real filename');
  assert.equal(sentToHost[2].filename, 'ArtCraft_0.41.0_universal.dmg');

  // 3. Deduplication: content.js sends download_media first, then chrome.downloads.onCreated fires for the same URL
  const directDmgUrl = 'https://cdn.artcraft.example.com/ArtCraft_0.41.0_universal.dmg';
  onMessageHandler(
    { action: 'download_media', url: directDmgUrl, filename: 'ArtCraft_0.41.0_universal.dmg', referrer: 'https://artcraft.example.com/' },
    { tab: { id: 1, url: 'https://artcraft.example.com/' } },
    () => {}
  );
  assert.equal(sentToHost.length, 4);
  onCreatedHandler({ id: 102, url: directDmgUrl, finalUrl: directDmgUrl, filename: 'ArtCraft_0.41.0_universal.dmg', referrer: 'https://artcraft.example.com/' });
  assert.equal(sentToHost.length, 4, 'Must not send duplicate start_download when content.js already handed off the same URL');
});