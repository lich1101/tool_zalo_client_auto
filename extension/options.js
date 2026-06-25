const tenantUrlInput = document.getElementById("tenantUrl");
const apiKeyInput = document.getElementById("apiKey");
const saveBtn = document.getElementById("saveBtn");
const testBtn = document.getElementById("testBtn");
const statusEl = document.getElementById("status");

function setStatus(message, kind = "ok") {
  statusEl.textContent = message;
  statusEl.className = `status ${kind}`;
}

async function load() {
  const { settings } = await chrome.storage.local.get("settings");
  if (settings) {
    tenantUrlInput.value = settings.tenantUrl || "";
    apiKeyInput.value = settings.apiKey || "";
  }
}

saveBtn.addEventListener("click", async () => {
  const settings = {
    tenantUrl: tenantUrlInput.value.trim(),
    apiKey: apiKeyInput.value.trim()
  };
  if (!settings.tenantUrl || !settings.apiKey) {
    setStatus("Cần nhập cả tenant URL và API key.", "error");
    return;
  }
  await chrome.runtime.sendMessage({ type: "campaio:set-settings", payload: settings });
  setStatus("Đã lưu cấu hình.", "ok");
});

testBtn.addEventListener("click", async () => {
  setStatus("Đang test kết nối...", "ok");
  const settings = {
    tenantUrl: tenantUrlInput.value.trim(),
    apiKey: apiKeyInput.value.trim()
  };
  await chrome.runtime.sendMessage({ type: "campaio:set-settings", payload: settings });
  // Trigger an immediate poll: if outbox call returns 200 (even empty), creds are valid.
  const response = await chrome.runtime.sendMessage({ type: "campaio:poll-now" });
  if (response?.ok) {
    setStatus("Kết nối OK. Extension đã đăng ký với tenant.", "ok");
  } else {
    setStatus(`Lỗi: ${response?.error || "Không rõ"}`, "error");
  }
});

load();
