// End-to-End Real Browser (Headless Chromium + CDP) Verification Suite
// Verifies:
// 1. Stream chunk deduplication (no 20x duplicate videoplayback.mp4 in Batch Grabber)
// 2. Category tab filtering (getComputedStyle(row).display === 'none' & getBoundingClientRect().height === 0)
//    and scoped Select All / Deselect All / Download actions
// 3. Floating download bar geometry (never triggers on header icons/avatars, never overlaps fixed header)

const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const os = require("node:os");

const CHROME_PATH = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const contentJs = fs.readFileSync(path.join(__dirname, "../Extension/content.js"), "utf8");
const snifferCss = fs.readFileSync(path.join(__dirname, "../Extension/styles/sniffer.css"), "utf8");

function buildTestHtml() {
  return `<!DOCTYPE html>
<html lang="vi">
<head>
  <meta charset="utf-8" />
  <title>(9+) Đang Xem Stream Trực Tiếp - YouTube</title>
  <style>
    body, html { margin: 0; padding: 0; background: #0f0f0f; color: #fff; font-family: sans-serif; }
    ytd-masthead, header#masthead-container {
      position: fixed; top: 0; left: 0; right: 0; height: 56px;
      background: #0f0f0f; display: flex; align-items: center; justify-content: flex-end;
      padding: 0 24px; gap: 16px; z-index: 2020; border-bottom: 1px solid #272727;
    }
    .create-btn { height: 36px; padding: 0 14px; border-radius: 18px; background: #272727; color: #fff; border: none; }
    .bell-btn { width: 40px; height: 40px; border-radius: 50%; background: transparent; border: none; position: relative; }
    .avatar-img { width: 32px; height: 32px; border-radius: 50%; }
    ytd-app { display: block; padding-top: 56px; }
    #movie_player {
      width: 854px; height: 480px; margin-left: 24px; position: relative; background: #000;
    }
    #movie_player video {
      width: 854px; height: 480px; display: block;
    }
    .gallery { display: flex; gap: 16px; padding: 24px; flex-wrap: wrap; }
  </style>
  <style>${snifferCss}</style>
</head>
<body>
  <ytd-masthead id="masthead-container" role="banner">
    <button id="createBtn" class="create-btn" type="button">+ Tạo</button>
    <button id="bellBtn" class="bell-btn" type="button" aria-label="Thông báo">
      <yt-icon class="icon">🔔 9+</yt-icon>
    </button>
    <img id="avatarIcon" class="avatar-img" src="/assets/avatar.jpg" width="32" height="32" alt="Avatar" />
  </ytd-masthead>

  <ytd-app>
    <div id="movie_player" class="html5-video-player">
      <video id="mainVideo" src="blob:http://localhost/stream-1" poster="/assets/poster.jpg"></video>
    </div>

    <div class="gallery">
      <img id="photo1" src="/assets/photo1.jpg" style="width: 300px; height: 200px;" />
      <img id="photo2" src="/assets/photo2.png" style="width: 260px; height: 180px;" />
      <img id="animGif" src="/assets/ reaction.gif" style="width: 160px; height: 160px;" />
      <img id="smallIcon" class="ui-icon" src="/assets/icon.svg" style="width: 24px; height: 24px;" />
      <a id="zipLink" href="/assets/release_bundle.zip">Tải gói cài đặt ZIP</a>
    </div>
  </ytd-app>

  <script>
    window.__msgListeners = [];
    window.__sentMessages = [];
    window.chrome = {
      storage: {
        local: {
          get: (keys, cb) => cb({ showFloatingBar: true, sniffImages: true })
        },
        onChanged: { addListener: () => {} }
      },
      runtime: {
        lastError: null,
        onMessage: {
          addListener: (fn) => window.__msgListeners.push(fn)
        },
        sendMessage: (msg, cb) => {
          window.__sentMessages.push(msg);
          if (msg.action === "get_tab_media") {
            if (cb) cb({ media: [] });
          } else if (msg.action === "batch_download_items") {
            if (cb) cb({ success: true, accepted: (msg.items || []).length });
          } else if (msg.action === "download_media") {
            if (cb) cb({ success: true, taskId: "task-1" });
          }
        }
      }
    };
  </script>
  <script>${contentJs}</script>
</body>
</html>`;
}

const zlib = require("node:zlib");
function makePng(width, height) {
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  function chunk(type, data) {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length, 0);
    const typeBuf = Buffer.from(type, "ascii");
    const crcBuf = Buffer.alloc(4);
    let c = 0xffffffff;
    for (const b of Buffer.concat([typeBuf, data])) {
      c ^= b;
      for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0);
    }
    crcBuf.writeUInt32BE((c ^ 0xffffffff) >>> 0, 0);
    return Buffer.concat([len, typeBuf, data, crcBuf]);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // color type RGB
  const raw = Buffer.alloc((width * 3 + 1) * height, 0);
  const idat = zlib.deflateSync(raw);
  return Buffer.concat([sig, chunk("IHDR", ihdr), chunk("IDAT", idat), chunk("IEND", Buffer.alloc(0))]);
}
const LARGE_PNG = makePng(300, 200);
const SMALL_AVATAR_PNG = makePng(32, 32);

async function run() {
  console.log("=== Running Real Headless Chromium E2E Tests for Media Sniffer & Batch Grabber ===");

  const server = http.createServer((req, res) => {
    if (req.url.startsWith("/watch")) {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(buildTestHtml());
    } else if (req.url.includes("avatar")) {
      res.writeHead(200, { "Content-Type": "image/png" });
      res.end(SMALL_AVATAR_PNG);
    } else {
      res.writeHead(200, { "Content-Type": "image/png" });
      res.end(LARGE_PNG);
    }
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  const pageUrl = `http://youtube.com.localhost:${port}/watch?v=stream123`;

  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), "idm-chrome-test-"));
  const chromeProc = spawn(CHROME_PATH, [
    "--headless=new",
    "--disable-gpu",
    "--no-first-run",
    "--no-default-browser-check",
    `--user-data-dir=${userDataDir}`,
    "--remote-debugging-port=0",
    "--window-size=1280,900",
    pageUrl
  ], { stdio: ["ignore", "pipe", "pipe"] });

  const wsUrl = await new Promise((resolve, reject) => {
    let stderr = "";
    const timer = setTimeout(() => reject(new Error("Timed out waiting for Chrome DevTools WS URL: " + stderr)), 10000);
    chromeProc.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
      const match = stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) {
        clearTimeout(timer);
        resolve(match[1]);
      }
    });
    chromeProc.on("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`Chrome exited early with code ${code}: ${stderr}`));
    });
  });

  try {
    // Get target page WebSocket URL
    const debugPort = new URL(wsUrl).port;
    let pageTarget = null;
    for (let attempt = 0; attempt < 30; attempt++) {
      const targets = await fetch(`http://127.0.0.1:${debugPort}/json/list`).then(r => r.json());
      pageTarget = targets.find(t => t.type === "page" && t.url.includes("/watch"));
      if (pageTarget) break;
      await new Promise(r => setTimeout(r, 100));
    }
    assert(pageTarget, "Could not find target page in Headless Chrome");

    const ws = new WebSocket(pageTarget.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      ws.addEventListener("open", resolve, { once: true });
      ws.addEventListener("error", reject, { once: true });
    });

    let msgId = 0;
    function sendCdp(method, params = {}) {
      const id = ++msgId;
      return new Promise((resolve, reject) => {
        const onMessage = (event) => {
          const data = JSON.parse(event.data);
          if (data.id === id) {
            ws.removeEventListener("message", onMessage);
            if (data.error) reject(new Error(data.error.message));
            else resolve(data.result);
          }
        };
        ws.addEventListener("message", onMessage);
        ws.send(JSON.stringify({ id, method, params }));
      });
    }

    async function evaluate(expression) {
      const res = await sendCdp("Runtime.evaluate", {
        expression,
        returnByValue: true,
        awaitPromise: true
      });
      if (res.exceptionDetails) {
        throw new Error("Page evaluation exception: " + JSON.stringify(res.exceptionDetails));
      }
      return res.result.value;
    }

    // Wait for page DOM elements to be ready
    for (let i = 0; i < 30; i++) {
      const ready = await evaluate(`Boolean(document.getElementById('bellBtn') && document.getElementById('mainVideo'))`);
      if (ready) break;
      await new Promise(r => setTimeout(r, 100));
    }

    // =========================================================================
    // TEST 1 (Image 3): Floating download bar never appears on header icons,
    // and positions inside video top-right (never overlapping header above)
    // =========================================================================
    console.log("-> 1. Verifying Floating Bar exclusion on header icons & pixel geometry on video...");
    const floatResult = await evaluate(`(() => {
      // 1a. Initially, without hovering media, no floating bar is visible
      const initialBar = document.querySelector('.idm-floating-bar.idm-visible');

      // 1b. Hover over Notification Bell icon in the 56px header
      const bell = document.getElementById('bellBtn');
      const bellRect = bell.getBoundingClientRect();
      document.dispatchEvent(new MouseEvent('mousemove', {
        clientX: Math.round(bellRect.left + bellRect.width / 2),
        clientY: Math.round(bellRect.top + bellRect.height / 2),
        bubbles: true
      }));
      const barOnBell = document.querySelector('.idm-floating-bar.idm-visible');

      // 1c. Hover over Avatar icon in the 56px header (wait 70ms for throttle)
      return new Promise(resolve => setTimeout(() => {
        const avatar = document.getElementById('avatarIcon');
        const avatarRect = avatar.getBoundingClientRect();
        document.dispatchEvent(new MouseEvent('mousemove', {
          clientX: Math.round(avatarRect.left + avatarRect.width / 2),
          clientY: Math.round(avatarRect.top + avatarRect.height / 2),
          bubbles: true
        }));
        const barOnAvatar = document.querySelector('.idm-floating-bar.idm-visible');

        // 1d. Hover inside main <video> player
        setTimeout(() => {
          const video = document.getElementById('mainVideo');
          const vRect = video.getBoundingClientRect();
          const headerRect = document.getElementById('masthead-container').getBoundingClientRect();
          document.dispatchEvent(new MouseEvent('mousemove', {
            clientX: Math.round(vRect.left + 200),
            clientY: Math.round(vRect.top + 150),
            bubbles: true
          }));
          const bar = document.querySelector('.idm-floating-bar');
          const barRect = bar ? bar.getBoundingClientRect() : null;
          const barStyle = bar ? getComputedStyle(bar) : null;
          resolve({
            initialBarVisible: !!initialBar,
            barOnBellVisible: !!barOnBell,
            barOnAvatarVisible: !!barOnAvatar,
            barVisibleOnVideo: !!(bar && bar.classList.contains('idm-visible') && barStyle.visibility === 'visible'),
            barRect: barRect ? { top: barRect.top, left: barRect.left, right: barRect.right, bottom: barRect.bottom, width: barRect.width, height: barRect.height } : null,
            videoRect: { top: vRect.top, left: vRect.left, right: vRect.right, bottom: vRect.bottom },
            headerBottom: headerRect.bottom
          });
        }, 80);
      }, 80));
    })()`);

    assert.equal(floatResult.initialBarVisible, false, "Floating bar must not auto-appear without hovering media");
    assert.equal(floatResult.barOnBellVisible, false, "Floating bar must NEVER appear when hovering notification bell icon");
    assert.equal(floatResult.barOnAvatarVisible, false, "Floating bar must NEVER appear when hovering avatar icon");
    assert.equal(floatResult.barVisibleOnVideo, true, "Floating bar must appear when hovering inside <video>");
    assert(floatResult.barRect.top >= floatResult.videoRect.top, `Floating bar top (${floatResult.barRect.top}px) must be inside video top (${floatResult.videoRect.top}px)`);
    assert(floatResult.barRect.top >= floatResult.headerBottom, `Floating bar top (${floatResult.barRect.top}px) must be below header bottom (${floatResult.headerBottom}px)`);
    console.log(`   ✓ Floating bar geometry verified: headerBottom=${floatResult.headerBottom}px, videoTop=${floatResult.videoRect.top}px, barTop=${floatResult.barRect.top}px`);

    // =========================================================================
    // TEST 2 (Image 1 & Image 2): Stream deduplication + Batch Grabber Filter & Selection
    // =========================================================================
    console.log("-> 2. Verifying Stream Deduplication & Batch Media Grabber Filtering/Selection in real DOM...");
    const grabberResult = await evaluate(`(() => {
      // Simulate 20 googlevideo.com/videoplayback stream chunk notifications while watching stream
      for (let i = 1; i <= 20; i++) {
        for (const fn of window.__msgListeners) {
          fn({
            action: 'media_stream_detected',
            mediaItem: {
              url: 'https://rr1---sn-g530uxow2-ioqe.googlevideo.com/videoplayback?id=abc&itag=248&range=' + (i * 1000) + '-' + ((i + 1) * 1000) + '&rn=' + i + '&ump=1',
              filename: 'videoplayback.mp4',
              mime: 'video/mp4'
            }
          });
        }
      }

      // Open Batch Media Grabber
      for (const fn of window.__msgListeners) {
        fn({ action: 'open_batch_grabber' });
      }

      const modal = document.getElementById('idm-batch-modal');
      const allRows = Array.from(modal.querySelectorAll('.idm-batch-row'));
      const categories = allRows.map(r => r.getAttribute('data-category'));
      const names = allRows.map(r => r.querySelector('.idm-item-name').textContent);

      function measureRows() {
        return allRows.map(r => {
          const cs = getComputedStyle(r);
          const rect = r.getBoundingClientRect();
          const chk = r.querySelector('.idm-item-check');
          return {
            category: r.getAttribute('data-category'),
            display: cs.display,
            height: rect.height,
            checked: chk.checked
          };
        });
      }

      const stateAll = {
        rows: measureRows(),
        selectedText: document.getElementById('idmSelectedNum').textContent,
        totalText: document.getElementById('idmTotalVisible').textContent,
        btnText: document.getElementById('idmDownloadBatch').textContent
      };

      // Click "Hình ảnh" tab
      modal.querySelector('.idm-tab-btn[data-filter="image"]').click();
      const stateImageTab = {
        rows: measureRows(),
        selectedText: document.getElementById('idmSelectedNum').textContent,
        totalText: document.getElementById('idmTotalVisible').textContent,
        btnText: document.getElementById('idmDownloadBatch').textContent
      };

      // Click "Bỏ chọn" while on "Hình ảnh" tab
      document.getElementById('idmDeselectAll').click();
      const stateAfterDeselect = {
        rows: measureRows(),
        selectedText: document.getElementById('idmSelectedNum').textContent,
        totalText: document.getElementById('idmTotalVisible').textContent,
        btnDisabled: document.getElementById('idmDownloadBatch').disabled
      };

      // Click "Chọn tất cả" while on "Hình ảnh" tab
      document.getElementById('idmSelectAll').click();
      const stateAfterSelectAll = {
        rows: measureRows(),
        selectedText: document.getElementById('idmSelectedNum').textContent,
        totalText: document.getElementById('idmTotalVisible').textContent,
        btnDisabled: document.getElementById('idmDownloadBatch').disabled
      };

      // Click Download while on "Hình ảnh" tab -> must only send the 3 image items
      window.__sentMessages.length = 0;
      document.getElementById('idmDownloadBatch').click();
      const sentBatchMsg = window.__sentMessages.find(m => m.action === 'batch_download_items');

      return {
        totalItems: allRows.length,
        categories,
        names,
        stateAll,
        stateImageTab,
        stateAfterDeselect,
        stateAfterSelectAll,
        sentBatchCount: sentBatchMsg ? sentBatchMsg.items.length : 0,
        sentBatchTypes: sentBatchMsg ? sentBatchMsg.items.map(i => i.type) : []
      };
    })()`);

    // Verify Issue 1: Only 1 video item (not 20 duplicate videoplayback.mp4!), 3 images/gif, 1 zip file = 5 total items
    const videoRowsCount = grabberResult.categories.filter(c => c === "video").length;
    const imageRowsCount = grabberResult.categories.filter(c => c === "image").length;
    const fileRowsCount = grabberResult.categories.filter(c => c === "file").length;
    assert.equal(videoRowsCount, 1, `Expected exactly 1 video item (no duplicate videoplayback chunks), got ${videoRowsCount}: ${JSON.stringify(grabberResult.names)}`);
    assert.equal(imageRowsCount, 3, `Expected 3 content images/GIF (excluding avatar & svg icon), got ${imageRowsCount}`);
    assert.equal(fileRowsCount, 1, `Expected 1 file item, got ${fileRowsCount}`);
    assert.equal(grabberResult.totalItems, 5, "Expected 5 total items in Batch Grabber");
    console.log(`   ✓ Stream deduplication verified: 20 videoplayback chunks collapsed to ${videoRowsCount} main stream entry (${grabberResult.names[0]})`);

    // Verify Issue 2: Real computed style & bounding box height when filtering to "image" tab
    for (const r of grabberResult.stateImageTab.rows) {
      if (r.category === "image") {
        assert.equal(r.display, "flex", "Image row must have computed display: flex on Image tab");
        assert(r.height > 30, `Image row must have rendered height > 30px, got ${r.height}`);
      } else {
        assert.equal(r.display, "none", `Non-image row (${r.category}) must have computed display: none on Image tab`);
        assert.equal(r.height, 0, `Non-image row (${r.category}) must have rendered height 0px on Image tab`);
      }
    }
    assert.equal(grabberResult.stateImageTab.selectedText, "3", "Selected count on Image tab must be 3");
    assert.equal(grabberResult.stateImageTab.totalText, "3", "Total visible count on Image tab must be 3");
    assert.equal(grabberResult.stateImageTab.btnText, "Tải 3 mục đã chọn");

    // Verify Deselect All on Image tab
    assert.equal(grabberResult.stateAfterDeselect.selectedText, "0", "Selected count after Deselect All must be 0");
    assert.equal(grabberResult.stateAfterDeselect.totalText, "3");
    assert.equal(grabberResult.stateAfterDeselect.btnDisabled, true, "Download button must be disabled when 0 items selected in active tab");

    // Verify Select All & Download on Image tab
    assert.equal(grabberResult.stateAfterSelectAll.selectedText, "3", "Selected count after Select All must be 3");
    assert.equal(grabberResult.stateAfterSelectAll.btnDisabled, false);
    assert.equal(grabberResult.sentBatchCount, 3, "Clicking download on Image tab must only send the 3 selected image items");
    assert(grabberResult.sentBatchTypes.every(t => t === "image" || t === "gif"), "Downloaded items from Image tab must all be images/gifs");
    console.log("   ✓ Tab filtering (computed display:none & height:0px), Select All, Deselect All, and scoped batch download verified in real Chromium!");

    ws.close();
  } finally {
    chromeProc.kill("SIGKILL");
    server.close();
    fs.rmSync(userDataDir, { recursive: true, force: true });
  }

  console.log("\n=======================================================");
  console.log("  ALL REAL CHROMIUM E2E & GEOMETRY TESTS PASSED 100%!");
  console.log("=======================================================\n");
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
