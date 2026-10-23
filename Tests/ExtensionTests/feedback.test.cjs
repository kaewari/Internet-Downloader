// Feedback tests for the browser → app handoff: mọi click phải kết thúc bằng một
// toast nhìn thấy được trên trang, kể cả khi floating bar đã bị gỡ.
//
// Cover:
//   (a) failure path luôn hiện toast dù bar đã biến mất
//   (b) watchdog 12s khi app không trả taskId
//   (c) blob:/data: không bao giờ tới chrome.runtime.sendMessage
//   (d) autoStart được chuyển tiếp content → background → native payload
//   (e) version mismatch: ping_host + hello check + map mã lỗi
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');

const CONTENT = fs.readFileSync('Extension/content.js', 'utf8');
const BACKGROUND = fs.readFileSync('Extension/background.js', 'utf8');
const TRANSFER = fs.readFileSync('Extension/browser-transfer.js', 'utf8');
const MANIFEST = JSON.parse(fs.readFileSync('Extension/manifest.json', 'utf8'));

function contentSlice(startMarker, endMarker) {
  const start = CONTENT.indexOf(startMarker);
  const end = CONTENT.indexOf(endMarker, start);
  assert(start >= 0 && end > start, `Không tìm thấy slice ${startMarker} → ${endMarker}`);
  return CONTENT.slice(start, end);
}

const DISPATCH_CODE = contentSlice('function dispatchDownload(', '// 1. Nền tảng video trực tuyến');
const ERROR_HELPERS_CODE = contentSlice('const DOWNLOAD_ERROR_MESSAGES =', 'function createFloatingBar(');
// Gồm getMediaDetails → helpers → createFloatingBar (đủ cho luồng click thật).
const BAR_CODE = contentSlice('function isVideoIframe(', 'function positionBar(');

// ---------------------------------------------------------------------------
// Harness cho dispatchDownload (floating bar) — có/không có floating bar
// ---------------------------------------------------------------------------
function dispatchEnvironment({autoStart = false, respond} = {}) {
  const toasts = [];
  const sent = [];
  const timers = [];
  const chromeRuntime = {lastError: null, sendMessage(message, callback) {
    sent.push({message, callback});
    if (respond) respond(message, callback);
  }};
  const context = vm.createContext({
    console,
    URL,
    setTimeout(fn, ms) { timers.push({fn, ms}); return timers.length; },
    clearTimeout() {},
    window: {location: {href: 'https://example.com/watch/123'}},
    media: {isIframeEmbed: false, embedSrc: 'https://example.com/embed'},
    filename: 'Video.mp4',
    autoStartBrowserDownloads: autoStart,
    setStatus: () => {},
    showDownloadToast(filename, url, status, options) { toasts.push({filename, url, status, options}); },
    chrome: {runtime: chromeRuntime}
  });
  // Nạp cả helpers (mapDownloadError, watchdog constants) trong cùng context để
  // dispatch dùng đúng logic thật; trong content.js chúng nằm cùng IIFE scope.
  vm.runInContext(ERROR_HELPERS_CODE + '\n' + DISPATCH_CODE, context);
  return {context, toasts, sent, timers, chromeRuntime};
}

test('(a) failure luôn hiện toast kể cả khi floating bar đã bị gỡ', () => {
  const environment = dispatchEnvironment({
    respond: (_message, callback) => callback({success: false, error: 'App từ chối', code: 'invalid_url'})
  });
  // Không hề tạo bar / không còn bar nào trong DOM — closure vẫn phải báo lỗi.
  environment.context.dispatchDownload('https://cdn.example.com/video.mp4', null);

  assert.equal(environment.sent.length, 1, 'Phải gửi download_media');
  assert.equal(environment.toasts.length, 1, 'Failure phải luôn có toast');
  assert.match(environment.toasts[0].status, /link media hợp lệ/);
  assert.equal(environment.toasts[0].options.kind, 'error');
  assert.equal(environment.toasts[0].options.force, true);
});

test('(a) success hiện toast "đã nhận tác vụ" và autoStart hiện "đã bắt đầu tải"', () => {
  const success = dispatchEnvironment({respond: (_m, cb) => cb({success: true, taskId: 'task-1'})});
  success.context.dispatchDownload('https://cdn.example.com/video.mp4', null);
  assert.equal(success.toasts.length, 1);
  assert.match(success.toasts[0].status, /App đã nhận tác vụ — chờ xác nhận trong app/);
  assert.equal(success.toasts[0].options.kind, 'success');

  const auto = dispatchEnvironment({autoStart: true, respond: (_m, cb) => cb({success: true, taskId: 'task-2'})});
  auto.context.dispatchDownload('https://cdn.example.com/video.mp4', null);
  assert.match(auto.toasts[0].status, /App đã bắt đầu tải/);
});

test('(a) app đóng (runtime.lastError) và mã lỗi lạ đều hiện toast rõ ràng', () => {
  const closed = dispatchEnvironment({respond: (_m, cb) => cb(undefined)});
  closed.chromeRuntime.lastError = {message: 'Could not establish connection'};
  closed.context.dispatchDownload('https://cdn.example.com/video.mp4', null);
  assert.match(closed.toasts[0].status, /mở Internet Downloader/);
  assert.equal(closed.toasts[0].options.kind, 'error');

  const unknown = dispatchEnvironment({
    respond: (_m, cb) => cb({success: false, error: 'Lỗi nội bộ', code: 'weird_failure'})
  });
  unknown.context.dispatchDownload('https://cdn.example.com/video.mp4', null);
  assert.match(unknown.toasts[0].status, /Lỗi nội bộ \(mã: weird_failure\)/,
    'Mã lỗi lạ phải được giữ lại trong toast để debug');
});

test('(b) watchdog 12s báo "App không phản hồi" và bỏ qua phản hồi đến muộn', () => {
  const environment = dispatchEnvironment();
  environment.context.dispatchDownload('https://cdn.example.com/video.mp4', null);

  assert.equal(environment.sent.length, 1);
  assert.equal(environment.toasts.length, 0, 'Chưa có phản hồi thì chưa toast');
  assert.equal(environment.timers.length, 1, 'Phải arm watchdog');
  assert.equal(environment.timers[0].ms, 12000, 'Watchdog phải là 12 giây');

  environment.timers[0].fn();
  assert.equal(environment.toasts.length, 1, 'Watchdog phải tạo toast');
  assert.match(environment.toasts[0].status, /App không phản hồi — hãy mở Internet Downloader rồi thử lại/);

  // Phản hồi đến sau watchdog là stale → không được tạo toast thứ hai.
  environment.sent[0].callback({success: true, taskId: 'late-task'});
  assert.equal(environment.toasts.length, 1, 'Phản hồi stale không được tạo toast trùng');
});

test('(c) blob:/data: không bao giờ tới chrome.runtime.sendMessage', () => {
  const direct = dispatchEnvironment();
  direct.context.dispatchDownload('blob:https://example.com/1234', null);
  direct.context.dispatchDownload('data:video/mp4;base64,AAAA', null);

  assert.equal(direct.sent.length, 0, 'Không được gửi blob:/data: sang background/app');
  assert.equal(direct.toasts.length, 2, 'Mỗi lần dispatch vẫn phải có toast hướng dẫn');
  for (const toast of direct.toasts) assert.match(toast.status, /bấm phát video/);

  // Background cũng phải từ chối blob:/data: (defense in depth, không tới native host).
  const background = backgroundEnvironment();
  let reply;
  background.onMessageHandler(
    {action: 'download_media', url: 'blob:https://example.com/mse', filename: 'x.mp4'},
    {tab: {id: 9, url: 'https://example.com/'}},
    (response) => { reply = response; }
  );
  assert.equal(background.sentToHost.length, 0, 'Background không được chuyển blob: sang app');
  assert.equal(reply.success, false);
  assert.equal(reply.code, 'browser_source_required');
});

test('(c) click trên video blob không có stream → toast "bấm phát video", không gửi blob', () => {
  const toasts = [];
  const sent = [];
  const barListeners = {};
  const bar = {
    type: '', className: '', innerHTML: '', isConnected: true, dataset: {}, style: {},
    setAttribute() {},
    addEventListener(event, handler) { barListeners[event] = handler; },
    querySelector: () => ({textContent: '', title: '', addEventListener() {}}),
    classList: {add() {}, remove() {}}
  };
  const context = vm.createContext({
    console,
    URL,
    window: {self: {}, top: null, innerHeight: 900, innerWidth: 1200,
      location: {hostname: 'example.com', href: 'https://example.com/post'}},
    location: {hostname: 'example.com', href: 'https://example.com/post'},
    document: {
      title: 'Example',
      body: {appendChild() {}},
      createElement: () => bar,
      querySelector: () => null,
      querySelectorAll: () => []
    },
    chrome: {
      runtime: {
        lastError: null,
        sendMessage(message, callback) {
          sent.push(message);
          if (message.action === 'get_captured_media' && callback) callback({media: []});
        },
        onMessage: {addListener() {}}
      }
    },
    showFloatingBarEnabled: true,
    autoStartBrowserDownloads: false,
    recentStreams: [],
    currentBar: null,
    currentTargetEl: null,
    hideTimeout: null,
    lastPointer: null,
    barResizeObserver: null,
    removeFloatingBar() {},
    updateBarVisibility() {},
    positionBar() { return true; },
    showDownloadToast(filename, url, status, options) { toasts.push({filename, url, status, options}); },
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (id) => clearTimeout(id)
  });
  context.window.top = context.window.self;
  vm.runInContext(BAR_CODE, context);

  const blobVideo = {
    tagName: 'VIDEO',
    currentSrc: 'blob:https://example.com/mse-player',
    closest: () => null,
    querySelector: () => null,
    getBoundingClientRect: () => ({width: 640, height: 360, top: 100, left: 100, right: 740, bottom: 460})
  };
  context.createFloatingBar(blobVideo, {url: 'blob:https://example.com/mse-player', type: 'video', label: 'Tải video này'});
  assert(barListeners.click, 'Bar phải đăng ký click listener');

  barListeners.click({isTrusted: true, stopPropagation() {}, preventDefault() {}});

  const downloadMessages = sent.filter((message) => message.action === 'download_media');
  assert.equal(downloadMessages.length, 0, 'Không được dispatch khi chỉ có blob URL');
  assert(sent.every((message) => !String(message.url || '').startsWith('blob:') && !String(message.url || '').startsWith('data:')),
    'Không message nào chứa blob:/data: URL');
  assert.equal(toasts.length, 1, 'Phải có toast hướng dẫn');
  assert.match(toasts[0].status, /bấm phát video/);
});

// ---------------------------------------------------------------------------
// Harness tối giản cho background.js (full source, importScripts mocked)
// ---------------------------------------------------------------------------
function backgroundEnvironment({nativeResponse, manifestVersion = '1.4.0', expectedAppVersion = '1.2.0'} = {}) {
  let onMessageHandler = null;
  const sentToHost = [];
  const event = () => ({addListener() {}});
  const context = vm.createContext({
    console, URL, Date, Set, Map, Promise,
    navigator: {userAgent: 'Mozilla/5.0 Test'},
    importScripts: () => {},
    IDM_EXPECTED_APP_VERSION: expectedAppVersion,
    chrome: {
      runtime: {
        onInstalled: event(),
        onMessage: {addListener(handler) { onMessageHandler = handler; }},
        getManifest: () => ({version: manifestVersion}),
        sendNativeMessage(_host, payload, callback) {
          sentToHost.push(payload);
          if (callback) callback(nativeResponse ? nativeResponse(payload) : {success: true, taskId: 'task-1'});
        }
      },
      storage: {
        local: {get: (_keys, callback) => callback && callback({interceptDownloads: true})},
        session: {get: (_keys, callback) => callback && callback({}), set() {}},
        onChanged: event()
      },
      contextMenus: {create() {}, onClicked: event()},
      cookies: {getAll: (_query, callback) => callback && callback([])},
      downloads: {
        onCreated: event(), onDeterminingFilename: event(), onChanged: event(),
        cancel: (_id, callback) => callback && callback(),
        erase: (_query, callback) => callback && callback(),
        download() {}
      },
      webRequest: {onBeforeSendHeaders: event(), onBeforeRedirect: event(), onResponseStarted: event()},
      tabs: {onRemoved: event(), onUpdated: event(), sendMessage: () => Promise.resolve()},
      webNavigation: {onHistoryStateUpdated: event()},
      action: {setBadgeText() {}, setBadgeBackgroundColor() {}}
    }
  });
  vm.runInContext(BACKGROUND, context);
  assert.equal(typeof onMessageHandler, 'function', 'background.js phải đăng ký runtime.onMessage');
  return {context, onMessageHandler, sentToHost};
}

test('(d) autoStart được chuyển tiếp trong native payload (content → background)', () => {
  // Content gửi autoStart:true khi setting bật.
  const content = dispatchEnvironment({autoStart: true, respond: (_m, cb) => cb({success: true, taskId: 't'})});
  content.context.dispatchDownload('https://cdn.example.com/video.mp4', null);
  assert.equal(content.sent[0].message.autoStart, true, 'Content phải gửi autoStart:true');

  const background = backgroundEnvironment();
  let reply;
  background.onMessageHandler(
    {action: 'download_media', url: 'https://cdn.example.com/video.mp4', filename: 'Video.mp4', autoStart: true},
    {tab: {id: 3, url: 'https://example.com/watch'}},
    (response) => { reply = response; }
  );
  assert.equal(background.sentToHost.length, 1);
  assert.equal(background.sentToHost[0].action, 'start_download');
  assert.equal(background.sentToHost[0].autoStart, true, 'Native payload phải mang autoStart:true');
  assert.equal(reply.success, true);

  // Mặc định (không bật) → false, không bỏ field để app luôn decode được.
  const off = backgroundEnvironment();
  off.onMessageHandler(
    {action: 'download_media', url: 'https://cdn.example.com/video2.mp4', filename: 'Video2.mp4'},
    {tab: {id: 4, url: 'https://example.com/watch'}},
    () => {}
  );
  assert.equal(off.sentToHost[0].autoStart, false, 'Không bật autoStart thì payload phải là false');
});

test('(e) ping_host trả cả hai version và báo mismatch khi app cũ hơn', () => {
  const oldApp = backgroundEnvironment({
    nativeResponse: (payload) => payload.action === 'hello'
      ? {success: true, extra: {protocolVersion: '2', appVersion: '1.1.0'}}
      : {success: true, taskId: 'task'}
  });
  let oldReply;
  oldApp.onMessageHandler({action: 'ping_host'}, {}, (response) => { oldReply = response; });
  assert.equal(oldReply.success, false, 'Version lệch phải fail handshake');
  assert.equal(oldReply.versionMismatch, true);
  assert.equal(oldReply.appVersion, '1.1.0');
  assert.equal(oldReply.expectedAppVersion, '1.2.0');
  assert.equal(oldReply.extensionVersion, '1.4.0', 'Extension version đọc từ manifest');
  assert.equal(oldReply.code, 'protocol_mismatch');

  const sameApp = backgroundEnvironment({
    nativeResponse: (payload) => payload.action === 'hello'
      ? {success: true, extra: {protocolVersion: '2', appVersion: '1.2.0'}}
      : {success: true, taskId: 'task'}
  });
  let okReply;
  sameApp.onMessageHandler({action: 'ping_host'}, {}, (response) => { okReply = response; });
  assert.equal(okReply.success, true);
  assert.equal(okReply.versionMismatch, false);
  assert.equal(okReply.appVersion, '1.2.0');
  assert.equal(okReply.extensionVersion, '1.4.0');
});

test('(e) browser-transfer hello dùng IDM_EXPECTED_APP_VERSION và từ chối app cũ', async () => {
  const listeners = {};
  const event = (name) => ({addListener(fn) { listeners[name] = fn; }});
  const context = vm.createContext({
    console, crypto: crypto.webcrypto, setTimeout, clearTimeout, setInterval, clearInterval, URL,
    chrome: {
      runtime: {onMessage: event('message')},
      downloads: {onCreated: event('created'), onChanged: event('changed')},
      tabs: {onRemoved: event('removed'), sendMessage: async () => {}},
      webNavigation: {onCommitted: event('navigation')}
    }
  });
  const code = fs.readFileSync('Extension/browser-transfer.js', 'utf8');
  vm.runInContext(code, context);
  assert.equal(vm.runInContext('IDM_EXPECTED_APP_VERSION', context), '1.2.0',
    'browser-transfer.js phải là nguồn duy nhất của expected app version');

  // hello trả app cũ 1.1.0 → phải reject trước khi tạo phiên.
  let receive;
  context.chrome.scripting = {executeScript: async () => [{result: true}]};
  context.chrome.runtime.connectNative = () => ({
    onMessage: {addListener(handler) { receive = handler; }},
    onDisconnect: {addListener() {}},
    postMessage(payload) {
      receive({requestId: payload.requestId, success: true,
        extra: payload.action === 'hello' ? {appVersion: '1.1.0', protocolVersion: '2'} : {}});
    }
  });
  await assert.rejects(
    context.startBrowserJob({selection: {handle: crypto.randomUUID(), mediaKind: 'video'}}, {tab: {id: 7}, frameId: 0}),
    /cùng phiên bản/
  );
});

test('(e) map mã lỗi app sang thông điệp tiếng Việt, mã lạ vẫn giữ mã', () => {
  const context = vm.createContext({console, URL, setTimeout, clearTimeout,
    chrome: {runtime: {lastError: null, sendMessage() {}}}});
  vm.runInContext(ERROR_HELPERS_CODE, context);

  assert.match(context.mapDownloadError({code: 'protocol_mismatch'}), /phiên bản/);
  assert.match(context.mapDownloadError({code: 'browser_source_required'}), /Chrome/);
  assert.match(context.mapDownloadError({code: 'invalid_url'}), /bấm phát video/);
  assert.match(context.mapDownloadError({code: 'app_not_running'}), /mở Internet Downloader/);
  assert.match(context.mapDownloadError({code: 'bad_request'}), /mở Internet Downloader/);
  assert.match(context.mapDownloadError({code: 'unknown_code', error: 'Lỗi'}), /\(mã: unknown_code\)/);
  assert.equal(vm.runInContext('WATCHDOG_TIMEOUT_MS', context), 12000);
  assert.match(vm.runInContext('APP_NO_RESPONSE_MESSAGE', context), /App không phản hồi/);
});

test('(f) popup có toggle autoStart, hàng version và manifest 1.4.0', () => {
  const html = fs.readFileSync('Extension/popup/popup.html', 'utf8');
  const js = fs.readFileSync('Extension/popup/popup.js', 'utf8');
  assert.match(html, /id="toggleAutoStart"/, 'Popup phải có toggle autoStart');
  assert.match(html, /id="versionInfo"/, 'Popup phải hiện version app + extension');
  assert.match(html, /id="versionWarning"/, 'Popup phải có hàng cảnh báo lệch version');
  assert.match(js, /autoStartBrowserDownloads/);
  assert.match(js, /versionMismatch/);
  assert.match(js, /getManifest\(\)\.version/, 'Extension version đọc từ manifest');
  assert.equal(MANIFEST.version, '1.4.0', 'manifest.json phải là 1.4.0');
});
