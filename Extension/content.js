// Internet Downloader Integration Module - Media Sniffer, Overlay Player Handler & Batch Grabber

(function () {
  let showFloatingBarEnabled = true;
  let sniffImagesEnabled = true;

  chrome.storage.local.get(["showFloatingBar", "sniffImages"], (res) => {
    if (res.showFloatingBar !== undefined) showFloatingBarEnabled = res.showFloatingBar;
    if (res.sniffImages !== undefined) sniffImagesEnabled = res.sniffImages;
  });

  chrome.storage.onChanged.addListener((changes) => {
    if (changes.showFloatingBar) {
      showFloatingBarEnabled = changes.showFloatingBar.newValue;
      if (!showFloatingBarEnabled) removeFloatingBar();
    }
    if (changes.sniffImages) {
      sniffImagesEnabled = changes.sniffImages.newValue;
    }
  });

  let currentBar = null;
  let currentTargetEl = null;
  let hideTimeout = null;

  // Xác định URL và loại media của phần tử
  function getMediaDetails(el) {
    if (!el) return null;

    // 1. Thẻ Video
    if (el.tagName === "VIDEO") {
      let src = el.currentSrc || el.src;
      if (!src) {
        const source = el.querySelector("source");
        if (source) src = source.src;
      }
      if (!src && (window.location.hostname.includes("youtube.com") || window.location.hostname.includes("youtu.be"))) {
        src = window.location.href;
      }
      return { url: src || window.location.href, type: "video", label: "Tải video này" };
    }

    // 2. Thẻ Audio
    if (el.tagName === "AUDIO") {
      const src = el.currentSrc || el.src;
      return { url: src || window.location.href, type: "audio", label: "Tải âm thanh" };
    }

    // 3. Thẻ Image / GIF
    if (el.tagName === "IMG") {
      if (!sniffImagesEnabled) return null;
      const src = el.currentSrc || el.src;
      if (!src || src.startsWith("data:")) return null;

      const rect = el.getBoundingClientRect();
      const isGif = src.toLowerCase().includes(".gif");
      // Lọc kích thước tối thiểu (150x150 cho ảnh tĩnh, 60x60 cho GIF)
      if (isGif && (rect.width >= 60 || rect.height >= 60)) {
        return { url: src, type: "gif", label: "Tải ảnh GIF" };
      }
      if (rect.width >= 150 && rect.height >= 150) {
        return { url: src, type: "image", label: "Tải hình ảnh" };
      }
      return null;
    }

    // 4. Video Player Container đặc thù (YouTube, TikTok, Facebook, Dailymotion)
    if (el.classList) {
      if (el.classList.contains("html5-video-player") || el.classList.contains("video-stream") || el.id === "movie_player") {
        return { url: window.location.href, type: "video", label: "Tải video này" };
      }
    }

    return null;
  }

  // Tìm phần tử media xuyên qua các lớp điều khiển phủ (Overlays)
  function findMediaUnderPointer(e) {
    // 1. Kiểm tra trực tiếp element tại tọa độ con trỏ
    const directEl = document.elementFromPoint(e.clientX, e.clientY);
    if (!directEl) return null;

    let media = getMediaDetails(directEl);
    if (media) return { element: directEl, media: media };

    // 2. Tìm thẻ video/img bên trong container hoặc cha gần nhất
    const videoInside = directEl.querySelector("video");
    if (videoInside) {
      const m = getMediaDetails(videoInside);
      if (m) return { element: directEl, media: m };
    }

    const parentPlayer = directEl.closest(".html5-video-player, video, [class*='player'], [class*='video-container']");
    if (parentPlayer) {
      const v = parentPlayer.tagName === "VIDEO" ? parentPlayer : parentPlayer.querySelector("video");
      if (v) {
        const m = getMediaDetails(v);
        if (m) return { element: parentPlayer, media: m };
      }
      if (window.location.hostname.includes("youtube.com")) {
        return { element: parentPlayer, media: { url: window.location.href, type: "video", label: "Tải video này" } };
      }
    }

    // 3. Kiểm tra ảnh trong container
    if (sniffImagesEnabled) {
      const img = directEl.tagName === "IMG" ? directEl : directEl.querySelector("img");
      if (img) {
        const m = getMediaDetails(img);
        if (m) return { element: img, media: m };
      }
    }

    return null;
  }

  function createFloatingBar(targetEl, media) {
    if (!showFloatingBarEnabled) return;
    if (currentBar && currentTargetEl === targetEl) return;
    removeFloatingBar();

    const bar = document.createElement("div");
    bar.className = "idm-floating-bar";
    bar.setAttribute("data-idm-bar", "true");

    let iconSvg = "";
    if (media.type === "video") {
      iconSvg = `<svg class="idm-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="7 10 12 15 17 10"></polyline><line x1="12" y1="15" x2="12" y2="3"></line></svg>`;
    } else if (media.type === "image" || media.type === "gif") {
      iconSvg = `<svg class="idm-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><circle cx="8.5" cy="8.5" r="1.5"></circle><polyline points="21 15 16 10 5 21"></polyline></svg>`;
    } else {
      iconSvg = `<svg class="idm-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M9 18V5l12-2v13"></path><circle cx="6" cy="18" r="3"></circle><circle cx="18" cy="16" r="3"></circle></svg>`;
    }

    bar.innerHTML = `
      <div class="idm-btn-content">
        ${iconSvg}
        <span>${media.label}</span>
      </div>
    `;

    bar.addEventListener("click", (e) => {
      e.stopPropagation();
      e.preventDefault();

      const pageTitle = document.title ? document.title.replace(/[/\\?%*:|"<>]/g, "-").trim() : "download";
      let ext = media.type === "video" ? ".mp4" : (media.type === "gif" ? ".gif" : (media.type === "image" ? ".jpg" : ".mp3"));
      if (media.url.includes(".png")) ext = ".png";
      if (media.url.includes(".webp")) ext = ".webp";

      chrome.runtime.sendMessage({
        action: "download_media",
        url: media.url,
        filename: `${pageTitle}${ext}`
      });

      bar.classList.add("idm-downloading");
      bar.querySelector("span").textContent = "Đã gửi tới App!";
      setTimeout(() => {
        bar.classList.remove("idm-downloading");
        bar.querySelector("span").textContent = media.label;
      }, 2500);
    });

    bar.addEventListener("mouseenter", () => {
      if (hideTimeout) {
        clearTimeout(hideTimeout);
        hideTimeout = null;
      }
    });

    bar.addEventListener("mouseleave", () => {
      scheduleHide();
    });

    positionBar(bar, targetEl);
    document.body.appendChild(bar);
    currentBar = bar;
    currentTargetEl = targetEl;
  }

  function positionBar(bar, targetEl) {
    const rect = targetEl.getBoundingClientRect();
    const top = Math.max(10, rect.top + window.scrollY + 10);
    const left = Math.max(10, rect.right + window.scrollX - 170);
    bar.style.top = `${top}px`;
    bar.style.left = `${left}px`;
  }

  function removeFloatingBar() {
    if (currentBar && currentBar.parentNode) {
      currentBar.parentNode.removeChild(currentBar);
    }
    currentBar = null;
    currentTargetEl = null;
  }

  function scheduleHide() {
    if (hideTimeout) clearTimeout(hideTimeout);
    hideTimeout = setTimeout(() => {
      removeFloatingBar();
    }, 400);
  }

  // Lắng nghe sự kiện di chuột thông minh với throttle
  let lastMoveTime = 0;
  document.addEventListener("mousemove", (e) => {
    const now = Date.now();
    if (now - lastMoveTime < 60) return; // 60ms throttle
    lastMoveTime = now;

    // Nếu con trỏ đang ở trên chính thanh Floating Bar, giữ nguyên
    if (e.target && (e.target.closest(".idm-floating-bar") || e.target.classList.contains("idm-floating-bar"))) {
      if (hideTimeout) {
        clearTimeout(hideTimeout);
        hideTimeout = null;
      }
      return;
    }

    const detected = findMediaUnderPointer(e);
    if (detected) {
      if (hideTimeout) {
        clearTimeout(hideTimeout);
        hideTimeout = null;
      }
      createFloatingBar(detected.element, detected.media);
    } else {
      if (currentBar && !hideTimeout) {
        scheduleHide();
      }
    }
  }, { passive: true });

  window.addEventListener("scroll", () => {
    if (currentBar && currentTargetEl) {
      positionBar(currentBar, currentTargetEl);
    }
  }, { passive: true });

  // ==========================================
  // IDM Batch Media Grabber Panel (Quét trang)
  // ==========================================
  chrome.runtime.onMessage.addListener((req) => {
    if (req.action === "open_batch_grabber") {
      openBatchGrabberModal();
    }
  });

  function openBatchGrabberModal() {
    const existing = document.getElementById("idm-batch-modal");
    if (existing) existing.remove();

    const items = [];
    const seenUrls = new Set();

    // 1. Quét tất cả thẻ video & audio
    document.querySelectorAll("video, audio").forEach((v) => {
      const src = v.currentSrc || v.src;
      if (src && !seenUrls.has(src) && !src.startsWith("blob:") && !src.startsWith("data:")) {
        seenUrls.add(src);
        items.push({ url: src, name: src.split("/").pop() || "media.mp4", type: v.tagName.toLowerCase() });
      }
    });

    // 2. Quét tất cả ảnh lớn & GIF
    document.querySelectorAll("img").forEach((img) => {
      const src = img.currentSrc || img.src;
      if (src && !seenUrls.has(src) && !src.startsWith("data:")) {
        const rect = img.getBoundingClientRect();
        if (rect.width >= 100 || rect.height >= 100 || src.includes(".gif")) {
          seenUrls.add(src);
          items.push({ url: src, name: src.split("/").pop() || "image.jpg", type: src.includes(".gif") ? "gif" : "image" });
        }
      }
    });

    // 3. Quét tất cả liên kết file download (.zip, .pdf, .dmg, .iso, .mp4, etc.)
    document.querySelectorAll("a[href]").forEach((a) => {
      const href = a.href;
      if (href && !seenUrls.has(href)) {
        const ext = href.split("?")[0].split(".").pop().toLowerCase();
        if (["zip", "rar", "7z", "dmg", "pkg", "iso", "pdf", "mp4", "mkv", "mp3", "tar", "gz", "exe"].includes(ext)) {
          seenUrls.add(href);
          items.push({ url: href, name: a.innerText.trim() || href.split("/").pop(), type: "file" });
        }
      }
    });

    const modal = document.createElement("div");
    modal.id = "idm-batch-modal";
    modal.className = "idm-batch-backdrop";
    modal.innerHTML = `
      <div class="idm-batch-dialog">
        <div class="idm-batch-header">
          <div class="idm-batch-title">⬇ IDM Batch Media Grabber (Tìm thấy ${items.length} mục)</div>
          <button class="idm-batch-close" id="idmBatchClose">✕</button>
        </div>
        <div class="idm-batch-body">
          ${items.length === 0 ? '<div class="idm-empty">Không tìm thấy media hoặc liên kết file nào trên trang này.</div>' : `
            <div class="idm-batch-actions-bar">
              <button id="idmSelectAll" class="idm-btn-secondary">Chọn tất cả</button>
              <button id="idmDeselectAll" class="idm-btn-secondary">Bỏ chọn</button>
            </div>
            <div class="idm-batch-list">
              ${items.map((it, idx) => `
                <label class="idm-batch-row">
                  <input type="checkbox" class="idm-item-check" data-idx="${idx}" checked />
                  <span class="idm-type-badge">${it.type.toUpperCase()}</span>
                  <span class="idm-item-name" title="${it.url}">${it.name}</span>
                </label>
              `).join("")}
            </div>
          `}
        </div>
        <div class="idm-batch-footer">
          <button class="idm-btn-secondary" id="idmCancel">Đóng</button>
          ${items.length > 0 ? '<button class="idm-btn-primary" id="idmDownloadBatch">Tải các mục đã chọn</button>' : ''}
        </div>
      </div>
    `;

    document.body.appendChild(modal);

    document.getElementById("idmBatchClose")?.addEventListener("click", () => modal.remove());
    document.getElementById("idmCancel")?.addEventListener("click", () => modal.remove());

    document.getElementById("idmSelectAll")?.addEventListener("click", () => {
      modal.querySelectorAll(".idm-item-check").forEach(c => c.checked = true);
    });

    document.getElementById("idmDeselectAll")?.addEventListener("click", () => {
      modal.querySelectorAll(".idm-item-check").forEach(c => c.checked = false);
    });

    document.getElementById("idmDownloadBatch")?.addEventListener("click", () => {
      const selected = [];
      modal.querySelectorAll(".idm-item-check:checked").forEach(c => {
        const idx = parseInt(c.getAttribute("data-idx"));
        selected.push(items[idx]);
      });
      if (selected.length > 0) {
        chrome.runtime.sendMessage({
          action: "batch_download_items",
          items: selected
        });
        modal.remove();
      }
    });
  }
})();
