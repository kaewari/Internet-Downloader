// Internet Downloader Integration Module - Media Sniffer, Proactive Overlay Player Handler, Toast & Batch Grabber

(function () {
  // Guard: prevent double-injection on SPA re-inject
  if (window.__idmContentLoaded) return;
  window.__idmContentLoaded = true;

  let interceptDownloadsEnabled = true;
  let showFloatingBarEnabled = true;
  let sniffImagesEnabled = true;

  chrome.storage.local.get(["interceptDownloads", "showFloatingBar", "sniffImages"], (res) => {
    if (res.interceptDownloads !== undefined) interceptDownloadsEnabled = Boolean(res.interceptDownloads);
    if (res.showFloatingBar !== undefined) showFloatingBarEnabled = res.showFloatingBar;
    if (res.sniffImages !== undefined) sniffImagesEnabled = res.sniffImages;
  });

  chrome.storage.onChanged.addListener((changes) => {
    if (changes.interceptDownloads) {
      interceptDownloadsEnabled = Boolean(changes.interceptDownloads.newValue);
    }
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
  let barResizeObserver = null;
  let lastPointer = null;
  const recentStreams = [];

  // ==========================================
  // In-Page IDM Floating Download Toast Card
  // ==========================================
  function showDownloadToast(filename, url, status = "App đã nhận tác vụ") {
    // Chỉ hiển thị toast trên top frame chính, không hiển thị trong iframe con
    if (typeof window !== "undefined" && window.self !== window.top) return;

    // Tránh hiển thị trùng lặp toast cho cùng một URL / file trong vòng 1.5 giây
    const now = Date.now();
    if (showDownloadToast._lastToast &&
        showDownloadToast._lastToast.url === url &&
        showDownloadToast._lastToast.filename === filename &&
        (now - showDownloadToast._lastToast.time < 1500)) {
      return;
    }
    showDownloadToast._lastToast = { url, filename, time: now };

    let container = document.getElementById("idm-toast-container");
    if (!container) {
      container = document.createElement("div");
      container.id = "idm-toast-container";
      container.className = "idm-toast-container";
      document.body.appendChild(container);
    }

    const toast = document.createElement("div");
    toast.className = "idm-toast-card";
    const displayName = filename || (url ? url.split("?")[0].split("/").pop() : "Tệp tin media") || "Tệp tin";

    toast.innerHTML = `
      <div class="idm-toast-icon">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
          <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path>
          <polyline points="7 10 12 15 17 10"></polyline>
          <line x1="12" y1="15" x2="12" y2="3"></line>
        </svg>
      </div>
      <div class="idm-toast-content">
        <div class="idm-toast-header">
          <span class="idm-toast-title">Internet Downloader</span>
          <span class="idm-toast-badge">TRẠNG THÁI</span>
        </div>
        <div class="idm-toast-name"></div>
        <div class="idm-toast-status"></div>
      </div>
      <button class="idm-toast-close" title="Đóng">✕</button>
    `;

    toast.querySelector(".idm-toast-name").textContent = displayName;
    toast.querySelector(".idm-toast-name").title = displayName;
    toast.querySelector(".idm-toast-status").textContent = status;
    const closeBtn = toast.querySelector(".idm-toast-close");
    closeBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      toast.classList.add("idm-toast-hiding");
      setTimeout(() => toast.remove(), 250);
    });

    container.appendChild(toast);

    // Auto-remove after 4.5 seconds
    setTimeout(() => {
      if (toast.parentNode) {
        toast.classList.add("idm-toast-hiding");
        setTimeout(() => toast.remove(), 250);
      }
    }, 4500);
  }

  // ==========================================
  // Iframe & Multi-layer Media Detection Helpers
  // ==========================================
  function isVideoIframe(el) {
    if (!el || el.tagName !== "IFRAME") return false;
    const src = (el.src || (el.dataset && el.dataset.src) || "").toLowerCase();
    const videoPatterns = ["recordplay", "embed", "player", "stream", "video", "play", "watch", "movie", "tube", "vcv", "v/e/", "m3u8"];
    if (videoPatterns.some(p => src.includes(p))) return true;
    const idAndClass = `${el.id || ""} ${el.className || ""}`.toLowerCase();
    if (idAndClass.includes("video") || idAndClass.includes("player")) return true;
    if (recentStreams.length > 0 && el.getBoundingClientRect) {
      const rect = el.getBoundingClientRect();
      if (rect.width >= 200 && rect.height >= 120) return true;
    }
    return false;
  }

  function findCandidateMedia(root = document) {
    if (!root) return null;
    const v = root.querySelector ? (root.querySelector("video") || root.querySelector(".html5-video-player")) : null;
    if (v) return v;

    if (root.querySelectorAll) {
      const iframes = root.querySelectorAll("iframe");
      for (const f of iframes) {
        const rect = f.getBoundingClientRect ? f.getBoundingClientRect() : { width: 0, height: 0 };
        if (rect.width >= 200 && rect.height >= 120 && (isVideoIframe(f) || recentStreams.length > 0)) {
          return f;
        }
      }
    }
    return null;
  }

  function observeIframeHover(iframe) {
    if (!iframe || iframe.__idmHoverObserved || typeof iframe.addEventListener !== "function") return;
    iframe.__idmHoverObserved = true;

    iframe.addEventListener("mouseenter", () => {
      const details = getMediaDetails(iframe);
      if (details) {
        if (hideTimeout) {
          clearTimeout(hideTimeout);
          hideTimeout = null;
        }
        createFloatingBar(iframe, details);
        if (currentBar) {
          currentBar.classList.add("idm-pointer-over");
          currentBar.classList.add("idm-iframe-hovered");
          updateBarVisibility(currentBar);
        }
      }
    });

    iframe.addEventListener("mouseleave", () => {
      if (currentBar && currentTargetEl === iframe) {
        currentBar.classList.remove("idm-pointer-over");
        currentBar.classList.remove("idm-iframe-hovered");
        scheduleHide();
      }
    });
  }

  // ==========================================
  // RC-1 FIX: Nhận diện chi tiết Media (chỉ nhận diện Video, Audio, Ảnh lớn, GIF; loại trừ Icon/Header/UI)
  // ==========================================
  function isUiOrIconElement(el) {
    if (!el) return false;
    const tag = (el.tagName || "").toUpperCase();
    if (["SVG", "PATH", "YT-ICON", "ICON-SHAPE", "YT-ICON-BUTTON", "BUTTON"].includes(tag)) return true;
    const clsAndId = `${el.id || ""} ${typeof el.className === "string" ? el.className : ""}`.toLowerCase();
    if (/(^|[\s_-])(avatar|icon|logo|emoji|badge|masthead|navbar|topbar|toolbar|header-btn)($|[\s_-])/i.test(clsAndId)) {
      return true;
    }
    if (typeof el.closest === "function") {
      const uiParent = el.closest("header, nav, ytd-masthead, #masthead-container, [role='banner'], [role='navigation'], button, [role='button'], yt-icon, [class*='avatar'], [class*='logo'], [id*='avatar'], [id*='logo']");
      if (uiParent && tag !== "VIDEO") return true;
    }
    return false;
  }

  function isPageLayoutContainer(el) {
    if (!el) return true;
    const tag = (el.tagName || "").toUpperCase();
    if (["HTML", "BODY", "MAIN", "HEADER", "FOOTER", "NAV", "ASIDE", "YTD-APP", "YTD-PAGE-MANAGER", "YTD-WATCH-FLEXY", "YTD-BROWSE", "YTD-MASTHEAD"].includes(tag)) {
      return true;
    }
    return false;
  }

  function pointInsideMediaRect(pt, rect) {
    if (!pt || !rect || rect.width <= 0 || rect.height <= 0) return false;
    return pt.x >= rect.left && pt.x <= rect.right && pt.y >= rect.top && pt.y <= rect.bottom;
  }

  function getMediaDetails(el) {
    if (!el || isPageLayoutContainer(el)) return null;

    // 1. Thẻ Video
    if (el.tagName === "VIDEO") {
      if (typeof isVideoPlatform === "function" && isVideoPlatform()) {
        return { url: window.location.href, type: "video", label: "Tải video này" };
      }
      let src = el.currentSrc || el.src;
      if (!src && el.querySelector) {
        const source = el.querySelector("source");
        if (source) src = source.src;
      }
      return { url: src || window.location.href, type: "video", label: "Tải video này" };
    }

    // 2. Thẻ Audio
    if (el.tagName === "AUDIO") {
      const src = el.currentSrc || el.src;
      return { url: src || window.location.href, type: "audio", label: "Tải âm thanh" };
    }

    // 3. Thẻ Image / GIF (loại trừ icon, avatar, svg, nút bấm)
    if (el.tagName === "IMG") {
      if (typeof sniffImagesEnabled !== "undefined" && !sniffImagesEnabled) return null;
      if (isUiOrIconElement(el)) return null;
      const src = el.currentSrc || el.src;
      if (!src || src.startsWith("data:") || /\.svg(\?|$|#)/i.test(src) || src.includes("image/svg")) return null;

      const rect = el.getBoundingClientRect ? el.getBoundingClientRect() : { width: 0, height: 0 };
      const isGif = /\.gif(\?|$|#)/i.test(src);
      if (el.naturalWidth > 0 && el.naturalHeight > 0 && (el.naturalWidth < 100 || el.naturalHeight < 100) && !isGif) {
        return null;
      }
      if (isGif && rect.width >= 100 && rect.height >= 100) {
        return { url: src, type: "gif", label: "Tải ảnh GIF" };
      }
      if (rect.width >= 150 && rect.height >= 150) {
        return { url: src, type: "image", label: "Tải hình ảnh" };
      }
      return null;
    }

    // RC-1a: <picture> element → lấy img bên trong
    if (el.tagName === "PICTURE") {
      const img = el.querySelector ? el.querySelector("img") : null;
      if (img) return getMediaDetails(img);
      return null;
    }

    // 4. Video Player Container đặc thù (chỉ khớp đúng player thực sự)
    if (el.classList) {
      if (el.classList.contains("html5-video-player") || el.classList.contains("video-stream") || el.id === "movie_player") {
        return { url: window.location.href, type: "video", label: "Tải video này" };
      }
    }

    // 5. Thẻ IFRAME Player nhúng (Recordplay, YouTube embed, Vimeo, v.v.)
    if (el.tagName === "IFRAME") {
      const rect = el.getBoundingClientRect ? el.getBoundingClientRect() : { width: 0, height: 0 };
      if (isVideoIframe(el) || (rect.width >= 200 && rect.height >= 120)) {
        const src = el.src || window.location.href;
        return { url: src, type: "video", label: "Tải video này", isIframeEmbed: true, embedSrc: src };
      }
      return null;
    }

    return null;
  }

  // RC-2 FIX: Dùng elementsFromPoint nhưng kiểm tra nghiêm ngặt tọa độ con trỏ nằm trong khung media thật, loại trừ thanh Header/Icon
  function findMediaUnderPointer(e) {
    if (typeof window !== "undefined" && window.self !== window.top) return null;
    const elements = document.elementsFromPoint(e.clientX, e.clientY);
    if (!elements || elements.length === 0) return null;
    const pt = { x: e.clientX, y: e.clientY };

    // Nếu phần tử trên cùng dưới con trỏ nằm trong thanh header/navbar/modal/icon giao diện thì dừng ngay
    const topEl = elements[0];
    if (topEl && isUiOrIconElement(topEl)) return null;

    for (const el of elements) {
      if (!el) continue;
      if (el.hasAttribute && el.hasAttribute("data-idm-bar")) continue;
      if (el.id && el.id.startsWith("idm-")) continue;

      // Nếu gặp thanh điều hướng / header cố định thì dừng, không xuyên qua header xuống phần tử bên dưới
      if (isUiOrIconElement(el)) return null;
      if (isPageLayoutContainer(el)) continue;

      // 1. Thử nhận diện trực tiếp trên phần tử media
      const media = getMediaDetails(el);
      if (media) {
        const rect = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
        if (!rect || pointInsideMediaRect(pt, rect)) {
          const innerVideo = (el.tagName !== "VIDEO" && el.querySelector) ? el.querySelector("video") : null;
          return { element: innerVideo || el, media };
        }
      }

      // 2. Chỉ tìm video/img con khi el là lớp phủ (overlay) nhỏ hơn hoặc bằng khung player, và con trỏ phải nằm trong chính khung video/img đó
      if (el.querySelector) {
        const videoInside = el.querySelector("video");
        if (videoInside && videoInside.getBoundingClientRect) {
          const vRect = videoInside.getBoundingClientRect();
          if (pointInsideMediaRect(pt, vRect)) {
            const m = getMediaDetails(videoInside);
            if (m) return { element: videoInside, media: m };
          }
        }

        if (sniffImagesEnabled) {
          const imgInside = el.tagName === "IMG" ? el : el.querySelector("img, picture img");
          if (imgInside && imgInside.getBoundingClientRect) {
            const iRect = imgInside.getBoundingClientRect();
            if (pointInsideMediaRect(pt, iRect)) {
              const m = getMediaDetails(imgInside);
              if (m) return { element: imgInside, media: m };
            }
          }
        }
      }

      // 3. Kiểm tra trình phát bao ngoài trực tiếp (.html5-video-player / #movie_player)
      if (el.closest) {
        const parentPlayer = el.closest(".html5-video-player, #movie_player, video");
        if (parentPlayer) {
          const v = parentPlayer.tagName === "VIDEO" ? parentPlayer : (parentPlayer.querySelector ? parentPlayer.querySelector("video") : null);
          const checkEl = v || parentPlayer;
          const pRect = checkEl.getBoundingClientRect ? checkEl.getBoundingClientRect() : null;
          if (pRect && pointInsideMediaRect(pt, pRect)) {
            const m = getMediaDetails(checkEl);
            if (m) return { element: checkEl, media: m };
          }
        }
      }
    }

    return null;
  }

  // ==========================================
  // Pinned IDM Video Download Bar
  // ==========================================
  const browserHandles = new Set();

  function isVideoPlatform() {
    const host = window.location.hostname.toLowerCase();
    const platforms = [
      "youtube.com", "youtu.be", "tiktok.com", "facebook.com", "fb.watch", "fb.com",
      "instagram.com", "threads.net", "twitter.com", "x.com", "vimeo.com", "dailymotion.com",
      "bilibili.com", "twitch.tv", "reddit.com", "pinterest.com", "pornhub.com", "xvideos.com", "xnxx.com"
    ];
    return platforms.some(p => host.includes(p));
  }

  function getBestStreamFromRecent(streams) {
    if (!streams || !streams.length) return null;
    const cleanStreams = streams.filter(s => s && s.url && !/\.(webmanifest|json|js|css|vtt|srt|xml|html)(\?|$|#)/i.test(s.url));
    if (!cleanStreams.length) return null;
    const viableStreams = cleanStreams.filter(s => !s.url.includes("recordplay.biz/stream/"));
    const pool = viableStreams.length > 0 ? viableStreams : cleanStreams;
    const masterPlaylist = pool.find(s => (s.isPlaylist || s.url.includes(".m3u8") || s.url.includes(".mpd")) && (s.url.includes("master") || s.url.includes("playlist")));
    if (masterPlaylist) return masterPlaylist.url;
    const playlist = pool.find(s => s.isPlaylist || s.url.includes(".m3u8") || s.url.includes(".mpd"));
    if (playlist) return playlist.url;
    const video = pool.find(s => !s.isChunk && (/\.(mp4|webm|mkv|mov)(\?|$|#)/i.test(s.url) || (s.mime && s.mime.includes("video"))));
    if (video) return video.url;
    const nonChunk = pool.find(s => !s.isChunk);
    if (nonChunk) return nonChunk.url;
    return pool[0].url;
  }

  function getBestStreamItem(streams) {
    if (!streams || !streams.length) return null;
    const bestUrl = getBestStreamFromRecent(streams);
    return streams.find(s => s && s.url === bestUrl) || streams[0];
  }

  function createFloatingBar(targetEl, media) {
    if (!showFloatingBarEnabled) return;
    if (typeof window !== "undefined" && window.self !== window.top) return;
    if (currentBar && currentTargetEl === targetEl) return;
    removeFloatingBar();

    const bar = document.createElement("button");
    bar.type = "button";
    bar.className = "idm-floating-bar";
    bar.setAttribute("data-idm-bar", "true");
    bar.setAttribute("aria-label", media.label);

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
      if (!e.isTrusted) return;
      e.stopPropagation();
      e.preventDefault();

      const pageTitle = document.title ? document.title.replace(/[/\\?%*:|"<>]/g, "-").trim() : "download";
      let ext = media.type === "video" ? ".mp4" : (media.type === "gif" ? ".gif" : (media.type === "image" ? ".jpg" : ".mp3"));
      if (media.url.includes(".png")) ext = ".png";
      if (media.url.includes(".webp")) ext = ".webp";
      const filename = `${pageTitle}${ext}`;

      const setStatus = text => { if (bar.isConnected) bar.querySelector("span").textContent = text; };
      setStatus("Đang xác định nguồn");
      if (location.hostname === "web.telegram.org") {
        try {
          const selection = window.__idmBrowser.prepare(targetEl);
          bar.dataset.browserHandle = selection.handle;
          browserHandles.add(selection.handle);
          chrome.runtime.sendMessage({action: "browser_start", selection}, response => {
            if (chrome.runtime.lastError || !response?.success || !response.taskId) setStatus(response?.error || chrome.runtime.lastError?.message || "App chưa nhận tác vụ");
          });
        } catch (error) {
          setStatus(window.__idmBrowser.errorMessage(error.message));
        }
        return;
      }

      function dispatchDownload(downloadUrl, streamReferrer) {
        let ref = streamReferrer || (typeof downloadUrl === "object" ? downloadUrl.referrer : null);
        const targetUrl = (typeof downloadUrl === "object" ? downloadUrl.url : downloadUrl);

        if (media && media.isIframeEmbed && media.embedSrc) {
          ref = media.embedSrc;
        } else if (!ref || (ref === window.location.href && media && media.embedSrc)) {
          ref = media.embedSrc;
        } else if (!ref) {
          ref = window.location.href;
        }

        chrome.runtime.sendMessage({action: "download_media", url: targetUrl, filename, referrer: ref}, response => {
          if (chrome.runtime.lastError || !response?.success || !response.taskId) {
            setStatus(response?.error || chrome.runtime.lastError?.message || "App chưa nhận tác vụ"); return;
          }
          setStatus("App đã nhận tác vụ");
        });
      }

      // 1. Nền tảng video trực tuyến (YouTube, TikTok, Facebook,...):
      // Gửi URL trang (window.location.href) cho Swift MediaURLResolver/yt-dlp
      // BẮT BUỘC ưu tiên hàng đầu để tải trọn vẹn video chất lượng cao có âm thanh,
      // không bị chặn bởi manifest.webmanifest hoặc các chunk MSE phân mảnh rời rạc
      if (isVideoPlatform()) {
        dispatchDownload(window.location.href);
        return;
      }

      // 2. Nếu là iframe embed, không gửi URL HTML iframe thô sang app; luôn ưu tiên luồng media thật đã bắt được
      if (media.isIframeEmbed) {
        const resolved = getBestStreamItem(recentStreams);
        if (resolved) {
          dispatchDownload(resolved.url, resolved.referrer);
          return;
        }
        chrome.runtime.sendMessage({action: "get_captured_media"}, response => {
          const bgStreams = response?.media || [];
          const bgResolved = getBestStreamItem(bgStreams);
          if (bgResolved) {
            dispatchDownload(bgResolved.url, bgResolved.referrer);
          } else {
            setStatus("Vui lòng bấm phát video để bắt link");
            showDownloadToast("Vui lòng bấm phát video để ứng dụng bắt luồng media.", "info");
          }
        });
        return;
      }

      // 3. Nếu URL là direct (không phải blob:), tải trực tiếp
      if (media.url && !media.url.startsWith("blob:")) {
        dispatchDownload(media.url, media.referrer);
        return;
      }

      // 4. Nếu là blob: (MSE player trên các web thông thường), tìm luồng stream tốt nhất (.m3u8, .mpd, .mp4) đã bắt được
      const resolved = getBestStreamItem(recentStreams);
      if (resolved) {
        dispatchDownload(resolved.url, resolved.referrer);
        return;
      }

      // 5. Kiểm tra background xem có stream nào đã bắt được cho tab này chưa
      chrome.runtime.sendMessage({action: "get_captured_media"}, response => {
        const bgStreams = response?.media || [];
        const bgResolved = getBestStreamItem(bgStreams);
        if (bgResolved) {
          dispatchDownload(bgResolved.url, bgResolved.referrer);
        } else {
          setStatus("Vui lòng bấm phát video để bắt link");
          showDownloadToast("Vui lòng bấm phát video để ứng dụng bắt luồng media.", "info");
        }
      });
    });

    bar.addEventListener("mouseenter", () => {
      if (hideTimeout) {
        clearTimeout(hideTimeout);
        hideTimeout = null;
      }
      bar.classList.add("idm-pointer-over");
      updateBarVisibility(bar);
    });

    bar.addEventListener("mouseleave", () => {
      bar.classList.remove("idm-pointer-over");
      scheduleHide();
    });

    bar.addEventListener("focus", () => updateBarVisibility(bar));
    bar.addEventListener("blur", () => scheduleHide());

    document.body.appendChild(bar);
    positionBar(bar, targetEl);
    currentBar = bar;
    currentTargetEl = targetEl;
    updateBarVisibility(bar);
    if (typeof ResizeObserver !== "undefined") {
      barResizeObserver = new ResizeObserver(() => {
        if (currentBar === bar) positionBar(bar, targetEl);
      });
      barResizeObserver.observe(targetEl);
      const playerWrapper = targetEl.closest?.(".html5-video-player, [class*='player'], [class*='video-container'], [id*='player']");
      if (playerWrapper && playerWrapper !== targetEl) barResizeObserver.observe(playerWrapper);
    }
  }

  chrome.runtime.onMessage.addListener(message => {
    if (message.action === "browser_phase" && browserHandles.has(message.handle)) {
      if (currentBar?.dataset.browserHandle === message.handle) currentBar.querySelector("span").textContent = message.message;
      if (["accepted", "needs_confirmation", "completed", "failed"].includes(message.phase)) showDownloadToast("Attachment Telegram", null, message.message + (message.phase === "completed" ? " · " + message.verification : ""));
      if (["completed", "failed"].includes(message.phase)) browserHandles.delete(message.handle);
    }
  });

  function positionBar(bar, targetEl) {
    if (!targetEl || !bar) return false;

    let refEl = targetEl;
    if (targetEl.tagName === "VIDEO" || targetEl.tagName === "IFRAME") {
      const playerWrapper = targetEl.closest?.(".html5-video-player, #movie_player, [class*='video-container']");
      if (playerWrapper && playerWrapper !== targetEl) {
        const wRect = playerWrapper.getBoundingClientRect();
        if (wRect.width > 0 && wRect.height > 0 && wRect.height < window.innerHeight * 1.5) {
          refEl = playerWrapper;
        }
      }
    }

    const rect = refEl.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) {
      bar.classList.remove("idm-positionable");
      updateBarVisibility(bar);
      return false;
    }

    const barWidth = bar.offsetWidth || 140;
    const barHeight = bar.offsetHeight || 28;
    const gap = 6;
    const viewportWidth = (document.documentElement && document.documentElement.clientWidth) || (typeof window !== "undefined" && window.innerWidth) || 1200;
    const viewportHeight = (typeof window !== "undefined" && window.innerHeight) || 900;

    let left = rect.right - barWidth;
    if (left < 0) left = Math.max(gap, rect.left);
    if (left + barWidth > viewportWidth) left = Math.max(0, viewportWidth - barWidth - gap);

    // Ưu tiên hiển thị phía trên player nếu có đủ khoảng trống bên dưới vùng thanh header cố định (top >= 60)
    let top = rect.top - barHeight - gap;
    // Nếu sát đỉnh trang hoặc nằm ngay dưới vùng thanh header/navbar cố định (top < 60), lật vào mép trên bên trong player để không đè lên icon header
    if (top < 60) {
      top = Math.max(0, rect.top + gap);
    }

    const positionable = rect.bottom > 0 && rect.top < viewportHeight &&
      rect.right > 0 && rect.left < viewportWidth;

    bar.style.top = `${Math.round(top)}px`;
    bar.style.left = `${Math.round(left)}px`;
    bar.classList.toggle("idm-positionable", positionable);
    updateBarVisibility(bar, rect);
    return positionable;
  }

  function pointInsideRect(point, rect) {
    return !!point && point.x >= rect.left && point.x <= rect.right && point.y >= rect.top && point.y <= rect.bottom;
  }

  function updateBarVisibility(bar, knownMediaRect) {
    if (!bar || (typeof currentBar !== "undefined" && currentBar && bar !== currentBar)) return;
    const activeElement = typeof document !== "undefined" ? document.activeElement : null;
    const target = typeof currentTargetEl !== "undefined" ? currentTargetEl : null;
    const keyboardFocused = bar.matches?.(":focus-visible") || !!(target &&
      (target.matches?.(":focus-visible") ||
        (target.contains?.(activeElement) && activeElement?.matches?.(":focus-visible"))));
    const barRect = bar.getBoundingClientRect ? bar.getBoundingClientRect() : null;
    const mediaRect = knownMediaRect || (target?.getBoundingClientRect ? target.getBoundingClientRect() : null);
    const pointer = typeof lastPointer !== "undefined" ? lastPointer : null;
    const pointerOver = bar.classList.contains("idm-pointer-over") ||
      bar.classList.contains("idm-iframe-hovered") ||
      (barRect && pointInsideRect(pointer, barRect)) ||
      (mediaRect && pointInsideRect(pointer, mediaRect));

    const isVisible = !!(bar.classList.contains("idm-positionable") && (pointerOver || keyboardFocused));

    bar.classList.toggle("idm-visible", isVisible);
  }

  function removeFloatingBar() {
    if (currentBar && currentBar.parentNode) {
      currentBar.parentNode.removeChild(currentBar);
    }
    currentBar = null;
    currentTargetEl = null;
    barResizeObserver?.disconnect();
    barResizeObserver = null;
  }

  function scheduleHide() {
    if (hideTimeout) clearTimeout(hideTimeout);
    hideTimeout = setTimeout(() => {
      hideTimeout = null;
      if (currentBar) {
        positionBar(currentBar, currentTargetEl);
        if (currentBar.classList.contains("idm-visible")) return;
      }
      removeFloatingBar();
    }, 300);
  }

  // ==========================================
  // Multi-layer Media Detection & Stream Deduplication
  // ==========================================
  function isChunkOrMseStreamUrl(urlStr) {
    if (!urlStr || typeof urlStr !== "string") return false;
    const lower = urlStr.toLowerCase();
    if (lower.includes("/videoplayback") || lower.includes("googlevideo.com")) return true;
    if (/\.(ts|m4s|m4f|cmfv|cmfa|fmp4)(\?|$|#)/i.test(lower)) return true;
    if (/[?&](range|bytestart|byteend|sq|ump|rbuf|srfvp)=/i.test(lower)) return true;
    return false;
  }

  function normalizeStreamUrlKey(urlStr) {
    if (!urlStr || typeof urlStr !== "string") return "";
    try {
      const u = new URL(urlStr, window.location.href);
      const transientParams = ["range", "rn", "rbuf", "sq", "bytestart", "byteend", "ump", "srfvp", "_", "t", "ts", "rand"];
      for (const p of transientParams) u.searchParams.delete(p);
      return u.origin + u.pathname + (u.searchParams.toString() ? "?" + u.searchParams.toString() : "");
    } catch (_) {
      return urlStr.split("#")[0];
    }
  }

  function addUniqueRecentStream(item) {
    if (!item || !item.url || isChunkOrMseStreamUrl(item.url)) return;
    const key = normalizeStreamUrlKey(item.url);
    if (recentStreams.some(s => s.url === item.url || normalizeStreamUrlKey(s.url) === key)) return;
    recentStreams.unshift(item);
    if (recentStreams.length > 20) recentStreams.pop();
  }

  function onMediaActive(el) {
    if (!el || !showFloatingBarEnabled) return;
    if (typeof window !== "undefined" && window.self !== window.top) return;
    // Chỉ hiển thị nút tải nổi khi con trỏ chuột thực sự đang nằm trên phần tử media đó
    if (!lastPointer || !el.getBoundingClientRect) return;
    const rect = el.getBoundingClientRect();
    if (!pointInsideRect(lastPointer, rect)) return;
    const details = getMediaDetails(el);
    if (details) {
      createFloatingBar(el, details);
      if (currentBar) updateBarVisibility(currentBar, rect);
    }
  }

  function handleMediaEvent(e) {
    if (typeof window !== "undefined" && window.self !== window.top) return;
    const path = e.composedPath ? e.composedPath() : [e.target];
    for (const el of path) {
      if (el && el.tagName && (el.tagName === "VIDEO" || el.tagName === "AUDIO")) {
        onMediaActive(el);
        return;
      }
    }
    onMediaActive(e.target);
  }

  document.addEventListener("play", handleMediaEvent, true);
  document.addEventListener("playing", handleMediaEvent, true);
  document.addEventListener("loadeddata", handleMediaEvent, true);
  document.addEventListener("canplay", handleMediaEvent, true);

  function scanMediaInNode(root) {
    if (typeof window !== "undefined" && window.self !== window.top) return;
    if (!root || !root.querySelectorAll) return;

    const iframes = root.querySelectorAll("iframe");
    for (const f of iframes) {
      observeIframeHover(f);
    }

    const all = root.querySelectorAll("*");
    for (const el of all) {
      if (el.shadowRoot) {
        scanMediaInNode(el.shadowRoot);
      }
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => scanMediaInNode(document.body));
  } else {
    scanMediaInNode(document.body);
  }

  const domObserver = new MutationObserver((mutations) => {
    if (typeof window !== "undefined" && window.self !== window.top) return;
    for (const mut of mutations) {
      for (const node of mut.addedNodes) {
        if (node.nodeType !== 1) continue;
        if (node.tagName === "IFRAME") {
          observeIframeHover(node);
        }
        if (node.querySelector) {
          const f = node.querySelector("iframe");
          if (f) observeIframeHover(f);
        }
        if (node.shadowRoot) {
          scanMediaInNode(node.shadowRoot);
        }
      }
    }
  });

  if (document.body) {
    domObserver.observe(document.body, { childList: true, subtree: true });
  }

  // 3. Lắng nghe Mousemove (hỗ trợ hover video, ảnh lớn, GIF)
  let lastMoveTime = 0;
  document.addEventListener("mousemove", (e) => {
    const now = Date.now();
    if (now - lastMoveTime < 60) return;
    lastMoveTime = now;

    lastPointer = {x: e.clientX, y: e.clientY};
    if (e.target instanceof Element && e.target.closest(".idm-floating-bar")) {
      if (hideTimeout) {
        clearTimeout(hideTimeout);
        hideTimeout = null;
      }
      if (currentBar) {
        currentBar.classList.add("idm-pointer-over");
        positionBar(currentBar, currentTargetEl);
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
      if (currentBar && currentTargetEl === detected.element) positionBar(currentBar, currentTargetEl);
    } else {
      if (currentBar && !hideTimeout) {
        scheduleHide();
      }
    }
  }, { passive: true });

  document.addEventListener("focusin", (event) => {
    if (currentBar?.contains(event.target)) {
      updateBarVisibility(currentBar);
      return;
    }
    const target = event.target;
    if (!(target instanceof Element)) return;
    const focusedMedia = target.matches("video, audio, img") ? target :
      target.closest(".html5-video-player, #movie_player, [class*='video-container'], a")?.querySelector("video, audio, img");
    const details = focusedMedia && getMediaDetails(focusedMedia);
    if (details) {
      createFloatingBar(focusedMedia, details);
      if (currentBar) updateBarVisibility(currentBar);
    }
  }, true);

  document.addEventListener("focusout", () => {
    setTimeout(() => {
      if (currentBar) {
        updateBarVisibility(currentBar);
        if (!currentBar.classList.contains("idm-visible")) scheduleHide();
      }
    }, 0);
  }, true);

  window.addEventListener("scroll", () => {
    if (currentBar && currentTargetEl) {
      positionBar(currentBar, currentTargetEl);
    }
  }, { passive: true, capture: true });

  window.addEventListener("resize", () => {
    if (currentBar && currentTargetEl) {
      positionBar(currentBar, currentTargetEl);
    }
  }, { passive: true });

  // ==========================================
  // 5b. Chặn trực tiếp click vào nút/link tải xuống (<a download> / link file trực tiếp)
  // và đánh thức MV3 Service Worker ở pointerdown để ngăn hộp thoại Save As gốc của trình duyệt
  // ==========================================
  const DIRECT_DOWNLOAD_EXT_REGEX = /\.(dmg|pkg|iso|zip|rar|7z|tar|gz|tgz|bz2|xz|zst|exe|msi|deb|rpm|appimage|apk|ipa)(\?|#|$)/i;

  function isInterceptableDownloadAnchor(anchor) {
    if (!anchor || typeof anchor.closest !== "function") return null;
    if (!interceptDownloadsEnabled) return null;
    if (location.hostname === "web.telegram.org") return null;

    const hrefAttr = (anchor.getAttribute("href") || "").trim();
    if (!hrefAttr || hrefAttr.startsWith("#") || hrefAttr.toLowerCase().startsWith("javascript:")) return null;

    const resolvedHref = anchor.href || hrefAttr;
    if (!resolvedHref || resolvedHref.startsWith("blob:") || resolvedHref.startsWith("data:")) return null;
    if (!/^https?:\/\//i.test(resolvedHref)) return null;

    const hasDownloadAttr = anchor.hasAttribute("download");
    let pathname = "";
    try {
      const parsed = new URL(resolvedHref, location.href);
      pathname = parsed.pathname || "";
      if (!hasDownloadAttr && !DIRECT_DOWNLOAD_EXT_REGEX.test(pathname)) {
        return null;
      }
      const attrName = (anchor.getAttribute("download") || "").trim();
      const rawName = attrName || decodeURIComponent(pathname.split("/").pop() || "") || "download";
      return { url: parsed.href, filename: rawName };
    } catch (_) {
      return null;
    }
  }

  document.addEventListener("pointerdown", (event) => {
    if (!interceptDownloadsEnabled || event.button !== 0) return;
    const target = event.target instanceof Element ? event.target : null;
    if (!target) return;
    const actionable = target.closest("a[href], button, [role='button']");
    if (actionable) {
      try {
        chrome.runtime.sendMessage({ action: "keepalive_ping" }, () => {
          void chrome.runtime.lastError;
        });
      } catch (_) {}
    }
  }, { capture: true, passive: true });

  document.addEventListener("click", (event) => {
    if (event.defaultPrevented || event.button !== 0) return;
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const target = event.target instanceof Element ? event.target : null;
    if (!target || currentBar?.contains(target)) return;

    const anchor = target.closest("a[href]");
    const info = isInterceptableDownloadAnchor(anchor);
    if (!info) return;

    event.preventDefault();
    event.stopPropagation();

    chrome.runtime.sendMessage({
      action: "download_media",
      url: info.url,
      filename: info.filename,
      referrer: location.href
    }, (response) => {
      if (chrome.runtime.lastError || !response?.success || !response.taskId) {
        showDownloadToast(info.filename, info.url, response?.error || "Không kết nối được App — hãy mở Internet Downloader");
      }
    });
  }, true);

  // ==========================================
  // Thông điệp từ Background (Network Streams, Toasts, Grabber)
  // ==========================================
  chrome.runtime.onMessage.addListener((req) => {
    if (req.action === "open_batch_grabber") {
      if (location.hostname === "web.telegram.org") showDownloadToast("Telegram", null, "Chọn attachment đang mở bằng nút Save trong extension");
      else openBatchGrabberModal();
    } else if (req.action === "show_download_toast") {
      if (typeof window !== "undefined" && window.self !== window.top) return;
      showDownloadToast(req.filename, req.url);
    } else if (req.action === "media_stream_detected") {
      if (req.mediaItem) {
        addUniqueRecentStream(req.mediaItem);
      }
    } else if (req.action === "spa_navigated") {
      // RC-5: SPA navigation — xóa danh sách stream cũ, đóng thanh nổi và quét lại
      recentStreams.length = 0;
      removeFloatingBar();
      window.__idmContentLoaded = false;
      setTimeout(() => scanMediaInNode(document.body), 800);
    }
  });

  // RC-6 FIX: Khi content script khởi tạo, tự query streams đã captured trước đó
  chrome.runtime.sendMessage({ action: "get_tab_media" }, (resp) => {
    if (chrome.runtime.lastError) return;
    if (resp && resp.media && resp.media.length > 0) {
      for (const item of resp.media) {
        addUniqueRecentStream(item);
      }
    }
  });

  // ==========================================
  // IDM Batch Media Grabber Panel (Quét trang)
  // ==========================================
  function openBatchGrabberModal() {
    const existing = document.getElementById("idm-batch-modal");
    if (existing) existing.remove();

    const items = [];
    const seenKeys = new Set();

    function addMediaItem(item) {
      if (!item || !item.url || item.url.startsWith("data:") || item.url.startsWith("blob:")) return;
      if (isChunkOrMseStreamUrl(item.url)) return;
      const key = normalizeStreamUrlKey(item.url);
      if (!key || seenKeys.has(key)) return;
      seenKeys.add(key);
      items.push(item);
    }

    function escapeHtml(str) {
      if (!str) return "";
      return String(str)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#039;");
    }

    function getDomain(url) {
      try {
        return new URL(url).hostname;
      } catch (_) {
        return "";
      }
    }

    let ytPoster = "";
    if (window.location.hostname.includes("youtube.com")) {
      const vId = new URLSearchParams(window.location.search).get("v");
      if (vId) ytPoster = `https://i.ytimg.com/vi/${vId}/hqdefault.jpg`;
    }
    const pageVideoPoster = document.querySelector("video[poster]")?.poster || ytPoster;
    const cleanPageTitle = (document.title || "video")
      .replace(/^\(\d+\+?\)\s*/, "")
      .replace(/\s*-\s*YouTube$/i, "")
      .replace(/[/\\?%*:|"<>]/g, "-")
      .trim() || "video";

    // 1. Nếu là nền tảng video (YouTube, TikTok, Facebook,...) và có thẻ video trên trang:
    // Tạo 1 mục duy nhất đại diện cho video/stream chính của trang (tránh nhân bản 20 chunk videoplayback.mp4)
    const pageVideos = Array.from(document.querySelectorAll("video, audio"));
    if (isVideoPlatform() && pageVideos.some(v => v.tagName.toLowerCase() === "video")) {
      addMediaItem({
        url: window.location.href,
        name: `${cleanPageTitle}.mp4`,
        type: "video",
        poster: pageVideoPoster
      });
    }

    // 1b. Quét tất cả thẻ video & audio có URL trực tiếp
    pageVideos.forEach((v) => {
      const src = v.currentSrc || v.src;
      if (src && !src.startsWith("blob:") && !src.startsWith("data:")) {
        const isVideo = v.tagName.toLowerCase() === "video";
        const poster = (isVideo && v.poster) ? v.poster : pageVideoPoster;
        addMediaItem({
          url: src,
          name: src.split("/").pop().split("?")[0] || (isVideo ? `${cleanPageTitle}.mp4` : "audio.mp3"),
          type: isVideo ? "video" : "audio",
          poster: poster
        });
      }
    });

    // 2. Bổ sung các stream thực từ WebRequest (chỉ khi không phải nền tảng video dùng yt-dlp page URL, và đã lọc bỏ MSE chunks)
    if (!isVideoPlatform()) {
      for (const stream of recentStreams) {
        if (stream && stream.url && !stream.isChunk && !isChunkOrMseStreamUrl(stream.url)) {
          const isAudio = (stream.mime && stream.mime.includes("audio")) || /\.(mp3|m4a|aac|flac|wav)(\?|$|#)/i.test(stream.url);
          addMediaItem({
            url: stream.url,
            name: stream.filename || (isAudio ? "audio.mp3" : `${cleanPageTitle}.mp4`),
            type: isAudio ? "audio" : "video",
            poster: isAudio ? "" : pageVideoPoster,
            referrer: stream.referrer
          });
        }
      }
    }

    // 3. Quét tất cả ảnh lớn & GIF (loại trừ icon, avatar, logo, svg, header/nav)
    document.querySelectorAll("img").forEach((img) => {
      if (isUiOrIconElement(img)) return;
      const src = img.currentSrc || img.src;
      if (!src || src.startsWith("data:") || /\.svg(\?|$|#)/i.test(src) || src.includes("image/svg")) return;
      const rect = img.getBoundingClientRect ? img.getBoundingClientRect() : { width: 0, height: 0 };
      const isGif = /\.gif(\?|$|#)/i.test(src);
      if (img.naturalWidth > 0 && img.naturalHeight > 0 && (img.naturalWidth < 100 || img.naturalHeight < 100) && !isGif) return;
      if ((isGif && rect.width >= 80 && rect.height >= 80) || (rect.width >= 120 && rect.height >= 120)) {
        const cleanName = src.split("/").pop().split("?")[0] || (isGif ? "image.gif" : "image.jpg");
        addMediaItem({
          url: src,
          name: cleanName,
          type: isGif ? "gif" : "image",
          poster: src
        });
      }
    });

    // 4. Quét tất cả liên kết file download
    document.querySelectorAll("a[href]").forEach((a) => {
      const href = a.href;
      if (href) {
        const ext = href.split("?")[0].split(".").pop().toLowerCase();
        if (["zip", "rar", "7z", "dmg", "pkg", "iso", "pdf", "mp4", "mkv", "mp3", "tar", "gz", "exe"].includes(ext)) {
          let itemType = "file";
          if (["mp4", "mkv"].includes(ext)) itemType = "video";
          else if (["mp3"].includes(ext)) itemType = "audio";
          addMediaItem({
            url: href,
            name: (a.innerText || "").trim() || href.split("/").pop().split("?")[0] || "file",
            type: itemType,
            poster: ""
          });
        }
      }
    });

    // Phân loại (Categories)
    function getItemCategory(it) {
      if (it.type === "video" || it.type === "audio") return "video";
      if (it.type === "image" || it.type === "gif") return "image";
      return "file";
    }

    const videoCount = items.filter(it => getItemCategory(it) === "video").length;
    const imageCount = items.filter(it => getItemCategory(it) === "image").length;
    const fileCount = items.filter(it => getItemCategory(it) === "file").length;

    function renderThumbnailHtml(it) {
      const ext = (it.url.split("?")[0].split(".").pop() || it.type).slice(0, 4).toUpperCase();
      if (it.type === "image" || it.type === "gif") {
        return `
          <div class="idm-thumb-box">
            <img class="idm-thumb-img" src="${escapeHtml(it.url)}" alt="" loading="lazy" onerror="this.style.display='none'; if(this.nextElementSibling) this.nextElementSibling.style.display='flex';" />
            <div class="idm-thumb-fallback" style="display:none;">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="16" height="16"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><circle cx="8.5" cy="8.5" r="1.5"></circle><polyline points="21 15 16 10 5 21"></polyline></svg>
            </div>
          </div>
        `;
      }
      if (it.type === "video") {
        if (it.poster) {
          return `
            <div class="idm-thumb-box">
              <img class="idm-thumb-img" src="${escapeHtml(it.poster)}" alt="" loading="lazy" onerror="this.style.display='none'; if(this.nextElementSibling) this.nextElementSibling.style.display='flex';" />
              <div class="idm-thumb-play-overlay">
                <svg viewBox="0 0 24 24" fill="currentColor" width="14" height="14"><polygon points="6 3 20 12 6 21 6 3"></polygon></svg>
              </div>
            </div>
          `;
        }
        return `
          <div class="idm-thumb-box idm-thumb-video-placeholder">
            <svg viewBox="0 0 24 24" fill="currentColor" width="14" height="14"><polygon points="6 3 20 12 6 21 6 3"></polygon></svg>
            <span class="idm-thumb-tag">${ext}</span>
          </div>
        `;
      }
      if (it.type === "audio") {
        return `
          <div class="idm-thumb-box idm-thumb-audio-placeholder">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="14" height="14"><path d="M9 18V5l12-2v13"></path><circle cx="6" cy="18" r="3"></circle><circle cx="18" cy="16" r="3"></circle></svg>
            <span class="idm-thumb-tag">${ext}</span>
          </div>
        `;
      }
      return `
        <div class="idm-thumb-box idm-thumb-file-placeholder">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="14" height="14"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><polyline points="14 2 14 8 20 8"></polyline></svg>
          <span class="idm-thumb-tag">${ext}</span>
        </div>
      `;
    }

    const modal = document.createElement("div");
    modal.id = "idm-batch-modal";
    modal.className = "idm-batch-backdrop";
    modal.innerHTML = `
      <div class="idm-batch-dialog">
        <div class="idm-batch-header">
          <div class="idm-batch-title">⬇ IDM Batch Media Grabber (${items.length} mục)</div>
          <button type="button" class="idm-batch-close" id="idmBatchClose">✕</button>
        </div>
        ${items.length === 0 ? '<div class="idm-empty">Không tìm thấy media hoặc liên kết file nào trên trang này.</div>' : `
          <div class="idm-batch-toolbar">
            <div class="idm-tab-bar" id="idmTabBar">
              <button type="button" class="idm-tab-btn active" data-filter="all">Tất cả <span class="idm-tab-count">${items.length}</span></button>
              <button type="button" class="idm-tab-btn" data-filter="video">Video <span class="idm-tab-count">${videoCount}</span></button>
              <button type="button" class="idm-tab-btn" data-filter="image">Hình ảnh <span class="idm-tab-count">${imageCount}</span></button>
              ${fileCount > 0 ? `<button type="button" class="idm-tab-btn" data-filter="file">Tệp tin <span class="idm-tab-count">${fileCount}</span></button>` : ''}
            </div>
            <div class="idm-batch-actions-bar">
              <button type="button" id="idmSelectAll" class="idm-btn-secondary">Chọn tất cả</button>
              <button type="button" id="idmDeselectAll" class="idm-btn-secondary">Bỏ chọn</button>
            </div>
          </div>
          <div class="idm-batch-body">
            <div class="idm-batch-list" id="idmBatchList">
              ${items.map((it, idx) => {
                const cat = getItemCategory(it);
                const domain = getDomain(it.url);
                return `
                  <label class="idm-batch-row" data-idx="${idx}" data-category="${cat}">
                    <input type="checkbox" class="idm-item-check" data-idx="${idx}" checked />
                    ${renderThumbnailHtml(it)}
                    <div class="idm-item-meta">
                      <div class="idm-item-name" title="${escapeHtml(it.url)}">${escapeHtml(it.name)}</div>
                      <div class="idm-item-sub">
                        <span class="idm-item-type-badge">${it.type.toUpperCase()}</span>
                        ${domain ? `<span class="idm-item-domain">${escapeHtml(domain)}</span>` : ''}
                      </div>
                    </div>
                  </label>
                `;
              }).join("")}
            </div>
          </div>
        `}
        <div class="idm-batch-footer">
          <div class="idm-batch-footer-left" id="idmFooterInfo">
            ${items.length > 0 ? `Đã chọn: <b id="idmSelectedNum" style="color:#0a84ff;">${items.length}</b> / <span id="idmTotalVisible">${items.length}</span> mục` : ''}
          </div>
          <div class="idm-batch-footer-right">
            <button type="button" class="idm-btn-secondary" id="idmCancel">Đóng</button>
            ${items.length > 0 ? `<button type="button" class="idm-btn-primary" id="idmDownloadBatch">Tải ${items.length} mục đã chọn</button>` : ''}
          </div>
        </div>
      </div>
    `;

    document.body.appendChild(modal);

    document.getElementById("idmBatchClose")?.addEventListener("click", () => modal.remove());
    document.getElementById("idmCancel")?.addEventListener("click", () => modal.remove());

    if (items.length === 0) return;

    let currentFilter = "all";
    const downloadBtn = document.getElementById("idmDownloadBatch");
    const selectedNumEl = document.getElementById("idmSelectedNum");
    const totalVisibleEl = document.getElementById("idmTotalVisible");
    const rows = Array.from(modal.querySelectorAll(".idm-batch-row"));

    function getVisibleRows() {
      return rows.filter(r => {
        if (r.classList.contains("idm-row-hidden")) return false;
        return currentFilter === "all" || r.getAttribute("data-category") === currentFilter;
      });
    }

    function getSelectedVisibleRows() {
      return getVisibleRows().filter(r => {
        const chk = r.querySelector(".idm-item-check");
        return !!(chk && chk.checked);
      });
    }

    function updateSelectionUI() {
      const visibleRows = getVisibleRows();
      const selectedRows = getSelectedVisibleRows();
      const selectedCount = selectedRows.length;

      if (selectedNumEl) selectedNumEl.textContent = String(selectedCount);
      if (totalVisibleEl) totalVisibleEl.textContent = String(visibleRows.length);

      if (downloadBtn) {
        if (selectedCount > 0) {
          downloadBtn.textContent = `Tải ${selectedCount} mục đã chọn`;
          downloadBtn.disabled = false;
        } else {
          downloadBtn.textContent = "Tải các mục đã chọn";
          downloadBtn.disabled = true;
        }
      }
    }

    // Toggle row style on check/uncheck
    modal.querySelectorAll(".idm-item-check").forEach((chk) => {
      chk.addEventListener("change", (e) => {
        const row = e.target.closest(".idm-batch-row");
        if (row) {
          row.classList.toggle("idm-row-unselected", !e.target.checked);
        }
        updateSelectionUI();
      });
    });

    // Tab Filtering: dùng cả class .idm-row-hidden (display: none !important) và style.setProperty
    modal.querySelectorAll(".idm-tab-btn").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        modal.querySelectorAll(".idm-tab-btn").forEach(b => b.classList.remove("active"));
        btn.classList.add("active");
        currentFilter = btn.getAttribute("data-filter") || "all";

        rows.forEach(r => {
          const cat = r.getAttribute("data-category");
          const show = currentFilter === "all" || cat === currentFilter;
          r.classList.toggle("idm-row-hidden", !show);
          if (r.style && typeof r.style.setProperty === "function") {
            r.style.setProperty("display", show ? "flex" : "none", "important");
          } else if (r.style) {
            r.style.display = show ? "flex" : "none";
          }
        });

        updateSelectionUI();
      });
    });

    // Chọn tất cả (theo tab hiện tại)
    document.getElementById("idmSelectAll")?.addEventListener("click", (e) => {
      e.stopPropagation();
      const visible = getVisibleRows();
      visible.forEach(r => {
        const chk = r.querySelector(".idm-item-check");
        if (chk) chk.checked = true;
        r.classList.remove("idm-row-unselected");
      });
      updateSelectionUI();
    });

    // Bỏ chọn (theo tab hiện tại)
    document.getElementById("idmDeselectAll")?.addEventListener("click", (e) => {
      e.stopPropagation();
      const visible = getVisibleRows();
      visible.forEach(r => {
        const chk = r.querySelector(".idm-item-check");
        if (chk) chk.checked = false;
        r.classList.add("idm-row-unselected");
      });
      updateSelectionUI();
    });

    // Thực hiện tải (chỉ tải các mục đang được chọn trong tab lọc hiện tại)
    downloadBtn?.addEventListener("click", (e) => {
      e.stopPropagation();
      const selected = [];
      getSelectedVisibleRows().forEach(r => {
        const idx = parseInt(r.getAttribute("data-idx"), 10);
        if (items[idx]) selected.push(items[idx]);
      });
      if (selected.length > 0) {
        chrome.runtime.sendMessage({
          action: "batch_download_items",
          items: selected
        }, response => showDownloadToast(`${selected.length} mục đã chọn`, null,
          response?.success ? `App đã nhận ${response.accepted} tác vụ` : response?.error || "App chưa nhận đủ tác vụ"));
        modal.remove();
      }
    });
  }
})();
