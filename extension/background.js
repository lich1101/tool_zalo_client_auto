// Background service worker.
// Responsibilities:
//   1. Periodically poll the tenant outbox for messages to send.
//   2. Forward outbox items to the active chat.zalo.me content script.
//   3. Receive sync payloads from the content script and POST them.
//   4. Manage settings (tenant URL + device API key) via chrome.storage.local.
//
// Safety: this script does no scraping by itself; it only relays already-
// extracted data from the content script and outbox commands from the tenant.

const POLL_ALARM = "outbox-poll";
const POLL_PERIOD_MIN = 0.5; // 30 seconds — chrome.alarms minimum is 0.5

async function getSettings() {
  const { settings } = await chrome.storage.local.get("settings");
  return settings || { tenantUrl: "", apiKey: "" };
}

async function setSettings(next) {
  await chrome.storage.local.set({ settings: next });
}

function buildHeaders(apiKey) {
  return {
    "Content-Type": "application/json",
    "X-Zalo-Personal-Device-Key": apiKey
  };
}

async function callTenant(path, init = {}) {
  const { tenantUrl, apiKey } = await getSettings();
  if (!tenantUrl || !apiKey) {
    throw new Error("Chưa cấu hình tenant URL hoặc API key.");
  }
  const base = tenantUrl.replace(/\/$/, "");
  const url = `${base}${path}`;
  const headers = { ...(init.headers || {}), ...buildHeaders(apiKey) };
  const response = await fetch(url, { ...init, headers });
  if (!response.ok) {
    const text = await response.text().catch(() => "");
    throw new Error(`HTTP ${response.status} ${response.statusText}: ${text.slice(0, 200)}`);
  }
  return response.json().catch(() => ({}));
}

async function postSync(payload) {
  return callTenant("/api/integrations/zalo-personal/sync", {
    method: "POST",
    body: JSON.stringify(payload)
  });
}

async function fetchOutbox() {
  return callTenant("/api/integrations/zalo-personal/outbox?limit=5", {
    method: "GET"
  });
}

async function ackOutbox(itemId, status, errorMessage = null) {
  return callTenant(`/api/integrations/zalo-personal/outbox/${itemId}/ack`, {
    method: "POST",
    body: JSON.stringify({ status, errorMessage })
  });
}

async function findActiveChatTab() {
  const tabs = await chrome.tabs.query({ url: "https://chat.zalo.me/*" });
  return tabs[0] || null;
}

async function dispatchOutboxToContentScript(items) {
  if (!items || items.length === 0) return;
  const tab = await findActiveChatTab();
  if (!tab) {
    console.warn("[campaio-zalo] No chat.zalo.me tab open; outbox skipped this tick.");
    return;
  }
  for (const item of items) {
    try {
      const response = await chrome.tabs.sendMessage(tab.id, {
        type: "campaio:send-message",
        payload: item
      });
      if (response?.ok) {
        await ackOutbox(item.id, "sent");
      } else {
        await ackOutbox(item.id, "failed", response?.error || "Gửi qua content script thất bại.");
      }
    } catch (error) {
      await ackOutbox(item.id, "failed", String(error?.message || error)).catch(() => null);
    }
  }
}

async function pollOnce() {
  try {
    const { items } = await fetchOutbox();
    await dispatchOutboxToContentScript(items || []);
  } catch (error) {
    console.warn("[campaio-zalo] poll failed:", error?.message || error);
  }
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create(POLL_ALARM, { periodInMinutes: POLL_PERIOD_MIN });
});

chrome.runtime.onStartup.addListener(() => {
  chrome.alarms.create(POLL_ALARM, { periodInMinutes: POLL_PERIOD_MIN });
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === POLL_ALARM) pollOnce();
});

// Listen for content-script messages.
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  (async () => {
    try {
      if (message?.type === "campaio:sync") {
        const result = await postSync(message.payload || {});
        sendResponse({ ok: true, result });
      } else if (message?.type === "campaio:get-settings") {
        const settings = await getSettings();
        sendResponse({ ok: true, settings });
      } else if (message?.type === "campaio:set-settings") {
        await setSettings(message.payload || {});
        sendResponse({ ok: true });
      } else if (message?.type === "campaio:poll-now") {
        await pollOnce();
        sendResponse({ ok: true });
      } else {
        sendResponse({ ok: false, error: "unknown message" });
      }
    } catch (error) {
      sendResponse({ ok: false, error: String(error?.message || error) });
    }
  })();
  return true; // keep channel open for async sendResponse
});
