document.addEventListener("DOMContentLoaded", () => {
  const toggleDownloads = document.getElementById("toggleDownloads");
  const toggleFloating = document.getElementById("toggleFloating");
  const toggleImages = document.getElementById("toggleImages");
  const toggleAutoStart = document.getElementById("toggleAutoStart");
  const statusDot = document.getElementById("statusDot");
  const statusText = document.getElementById("statusText");
  const versionInfo = document.getElementById("versionInfo");
  const versionWarning = document.getElementById("versionWarning");
  const btnPing = document.getElementById("btnPing");
  const btnBatchGrabber = document.getElementById("btnBatchGrabber");
  const mediaCountBadge = document.getElementById("mediaCountBadge");
  const mediaList = document.getElementById("mediaList");

  // Nạp cấu hình hiện tại
  chrome.storage.local.get(["interceptDownloads", "showFloatingBar", "sniffImages", "autoStartBrowserDownloads"], (res) => {
    if (res.interceptDownloads !== undefined) toggleDownloads.checked = res.interceptDownloads;
    if (res.showFloatingBar !== undefined) toggleFloating.checked = res.showFloatingBar;
    if (res.sniffImages !== undefined) toggleImages.checked = res.sniffImages;
    // Mặc định TẮT: app vẫn hỏi xác nhận trước khi tải.
    toggleAutoStart.checked = res.autoStartBrowserDownloads === true;
  });

  toggleDownloads.addEventListener("change", () => {
    chrome.storage.local.set({ interceptDownloads: toggleDownloads.checked });
  });

  toggleFloating.addEventListener("change", () => {
    chrome.storage.local.set({ showFloatingBar: toggleFloating.checked });
  });

  toggleImages.addEventListener("change", () => {
    chrome.storage.local.set({ sniffImages: toggleImages.checked });
  });

  toggleAutoStart.addEventListener("change", () => {
    chrome.storage.local.set({ autoStartBrowserDownloads: toggleAutoStart.checked });
  });

  // Nút mở Batch Media Grabber trên tab hiện tại
  btnBatchGrabber.addEventListener("click", () => {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      if (tabs[0] && tabs[0].id) {
        chrome.tabs.sendMessage(tabs[0].id, { action: "open_batch_grabber" });
        window.close();
      }
    });
  });

  // Hiển thị version extension (từ manifest) + app (từ ping_host) và cảnh báo
  // lệch phiên bản — đây là nguyên nhân handoff "im lặng" phổ biến nhất.
  function renderVersions(res) {
    const extensionVersion = (chrome.runtime.getManifest && chrome.runtime.getManifest().version) || "?";
    const expectedAppVersion = (res && res.expectedAppVersion) || "1.2.0";
    const appVersion = (res && res.appVersion) || null;
    if (versionInfo) {
      versionInfo.textContent = appVersion
        ? `Extension ${extensionVersion} · App ${appVersion} (cần ${expectedAppVersion})`
        : `Extension ${extensionVersion} · App chưa kết nối (cần ${expectedAppVersion})`;
    }
    const mismatch = Boolean(res && res.versionMismatch);
    if (versionWarning) {
      versionWarning.classList.toggle("visible", mismatch);
      versionWarning.textContent = mismatch
        ? `Phiên bản App (${appVersion || "không rõ"}) khác extension (${extensionVersion}). Cập nhật app/extension cùng phiên bản (cần app ${expectedAppVersion}).`
        : "";
    }
  }

  function checkConnection() {
    statusText.textContent = "Đang kiểm tra...";
    statusDot.className = "status-dot";

    chrome.runtime.sendMessage({ action: "ping_host" }, (res) => {
      renderVersions(res || {});
      if (res && res.success) {
        statusDot.className = "status-dot online";
        statusText.textContent = "Đã kết nối với macOS App";
      } else {
        // Auto-connected mode: will launch app automatically on demand
        statusDot.className = "status-dot offline";
        statusText.textContent = res?.error || "Chưa xác minh kết nối App";
      }
    });
  }

  // Tải danh sách media đã bắt trên tab hiện tại
  function loadTabMedia() {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      if (!tabs[0] || !tabs[0].id) return;
      const tabId = tabs[0].id;
      if (tabs[0].url?.startsWith("https://web.telegram.org/")) {
        mediaList.textContent = "Telegram: chọn attachment đang mở bằng nút Save phía dưới.";
        return;
      }
      chrome.runtime.sendMessage({ action: "get_tab_media", tabId: tabId }, (res) => {
        const media = (res && res.media) ? res.media : [];
        mediaCountBadge.textContent = String(media.length);

        // D-F1: dựng DOM bằng createElement/textContent/setAttribute, không dùng
        // innerHTML với url/mime/name do server kiểm soát (XSS trong popup
        // đặc quyền). setAttribute("title", url) không parse HTML nên an toàn.
        mediaList.replaceChildren();
        if (media.length === 0) {
          const emptyDiv = document.createElement("div");
          emptyDiv.className = "media-empty";
          emptyDiv.textContent = "Chưa có luồng media nào đang phát";
          mediaList.appendChild(emptyDiv);
          return;
        }

        media.forEach((item, idx) => {
          const div = document.createElement("div");
          div.className = "media-item";
          const ext = String(item.url).split("?")[0].split(".").pop() || "media";
          const shortName = item.filename || String(item.url).split("/").pop().split("?")[0] || `Media stream #${idx + 1}`;

          const infoDiv = document.createElement("div");
          infoDiv.className = "media-info";
          const nameDiv = document.createElement("div");
          nameDiv.className = "media-name";
          nameDiv.textContent = shortName;
          nameDiv.setAttribute("title", String(item.url));
          const subDiv = document.createElement("div");
          subDiv.className = "media-sub";
          subDiv.textContent = String(item.mime || ext);
          infoDiv.appendChild(nameDiv);
          infoDiv.appendChild(subDiv);

          const dlBtn = document.createElement("button");
          dlBtn.className = "btn-dl-item";
          dlBtn.textContent = "⬇ Tải";
          dlBtn.setAttribute("data-url", String(item.url));
          dlBtn.setAttribute("data-name", shortName);

          div.appendChild(infoDiv);
          div.appendChild(dlBtn);
          dlBtn.addEventListener("click", () => {
            dlBtn.disabled = true;
            dlBtn.textContent = "Đang tải...";
            chrome.runtime.sendMessage({
              action: "download_media",
              url: item.url,
              filename: shortName,
              referrer: item.referrer || (tabs[0] ? tabs[0].url : ""),
              autoStart: toggleAutoStart.checked === true,
              tabId: tabId
            }, response => {
              dlBtn.textContent = response?.success && response.taskId ? "App đã nhận" : response?.error || "App chưa nhận tác vụ";
              setTimeout(() => {
                dlBtn.disabled = false;
                dlBtn.textContent = "⬇ Tải";
              }, 2000);
            });
          });

          mediaList.appendChild(div);
        });
      });
    });
  }

  btnPing.addEventListener("click", checkConnection);
  checkConnection();
  loadTabMedia();
});
