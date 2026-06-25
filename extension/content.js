// Content script — entry point. Loads the module registry dynamically via
// chrome.runtime.getURL so module files can stay as ES modules under
// modules/<platform>/. To add a new platform, drop a new module file in
// modules/, register it in modules/registry.js, and add its host pattern
// here + in manifest.json.
//
// MV3 content scripts are classic scripts, so we use a dynamic import
// against an extension-internal URL (declared in web_accessible_resources).

(async function bootstrap() {
  let registry;
  try {
    registry = await import(chrome.runtime.getURL("modules/registry.js"));
  } catch (error) {
    console.error("[campaio-bridge] failed to load module registry:", error);
    return;
  }

  const activeModule = registry.findModuleForUrl(location.href);
  if (!activeModule) {
    console.warn("[campaio-bridge] no module matched URL:", location.href);
    return;
  }
  console.log("[campaio-bridge] active module:", activeModule.id);

  async function runSync() {
    const snapshot = await activeModule.scrape();
    if ((snapshot.contacts?.length || 0) === 0 && (snapshot.messages?.length || 0) === 0) {
      return { skipped: true };
    }
    // Adapt module's platform-neutral shape to the tenant ingest contract.
    const payload = {
      contacts: (snapshot.contacts || []).map((c) => ({
        zaloId: c.externalId,
        name: c.name,
        avatarUrl: c.avatarUrl
      })),
      messages: (snapshot.messages || []).map((m) => ({
        zaloId: m.externalId,
        direction: m.direction,
        content: m.content,
        externalSenderId: m.externalSenderId,
        sentAt: m.sentAt,
        externalMessageId: m.externalMessageId
      })),
      deviceInfo: {
        os: navigator.platform,
        appVersion: "0.2.0",
        module: activeModule.id
      }
    };
    return new Promise((resolve) => {
      chrome.runtime.sendMessage({ type: "campaio:sync", payload }, (response) => {
        resolve(response || { ok: false, error: "no response" });
      });
    });
  }

  async function handleOutboxItem(item) {
    try {
      await activeModule.openConversation(item.recipientZaloId);
      await activeModule.injectMessage(item.content);
      return { ok: true };
    } catch (error) {
      return { ok: false, error: String(error?.message || error) };
    }
  }

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type === "campaio:sync-now") {
      runSync().then((result) => sendResponse(result));
      return true;
    }
    if (message?.type === "campaio:send-message") {
      handleOutboxItem(message.payload).then((result) => sendResponse(result));
      return true;
    }
  });

  setInterval(() => { runSync().catch(() => null); }, 5 * 60 * 1000);
  setTimeout(() => { runSync().catch(() => null); }, 5000);
})();
