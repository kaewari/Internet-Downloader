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
  if (info.menuItemId === "idm_download_link" && info.linkUrl) {
    sendDownloadToHost({
      url: info.linkUrl,
      referrer: tab ? tab.url : "",
      filename: ""
    });
  } else if (info.menuItemId === "idm_download_media" && info.srcUrl) {
    sendDownloadToHost({
      url: info.srcUrl,
      referrer: tab ? tab.url : "",
      filename: tab && tab.title ? `${tab.title}.mp4` : ""
    });
  } else if (info.menuItemId === "idm_download_image" && info.srcUrl) {
    sendDownloadToHost({
      url: info.srcUrl,
      referrer: tab ? tab.url : "",
      filename: ""
    });
  } else if (info.menuItemId === "idm_batch_download" && tab && tab.id) {
    chrome.tabs.sendMessage(tab.id, { action: "open_batch_grabber" });
  }
});

// Bắt sự kiện tải file của trình duyệt (Download Interception)
chrome.downloads.onCreated.addListener(async (item) => {
  chrome.storage.local.get(["interceptDownloads"], (res) => {
    if (res.interceptDownloads === false) return;

    // Không can thiệp nếu là blob URL hoặc data URL
    if (item.url.startsWith("blob:") || item.url.startsWith("data:")) return;

    // Hủy trình tải mặc định của Chrome
    chrome.downloads.cancel(item.id, () => {
      chrome.downloads.erase({ id: item.id }, () => {});
    });

    sendDownloadToHost({
      url: item.finalUrl || item.url,
      filename: item.filename || "",
      referrer: item.referrer || "",
      userAgent: navigator.userAgent
    });
  });
});

// Lắng nghe thông điệp từ Content Script hoặc Popup
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.action === "download_media") {
    sendDownloadToHost({
      url: message.url,
      filename: message.filename || "",
      referrer: sender.tab ? sender.tab.url : ""
    }, (resp) => {
      sendResponse(resp);
    });
    return true; // Asynchronous response
  }

  if (message.action === "batch_download_items") {
    const items = message.items || [];
    for (const item of items) {
      sendDownloadToHost({
        url: item.url,
        filename: item.filename || "",
        referrer: sender.tab ? sender.tab.url : ""
      });
    }
    sendResponse({ success: true, count: items.length });
    return true;
  }

  if (message.action === "ping_host") {
    chrome.runtime.sendNativeMessage(HOST_NAME, { action: "ping" }, (response) => {
      if (chrome.runtime.lastError) {
        // Silently handle error without nagging alert
        sendResponse({ success: false, error: chrome.runtime.lastError.message });
      } else {
        sendResponse({ success: true, response: response });
      }
    });
    return true;
  }
});

// Gửi request tới Native Messaging Host của Internet Downloader
function sendDownloadToHost(data, callback) {
  const payload = {
    action: "start_download",
    url: data.url,
    filename: data.filename || "",
    referrer: data.referrer || "",
    userAgent: navigator.userAgent
  };

  chrome.runtime.sendNativeMessage(HOST_NAME, payload, (response) => {
    if (chrome.runtime.lastError) {
      // Native host will auto-launch the desktop app silently
      if (callback) callback({ success: false, error: chrome.runtime.lastError.message });
    } else {
      if (callback) callback({ success: true, data: response });
    }
  });
}
