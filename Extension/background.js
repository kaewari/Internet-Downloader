importScripts("browser-transfer.js");
// Internet Downloader Integration Module - Background Service Worker

const HOST_NAME = "com.internetdownloader.host";

// Khởi tạo cài đặt mặc định
chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.local.get(["interceptDownloads", "showFloatingBar", "sniffImages"], (res) => {
    if (res.interceptDownloads === undefined) {
      chrome.storage.local.set({ interceptDownloads: true });
    }
    if (res.showFloatingBar === undefined) {
      chrome.storage.local.set({ showFloatingBar: true });
    }
    if (res.sniffImages === undefined) {
      chrome.storage.local.set({ sniffImages: true });
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
      filename: tab && tab.title ? `${tab.title}.mp4` : ""
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
  const urls = [data.finalUrl, data.url, data.originalUrl].filter(Boolean);
  for (const u of urls) {
    const meta = capturedResponseMetaByUrl[u];
    if (meta && meta.contentDisposition) {
      const fromHeader = parseDispositionFilename(meta.contentDisposition);
      if (fromHeader && !isOpaqueFilename(fromHeader)) return fromHeader;
    }
  }
  for (const u of urls) {
    const fromQuery = extractQueryFilename(u);
    if (fromQuery) return fromQuery;
  }
  for (const u of [data.originalUrl, data.url, data.finalUrl].filter(Boolean)) {
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

// Bắt sự kiện tải file của trình duyệt (Download Interception)
chrome.downloads.onCreated.addListener(async (item) => {
  chrome.storage.local.get(["interceptDownloads"], (res) => {
    if (res.interceptDownloads === false) return;
    // A browser transfer owns Chrome's Save flow. Leave all concurrent downloads
    // alone until correlation/confirmation finishes; never cancel its input.
    if (browserJobs.size || /^https:\/\/web\.telegram\.org\//i.test(item.url) || /^https:\/\/web\.telegram\.org\//i.test(item.referrer || '')) return;

    // Không can thiệp nếu là blob URL hoặc data URL
    if (item.url.startsWith("blob:") || item.url.startsWith("data:")) return;

    const targetUrl = item.finalUrl || item.url;
    const initialBest = resolveBestFilename({
      url: targetUrl,
      originalUrl: item.url,
      filename: item.filename || ""
    });

    const finalizeInterception = (resolvedFilename) => {
      chrome.downloads.cancel(item.id, () => {
        chrome.downloads.erase({ id: item.id }, () => {});
      });
      sendDownloadToHost({
        url: targetUrl,
        originalUrl: item.url,
        filename: resolvedFilename || initialBest || "",
        referrer: item.referrer || "",
        userAgent: navigator.userAgent
      });
    };

    if ((initialBest && !isOpaqueFilename(initialBest)) || !chrome.downloads.onChanged) {
      finalizeInterception(initialBest);
      return;
    }

    let settled = false;
    const onChangedListener = (delta) => {
      if (delta && delta.id === item.id && delta.filename && delta.filename.current) {
        if (settled) return;
        settled = true;
        chrome.downloads.onChanged.removeListener(onChangedListener);
        const chromeBase = String(delta.filename.current).split(/[\\/]/).pop().trim();
        finalizeInterception(!isOpaqueFilename(chromeBase) ? chromeBase : initialBest);
      }
    };
    chrome.downloads.onChanged.addListener(onChangedListener);
    setTimeout(() => {
      if (settled) return;
      settled = true;
      chrome.downloads.onChanged.removeListener(onChangedListener);
      finalizeInterception(initialBest);
    }, 350);
  });
});

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
    },
    { urls: ["<all_urls>"] },
    ["requestHeaders", "extraHeaders"]
  );
}

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

// Lắng nghe luồng dữ liệu media thực tế từ WebRequest
if (chrome.webRequest && chrome.webRequest.onResponseStarted) {
  chrome.webRequest.onResponseStarted.addListener(
    (details) => {
      if (!details) return;
      const url = details.url;
      if (!url || url.startsWith("blob:") || url.startsWith("data:") || url.startsWith("chrome-extension:")) return;

      if (details.responseHeaders) {
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

      // Bỏ qua mạng quảng cáo và âm thanh giao diện người dùng
      if (AD_DOMAINS.some((domain) => lowerUrl.includes(domain))) return;
      if (UI_SOUNDS.some((sound) => lowerUrl.includes(sound))) return;

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
            if (mime.includes("video/") || mime.includes("audio/") || mime.includes("mpegurl") || mime.includes("dash+xml")) {
              isMedia = true;
            }
            break;
          }
        }
      }

      if (!isMedia) {
        const mediaExtRegex = /\.(mp4|webm|mkv|mov|m3u8|mpd|m4s|ts|mp3|m4a|aac|flac|wav)(\?|$|#)/i;
        if (lowerUrl.includes("videoplayback") || mediaExtRegex.test(lowerUrl)) {
          isMedia = true;
        }
      }

      if (isMedia) {
        if (!capturedMediaByTab[details.tabId]) {
          capturedMediaByTab[details.tabId] = [];
        }
        let list = capturedMediaByTab[details.tabId];
        const isPlaylist = lowerUrl.includes(".m3u8") || mime.includes("mpegurl") || lowerUrl.includes(".mpd") || mime.includes("dash+xml");
        const isChunk = lowerUrl.includes(".ts") || lowerUrl.includes(".m4s");

        // Khi đã có playlist (.m3u8), không lưu các chunk lẻ (.ts/.m4s) để tránh làm loãng danh sách
        if (isChunk && list.some((item) => item.isPlaylist)) return;
        if (isChunk && list.filter((item) => item.isChunk).length >= 2) return;

        if (!list.some((item) => item.url === url)) {
          let filename = url.split("?")[0].split("/").pop() || "media";
          if (!filename.includes(".")) {
            if (mime.includes("mp4") || lowerUrl.includes(".mp4")) filename += ".mp4";
            else if (mime.includes("mpegurl") || lowerUrl.includes(".m3u8")) filename += ".m3u8";
            else if (mime.includes("webm") || lowerUrl.includes(".webm")) filename += ".webm";
            else filename += ".mp4";
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

// Lắng nghe thông điệp từ Content Script hoặc Popup
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.action === "get_captured_media" || message.action === "get_tab_media") {
    const tabId = (sender.tab && sender.tab.id) ? sender.tab.id : message.tabId;
    const media = (tabId && capturedMediaByTab[tabId]) ? capturedMediaByTab[tabId] : [];
    sendResponse({ media: media });
    return true;
  }

  if (message.action === "download_media") {
    const tabId = sender.tab ? sender.tab.id : message.tabId;
    const referrer = message.referrer || (sender.tab ? sender.tab.url : "") || (tabId >= 0 && tabUrls[tabId] ? tabUrls[tabId] : "");
    sendDownloadToHost({
      url: message.url,
      filename: message.filename || "",
      referrer: referrer
    }, (resp) => {
      sendResponse(resp);
    }, tabId);
    return true; // Asynchronous response
  }

  if (message.action === "batch_download_items") {
    const tabId = sender.tab ? sender.tab.id : message.tabId;
    const items = message.items || [];
    const referrer = message.referrer || (sender.tab ? sender.tab.url : "") || (tabId >= 0 && tabUrls[tabId] ? tabUrls[tabId] : "");
    Promise.all(items.map(item => new Promise(resolve => sendDownloadToHost({
      url: item.url, filename: item.filename || item.name || "", referrer: item.referrer || referrer
    }, resolve, tabId)))).then(results => {
      const accepted = results.filter(x => x.success && x.taskId).length;
      sendResponse({success: accepted === results.length, accepted, count: results.length,
        error: results.find(x => !x.success)?.error});
    });
    return true;
  }

  if (message.action === "ping_host") {
    chrome.runtime.sendNativeMessage(HOST_NAME, { action: "hello", protocolVersion: 2 }, (response) => {
      if (chrome.runtime.lastError) {
        // Silently handle error without nagging alert
        sendResponse({ success: false, error: chrome.runtime.lastError.message });
      } else {
        sendResponse({success: response?.success === true && response.extra?.protocolVersion === "2" && response.extra?.appVersion === "1.1.0", response, error: response?.message});
      }
    });
    return true;
  }
});

// Gửi thông báo tới Content Script trên Tab để hiện Toast thông báo tải (chỉ gửi tới main frame để tránh trùng lặp popup)
function notifyTabOfDownload(tabId, filename, url) {
  if (tabId && tabId >= 0) {
    chrome.tabs.sendMessage(tabId, {
      action: "show_download_toast",
      filename: filename || url.split("/").pop().split("?")[0] || "Tệp tin",
      url: url
    }, { frameId: 0 }).catch(() => {});
  }
}

function isSameBaseDomain(url1, url2) {
  if (!url1 || !url2) return false;
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
    const p1 = h1.split(".").slice(-2).join(".");
    const p2 = h2.split(".").slice(-2).join(".");
    return p1 === p2;
  } catch (_) {
    return false;
  }
}

// Gửi request tới Native Messaging Host của Internet Downloader
function sendDownloadToHost(data, callback, tabId) {
  const bestFilename = resolveBestFilename(data);
  const filename = bestFilename || data.filename || data.url.split("/").pop().split("?")[0] || "Tệp tin";

  function proceed(cookies) {
    const capturedHeaders = capturedHeadersByUrl[data.url] || {};
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
      headers: Object.keys(headers).length > 0 ? headers : undefined
    };

    chrome.runtime.sendNativeMessage(HOST_NAME, payload, (response) => {
      if (chrome.runtime.lastError) {
        if (callback) callback({ success: false, error: chrome.runtime.lastError.message });
      } else {
        if (response?.success === true && response.taskId) {
          notifyTabOfDownload(tabId, filename, data.url);
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
