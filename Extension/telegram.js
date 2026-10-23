// Isolated world only: page scripts never receive transfer tokens or file paths.
(() => {
  const items = new Map();
  const viewerSelector = '#MediaViewer,.MediaViewer,.media-viewer,.media-viewer-whole';
  const visible = el => {
    if (!el?.isConnected || el.closest('[hidden],[inert],[aria-hidden="true"]')) return false;
    for (let p = el; p; p = p.parentElement) {
      const css = getComputedStyle(p);
      if (css.display === 'none' || css.visibility === 'hidden' || css.opacity === '0') return false;
    }
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && r.bottom >= 0 && r.top <= innerHeight;
  };
  // D-F4: luôn gọi per-element saveControl(el), không bao giờ truyền mảng
  // controls. Guard typeof để TypeError không bị scan nuốt thành im lặng.
  const saveControl = el => {
    if (!el || typeof el.matches !== 'function') return false;
    try {
      if (el.matches('a[download]')) return true;
      const cls = typeof el.className === 'string' ? el.className : '';
      const parts = [el.title, typeof el.getAttribute === 'function' ? el.getAttribute('aria-label') : '', cls];
      try {
        if (typeof el.querySelectorAll === 'function') {
          for (const x of el.querySelectorAll('[class]')) parts.push(typeof x.className === 'string' ? x.className : '');
        }
      } catch (_) {}
      return /download|save (as|file|image|video|audio)|tải xuống|lưu (file|ảnh)|ダウンロード/i.test(parts.join(' '));
    } catch (_) { return false; }
  };
  const isSave = el => saveControl(el) && !el.disabled && el.getAttribute('aria-disabled') !== 'true' &&
    !el.querySelector('.ProgressSpinner,.progress-spinner,[role="progressbar"]');
  const restricted = (el, scope) => !!(el.closest('.no-forwards') || scope.closest('.no-forwards'));
  const errorMessage = code => ({
    website_save_unavailable: 'Telegram đang bật hạn chế lưu mục này',
    website_save_not_found: 'Chưa tìm thấy nút Download/Save gốc trong viewer',
    website_save_not_ready: 'Nút Download/Save chưa sẵn sàng. Chờ rồi thử lại',
    attachment_viewer_required: 'Mở attachment trong viewer Telegram rồi thử lại',
    selection_required: 'Có nhiều mục tải. Chọn rõ mục trong popup extension',
    source_changed: 'Mục đã thay đổi. Chọn lại attachment'
  }[code] || 'Không xác định được mục tải. Chọn lại attachment');
  const fingerprint = (el, save, scope) => JSON.stringify([
    location.href, el.currentSrc || el.src || el.href || '', scope.getAttribute('data-mid') || scope.getAttribute('data-message-id'),
    [...scope.querySelectorAll('video,audio,img')].map(x => [x.currentSrc || x.src || '', x.getAttribute('data-mid')]),
    restricted(el, scope)
  ]);
  function prepare(el) {
    if (!visible(el)) throw Error('source_changed');
    // Web K puts its Save toolbar beside the inner .media-viewer content.
    // The outer viewer owns both the selected media and its native Save action.
    const viewer = el.closest('.media-viewer-whole') || el.closest(viewerSelector);
    const scope = viewer || el.closest('[data-mid],[data-message-id]') || el.parentElement;
    if (!scope) throw Error('attachment_viewer_required');
    // D-F3: no-forwards ném website_save_unavailable NGAY khi restricted đúng,
    // trước mọi nhánh save (kể cả khi vẫn tìm thấy nút Save). Fingerprint giữ
    // nguyên restricted để check() vẫn phát hiện đổi trạng thái.
    if (restricted(el, scope)) throw Error('website_save_unavailable');
    const controls = [...scope.querySelectorAll('button,[role="button"],a[download],.btn-icon')].filter(x => visible(x) && saveControl(x));
    if (saveControl(el)) controls.push(el);
    let saves = controls.filter(isSave);
    saves = [...new Set(saves)].filter(x => !saves.some(parent => parent !== x && parent.contains(x)));
    // Message menus can refer to an entire album. Only a viewer or a concrete
    // download anchor supplies a single selected action for this button.
    if (!viewer) saves = isSave(el) ? [el] : saves.filter(x => x.matches('a[download]'));
    if (!saves.length) {
      if (restricted(el, scope)) throw Error('website_save_unavailable');
      if (!viewer && !el.matches('a[download]') && !saveControl(el)) throw Error('attachment_viewer_required');
      throw Error(controls.length ? 'website_save_not_ready' : 'website_save_not_found');
    }
    if (saves.length !== 1) throw Error('selection_required');
    const save = saves[0]; const handle = crypto.randomUUID();
    el.setAttribute('data-idm-selected', handle); save.setAttribute('data-idm-save', handle);
    if (items.size >= 200) {
      for (const [old, item] of items) if (!item.el.isConnected) items.delete(old);
      if (items.size >= 200) throw Error('selection_required');
    }
    const primary = el.matches('video,audio,img') ? el : viewer?.querySelector('video,audio,img');
    const kind = primary?.matches('video') ? 'video' : primary?.matches('audio') ? 'audio' : primary?.matches('img') ? 'image' : 'file';
    const item = {el, save, scope, fingerprint: fingerprint(el, save, scope)}; items.set(handle, item);
    // D-F16: tên theo mid (scan() sẽ đánh lại index); bỏ tên cứng "Attachment Telegram.*".
    return {handle, requiresConfirmation: !viewer && !save.matches('a[download]'), source: el.currentSrc || el.src || el.href || '', mediaKind: kind, filename: telegramFileName(scope, 0, kind),
      expectedDuration: Number.isFinite(el.duration) && el.duration > 0 ? el.duration : undefined};
  }
  function check(handle) {
    const item = items.get(handle);
    return !!item && visible(item.el) && (item.saving || (visible(item.save) && isSave(item.save))) && fingerprint(item.el, item.save, item.scope) === item.fingerprint;
  }
  // D-F16: tên file theo mid/index thay vì cứng "Attachment Telegram.*".
  const telegramFileName = (scope, index, kind) => {
    let mid = '';
    try { mid = scope.getAttribute('data-mid') || scope.getAttribute('data-message-id') || ''; } catch (_) {}
    mid = String(mid).replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 32) || 'chat';
    const ext = kind === 'video' ? 'mp4' : kind === 'audio' ? 'ogg' : kind === 'image' ? 'jpg' : 'bin';
    return `Telegram_${mid}_${index}.${ext}`;
  };
  window.__idmBrowser = {prepare, check, errorMessage,
    markSaving(handle) { if (!check(handle)) return false; items.get(handle).saving = true; return true; },
    scan() {
      const telegram = location.hostname === 'web.telegram.org';
      const selector = telegram ? '#MediaViewer video,#MediaViewer audio,#MediaViewer img,.media-viewer-whole video,.media-viewer-whole img,.MediaViewer video,.MediaViewer img,a[download],button,[role="button"],.btn-icon' : 'a[download],button,[role="button"]';
      // D-F16: giới hạn scan trong viewer đang mở (nếu có) thay vì toàn document.
      let root = null;
      try { root = (typeof document.querySelector === 'function' && telegram) ? (document.querySelector('.media-viewer-whole,#MediaViewer,.MediaViewer') || null) : null; } catch (_) { root = null; }
      const scope0 = root || document;
      const seen = new Map(), results = [];
      for (const el of [...scope0.querySelectorAll(selector)].filter(visible)) {
        if (!el.matches('video,audio,img') && !isSave(el)) continue;
        try {
          const item = prepare(el), internal = items.get(item.handle);
          if (seen.has(internal.save)) { internal.save.setAttribute("data-idm-save", seen.get(internal.save)); items.delete(item.handle); continue; }
          seen.set(internal.save, item.handle);
          item.filename = telegramFileName(internal.scope, results.length, item.mediaKind);
          results.push(item);
        } catch {}
        if (results.length >= 30) break;
      }
      return results;
    }
  };
})();
