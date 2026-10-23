// Native browser protocol 2. No URL, page locator, cookie or token is persisted.
//
// Single source of truth cho phiên bản handshake phía extension. Mirror của
// `AppVersion.appVersion` trong Sources/DownloaderCore/AppVersion.swift:
// importScripts() nạp file này trước tiên trong background.js nên hằng số dùng
// chung được cho cả hello check lẫn ping_host. Lệch phiên bản là nguyên nhân
// khiến người dùng "bấm tải mà không có gì xảy ra" — luôn giữ khớp với app.
const IDM_EXPECTED_APP_VERSION = '1.2.0';

const browserJobs = new Map();
const browserSelections = new Map();
// D-F7: persist tối thiểu browserJobs vào chrome.storage.session để sống sót
// qua SW suspend/wake; resume phiên needs_confirmation, reject phiên dở dang.
// Mọi truy cập storage.session đều bọc try — thiếu API thì fallback RAM.
const BROWSER_JOBS_KEY = 'idm_browser_jobs';
function persistBrowserJobs() {
  try {
    if (!chrome.storage || !chrome.storage.session || typeof chrome.storage.session.set !== 'function') return;
    const minimal = [...browserJobs.values()].map(job => ({
      sessionId: job.sessionId, taskId: job.taskId, token: job.token,
      tabId: job.tabId, frameId: job.frameId, handle: job.handle, source: job.source,
      filename: job.filename, mediaKind: job.mediaKind, expectedDuration: job.expectedDuration,
      requiresConfirmation: !!job.requiresConfirmation, phase: job.phase, message: job.message,
      verification: job.verification, downloadId: job.downloadId,
      intents: Array.isArray(job.intents) ? job.intents : [],
      existing: job.existing ? [...job.existing] : []
    }));
    chrome.storage.session.set({ [BROWSER_JOBS_KEY]: minimal }, () => {
      try { void chrome.runtime.lastError; } catch (_) {}
    });
  } catch (_) { /* fallback RAM: Map vẫn giữ jobs trong phiên SW hiện tại */ }
}
function armBrowserHeartbeat(job) {
  try { if (job.heartbeat) clearInterval(job.heartbeat); } catch (_) {}
  job.heartbeat = setInterval(async () => {
    if (!browserJobs.has(job.sessionId)) return;
    try {
      await jobCommand(job, 'browser_poll');
      // Save As may block page JavaScript. Keep the app capability alive while
      // a single selection check waits; navigation/tab-close events still cancel.
      if (!job.checking) {
        job.checking = true;
        checkBrowserSelection(job).catch(error => { if (browserJobs.has(job.sessionId)) failBrowserJob(job, error); })
          .finally(() => { job.checking = false; });
      }
    } catch (error) {
      if (error.code === 'invalid_transfer' && job.phase === 'importing') return;
      if (browserJobs.has(job.sessionId) && job.phase !== 'completed') await failBrowserJob(job, error);
    }
  }, 2000);
}
function resumeBrowserJobs(saved) {
  for (const entry of saved) {
    try {
      if (!entry || !entry.sessionId) continue;
      if (entry.phase === 'completed' || entry.phase === 'failed') continue;
      const job = { ...entry, observed: new Map(), existing: new Set(entry.existing || []), checking: false };
      if (entry.phase === 'needs_confirmation') {
        // Resume: giữ phiên chờ user xác nhận file, dựng lại heartbeat.
        browserJobs.set(job.sessionId, job);
        armBrowserHeartbeat(job);
        browserPhase(job, 'needs_confirmation', job.message || 'Chọn đúng file Chrome đã hoàn tất trong extension');
      } else {
        // Reject: phiên dở dang (saving_browser/importing/...) không thể tiếp
        // tục an toàn sau wake — báo failed để user bấm lại.
        browserJobs.set(job.sessionId, job);
        failBrowserJob(job, Object.assign(Error('Phiên tải bị gián đoạn khi extension khởi động lại. Chọn lại mục.'), { code: 'browser_reconnect' }));
      }
    } catch (_) {}
  }
  persistBrowserJobs();
}
try {
  if (chrome.storage && chrome.storage.session && typeof chrome.storage.session.get === 'function') {
    chrome.storage.session.get([BROWSER_JOBS_KEY], (res) => {
      try {
        try { void chrome.runtime.lastError; } catch (_) {}
        const saved = res && res[BROWSER_JOBS_KEY];
        if (Array.isArray(saved) && saved.length) resumeBrowserJobs(saved);
      } catch (_) {}
    });
  }
} catch (_) {}
let browserPort;
let nativeIdleTimer;
function closeIdleNative() {
  clearTimeout(nativeIdleTimer);
  nativeIdleTimer = setTimeout(() => { if (!browserJobs.size && !nativePending.size) browserPort?.disconnect(); }, 5000);
}
let observingSave = Promise.resolve();
const nativePending = new Map();
function browserNative(payload, timeout = 40000) {
  clearTimeout(nativeIdleTimer);
  if (!browserPort) {
    browserPort = chrome.runtime.connectNative('com.internetdownloader.host');
    browserPort.onMessage.addListener(response => {
      const pending = nativePending.get(response.requestId);
      if (!pending) return;
      nativePending.delete(response.requestId); clearTimeout(pending.timer);
      if (response.success === true) pending.resolve(response);
      else pending.reject(Object.assign(Error(response.message || 'App từ chối tác vụ'), {code: response.extra?.code || 'native_host_error'}));
    });
    browserPort.onDisconnect.addListener(() => {
      const message = chrome.runtime.lastError?.message || 'Phiên native host đã mất';
      browserPort = null;
      for (const pending of nativePending.values()) { clearTimeout(pending.timer); pending.reject(Error(message)); }
      nativePending.clear();
      for (const job of browserJobs.values()) browserPhase(job, 'failed', message);
      browserJobs.clear();
    });
  }
  const requestId = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timer = timeout ? setTimeout(() => { nativePending.delete(requestId); reject(Error('Native host không phản hồi')); }, timeout) : null;
    nativePending.set(requestId, {resolve, reject, timer});
    browserPort.postMessage({...payload, protocolVersion: 2, requestId});
  });
}
function jobCommand(job, action, fields = {}, timeout) {
  return browserNative({action, taskId: job.taskId, browser: {sessionId: job.sessionId, token: job.token, ...fields}}, timeout);
}
function browserPhase(job, phase, message, verification) {
  job.phase = phase; job.message = message; job.verification = verification || job.verification || 'NOT VERIFIED';
  chrome.runtime.sendMessage({action: 'browser_status_changed', sessionId: job.sessionId, phase, message, verification: job.verification}).catch(() => {});
  chrome.tabs.sendMessage(job.tabId, {action: 'browser_phase', handle: job.handle, phase, message, verification: job.verification}, {frameId: job.frameId}).catch(() => {});
  persistBrowserJobs();
}
async function checkBrowserSelection(job) {
  const [result] = await chrome.scripting.executeScript({target: {tabId: job.tabId, frameIds: [job.frameId]},
    func: handle => !!window.__idmBrowser?.check(handle), args: [job.handle]});
  if (!result?.result) throw Object.assign(Error('Mục đã thay đổi. Chọn lại trong Chrome.'), {code: 'source_changed'});
}
// This function runs synchronously in MAIN only around the selected native Save.
// Async URL generation has no automatic selection proof.
// D-F5: mirror spinner-check của telegram isSave — nút đang loading
// (ProgressSpinner/progress-spinner/role=progressbar) không phải Save sẵn sàng.
function isSaveControlBusy(save) {
  try {
    if (!save || typeof save.querySelector !== 'function') return false;
    return !!save.querySelector('.ProgressSpinner,.progress-spinner,[role="progressbar"]');
  } catch (_) { return false; }
}
function triggerBrowserSave(handle, source) {
  const selected = document.querySelector(`[data-idm-selected="${handle}"]`);
  const save = document.querySelector(`[data-idm-save="${handle}"]`);
  if (!selected || (selected.currentSrc || selected.src || selected.href || '') !== source || !save || save.disabled || save.getAttribute?.('aria-disabled') === 'true') return {error: 'source_changed'};
  if (isSaveControlBusy(save)) return {error: 'website_save_not_ready'};
  const intents = []; const add = value => { try { intents.push(new URL(value, location.href).href); } catch {} };
  const oldClick = HTMLAnchorElement.prototype.click, oldOpen = window.open;
  const descriptor = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'src');
  HTMLAnchorElement.prototype.click = function(...args) { if (this.href) add(this.href); return oldClick.apply(this, args); };
  window.open = function(url, ...args) { if (url) add(url); return oldOpen.call(this, url, ...args); };
  if (descriptor?.set) Object.defineProperty(HTMLIFrameElement.prototype, 'src', {...descriptor, set(value) { if (value) add(value); return descriptor.set.call(this, value); }});
  try { save.click(); }
  finally { HTMLAnchorElement.prototype.click = oldClick; window.open = oldOpen; if (descriptor) Object.defineProperty(HTMLIFrameElement.prototype, 'src', descriptor); }
  return {intents: [...new Set(intents)]};
}
function exactDownload(intents, items) {
  const matches = items.filter(x => intents.includes(x.url) || intents.includes(x.finalUrl));
  return matches.length === 1 ? matches[0] : null;
}
async function pollUntilSlot(job) {
  for (;;) {
    await checkBrowserSelection(job);
    const response = await jobCommand(job, 'browser_poll');
    if (response.extra?.status === 'downloading') return;
    if (response.extra?.status !== 'pending') throw Error('Tác vụ không còn chờ tải');
    await new Promise(resolve => setTimeout(resolve, 500));
  }
}
async function importBrowserFile(job, item, confirmed = false) {
  if (item.state !== 'complete' || !item.filename) throw Error('File Chrome chưa hoàn tất');
  await checkBrowserSelection(job);
  if (confirmed) { await jobCommand(job, 'browser_confirm'); await pollUntilSlot(job); }
  browserPhase(job, 'importing', 'Đang nhập/kiểm tra');
  const response = await jobCommand(job, 'browser_copy', {downloadId: item.id, downloadState: item.state, sourcePath: item.filename,
    selectionProof: confirmed ? 'user_confirmed_file' : 'native_action_exact_url'}, 0);
  if (response.extra?.status !== 'completed') throw Error('App chưa xác nhận hoàn tất');
  browserPhase(job, 'completed', 'Hoàn tất', response.extra.verification);
  clearInterval(job.heartbeat); browserJobs.delete(job.sessionId); persistBrowserJobs(); closeIdleNative();
}
async function failBrowserJob(job, error) {
  if (!browserJobs.has(job.sessionId) || job.ending) return;
  job.ending = true;
  clearInterval(job.heartbeat);
  await jobCommand(job, 'browser_failure', {errorCode: error.code || 'browser_transfer_failed'}).catch(() => {});
  browserPhase(job, 'failed', error.message || String(error)); browserJobs.delete(job.sessionId); persistBrowserJobs(); closeIdleNative();
}
async function startBrowserJob(message, sender) {
  if (!sender.tab || !Number.isInteger(sender.frameId) || !/^[a-f0-9-]{36}$/.test(message.selection?.handle || '')) throw Error('Lựa chọn không hợp lệ');
  const job = {...message.selection, tabId: sender.tab.id, frameId: sender.frameId, sessionId: crypto.randomUUID(), phase: 'discovering', observed: new Map()};
  await checkBrowserSelection(job);
  const hello = await browserNative({action: 'hello'});
  if (hello.extra?.appVersion !== IDM_EXPECTED_APP_VERSION || hello.extra?.protocolVersion !== '2') throw Error('Cần cập nhật app và extension cùng phiên bản');
  const created = await browserNative({action: 'browser_create', browser: {sessionId: job.sessionId, mediaKind: job.mediaKind,
    filename: job.filename, expectedDuration: job.expectedDuration}});
  if (!created.taskId || !created.extra?.token) throw Error('App chưa trả taskId/token');
  job.taskId = created.taskId; job.token = created.extra.token; browserJobs.set(job.sessionId, job);
  browserPhase(job, 'accepted', 'App đã nhận tác vụ');
  armBrowserHeartbeat(job);
  // Return acceptance immediately; subsequent phases arrive through content messages.
  runBrowserSave(job).catch(error => failBrowserJob(job, error));
  return {success: true, taskId: job.taskId, sessionId: job.sessionId};
}
async function runBrowserSave(job) {
  await pollUntilSlot(job);
  // Serialize action observation across browser jobs, while completed correlations
  // continue downloading in parallel under the shared two-job app queue.
  const previous = observingSave; let unlock;
  observingSave = new Promise(resolve => { unlock = resolve; });
  await previous;
  try { await observeBrowserSave(job); } finally { unlock(); }
  if (job.downloadId === undefined) return;
  for (;;) {
    await checkBrowserSelection(job);
    const [item] = await chrome.downloads.search({id: job.downloadId});
    if (!item || item.state === 'interrupted') throw Error('Chrome đã hủy hoặc gián đoạn tải');
    if (item.state === 'complete') { await importBrowserFile(job, item); return; }
    await new Promise(resolve => setTimeout(resolve, 500));
  }
}
async function observeBrowserSave(job) {
  await checkBrowserSelection(job); browserPhase(job, 'saving_browser', 'Đang lưu qua Chrome');
  // Snapshot is used only to exclude already existing downloads, never as proof.
  const before = await chrome.downloads.search({}); job.existing = new Set(before.map(x => x.id));
  await chrome.scripting.executeScript({target: {tabId: job.tabId, frameIds: [job.frameId]}, func: handle => window.__idmBrowser.markSaving(handle), args: [job.handle]});
  job.armed = true;
  const deadline = Date.now() + 16000;
  let deadlineTimer;
  const results = await Promise.race([
    chrome.scripting.executeScript({target: {tabId: job.tabId, frameIds: [job.frameId]}, world: 'MAIN', func: triggerBrowserSave, args: [job.handle, job.source]}),
    new Promise(resolve => { deadlineTimer = setTimeout(() => resolve([]), 16000); })
  ]);
  clearTimeout(deadlineTimer);
  const [result] = results;
  if (result?.result?.error) throw Object.assign(Error('Mục đã thay đổi'), {code: result.result.error});
  job.intents = result?.result?.intents || [];
  while (Date.now() < deadline) {
    await checkBrowserSelection(job);
    const match = job.requiresConfirmation ? null : exactDownload(job.intents, [...job.observed.values()]);
    if (match) { job.downloadId = match.id; break; }
    await new Promise(resolve => setTimeout(resolve, 150));
  }
  job.armed = false;
  if (job.downloadId === undefined) {
    await jobCommand(job, 'browser_failure', {errorCode: 'needs_confirmation'});
    browserPhase(job, 'needs_confirmation', 'Chọn đúng file Chrome đã hoàn tất trong extension'); return;
  }

}
chrome.downloads.onCreated.addListener(item => {
  for (const job of browserJobs.values()) if (job.armed && !job.existing?.has(item.id)) job.observed.set(item.id, item);
});
chrome.downloads.onChanged.addListener(async change => {
  for (const job of browserJobs.values()) if (job.observed.has(change.id)) {
    const [item] = await chrome.downloads.search({id: change.id}); if (item) job.observed.set(item.id, item);
  }
});
chrome.tabs.onRemoved.addListener(tabId => { for (const job of browserJobs.values()) if (job.tabId === tabId) failBrowserJob(job, Object.assign(Error('Tab đã đóng. Chọn lại mục.'), {code: 'browser_reconnect'})); });
chrome.webNavigation.onCommitted.addListener(details => { for (const job of browserJobs.values()) if (job.tabId === details.tabId && job.frameId === details.frameId) failBrowserJob(job, Object.assign(Error('Trang đã điều hướng. Chọn lại mục.'), {code: 'browser_reconnect'})); });
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  let work;
  if (message.action === 'browser_start') work = startBrowserJob(message, sender);
  if (message.action === 'browser_scan' && !sender.tab) work = (async () => {
    const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
    if (!tab) throw Error('Chưa chọn tab');
    const frames = await chrome.scripting.executeScript({target: {tabId: tab.id, allFrames: true}, func: () => window.__idmBrowser?.scan() || []});
    const selections = [];
    for (const frame of frames) for (const selection of frame.result || []) {
      browserSelections.set(selection.handle, {selection, tab, frameId: frame.frameId});
      selections.push({handle: selection.handle, mediaKind: selection.mediaKind});
    }
    return {success: true, selections};
  })();
  if (message.action === 'browser_pick' && !sender.tab) work = (async () => {
    const entry = browserSelections.get(message.handle); browserSelections.delete(message.handle);
    if (!entry) throw Error('Lựa chọn đã mất. Quét lại tab.');
    return await startBrowserJob({selection: entry.selection}, {tab: entry.tab, frameId: entry.frameId});
  })();
  // D-F11: kèm intents + requiresConfirmation để popup lọc dropdown theo nguồn đã bấm.
  if (message.action === 'browser_jobs') work = Promise.resolve({success: true, jobs: [...browserJobs.values()].map(x => ({sessionId: x.sessionId, phase: x.phase, message: x.message, requiresConfirmation: !!x.requiresConfirmation, intents: Array.isArray(x.intents) ? x.intents : []}))});
  if (message.action === 'browser_confirm_file' && !sender.tab) work = (async () => {
    const job = browserJobs.get(message.sessionId);
    if (!job || job.phase !== 'needs_confirmation') throw Error('Phiên xác nhận đã mất');
    const [item] = await chrome.downloads.search({id: message.downloadId});
    try { await importBrowserFile(job, item, true); }
    catch (error) { await failBrowserJob(job, error); throw error; }
    return {success: true};
  })();
  if (message.action === 'browser_cancel') work = (async () => {
    const job = browserJobs.get(message.sessionId);
    if (job) { if (job.downloadId !== undefined) await chrome.downloads.cancel(job.downloadId).catch(() => {}); await failBrowserJob(job, Object.assign(Error('Đã hủy'), {code: 'browser_cancelled'})); }
    return {success: true};
  })();
  if (!work) return;
  work.then(respond, error => respond({success: false, error: error.message, code: error.code})); return true;
});
