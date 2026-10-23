importScripts("browser-transfer.js");
// Internet Downloader Integration Module - Background Service Worker

const HOST_NAME = "com.internetdownloader.host";

// Trả về version từ manifest (hiển thị ở popup + ping_host). Không hardcode:
// manifest.json là nguồn duy nhất cho phiên bản extension.
function currentExtensionVersion() {
  try {
    return chrome.runtime.getManifest().version;
  } catch (_) {
    return null;
  }
}

// `IDM_EXPECTED_APP_VERSION` được khai báo trong browser-transfer.js (nạp bằng
// importScripts ở dòng đầu) — dùng chung cho browser handshake và ping_host.
function expectedAppVersion() {
  try {
    return IDM_EXPECTED_APP_VERSION;
  } catch (_) {
    return null;
  }
}

// Khởi tạo cài đặt mặc định
chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.local.get(["interceptDownloads", "showFloatingBar", "sniffImages", "autoStartBrowserDownloads"], (res) => {
    if (res.interceptDownloads === undefined) {
      chrome.storage.local.set({ interceptDownloads: true });
    }
    if (res.showFloatingBar === undefined) {
      chrome.storage.local.set({ showFloatingBar: true });
    }
    if (res.sniffImages === undefined) {
      chrome.storage.local.set({ sniffImages: true });
    }
    // Mặc định TẮT: app vẫn hỏi xác nhận trước khi tải.
    if (res.autoStartBrowserDownloads === undefined) {
      chrome.storage.local.set({ autoStartBrowserDownloads: false });
    }
  });

  // Tạo Context Menus
  chrome.contextMenus.create({
    id: "idm_download_link",
    title: "Tải liên kết bằng Internet Downloader",
    contexts: ["link"]
  });

  chrome.contextMenus.create({
    id: "idm_download_media",
    title: "Tải video/âm thanh này bằng Internet Downloader",
    contexts: ["video", "audio"]
  });

  chrome.contextMenus.create({
    id: "idm_download_image",
    title: "Tải hình ảnh này bằng Internet Downloader",
    contexts: ["image"]
  });

  chrome.contextMenus.create({
    id: "idm_batch_download",
    title: "Quét & Tải toàn bộ media trên trang này (Batch Grabber)",
    contexts: ["page"]
  });
});

// Xử lý Context Menus
chrome.contextMenus.onClicked.addListener((info, tab) => {
  const tabId = tab ? tab.id : null;
  if (info.menuItemId === "idm_download_link" && info.linkUrl) {
    sendDownloadToHost({
      url: info.linkUrl,
      referrer: tab ? tab.url : "",
      filename: ""
    }, null, tabId);
  } else if (info.menuItemId === "idm_download_media" && info.srcUrl) {
    sendDownloadToHost({
      url: info.srcUrl,
      referrer: tab ? tab.url : "",
      filename: ""
    }, null, tabId);
  } else if (info.menuItemId === "idm_download_image" && info.srcUrl) {
    sendDownloadToHost({
      url: info.srcUrl,
      referrer: tab ? tab.url : "",
      filename: ""
    }, null, tabId);
  } else if (info.menuItemId === "idm_batch_download" && tab && tab.id) {
    chrome.tabs.sendMessage(tab.id, { action: "open_batch_grabber" }).catch(() => {});
  }
});

const capturedMediaByTab = {};
const tabUrls = {};
const capturedHeadersByUrl = {};
const capturedResponseMetaByUrl = {};
const capturedRedirectByUrl = {};
const interceptedDownloadIds = new Set();
const interceptedDownloadMeta = new Map();
const recentHandedOffUrls = new Map();
let interceptDownloadsEnabled = true;

// MV3 service worker bị kill sau idle — lấy lại state nóng từ storage.session
// (sống sót qua restart SW) để không mất headers/dedup ngay sau khi wake.
// D-F6: mọi handoff (sendDownloadToHost/intercept) đi qua promise hydrate:
// chưa ready thì xếp hàng pendingHandoffQueue, flush sau khi ready.
const SESSION_KEY = "idm_sw_state";
let sessionHydrated = false;
let sessionReadyResolve = null;
const sessionReady = new Promise((resolve) => { sessionReadyResolve = resolve; });
const pendingHandoffQueue = [];
function flushPendingHandoffs() {
  try {
    while (pendingHandoffQueue.length) {
      const next = pendingHandoffQueue.shift();
      if (next) sendDownloadToHost(next.data, next.callback, next.tabId, next.options);
    }
  } catch (_) {}
}
function hydrateSessionState() {
  if (sessionHydrated || !chrome.storage?.session) {
    sessionHydrated = true;
    try { if (sessionReadyResolve) sessionReadyResolve(); } catch (_) {}
    return Promise.resolve();
  }
  let hydrateDone = false;
  const finishHydrate = () => {
    if (hydrateDone) return;
    hydrateDone = true;
    sessionHydrated = true;
    try { if (sessionReadyResolve) sessionReadyResolve(); } catch (_) {}
    flushPendingHandoffs();
  };
  return new Promise((resolve) => {
    const done = () => { finishHydrate(); resolve(); };
    try {
      chrome.storage.session.get([SESSION_KEY], (res) => {
        // Callback muộn (sau fail-open timeout) vẫn áp restore — các map
        // chỉ cộng thêm nên an toàn.
        try {
          try { void chrome.runtime.lastError; } catch (_) {}
          const saved = res && res[SESSION_KEY];
          if (saved) {
            for (const [k, v] of Object.entries(saved.headers || {})) capturedHeadersByUrl[k] = v;
            for (const [k, v] of Object.entries(saved.redirects || {})) capturedRedirectByUrl[k] = v;
            for (const [k, v] of Object.entries(saved.handoffs || {})) recentHandedOffUrls.set(k, v);
            for (const id of saved.intercepted || []) interceptedDownloadIds.add(id);
          }
        } catch (_) {}
        done();
      });
    } catch (_) { done(); return; }
    // Fail-open: storage.session không callback (mock/test) thì vẫn tiếp tục
    // bằng RAM sau timeout ngắn — không bao giờ treo handoff.
    try {
      setTimeout(() => { done(); }, 500);
    } catch (_) { done(); }
  });
}
function persistSessionState() {
  if (!chrome.storage?.session) return;
  try {
    chrome.storage.session.set({ [SESSION_KEY]: {
      headers: capturedHeadersByUrl,
      redirects: capturedRedirectByUrl,
      handoffs: Object.fromEntries(recentHandedOffUrls),
      intercepted: [...interceptedDownloadIds]
    } });
  } catch (_) {}
}
hydrateSessionState();

function getRedirectChainUrls(...seedUrls) {
  const seen = new Set();
  const result = [];
  for (const startUrl of seedUrls) {
    let current = startUrl;
    let hops = 0;
    while (current && !seen.has(current) && hops < 10) {
      seen.add(current);
      result.push(current);
      current = (typeof capturedRedirectByUrl !== "undefined" && capturedRedirectByUrl[current]) || "";
      hops++;
    }
  }
  return result;
}

function resolveRedirectTarget(url) {
  if (!url || typeof capturedRedirectByUrl === "undefined") return url || "";
  const chain = getRedirectChainUrls(url);
  return chain.length > 0 ? chain[chain.length - 1] : url;
}

if (chrome.storage && chrome.storage.local) {
  chrome.storage.local.get(["interceptDownloads"], (res) => {
    if (res && res.interceptDownloads !== undefined) {
      interceptDownloadsEnabled = Boolean(res.interceptDownloads);
    }
  });
}
if (chrome.storage && chrome.storage.onChanged) {
  chrome.storage.onChanged.addListener((changes) => {
    if (changes && changes.interceptDownloads !== undefined) {
      interceptDownloadsEnabled = Boolean(changes.interceptDownloads.newValue);
    }
  });
}

function parseDispositionFilename(disposition) {
  if (!disposition || typeof disposition !== "string") return "";
  const items = disposition.replace(/\+/g, " ").split(";").map(s => s.trim());
  let standard = "";
  for (const part of items) {
    const lower = part.toLowerCase();
    if (lower.startsWith("filename*=")) {
      const val = part.slice("filename*=".length);
      const utf8Part = val.split("''").pop() || val;
      try {
        const decoded = decodeURIComponent(utf8Part).split(/[\\/]/).pop().replace(/^["']|["']$/g, "").trim();
        if (decoded && decoded !== "." && decoded !== "..") return decoded;
      } catch (_) {}
    } else if (lower.startsWith("filename=") && !standard) {
      let val = part.slice("filename=".length).trim();
      if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
        val = val.slice(1, -1);
      }
      try { val = decodeURIComponent(val); } catch (_) {}
      const clean = val.split(/[\\/]/).pop().replace(/^["']|["']$/g, "").trim();
      if (clean && clean !== "." && clean !== "..") standard = clean;
    }
  }
  return standard;
}

function isOpaqueFilename(name) {
  if (!name || typeof name !== "string") return true;
  const clean = name.trim();
  if (!clean || clean === "download" || clean === "Tệp tin") return true;
  const dotIdx = clean.lastIndexOf(".");
  if (dotIdx > 0 && dotIdx < clean.length - 1) {
    const ext = clean.slice(dotIdx + 1).toLowerCase();
    if (ext.length <= 6 && !/^\d+$/.test(ext)) return false;
  }
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(clean)) return true;
  if (/^[0-9a-f]{32,64}$/i.test(clean)) return true;
  if (/^\d+$/.test(clean)) return true;
  return dotIdx <= 0;
}

function extractQueryFilename(urlStr) {
  if (!urlStr || typeof urlStr !== "string") return "";
  try {
    const u = new URL(urlStr);
    for (const [k, v] of u.searchParams.entries()) {
      const lk = k.toLowerCase();
      if (lk === "rscd" || lk === "response-content-disposition") {
        const parsed = parseDispositionFilename(v);
        if (parsed) return parsed;
      }
    }
    for (const [k, v] of u.searchParams.entries()) {
      const lk = k.toLowerCase();
      if (["filename", "response-filename", "download_filename", "name", "file"].includes(lk) && v) {
        const clean = v.split(/[\\/]/).pop().replace(/^["']|["']$/g, "").trim();
        if (clean && clean.includes(".") && clean !== "." && clean !== "..") return clean;
      }
    }
  } catch (_) {}
  return "";
}

function resolveBestFilename(data) {
  if (!data) return "";
  if (data.filename) {
    const base = String(data.filename).split(/[\\/]/).pop().trim();
    if (base && !isOpaqueFilename(base)) return base;
  }
  const redirected = resolveRedirectTarget(data.originalUrl || data.url);
  const urls = getRedirectChainUrls(data.finalUrl, redirected, data.url, data.originalUrl);
  if (typeof capturedResponseMetaByUrl !== "undefined") {
    for (const u of urls) {
      const meta = capturedResponseMetaByUrl[u];
      if (meta && meta.contentDisposition) {
        const fromHeader = parseDispositionFilename(meta.contentDisposition);
        if (fromHeader && !isOpaqueFilename(fromHeader)) return fromHeader;
      }
    }
  }
  for (const u of urls) {
    const fromQuery = extractQueryFilename(u);
    if (fromQuery) return fromQuery;
  }
  for (const u of urls) {
    const lastPart = String(u).split("?")[0].split("#")[0].split("/").pop() || "";
    try {
      const decoded = decodeURIComponent(lastPart).trim();
      if (decoded && !isOpaqueFilename(decoded)) return decoded;
    } catch (_) {
      if (lastPart && !isOpaqueFilename(lastPart)) return lastPart;
    }
  }
  if (data.filename) {
    return String(data.filename).split(/[\\/]/).pop().trim();
  }
  return "";
}

// Khi handoff thất bại (app đóng/lỗi): khởi động lại download trong Chrome để
// file không bị mất, thay vì im lặng. Browser tự mang cookie của nó; headers /
// referrer đã capture được giữ lại trong capturedHeadersByUrl để lần handoff
// sau tái dùng (downloads API không cho gắn header tùy ý).
// D-F8: opts = { headers, referrer } giữ lại capture, không đánh mất auth.
function restartDownloadInBrowser(url, filename, opts = {}) {
  if (!url) return;
  try {
    if (opts.headers && typeof capturedHeadersByUrl !== "undefined") {
      capturedHeadersByUrl[url] = { ...(capturedHeadersByUrl[url] || {}), ...opts.headers };
    }
    if (chrome.downloads && typeof chrome.downloads.download === "function") {
      chrome.downloads.download({
        url: url,
        filename: filename && filename.includes(".") ? filename : undefined,
        conflictAction: "uniquify"
      }, () => {
        try { void chrome.runtime.lastError; } catch (_) {}
      });
    }
  } catch (_) {}
}
// D-F8: truyền tabId thật (tab active) thay vì null để toast tới đúng tab.
function notifyHandoffForItem(item, url) {
  try {
    if (chrome.tabs && typeof chrome.tabs.query === "function") {
      chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
        let tid = null;
        try {
          if (tabs && tabs[0] && Number.isInteger(tabs[0].id)) tid = tabs[0].id;
        } catch (_) {}
        notifyHandoffFailure(tid, url);
      });
    } else {
      notifyHandoffFailure(null, url);
    }
  } catch (_) {
    try { notifyHandoffFailure(null, url); } catch (_) {}
  }
}

function notifyHandoffFailure(tabId, url) {
  try {
    chrome.notifications.create({
      type: "basic",
      iconUrl: "icons/icon128.png",
      title: "Internet Downloader",
      message: "Không chuyển được sang app — tải tiếp trong trình duyệt."
    }, () => {});
  } catch (_) {}
  if (tabId && tabId >= 0) {
    chrome.tabs.sendMessage(tabId, {
      action: "show_download_toast",
      filename: String(url).split("/").pop().split("?")[0] || "Tệp tin",
      url: url,
      error: true
    }, { frameId: 0 }).catch(() => {});
  }
}

function interceptBrowserDownload(item) {
  if (!interceptDownloadsEnabled || !item || !item.url) return false;
  // A browser transfer owns Chrome's Save flow. Leave all concurrent downloads
  // alone until correlation/confirmation finishes; never cancel its input.
  if ((typeof browserJobs !== "undefined" && browserJobs.size) ||
      /^https:\/\/web\.telegram\.org\//i.test(item.url) ||
      /^https:\/\/web\.telegram\.org\//i.test(item.referrer || "")) {
    return false;
  }

  // Không can thiệp nếu là blob URL hoặc data URL
  if (item.url.startsWith("blob:") || item.url.startsWith("data:")) return false;

  const targetUrl = item.finalUrl || resolveRedirectTarget(item.url) || item.url;
  const bestFilename = resolveBestFilename({
    finalUrl: item.finalUrl || "",
    url: targetUrl,
    originalUrl: item.url,
    filename: item.filename || ""
  });

  if (interceptedDownloadIds.has(item.id)) {
    const prevMeta = interceptedDownloadMeta.get(item.id);
    if (prevMeta && isOpaqueFilename(prevMeta.filename) && bestFilename && !isOpaqueFilename(bestFilename)) {
      prevMeta.filename = bestFilename;
      sendDownloadToHost({
        url: targetUrl,
        originalUrl: item.url,
        filename: bestFilename,
        referrer: item.referrer || "",
        userAgent: navigator.userAgent
      }, (result) => {
        if (result?.success !== true) {
          restartDownloadInBrowser(targetUrl, bestFilename, { referrer: item.referrer || "" });
          notifyHandoffForItem(item, targetUrl);
        }
      }, null);
    }
    return true;
  }
  interceptedDownloadIds.add(item.id);
  interceptedDownloadMeta.set(item.id, { url: targetUrl, filename: bestFilename });
  if (interceptedDownloadIds.size > 500) {
    const oldest = interceptedDownloadIds.values().next().value;
    interceptedDownloadIds.delete(oldest);
    interceptedDownloadMeta.delete(oldest);
  }

  const now = Date.now();
  for (const candidateUrl of getRedirectChainUrls(targetUrl, item.url)) {
    const recent = recentHandedOffUrls.get(candidateUrl);
    if (recent && now - recent.ts < 3000) {
      if (isOpaqueFilename(recent.filename) && bestFilename && !isOpaqueFilename(bestFilename)) {
        recent.filename = bestFilename;
        break;
      }
      return true;
    }
  }

  // Hủy đồng bộ để chặn hộp thoại Save As của macOS (test khóa hợp đồng này).
  // D-F8: chỉ erase SAU KHI app ACK (giữ item để restart khi handoff lỗi);
  // nếu app không nhận thì restart trong Chrome + toast đúng tab.
  // Hủy giữ nguyên đồng bộ; handoff đi qua hàng đợi hydrate (D-F6).
  let capturedForRestart = {};
  try {
    if (typeof capturedHeadersByUrl !== "undefined") {
      for (const u of getRedirectChainUrls(targetUrl, item.url)) {
        if (u && capturedHeadersByUrl[u]) capturedForRestart = { ...capturedForRestart, ...capturedHeadersByUrl[u] };
      }
    }
  } catch (_) {}
  chrome.downloads.cancel(item.id, () => {
    try { void chrome.runtime.lastError; } catch (_) {}
  });
  sendDownloadToHost({
    url: targetUrl,
    originalUrl: item.url,
    filename: bestFilename,
    referrer: item.referrer || "",
    userAgent: navigator.userAgent
  }, (result) => {
    if (result?.success === true) {
      try {
        if (chrome.downloads && typeof chrome.downloads.erase === "function") {
          chrome.downloads.erase({ id: item.id }, () => {
            try { void chrome.runtime.lastError; } catch (_) {}
          });
        }
      } catch (_) {}
    } else {
      restartDownloadInBrowser(targetUrl, bestFilename, { headers: capturedForRestart, referrer: item.referrer || "" });
      notifyHandoffForItem(item, targetUrl);
    }
  }, null);
  return true;
}

// Bắt sự kiện tải file của trình duyệt đồng bộ ngay ở cả onDeterminingFilename và onCreated
if (chrome.downloads && chrome.downloads.onDeterminingFilename) {
  chrome.downloads.onDeterminingFilename.addListener((item, suggest) => {
    if (interceptBrowserDownload(item)) {
      // Giữ DownloadTargetDeterminer để chặn Save As dialog; không gọi suggest()
      // vì download đã bị cancel đồng bộ trong interceptBrowserDownload.
      return true;
    }
    if (typeof suggest === "function") {
      suggest();
    }
    return false;
  });
}
if (chrome.downloads && chrome.downloads.onCreated) {
  chrome.downloads.onCreated.addListener((item) => {
    interceptBrowserDownload(item);
  });
}


// Thu thập request headers (Origin, Referer, Authorization, Sec-Fetch-*, x-*) để gửi sang App
if (chrome.webRequest && chrome.webRequest.onBeforeSendHeaders) {
  chrome.webRequest.onBeforeSendHeaders.addListener(
    (details) => {
      if (!details || !details.url || details.tabId < 0) return;
      const headers = {};
      if (details.requestHeaders) {
        for (const h of details.requestHeaders) {
          const name = h.name.toLowerCase();
          if (name === "origin" || name === "referer" || name === "authorization" ||
              name.startsWith("sec-fetch-") || name.startsWith("x-")) {
            headers[h.name] = h.value;
          }
        }
      }
      if (details.initiator && !headers["Origin"] && details.initiator.startsWith("http")) {
        headers["Origin"] = details.initiator;
      }
      capturedHeadersByUrl[details.url] = headers;
      const keys = Object.keys(capturedHeadersByUrl);
      if (keys.length > 500) delete capturedHeadersByUrl[keys[0]];
      persistSessionState();
    },
    { urls: ["<all_urls>"] },
    ["requestHeaders", "extraHeaders"]
  );
}

if (chrome.webRequest && chrome.webRequest.onBeforeRedirect) {
  chrome.webRequest.onBeforeRedirect.addListener(
    (details) => {
      if (!details || !details.url || !details.redirectUrl || typeof capturedRedirectByUrl === "undefined") return;
      capturedRedirectByUrl[details.url] = details.redirectUrl;
      const keys = Object.keys(capturedRedirectByUrl);
      if (keys.length > 500) delete capturedRedirectByUrl[keys[0]];
      persistSessionState();
    },
    { urls: ["<all_urls>"] }
  );
}

// Lắng nghe luồng dữ liệu media thực tế từ WebRequest
if (chrome.webRequest && chrome.webRequest.onResponseStarted) {
  const AD_DOMAINS = [
    "adtng.com", "doubleclick.net", "googlesyndication.com", "adnxs.com",
    "advertising.com", "taboola.com", "outbrain.com", "scorecardresearch.com",
    "moatads.com", "serving-sys.com", "adroll.com", "rubiconproject.com",
    "smartadserver.com", "trafficjunky.com", "exoclick.com", "popads.net"
  ];

  const UI_SOUNDS = [
    "no_input.mp3", "open.mp3", "close.mp3", "click.mp3", "pop.mp3",
    "beep.mp3", "notify.mp3", "bell.mp3", "chime.mp3"
  ];

  function isMseRangeOrChunkUrl(urlStr) {
    if (!urlStr) return false;
    const lower = urlStr.toLowerCase();
    if (lower.includes("/videoplayback") || lower.includes("googlevideo.com")) return true;
    if (/[?&](range|bytestart|byteend|sq|ump|rbuf|srfvp)=/i.test(lower)) return true;
    return false;
  }

  function normalizeMediaStreamKey(urlStr) {
    if (!urlStr || typeof urlStr !== "string") return "";
    try {
      const u = new URL(urlStr);
      const transientParams = ["range", "rn", "rbuf", "sq", "bytestart", "byteend", "ump", "srfvp", "_", "t", "ts", "rand"];
      for (const p of transientParams) u.searchParams.delete(p);
      return u.origin + u.pathname + (u.searchParams.toString() ? "?" + u.searchParams.toString() : "");
    } catch (_) {
      return urlStr.split("#")[0];
    }
  }

  // D-F13: MIME-allowlist 2 phía (background) + sniff query-param
  // (?format=mp4, ?mime=video/mp4, ?ext=m3u8 cho download.php/v2.0/download...).
  const MEDIA_MIME_ALLOW = [
    "video/", "audio/",
    "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/x-mpegurl",
    "application/dash+xml", "application/vnd.ms-sstr+xml"
  ];
  function isAllowedMediaMime(mimeValue) {
    if (!mimeValue || typeof mimeValue !== "string") return false;
    const clean = mimeValue.toLowerCase().split(";")[0].trim();
    if (!clean || clean === "application/octet-stream") return false;
    return MEDIA_MIME_ALLOW.some((prefix) => clean === prefix || clean.startsWith(prefix));
  }
  function extFromMediaQueryParams(urlStr) {
    if (!urlStr || typeof urlStr !== "string") return "";
    try {
      const u = new URL(urlStr);
      const pick = (names) => {
        for (const n of names) {
          const v = u.searchParams.get(n);
          if (v) return v;
        }
        return "";
      };
      const fmt = (pick(["format", "ext", "extension"]) || "").toLowerCase().trim();
      if (/^(mp4|webm|mkv|mov|m3u8|mpd|m4s|ts|mp3|m4a|aac|flac|wav|ogg|ogv|oga)$/.test(fmt)) return "." + fmt;
      const mt = (pick(["mime", "mimetype", "content-type", "type"]) || "").toLowerCase().trim();
      const m = mt.match(/^(video|audio)\/([a-z0-9+.-]+)/);
      if (m) {
        const sub = m[2];
        if (sub.includes("mpegurl") || sub === "x-mpegurl") return ".m3u8";
        if (sub.includes("dash")) return ".mpd";
        if (sub === "mp4" || sub === "webm") return "." + sub;
        if (m[1] === "video") return ".mp4";
        if (m[1] === "audio") return m[2] === "ogg" ? ".ogg" : ".m4a";
      }
    } catch (_) {}
    return "";
  }

  chrome.webRequest.onResponseStarted.addListener(
    (details) => {
      if (!details) return;
      const url = details.url;
      if (!url || url.startsWith("blob:") || url.startsWith("data:") || url.startsWith("chrome-extension:")) return;

      if (details.responseHeaders && typeof capturedResponseMetaByUrl !== "undefined") {
        let disp = "";
        let ctype = "";
        for (const h of details.responseHeaders) {
          const hn = (h.name || "").toLowerCase();
          if (hn === "content-disposition" && h.value) disp = h.value;
          else if (hn === "content-type" && h.value) ctype = h.value;
        }
        if (disp || ctype) {
          capturedResponseMetaByUrl[url] = { contentDisposition: disp, contentType: ctype };
          const metaKeys = Object.keys(capturedResponseMetaByUrl);
          if (metaKeys.length > 500) delete capturedResponseMetaByUrl[metaKeys[0]];
        }
      }

      if (details.tabId < 0 || details.statusCode >= 400) return;

      const lowerUrl = url.toLowerCase();

      // Bỏ qua mạng quảng cáo, âm thanh giao diện và các phân đoạn MSE (videoplayback / byte-range)
      if (typeof AD_DOMAINS !== "undefined" && AD_DOMAINS.some((domain) => lowerUrl.includes(domain))) return;
      if (typeof UI_SOUNDS !== "undefined" && UI_SOUNDS.some((sound) => lowerUrl.includes(sound))) return;
      if (isMseRangeOrChunkUrl(url)) return;

      const isPlaylistCandidate = lowerUrl.includes(".m3u8") || lowerUrl.includes(".mpd");

      // Loại trừ các tệp tài nguyên web, tài liệu hoặc manifest không phải media
      const nonMediaExts = /\.(webmanifest|json|js|css|vtt|srt|xml|html|htm|txt|ico|woff|woff2|ttf|eot)(\?|$|#)/i;
      if (!isPlaylistCandidate && nonMediaExts.test(lowerUrl)) return;

      let isMedia = false;
      let mime = "";

      if (details.responseHeaders) {
        for (const h of details.responseHeaders) {
          if (h.name.toLowerCase() === "content-type") {
            mime = h.value.toLowerCase();
            if (!isPlaylistCandidate && (mime.includes("manifest+json") || mime.includes("application/json") || mime.includes("text/"))) {
              return;
            }
            // D-F13: chỉ nhận MIME trong allowlist thay vì includes lỏng.
            if (isAllowedMediaMime(mime)) {
              isMedia = true;
            }
            break;
          }
        }
      }

      if (!isMedia) {
        // mediaExtRegex khớp đuôi file ở pathOnly (khét điểm URL chứa ".ts"
        // giữa đường như src/main.ts/assets vẫn bị coi là stream HLS)
        const pathOnly = lowerUrl.split("?")[0].split("#")[0];
        const mediaExtRegex = /\.(mp4|webm|mkv|mov|m3u8|mpd|m4s|ts|mp3|m4a|aac|flac|wav)(\?|$|#)/i;
        if (mediaExtRegex.test(pathOnly)) {
          isMedia = true;
        } else if (extFromMediaQueryParams(url)) {
          // D-F13: download.php / v2.0/download / ?format=m3u8... không đuôi file.
          isMedia = true;
        }
      }

      if (isMedia) {
        if (!capturedMediaByTab[details.tabId]) {
          capturedMediaByTab[details.tabId] = [];
        }
        let list = capturedMediaByTab[details.tabId];
        const pathOnly = lowerUrl.split("?")[0].split("#")[0];
        const isPlaylist = pathOnly.includes(".m3u8") || mime.includes("mpegurl") || pathOnly.includes(".mpd") || mime.includes("dash+xml");
        const isChunk = /\.(ts|m4s|m4f|cmfv|cmfa)(\?|$|#)/.test(pathOnly);

        // Khi đã có playlist (.m3u8), không lưu các chunk lẻ (.ts/.m4s) để tránh làm loãng danh sách
        if (isChunk && list.some((item) => item.isPlaylist)) return;
        if (isChunk && list.filter((item) => item.isChunk).length >= 1) return;

        const streamKey = normalizeMediaStreamKey(url);
        if (!list.some((item) => item.url === url || normalizeMediaStreamKey(item.url) === streamKey)) {
          let filename = url.split("?")[0].split("/").pop() || "media";
          if (!filename.includes(".")) {
            // Chỉ gán ext khi thật sự nhận diện được mime media — URL không
            // có đuôi + mime không rõ thì không mù thêm .mp4.
            // D-F13: ưu tiên ext từ query-param (?format=/?mime=/?ext=).
            const qext = extFromMediaQueryParams(url);
            if (qext) filename += qext;
            else if (mime.includes("mpegurl") || lowerUrl.includes(".m3u8")) filename += ".m3u8";
            else if (mime.includes("webm") || lowerUrl.includes(".webm")) filename += ".webm";
            else if (mime.includes("video/")) filename += ".mp4";
            else if (mime.includes("audio/")) filename += ".m4a";
            else if (mime.includes("mp4")) filename += ".mp4";
          }
          const isFrameRequest = details.documentUrl && details.documentUrl !== tabUrls[details.tabId];
          const effectiveRef = (isFrameRequest && details.documentUrl.startsWith("http"))
            ? details.documentUrl
            : ((details.tabId >= 0 && tabUrls[details.tabId])
                ? tabUrls[details.tabId]
                : (details.initiator && details.initiator.startsWith("http") && details.initiator !== "null"
                    ? details.initiator
                    : ""));
          const item = {
            url: url,
            mime: mime,
            filename: filename,
            isPlaylist: isPlaylist,
            isChunk: isChunk,
            referrer: effectiveRef,
            initiator: details.initiator || "",
            documentUrl: details.documentUrl || "",
            tabId: details.tabId,
            timestamp: Date.now()
          };
          if (isPlaylist) {
            // Khi có playlist, lọc bỏ các chunk con lẻ tẻ và đặt playlist lên đầu.
            // Ưu tiên master playlist lên vị trí đầu tiên.
            list = list.filter((it) => !it.isChunk);
            const isMaster = lowerUrl.includes("master") || lowerUrl.includes("playlist");
            if (isMaster) {
              list.unshift(item);
            } else {
              const masterIdx = list.findIndex(it => it.url.toLowerCase().includes("master") || it.url.toLowerCase().includes("playlist"));
              if (masterIdx >= 0) {
                list.splice(masterIdx + 1, 0, item);
              } else {
                list.unshift(item);
              }
            }
            capturedMediaByTab[details.tabId] = list;
          } else {
            list.unshift(item);
          }
          if (list.length > 50) list.pop();

          // Cập nhật Badge trên toolbar icon
          const count = list.length;
          chrome.action.setBadgeText({ text: String(count), tabId: details.tabId });
          chrome.action.setBadgeBackgroundColor({ color: "#0A84FF", tabId: details.tabId });

          // Gửi thông báo trực tiếp tới content script (cả main frame và child frame) để hiện nút tải ngay tức thì
          chrome.tabs.sendMessage(details.tabId, {
            action: "media_stream_detected",
            mediaItem: item,
            totalCount: count
          }).catch(() => {});

          if (details.frameId && details.frameId > 0) {
            chrome.tabs.sendMessage(details.tabId, {
              action: "media_stream_detected",
              mediaItem: item,
              totalCount: count
            }, { frameId: details.frameId }).catch(() => {});
          }
        }
      }
    },
    { urls: ["<all_urls>"] },
    ["responseHeaders"]
  );
}

// Xóa danh sách khi đóng tab hoặc tải lại tab
chrome.tabs.onRemoved.addListener((tabId) => {
  delete capturedMediaByTab[tabId];
  delete tabUrls[tabId];
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (tab && tab.url) {
    tabUrls[tabId] = tab.url;
  }
  if (changeInfo.status === "loading") {
    capturedMediaByTab[tabId] = [];
    chrome.action.setBadgeText({ text: "", tabId: tabId });
  }
});

// RC-5 FIX: SPA Navigation Detection (TikTok, Instagram, YouTube, Facebook)
// history.pushState / replaceState không reload page, content script không chạy lại tự động.
// Dùng webNavigation.onHistoryStateUpdated để phát hiện và thông báo content script reset.
if (chrome.webNavigation && chrome.webNavigation.onHistoryStateUpdated) {
  chrome.webNavigation.onHistoryStateUpdated.addListener((details) => {
    if (details.frameId !== 0) return; // Chỉ xử lý main frame
    // Reset media list cho tab
    capturedMediaByTab[details.tabId] = [];
    chrome.action.setBadgeText({ text: "", tabId: details.tabId });
    // Thông báo content script về SPA navigation để nó tự reset và re-scan
    chrome.tabs.sendMessage(details.tabId, { action: "spa_navigated" }).catch(() => {});
  });
}

// D-F2: chỉ phục vụ top-frame (content all_frames:true nên iframe hostile cũng
// gửi message được). Iframe (frameId != 0) bị từ chối kèm log để không rò
// cookie/headers theo request lạ. Popup (không có sender.tab) vẫn phục vụ.
// D-F9: validator URL dùng chung cho download_media + batch (chặn blob:/data:).
function handoffUrlError(url) {
  if (!url || typeof url !== "string") {
    return { success: false, error: "Không tìm thấy link media hợp lệ — hãy bấm phát video rồi thử lại", code: "invalid_url" };
  }
  if (url.startsWith("blob:") || url.startsWith("data:")) {
    return { success: false, error: "Nguồn blob:/data: chỉ tải được trong trình duyệt", code: "browser_source_required" };
  }
  return null;
}
function isTopFrameSender(sender) {
  if (!sender) return true;
  if (typeof sender.frameId === "number" && sender.frameId !== 0) {
    try { console.warn("[IDM] reject iframe sender", sender.frameId, sender.url || ""); } catch (_) {}
    return false;
  }
  return true;
}
// Request phải gắn với tab giữ nó: url hoặc referrer cùng-site (eTLD+1, D-F10)
// với tab của sender. CDN cross-site vẫn qua được nhờ referrer cùng-site.
function isSenderForRequest(sender, url, referrer) {
  if (!sender || !sender.tab || !sender.tab.url) return true;
  try {
    if (url && isSameBaseDomain(sender.tab.url, url)) return true;
    if (referrer && isSameBaseDomain(sender.tab.url, referrer)) return true;
  } catch (_) {}
  try { console.warn("[IDM] sender/request site mismatch", sender.tab.url, url || ""); } catch (_) {}
  return false;
}
function senderGateError(sender, url, referrer) {
  if (!isTopFrameSender(sender)) {
    return { success: false, error: "Yêu cầu chỉ nhận từ khung chính của trang", code: "forbidden_frame" };
  }
  if (!isSenderForRequest(sender, url, referrer)) {
    return { success: false, error: "Yêu cầu không thuộc tab đang giữ", code: "sender_mismatch" };
  }
  return null;
}

// Lắng nghe thông điệp từ Content Script hoặc Popup
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.action === "get_captured_media" || message.action === "get_tab_media") {
    if (!isTopFrameSender(sender)) {
      sendResponse({ media: [] });
      return true;
    }
    const tabId = (sender.tab && sender.tab.id) ? sender.tab.id : message.tabId;
    const media = (tabId && capturedMediaByTab[tabId]) ? capturedMediaByTab[tabId] : [];
    sendResponse({ media: media });
    return true;
  }

  if (message.action === "download_media") {
    // Defense in depth: blob:/data: chỉ tồn tại trong trang, app không tải được.
    const urlErr = handoffUrlError(message.url);
    if (urlErr) {
      sendResponse(urlErr);
      return true;
    }
    const gateErr = senderGateError(sender, message.url, message.referrer);
    if (gateErr) {
      sendResponse(gateErr);
      return true;
    }
    const tabId = sender.tab ? sender.tab.id : message.tabId;
    const referrer = message.referrer || (sender.tab ? sender.tab.url : "") || (tabId >= 0 && tabUrls[tabId] ? tabUrls[tabId] : "");
    sendDownloadToHost({
      url: message.url,
      filename: message.filename || "",
      referrer: referrer,
      // `autoStart` (tùy chọn, mặc định false): app bỏ qua hộp thoại xác nhận
      // khi người dùng đã bật "Tự động bắt đầu tải trong app".
      autoStart: message.autoStart === true
    }, (resp) => {
      sendResponse(resp);
    }, tabId, { silentTabToast: true });
    return true; // Asynchronous response
  }

  if (message.action === "batch_download_items") {
    // Top-level chỉ chặn iframe; kiểm tra site thực hiện per-item (item có url).
    if (!isTopFrameSender(sender)) {
      sendResponse({ success: false, error: "Yêu cầu chỉ nhận từ khung chính của trang", code: "forbidden_frame", accepted: 0, count: (message.items || []).length });
      return true;
    }
    const tabId = sender.tab ? sender.tab.id : message.tabId;
    const items = message.items || [];
    const referrer = message.referrer || (sender.tab ? sender.tab.url : "") || (tabId >= 0 && tabUrls[tabId] ? tabUrls[tabId] : "");
    Promise.all(items.map(item => new Promise(resolve => {
      // D-F9: batch dùng chung validator với download_media (chặn blob:/data:).
      const urlErr = handoffUrlError(item.url);
      if (urlErr) { resolve(urlErr); return; }
      const itemGate = senderGateError(sender, item.url, item.referrer || referrer);
      if (itemGate) { resolve(itemGate); return; }
      sendDownloadToHost({
        url: item.url, filename: item.filename || item.name || "", referrer: item.referrer || referrer
      }, resolve, tabId, { silentTabToast: true });
    }))).then(results => {
      const accepted = results.filter(x => x.success && x.taskId).length;
      sendResponse({success: accepted === results.length, accepted, count: results.length,
        error: results.find(x => !x.success)?.error});
    });
    return true;
  }

  if (message.action === "keepalive_ping") {
    sendResponse({ ok: true });
    return false;
  }

  if (message.action === "ping_host") {
    const extensionVersion = currentExtensionVersion();
    const expected = expectedAppVersion();
    chrome.runtime.sendNativeMessage(HOST_NAME, { action: "hello", protocolVersion: 2 }, (response) => {
      if (chrome.runtime.lastError) {
        // Silently handle error without nagging alert
        sendResponse({
          success: false,
          error: chrome.runtime.lastError.message,
          appVersion: null,
          extensionVersion,
          expectedAppVersion: expected,
          protocolVersion: null,
          versionMismatch: false,
          code: "app_not_running"
        });
      } else {
        const appVersion = response?.extra?.appVersion || null;
        const protocolVersion = response?.extra?.protocolVersion || null;
        const protocolOk = protocolVersion === "2";
        const versionOk = !!expected && appVersion === expected;
        const versionMismatch = !versionOk || !protocolOk;
        sendResponse({
          success: response?.success === true && protocolOk && versionOk,
          response,
          error: response?.message || (versionMismatch ? "App và extension khác phiên bản — cập nhật cả hai" : undefined),
          appVersion,
          extensionVersion,
          expectedAppVersion: expected,
          protocolVersion,
          protocolOk,
          versionOk,
          versionMismatch,
          code: versionMismatch ? "protocol_mismatch" : undefined
        });
      }
    });
    return true;
  }
});

// Gửi thông báo tới Content Script trên Tab để hiện Toast thông báo tải (chỉ gửi tới main frame để tránh trùng lặp popup)
// D-F14: background fallback — tab không có content script nhận (sendMessage
// reject) thì dựng chrome.notifications để không im lặng. Giữ "notifications"
// trong manifest vì fallback này (không phải toast trùng).
function notifyTabOfDownload(tabId, filename, url) {
  if (tabId && tabId >= 0) {
    chrome.tabs.sendMessage(tabId, {
      action: "show_download_toast",
      filename: filename || url.split("/").pop().split("?")[0] || "Tệp tin",
      url: url
    }, { frameId: 0 }).catch(() => {
      try {
        if (chrome.notifications && typeof chrome.notifications.create === "function") {
          chrome.notifications.create({
            type: "basic",
            iconUrl: "icons/icon128.png",
            title: "Internet Downloader",
            message: filename ? `Đã nhận: ${filename}` : "App đã nhận tác vụ tải."
          }, () => {
            try { void chrome.runtime.lastError; } catch (_) {}
          });
        }
      } catch (_) {}
    });
  }
}

function isSameBaseDomain(url1, url2) {
  if (!url1 || !url2) return false;
  // D-F10 + A-F16 (gộp, cùng root-cause): eTLD+1 tối thiểu — so 2 nhãn cuối
  // sai với public suffix nhiều cấp (evil.co.uk vs shop.co.uk cùng "co.uk").
  // Các suffix này yêu cầu 3 nhãn, còn lại 2 nhãn.
  // (Đặt trong thân hàm để các slice test trích từ 'function isSameBaseDomain('
  // vẫn thấy đầy đủ logic.)
  const TWO_LEVEL_PUBLIC_SUFFIXES = new Set([
    "co.uk", "org.uk", "me.uk", "net.uk", "gov.uk", "ac.uk", "nhs.uk", "police.uk",
    "com.au", "net.au", "org.au", "gov.au", "edu.au",
    "co.jp", "ne.jp", "or.jp", "go.jp", "ac.jp",
    "co.kr", "ne.kr", "or.kr", "go.kr",
    "com.br", "net.br", "org.br",
    "co.nz", "net.nz", "org.nz", "govt.nz",
    "co.in", "net.in", "org.in", "gov.in",
    "co.za", "org.za", "gov.za",
    "com.cn", "net.cn", "org.cn", "gov.cn",
    "com.tw", "com.hk", "com.sg", "com.ar", "com.mx", "com.tr", "com.ua"
  ]);
  const baseDomain = (host) => {
    const clean = String(host || "").toLowerCase().replace(/\.+$/, "");
    if (!clean) return "";
    const parts = clean.split(".");
    if (parts.length <= 2) return clean;
    const last2 = parts.slice(-2).join(".");
    if (TWO_LEVEL_PUBLIC_SUFFIXES.has(last2)) return parts.slice(-3).join(".");
    return last2;
  };
  try {
    const getHost = (u) => {
      if (typeof URL !== "undefined") {
        try { return new URL(u).hostname.toLowerCase(); } catch (_) {}
      }
      const m = String(u).match(/^https?:\/\/([^/:]+)/i);
      return m ? m[1].toLowerCase() : "";
    };
    const h1 = getHost(url1);
    const h2 = getHost(url2);
    if (!h1 || !h2) return false;
    if (h1 === h2) return true;
    return baseDomain(h1) === baseDomain(h2);
  } catch (_) {
    return false;
  }
}

// Gửi request tới Native Messaging Host của Internet Downloader
function sendDownloadToHost(data, callback, tabId, options = {}) {
  // D-F6: chưa hydrate xong thì xếp hàng — không dùng headers/dedup còn rỗng.
  // typeof-guard để các slice test (không có sessionReady) vẫn chạy thẳng.
  try {
    if (typeof sessionHydrated !== "undefined" && !sessionHydrated &&
        typeof pendingHandoffQueue !== "undefined" && typeof sessionReady !== "undefined" && sessionReady &&
        typeof flushPendingHandoffs === "function") {
      pendingHandoffQueue.push({ data, callback, tabId, options });
      Promise.resolve(sessionReady).then(() => {
        try { flushPendingHandoffs(); } catch (_) {}
      });
      return;
    }
  } catch (_) {}
  const bestFilename = typeof resolveBestFilename === "function" ? resolveBestFilename(data) : (data.filename || "");
  const filename = bestFilename || data.filename || data.url.split("/").pop().split("?")[0] || "Tệp tin";
  const chainUrls = typeof getRedirectChainUrls === "function"
    ? getRedirectChainUrls(data.originalUrl, data.url)
    : [data.originalUrl, data.url].filter(Boolean);

  function proceed(cookies) {
    let capturedHeaders = {};
    if (typeof capturedHeadersByUrl !== "undefined") {
      for (const u of chainUrls) {
        if (u && capturedHeadersByUrl[u]) {
          capturedHeaders = { ...capturedHeaders, ...capturedHeadersByUrl[u] };
        }
      }
    }
    const headers = { ...capturedHeaders };
    if (!headers["Referer"] && data.referrer) {
      headers["Referer"] = data.referrer;
    }
    if (!headers["Origin"] && data.referrer && data.referrer.startsWith("http")) {
      try {
        headers["Origin"] = new URL(data.referrer).origin;
      } catch (_) {}
    }

    const payload = {
      action: "start_download",
      url: data.url,
      filename: bestFilename || data.filename || "",
      referrer: data.referrer || "",
      cookies: cookies || "",
      userAgent: navigator.userAgent,
      // Tùy chọn, app bỏ qua hộp thoại xác nhận khi true.
      autoStart: data.autoStart === true,
      headers: Object.keys(headers).length > 0 ? headers : undefined
    };

    chrome.runtime.sendNativeMessage(HOST_NAME, payload, (response) => {
      if (chrome.runtime.lastError) {
        if (callback) callback({ success: false, error: chrome.runtime.lastError.message, code: "app_not_running" });
      } else {
        if (response?.success === true && response.taskId) {
          if (typeof recentHandedOffUrls !== "undefined") {
            const now = Date.now();
            for (const u of chainUrls) {
              if (u) recentHandedOffUrls.set(u, { ts: now, filename: filename });
            }
            if (recentHandedOffUrls.size > 500) {
              const oldestKey = recentHandedOffUrls.keys().next().value;
              recentHandedOffUrls.delete(oldestKey);
            }
            persistSessionState();
          }
          // Content script đã tự hiện toast cho download_media / batch nên không
          // gửi thêm để tránh 2 toast cho cùng một click; context menu vẫn cần.
          if (!options.silentTabToast) notifyTabOfDownload(tabId, filename, data.url);
          if (callback) callback({success: true, taskId: response.taskId, data: response});
        } else if (callback) callback({success: false, error: response?.message || "App chưa nhận tác vụ", code: response?.extra?.code});
      }
    });
  }

  if (data.cookies) {
    proceed(data.cookies);
  } else if (chrome.cookies && data.url && !data.url.startsWith("data:") && !data.url.startsWith("blob:")) {
    try {
      chrome.cookies.getAll({ url: data.url }, (cookieList) => {
        const cookieStr = (cookieList || []).map(c => `${c.name}=${c.value}`).join("; ");
        const tabUrl = (typeof tabUrls !== "undefined" && tabId && tabId >= 0 && tabUrls[tabId]) ? tabUrls[tabId] : null;
        const extraUrls = [];
        if (data.referrer && !data.referrer.startsWith("data:") && !data.referrer.startsWith("blob:") && isSameBaseDomain(data.url, data.referrer)) {
          extraUrls.push(data.referrer);
        }
        if (tabUrl && !extraUrls.includes(tabUrl) && isSameBaseDomain(data.url, tabUrl)) {
          extraUrls.push(tabUrl);
        }
        if (extraUrls.length === 0) {
          proceed(cookieStr);
          return;
        }
        let remaining = extraUrls.length;
        const extraCookies = [];
        extraUrls.forEach(u => {
          try {
            chrome.cookies.getAll({ url: u }, (list) => {
              const str = (list || []).map(c => `${c.name}=${c.value}`).join("; ");
              if (str) extraCookies.push(str);
              remaining--;
              if (remaining === 0) {
                const combined = [cookieStr, ...extraCookies].filter(Boolean).join("; ");
                proceed(combined);
              }
            });
          } catch (_) {
            remaining--;
            if (remaining === 0) {
              const combined = [cookieStr, ...extraCookies].filter(Boolean).join("; ");
              proceed(combined);
            }
          }
        });
      });
    } catch (_) {
      proceed("");
    }
  } else {
    proceed("");
  }
}
