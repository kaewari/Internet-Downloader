// Internet Downloader Integration Module - Media Sniffer & Floating Download Bar

(function () {
  let showFloatingBarEnabled = true;

  chrome.storage.local.get(["showFloatingBar"], (res) => {
    if (res.showFloatingBar !== undefined) {
      showFloatingBarEnabled = res.showFloatingBar;
    }
  });

  chrome.storage.onChanged.addListener((changes) => {
    if (changes.showFloatingBar) {
      showFloatingBarEnabled = changes.showFloatingBar.newValue;
      if (!showFloatingBarEnabled) {
        removeFloatingBar();
      }
    }
  });

  let currentBar = null;
  let currentTargetVideo = null;

  function findMediaURL(mediaEl) {
    if (mediaEl.src && !mediaEl.src.startsWith("blob:") && !mediaEl.src.startsWith("data:")) {
      return mediaEl.src;
    }

    if (mediaEl.currentSrc && !mediaEl.currentSrc.startsWith("blob:") && !mediaEl.currentSrc.startsWith("data:")) {
      return mediaEl.currentSrc;
    }

    // Kiểm tra các thẻ source con
    const sources = mediaEl.querySelectorAll("source");
    for (const source of sources) {
      if (source.src && !source.src.startsWith("blob:") && !source.src.startsWith("data:")) {
        return source.src;
      }
    }

    // Nếu là blob trên YouTube hoặc video site, gửi URL trang hiện tại để app phân tích
    if (window.location.hostname.includes("youtube.com") || window.location.hostname.includes("youtu.be")) {
      return window.location.href;
    }

    return mediaEl.src || mediaEl.currentSrc || window.location.href;
  }

  function createFloatingBar(videoEl) {
    if (!showFloatingBarEnabled) return;
    if (currentBar) removeFloatingBar();

    const mediaUrl = findMediaURL(videoEl);
    if (!mediaUrl) return;

    const bar = document.createElement("div");
    bar.className = "idm-floating-bar";
    bar.innerHTML = `
      <div class="idm-btn-content">
        <svg class="idm-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
          <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path>
          <polyline points="7 10 12 15 17 10"></polyline>
          <line x1="12" y1="15" x2="12" y2="3"></line>
        </svg>
        <span>Tải video này</span>
      </div>
    `;

    bar.addEventListener("click", (e) => {
      e.stopPropagation();
      e.preventDefault();

      const pageTitle = document.title ? document.title.replace(/[/\\?%*:|"<>]/g, "-").trim() : "video";
      chrome.runtime.sendMessage({
        action: "download_media",
        url: mediaUrl,
        filename: `${pageTitle}.mp4`
      }, (resp) => {
        bar.classList.add("idm-downloading");
        bar.querySelector("span").textContent = "Đã gửi tới App!";
        setTimeout(() => {
          bar.classList.remove("idm-downloading");
          bar.querySelector("span").textContent = "Tải video này";
        }, 2500);
      });
    });

    positionBar(bar, videoEl);
    document.body.appendChild(bar);
    currentBar = bar;
    currentTargetVideo = videoEl;
  }

  function positionBar(bar, videoEl) {
    const rect = videoEl.getBoundingClientRect();
    const top = Math.max(10, rect.top + window.scrollY + 10);
    const left = Math.max(10, rect.right + window.scrollX - 160);
    bar.style.top = `${top}px`;
    bar.style.left = `${left}px`;
  }

  function removeFloatingBar() {
    if (currentBar && currentBar.parentNode) {
      currentBar.parentNode.removeChild(currentBar);
    }
    currentBar = null;
    currentTargetVideo = null;
  }

  function attachListeners(videoEl) {
    if (videoEl.__idmAttached) return;
    videoEl.__idmAttached = true;

    videoEl.addEventListener("mouseenter", () => {
      createFloatingBar(videoEl);
    });

    videoEl.addEventListener("mouseleave", (e) => {
      setTimeout(() => {
        if (currentBar && !currentBar.matches(":hover") && !videoEl.matches(":hover")) {
          removeFloatingBar();
        }
      }, 300);
    });
  }

  function scanMedia() {
    const videos = document.querySelectorAll("video");
    videos.forEach(attachListeners);
  }

  // Quét định kỳ và quan sát DOM mutations
  scanMedia();
  const observer = new MutationObserver(() => {
    scanMedia();
  });
  observer.observe(document.body, { childList: true, subtree: true });

  window.addEventListener("scroll", () => {
    if (currentBar && currentTargetVideo) {
      positionBar(currentBar, currentTargetVideo);
    }
  }, { passive: true });
})();
