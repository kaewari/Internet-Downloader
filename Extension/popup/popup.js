document.addEventListener("DOMContentLoaded", () => {
  const toggleDownloads = document.getElementById("toggleDownloads");
  const toggleFloating = document.getElementById("toggleFloating");
  const statusDot = document.getElementById("statusDot");
  const statusText = document.getElementById("statusText");
  const btnPing = document.getElementById("btnPing");

  // Nạp cấu hình hiện tại
  chrome.storage.local.get(["interceptDownloads", "showFloatingBar"], (res) => {
    if (res.interceptDownloads !== undefined) {
      toggleDownloads.checked = res.interceptDownloads;
    }
    if (res.showFloatingBar !== undefined) {
      toggleFloating.checked = res.showFloatingBar;
    }
  });

  toggleDownloads.addEventListener("change", () => {
    chrome.storage.local.set({ interceptDownloads: toggleDownloads.checked });
  });

  toggleFloating.addEventListener("change", () => {
    chrome.storage.local.set({ showFloatingBar: toggleFloating.checked });
  });

  function checkConnection() {
    statusText.textContent = "Đang kiểm tra...";
    statusDot.className = "status-dot";

    chrome.runtime.sendMessage({ action: "ping_host" }, (res) => {
      if (res && res.success) {
        statusDot.className = "status-dot online";
        statusText.textContent = "Đã kết nối với macOS App";
      } else {
        statusDot.className = "status-dot offline";
        statusText.textContent = "Chưa kết nối App (Hãy mở App)";
      }
    });
  }

  btnPing.addEventListener("click", checkConnection);
  checkConnection();
});
