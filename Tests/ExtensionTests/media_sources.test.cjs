/**
 * Quét bộ nguồn media THẬT (scripts/media_sources_100.json) qua logic của
 * extension, để đảm bảo sniffer nhận diện đúng các định dạng thực tế — không
 * chỉ các URL giả trong test.
 *
 * Ba phần:
 *   1. Sniffer (`background.js` onResponseStarted) phải BẮT được mọi nguồn thật
 *      (không bị lọc nhầm là chunk/MSE/noise) và đặt đúng đuôi tệp.
 *   2. Phân loại trang video (`content.js` isVideoWatchPage) phải đúng với mọi
 *      URL nền tảng trong ma trận live.
 *   3. Danh sách nền tảng của extension phải chứa mọi nền tảng mà app resolve
 *      (URLNormalizer.swift) — chặn hai danh sách lệch nhau.
 *
 * Tất cả chạy offline (không cần mạng): dữ liệu lấy từ catalog trong repo.
 */

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const CATALOG = path.join(ROOT, 'scripts', 'media_sources_100.json');
const PLATFORM_CONFIG = path.join(ROOT, 'scripts', 'live_platform_sources.json');

function loadCatalog() {
  const raw = JSON.parse(fs.readFileSync(CATALOG, 'utf8'));
  return raw.cases.filter((c) => c.status !== 'retired' && c.access !== 'requires-auth');
}

/** Định dạng Content-Type giả lập theo loại media khai báo trong catalog. */
function contentTypeFor(kind, url) {
  const ext = (url.split('?')[0].split('#')[0].match(/\.([a-z0-9]+)$/i) || [])[1];
  if (kind === 'audio' || ['mp3', 'm4a', 'aac', 'flac', 'ogg', 'wav'].includes(ext)) return 'audio/mpeg';
  if (kind === 'image' || ['png', 'jpg', 'jpeg', 'gif', 'webp', 'tif'].includes(ext)) return 'image/png';
  return 'video/mp4';
}

/** Dựng context giả cho onResponseStarted của background.js. */
function makeSnifferContext() {
  const source = fs.readFileSync(path.join(ROOT, 'Extension', 'background.js'), 'utf8');
  const startIdx = source.indexOf('if (chrome.webRequest && chrome.webRequest.onResponseStarted)');
  const endIdx = source.indexOf('// Xóa danh sách khi đóng tab');
  assert(startIdx >= 0 && endIdx > startIdx, 'Không tìm thấy khối onResponseStarted trong background.js');

  const c = vm.createContext({
    chrome: {
      webRequest: { onResponseStarted: { addListener: (fn) => { c.handler = fn; } } },
      action: { setBadgeText: () => {}, setBadgeBackgroundColor: () => {} },
      tabs: { sendMessage: () => Promise.resolve() }
    },
    capturedMediaByTab: {},
    tabUrls: {}
  });
  vm.runInContext(source.slice(startIdx, endIdx), c);
  assert(typeof c.handler === 'function', 'Listener onResponseStarted phải được đăng ký');
  return c;
}

test('sniffer bắt được toàn bộ nguồn media thật và gán đúng đuôi tệp', () => {
  const catalog = loadCatalog();
  assert(catalog.length >= 120, `Catalog phải có ≥ 120 nguồn (thực tế: ${catalog.length})`);

  const c = makeSnifferContext();
  const missed = [];
  const badExt = [];
  const images = [];

  catalog.forEach((entry, index) => {
    // Sniffer CHỈ bắt video/audio (ảnh đi qua đường <a download> của content.js)
    // → nguồn ảnh phải bị bỏ qua có chủ đích.
    if (entry.kind === 'image') { images.push(entry.id); return; }
    const tabId = 9000 + index;
    c.handler({
      tabId,
      url: entry.url,
      statusCode: 200,
      responseHeaders: [{ name: 'Content-Type', value: contentTypeFor(entry.kind, entry.url) }],
      initiator: 'https://example.com',
      documentUrl: 'https://example.com',
      timeStamp: Date.now()
    });

    const captured = (c.capturedMediaByTab[tabId] || []);
    if (captured.length === 0) {
      missed.push(`${entry.id} (${entry.url.slice(0, 70)})`);
      return;
    }
    const filename = captured[0].filename || '';
    // Tên phải khác rỗng và không chứa dấu phân cách đường dẫn. Đuôi lạ (ví dụ
    // `format=h.264`) là hệ quả của URL — app sẽ sửa lại theo magic byte sau khi tải.
    if (!filename || filename.includes('/') || filename.includes('\\')) {
      badExt.push(`${entry.id} → "${filename}"`);
    }
  });

  assert.strictEqual(missed.length, 0,
    `Sniffer bỏ sót ${missed.length} nguồn video/audio thật:\n  ` + missed.slice(0, 10).join('\n  '));
  assert.strictEqual(badExt.length, 0,
    `Sniffer gán sai đuôi tệp cho ${badExt.length} nguồn:\n  ` + badExt.slice(0, 10).join('\n  '));
  assert(images.length > 0, 'Catalog phải có nguồn ảnh để kiểm chứng hành vi bỏ qua có chủ đích');
});

test('sniffer bỏ qua MSE chunk và trang lỗi; .ts được gắn cờ chunk', () => {
  const c = makeSnifferContext();
  const tabId = 9500;
  // MSE chunk của YouTube: phải bị bỏ qua hoàn toàn.
  c.handler({
    tabId,
    url: 'https://rr3---sn-abc.googlevideo.com/videoplayback?sq=1&range=0-100',
    statusCode: 200,
    responseHeaders: [{ name: 'Content-Type', value: 'video/mp4' }]
  });
  // Trang lỗi 403: không được coi là media.
  c.handler({
    tabId,
    url: 'https://example.com/page.html',
    statusCode: 403,
    responseHeaders: [{ name: 'Content-Type', value: 'text/html' }]
  });
  // Segment .ts của HLS: được ghi nhận nhưng phải bị đánh dấu là chunk.
  c.handler({
    tabId,
    url: 'https://cdn.example.com/seg/1000.ts',
    statusCode: 200,
    responseHeaders: [{ name: 'Content-Type', value: 'video/mp2t' }]
  });

  const captured = c.capturedMediaByTab[tabId] || [];
  const urls = captured.map((m) => m.url);
  assert(!urls.some((u) => u.includes('googlevideo.com')),
    'MSE chunk của YouTube không được bắt');
  assert(!urls.some((u) => u.includes('page.html')),
    'Trang lỗi 403 không được bắt');
  const ts = captured.find((m) => m.url.endsWith('.ts'));
  assert(ts, 'Segment .ts phải được ghi nhận');
  assert.strictEqual(ts.isChunk, true, 'Segment .ts phải được đánh dấu isChunk (không phải media chính)');
});

test('isVideoWatchPage phân loại đúng mọi URL nền tảng trong ma trận live', () => {
  const source = fs.readFileSync(path.join(ROOT, 'Extension', 'content.js'), 'utf8');
  const c = vm.createContext({ URL, console });
  vm.runInContext(
    source.slice(source.indexOf('function hostMatches('), source.indexOf('function findVideoPostPermalink(')),
    c
  );

  const config = JSON.parse(fs.readFileSync(PLATFORM_CONFIG, 'utf8'));
  // URL trang xem video → phải nhận ra; URL media thô/trang nhúng → không.
  const watchPatterns = [
    /youtube\.com\/(watch|shorts)/, /youtu\.be\//,
    /facebook\.com\/(watch|reel|posts|videos)/,
    /tiktok\.com\/.*\/video\//, /instagram\.com\/(reel|p)\//,
    /x\.com\/.*\/status\//, /reddit\.com\/.*\/comments\//,
    /vimeo\.com\/.*\/\d+/, /dailymotion\.com\/video\//,
    /bilibili\.com\/video\//, /^https:\/\/v?\.?redd\.it\//
  ];
  const isWatch = (u) => watchPatterns.some((re) => re.test(u));

  const wrong = [];
  for (const testCase of config.cases) {
    const expected = isWatch(testCase.url);
    const actual = c.isVideoWatchPage(testCase.url);
    if (expected !== actual) {
      wrong.push(`${testCase.id}: ${testCase.url} (mong đợi ${expected}, nhận ${actual})`);
    }
  }
  assert.strictEqual(wrong.length, 0,
    `Phân loại trang video sai ${wrong.length} ca:\n  ` + wrong.join('\n  '));
});

test('danh sách nền tảng của extension chứa mọi nền tảng mà app resolve', () => {
  // URLNormalizer.swift (app) là nguồn chuẩn; danh sách JS phải BAO HÀM nó,
  // nếu không extension sẽ không nhận ra nền tảng mà app vẫn hỗ trợ.
  const swift = fs.readFileSync(path.join(ROOT, 'Sources', 'DownloaderCore', 'Engine', 'URLNormalizer.swift'), 'utf8');
  const block = swift.match(/let knownPlatforms = \[([\s\S]*?)\]/);
  assert(block, 'Không tìm thấy knownPlatforms trong URLNormalizer.swift');
  const swiftPlatforms = Array.from(block[1].matchAll(/"([^"]+)"/g)).map((m) => m[1]);

  const js = fs.readFileSync(path.join(ROOT, 'Extension', 'content.js'), 'utf8');
  const jsBlock = js.match(/const VIDEO_PLATFORM_DOMAINS = \[([\s\S]*?)\]/);
  assert(jsBlock, 'Không tìm thấy VIDEO_PLATFORM_DOMAINS trong content.js');
  const jsPlatforms = Array.from(jsBlock[1].matchAll(/"([^"]+)"/g)).map((m) => m[1]);

  const missing = swiftPlatforms.filter((p) => !jsPlatforms.includes(p));
  assert.strictEqual(missing.length, 0,
    `Extension thiếu nền tảng có trong app: ${missing.join(', ')}`);
});
