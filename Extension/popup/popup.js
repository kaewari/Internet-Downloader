document.addEventListener("DOMContentLoaded", () => {
  const toggleDownloads = document.getElementById("toggleDownloads");
  const toggleFloating = document.getElementById("toggleFloating");
  const toggleImages = document.getElementById("toggleImages");
  const statusDot = document.getElementById("statusDot");
  const statusText = document.getElementById("statusText");
  const btnPing = document.getElementById("btnPing");
  const btnBatchGrabber = document.getElementById("btnBatchGrabber");
  const mediaCountBadge = document.getElementById("mediaCountBadge");
  const mediaList = document.getElementById("mediaList");

  // Nạp cấu hình hiện tại
  chrome.storage.local.get(["interceptDownloads", "showFloatingBar", "sniffImages"], (res) => {
    if (res.interceptDownloads !== undefined) toggleDownloads.checked = res.interceptDownloads;
    if (res.showFloatingBar !== undefined) toggleFloating.checked = res.showFloatingBar;
    if (res.sniffImages !== undefined) toggleImages.checked = res.sniffImages;
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

  // Nút mở Batch Media Grabber trên tab hiện tại
  btnBatchGrabber.addEventListener("click", () => {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      if (tabs[0] && tabs[0].id) {
        chrome.tabs.sendMessage(tabs[0].id, { action: "open_batch_grabber" });
        window.close();
      }
    });
  });

  function checkConnection() {
    statusText.textContent = "Đang kiểm tra...";
    statusDot.className = "status-dot";

    chrome.runtime.sendMessage({ action: "ping_host" }, (res) => {
      if (res && res.success) {
        statusDot.className = "status-dot online";
        statusText.textContent = "Đã kết nối với macOS App";
      } else {
        // Auto-connected mode: will launch app automatically on demand
        statusDot.className = "status-dot";
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

        if (media.length === 0) {
          mediaList.innerHTML = '<div class="media-empty">Chưa có luồng media nào đang phát</div>';
          return;
        }

        mediaList.innerHTML = "";
        media.forEach((item, idx) => {
          const div = document.createElement("div");
          div.className = "media-item";
          const ext = item.url.split("?")[0].split(".").pop() || "media";
          const shortName = item.filename || item.url.split("/").pop().split("?")[0] || `Media stream #${idx + 1}`;

          div.innerHTML = `
            <div class="media-info">
              <div class="media-name" title="${item.url}">${shortName}</div>
              <div class="media-sub">${item.mime || ext}</div>
            </div>
            <button class="btn-dl-item" data-url="${item.url}" data-name="${shortName}">⬇ Tải</button>
          `;

          const dlBtn = div.querySelector(".btn-dl-item");
          dlBtn.addEventListener("click", () => {
            dlBtn.disabled = true;
            dlBtn.textContent = "Đang tải...";
            chrome.runtime.sendMessage({
              action: "download_media",
              url: item.url,
              filename: shortName,
              referrer: item.referrer || (tabs[0] ? tabs[0].url : ""),
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
