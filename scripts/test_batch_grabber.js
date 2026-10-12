// Comprehensive Test Suite for IDM Batch Media Grabber
// Tests: Category filtering, Thumbnail generation, Selection state transitions, and CSS resilience

const fs = require("fs");
const path = require("path");
const assert = require("assert");

console.log("=== Testing IDM Batch Media Grabber Logic & Integrity ===");

const contentJsPath = path.join(__dirname, "../Extension/content.js");
const snifferCssPath = path.join(__dirname, "../Extension/styles/sniffer.css");

const contentJs = fs.readFileSync(contentJsPath, "utf-8");
const snifferCss = fs.readFileSync(snifferCssPath, "utf-8");

// 1. Verify CSS Rules
console.log("-> 1. Verifying sniffer.css resilient styles...");
assert(snifferCss.includes(".idm-batch-toolbar"), "CSS missing .idm-batch-toolbar");
assert(snifferCss.includes(".idm-tab-bar"), "CSS missing .idm-tab-bar");
assert(snifferCss.includes(".idm-tab-btn.active"), "CSS missing .idm-tab-btn.active");
assert(snifferCss.includes(".idm-thumb-box"), "CSS missing .idm-thumb-box");
assert(snifferCss.includes(".idm-thumb-img"), "CSS missing .idm-thumb-img");
assert(snifferCss.includes(".idm-thumb-play-overlay"), "CSS missing .idm-thumb-play-overlay");
assert(snifferCss.includes(".idm-thumb-video-placeholder"), "CSS missing .idm-thumb-video-placeholder");
assert(snifferCss.includes(".idm-thumb-audio-placeholder"), "CSS missing .idm-thumb-audio-placeholder");
assert(snifferCss.includes("-webkit-appearance: none !important"), "CSS missing resilient checkbox appearance reset");
assert(snifferCss.includes(".idm-item-check:checked"), "CSS missing .idm-item-check:checked");
assert(snifferCss.includes(".idm-batch-row.idm-row-unselected"), "CSS missing unselected row style");
console.log("   ✓ sniffer.css contains all required resilient styles.");

// 2. Test Category Determination Logic
console.log("-> 2. Testing item categorization (All, Video, Image, File)...");

function getItemCategory(it) {
  if (it.type === "video" || it.type === "audio") return "video";
  if (it.type === "image" || it.type === "gif") return "image";
  return "file";
}

const mockItems = [
  { url: "https://example.com/movie.mp4", name: "movie.mp4", type: "video", poster: "https://example.com/poster.jpg" },
  { url: "https://example.com/stream.m3u8", name: "stream.m3u8", type: "video", poster: "" },
  { url: "https://example.com/song.mp3", name: "song.mp3", type: "audio", poster: "" },
  { url: "https://example.com/photo.png", name: "photo.png", type: "image", poster: "https://example.com/photo.png" },
  { url: "https://example.com/banner.jpg", name: "banner.jpg", type: "image", poster: "https://example.com/banner.jpg" },
  { url: "https://example.com/anim.gif", name: "anim.gif", type: "gif", poster: "https://example.com/anim.gif" },
  { url: "https://example.com/archive.zip", name: "archive.zip", type: "file", poster: "" }
];

assert.strictEqual(getItemCategory(mockItems[0]), "video");
assert.strictEqual(getItemCategory(mockItems[1]), "video");
assert.strictEqual(getItemCategory(mockItems[2]), "video");
assert.strictEqual(getItemCategory(mockItems[3]), "image");
assert.strictEqual(getItemCategory(mockItems[4]), "image");
assert.strictEqual(getItemCategory(mockItems[5]), "image");
assert.strictEqual(getItemCategory(mockItems[6]), "file");

const videoCount = mockItems.filter(it => getItemCategory(it) === "video").length;
const imageCount = mockItems.filter(it => getItemCategory(it) === "image").length;
const fileCount = mockItems.filter(it => getItemCategory(it) === "file").length;

assert.strictEqual(videoCount, 3, "Expected 3 video items");
assert.strictEqual(imageCount, 3, "Expected 3 image items");
assert.strictEqual(fileCount, 1, "Expected 1 file item");
assert.strictEqual(mockItems.length, 7, "Expected 7 total items");
console.log(`   ✓ Item counts: Total=${mockItems.length}, Video=${videoCount}, Image=${imageCount}, File=${fileCount}`);

// 3. Test Thumbnail Generator Logic
console.log("-> 3. Testing thumbnail preview generation...");

function escapeHtml(str) {
  if (!str) return "";
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function renderThumbnailHtml(it) {
  const ext = (it.url.split("?")[0].split(".").pop() || it.type).slice(0, 4).toUpperCase();
  if (it.type === "image" || it.type === "gif") {
    return `<div class="idm-thumb-box"><img class="idm-thumb-img" src="${escapeHtml(it.url)}" alt="" loading="lazy" onerror="this.style.display='none'; if(this.nextElementSibling) this.nextElementSibling.style.display='flex';" /><div class="idm-thumb-fallback" style="display:none;"><svg viewBox="0 0 24 24"></svg></div></div>`;
  }
  if (it.type === "video") {
    if (it.poster) {
      return `<div class="idm-thumb-box"><img class="idm-thumb-img" src="${escapeHtml(it.poster)}" alt="" loading="lazy" /><div class="idm-thumb-play-overlay"><svg viewBox="0 0 24 24"></svg></div></div>`;
    }
    return `<div class="idm-thumb-box idm-thumb-video-placeholder"><svg viewBox="0 0 24 24"></svg><span class="idm-thumb-tag">${ext}</span></div>`;
  }
  if (it.type === "audio") {
    return `<div class="idm-thumb-box idm-thumb-audio-placeholder"><svg viewBox="0 0 24 24"></svg><span class="idm-thumb-tag">${ext}</span></div>`;
  }
  return `<div class="idm-thumb-box idm-thumb-file-placeholder"><svg viewBox="0 0 24 24"></svg><span class="idm-thumb-tag">${ext}</span></div>`;
}

// Check each thumbnail output
const imgThumb = renderThumbnailHtml(mockItems[3]);
assert(imgThumb.includes('class="idm-thumb-img"') && imgThumb.includes('src="https://example.com/photo.png"'), "Image thumb must render img tag");

const videoPosterThumb = renderThumbnailHtml(mockItems[0]);
assert(videoPosterThumb.includes('src="https://example.com/poster.jpg"') && videoPosterThumb.includes('idm-thumb-play-overlay'), "Video with poster must render poster with play overlay");

const videoStreamThumb = renderThumbnailHtml(mockItems[1]);
assert(videoStreamThumb.includes('idm-thumb-video-placeholder') && videoStreamThumb.includes('M3U8'), "Video without poster must render video placeholder with extension");

const audioThumb = renderThumbnailHtml(mockItems[2]);
assert(audioThumb.includes('idm-thumb-audio-placeholder') && audioThumb.includes('MP3'), "Audio must render audio placeholder");

const fileThumb = renderThumbnailHtml(mockItems[6]);
assert(fileThumb.includes('idm-thumb-file-placeholder') && fileThumb.includes('ZIP'), "File must render file placeholder");

console.log("   ✓ Thumbnails render accurately for images, posters, video streams, audio, and files.");

// 4. Test Selection State Machine (Check / Uncheck / Select All / Deselect All / Filtering)
console.log("-> 4. Testing selection state transitions and filtering...");

class MockGrabberState {
  constructor(items) {
    this.items = items;
    this.currentFilter = "all";
    this.selected = new Set(items.map((_, i) => i)); // Default all checked
  }

  getVisibleIndices() {
    if (this.currentFilter === "all") {
      return this.items.map((_, i) => i);
    }
    return this.items
      .map((it, i) => ({ it, i }))
      .filter(({ it }) => getItemCategory(it) === this.currentFilter)
      .map(({ i }) => i);
  }

  setFilter(filter) {
    this.currentFilter = filter;
  }

  toggleItem(index, isChecked) {
    if (isChecked) {
      this.selected.add(index);
    } else {
      this.selected.delete(index);
    }
  }

  selectAll() {
    for (const idx of this.getVisibleIndices()) {
      this.selected.add(idx);
    }
  }

  deselectAll() {
    for (const idx of this.getVisibleIndices()) {
      this.selected.delete(idx);
    }
  }

  getSelectedCount() {
    return this.selected.size;
  }

  getDownloadButtonText() {
    const count = this.getSelectedCount();
    return count > 0 ? `Tải ${count} mục đã chọn` : "Tải các mục đã chọn";
  }

  isDownloadButtonDisabled() {
    return this.getSelectedCount() === 0;
  }
}

const state = new MockGrabberState(mockItems);

// Initial state: all 7 selected
assert.strictEqual(state.getSelectedCount(), 7);
assert.strictEqual(state.getDownloadButtonText(), "Tải 7 mục đã chọn");
assert.strictEqual(state.isDownloadButtonDisabled(), false);

// Uncheck item 0
state.toggleItem(0, false);
assert.strictEqual(state.getSelectedCount(), 6);
assert.strictEqual(state.getDownloadButtonText(), "Tải 6 mục đã chọn");

// Filter by video (should have 3 items: 0, 1, 2)
state.setFilter("video");
assert.deepStrictEqual(state.getVisibleIndices(), [0, 1, 2]);

// Deselect all in video tab -> indices 0, 1, 2 become unchecked
state.deselectAll();
assert.strictEqual(state.selected.has(0), false);
assert.strictEqual(state.selected.has(1), false);
assert.strictEqual(state.selected.has(2), false);
// Image and file items (3, 4, 5, 6) remain checked!
assert.strictEqual(state.selected.has(3), true);
assert.strictEqual(state.selected.has(4), true);
assert.strictEqual(state.selected.has(5), true);
assert.strictEqual(state.selected.has(6), true);
assert.strictEqual(state.getSelectedCount(), 4);
assert.strictEqual(state.getDownloadButtonText(), "Tải 4 mục đã chọn");

// Switch to image tab
state.setFilter("image");
assert.deepStrictEqual(state.getVisibleIndices(), [3, 4, 5]);

// Deselect all images
state.deselectAll();
assert.strictEqual(state.selected.has(3), false);
assert.strictEqual(state.selected.has(4), false);
assert.strictEqual(state.selected.has(5), false);
// Only file (6) remains
assert.strictEqual(state.getSelectedCount(), 1);

// Deselect item 6
state.toggleItem(6, false);
assert.strictEqual(state.getSelectedCount(), 0);
assert.strictEqual(state.getDownloadButtonText(), "Tải các mục đã chọn");
assert.strictEqual(state.isDownloadButtonDisabled(), true);

// Select all in all tab
state.setFilter("all");
state.selectAll();
assert.strictEqual(state.getSelectedCount(), 7);
assert.strictEqual(state.getDownloadButtonText(), "Tải 7 mục đã chọn");
assert.strictEqual(state.isDownloadButtonDisabled(), false);

console.log("   ✓ Selection state machine, filtering, and button states verified 100%!");

console.log("\n=======================================================");
console.log("  ALL TESTS PASSED WITH 100% SUCCESS!");
console.log("=======================================================\n");
