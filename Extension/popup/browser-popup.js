let activeBrowserSession;
const saveButton = document.getElementById('btnBrowserSave');
const selections = document.getElementById('browserSelections');
const confirmations = document.getElementById('browserConfirmations');
const send = message => chrome.runtime.sendMessage(message).then(response => {
  if (!response?.success) throw Error(response?.error || 'App chưa nhận tác vụ'); return response;
});
function button(parent, text, action) {
  const el = document.createElement('button'); el.className = 'btn-action'; el.textContent = text;
  el.addEventListener('click', async () => {
    el.disabled = true;
    try { await action(); } catch (error) { el.textContent = error.message; }
    finally { el.disabled = false; }
  }); parent.appendChild(el);
}
saveButton.addEventListener('click', async () => {
  selections.textContent = 'Đang xác định nguồn';
  try {
    const response = await send({action: 'browser_scan'}); selections.replaceChildren();
    if (!response.selections.length) { selections.textContent = 'Không có nút Download/Save gốc khả dụng cho attachment đang mở.'; return; }
    response.selections.forEach((item, index) => button(selections, `Lưu mục ${index + 1} (${item.mediaKind})`, async () => {
      const accepted = await send({action: 'browser_pick', handle: item.handle});
      if (!accepted.taskId) throw Error('App chưa trả taskId');
      activeBrowserSession = accepted.sessionId;
      selections.textContent = 'App đã nhận tác vụ. Giữ tab mở trong lúc Chrome lưu.';
    }));
  } catch (error) { selections.textContent = error.message; }
});
async function showConfirmations() {
  try {
    const response = await send({action: 'browser_jobs'});
    confirmations.replaceChildren();
    for (const job of response.jobs) {
      const status = document.createElement('p'); status.textContent = job.message || job.phase; confirmations.appendChild(status);
      button(confirmations, 'Hủy phiên tải', () => send({action: 'browser_cancel', sessionId: job.sessionId}));
      if (job.phase !== 'needs_confirmation') continue;
      const files = await chrome.downloads.search({state: 'complete', orderBy: ['-startTime'], limit: 30});
      const select = document.createElement('select');
      const empty = document.createElement('option'); empty.value = ''; empty.textContent = 'Chọn đúng file Chrome đã lưu'; select.appendChild(empty);
      for (const file of files) {
        const option = document.createElement('option'); option.value = file.id;
        option.textContent = `${file.filename.split('/').pop()} · ${file.fileSize} B · #${file.id}`; select.appendChild(option);
      }
      confirmations.appendChild(select);
      button(confirmations, 'Xác nhận đây là file đã chọn', async () => {
        if (!select.value) throw Error('Hãy chọn file trước');
        await send({action: 'browser_confirm_file', sessionId: job.sessionId, downloadId: Number(select.value)});
        confirmations.textContent = 'Hoàn tất · USER_CONFIRMED';
      });
    }
  } catch (error) { confirmations.textContent = error.message; }
}
showConfirmations();

chrome.runtime.onMessage.addListener(message => {
  if (message.action !== 'browser_status_changed') return;
  if (message.sessionId === activeBrowserSession) selections.textContent = message.message + (message.phase === 'completed' ? ' · ' + message.verification : '');
  if (message.phase === 'needs_confirmation' || message.phase === 'failed' || message.phase === 'completed') showConfirmations();
});
