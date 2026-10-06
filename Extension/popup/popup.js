document.addEventListener("DOMContentLoaded", () => {
  const toggleDownloads = document.getElementById("toggleDownloads");
  const toggleFloating = document.getElementById("toggleFloating");
  const toggleImages = document.getElementById("toggleImages");
  const statusDot = document.getElementById("statusDot");
  const statusText = document.getElementById("statusText");
  const btnPing = document.getElementById("btnPing");
  const btnBatchGrabber = document.getElementById("btnBatchGrabber");

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
        statusDot.className = "status-dot online";
        statusText.textContent = "Sẵn sàng tự động kết nối App";
      }
    });
  }

  btnPing.addEventListener("click", checkConnection);
  checkConnection();
});
