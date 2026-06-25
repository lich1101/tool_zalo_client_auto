const syncBtn = document.getElementById("syncBtn");
const pollBtn = document.getElementById("pollBtn");
const optionsLink = document.getElementById("optionsLink");
const statusEl = document.getElementById("status");

function setStatus(message) {
  statusEl.textContent = message;
}

optionsLink.addEventListener("click", (event) => {
  event.preventDefault();
  chrome.runtime.openOptionsPage();
});

syncBtn.addEventListener("click", async () => {
  setStatus("Đang đồng bộ...");
  const [tab] = await chrome.tabs.query({ url: "https://chat.zalo.me/*" });
  if (!tab) {
    setStatus("Hãy mở tab chat.zalo.me trước khi đồng bộ.");
    return;
  }
  const result = await chrome.tabs.sendMessage(tab.id, { type: "campaio:sync-now" }).catch((error) => ({ ok: false, error: String(error?.message || error) }));
  if (result?.ok) {
    const r = result.result?.result;
    setStatus(`OK · ${r?.contactsProcessed || 0} contact · ${r?.messagesIngested || 0} message`);
  } else if (result?.skipped) {
    setStatus("Không có dữ liệu mới để đồng bộ.");
  } else {
    setStatus(`Lỗi: ${result?.error || "không rõ"}`);
  }
});

pollBtn.addEventListener("click", async () => {
  setStatus("Đang kiểm tra outbox...");
  const result = await chrome.runtime.sendMessage({ type: "campaio:poll-now" });
  setStatus(result?.ok ? "Đã poll. Nếu có outbox sẽ tự inject trên tab Zalo." : `Lỗi: ${result?.error || "không rõ"}`);
});
