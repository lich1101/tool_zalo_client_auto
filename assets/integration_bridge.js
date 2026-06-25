// Campaio Bridge — inline build for webview_cef injection.
//
// This is the SAME logic as the Chrome extension under
// ../extension/modules/zalo_personal/module.js, but bundled into one file
// because webview_cef cannot load Chrome extensions natively — it can only
// run executeJavaScript on a single string.
//
// When you change selectors or add a new module:
//   1. Update extension/modules/<module>/module.js + selectors.json (single
//      source of truth).
//   2. Mirror the change to this file so the Flutter-injected build stays
//      in sync.
//
// Expected globals (set by Dart immediately before injection):
//   window.__CAMPAIO__ = { tenantUrl, apiKey, moduleId? }
//
// Idempotent: if injected twice, clears prior intervals via __CAMPAIO_BRIDGE__.

(function bootstrap() {
  if (!window.__CAMPAIO__ || !window.__CAMPAIO__.tenantUrl || !window.__CAMPAIO__.apiKey) {
    console.warn("[campaio-bridge] settings missing; skipping bootstrap");
    return;
  }

  if (window.__CAMPAIO_BRIDGE__?.syncInterval) clearInterval(window.__CAMPAIO_BRIDGE__.syncInterval);
  if (window.__CAMPAIO_BRIDGE__?.pollInterval) clearInterval(window.__CAMPAIO_BRIDGE__.pollInterval);

  const TENANT_URL = String(window.__CAMPAIO__.tenantUrl).replace(/\/$/, "");
  const API_KEY = String(window.__CAMPAIO__.apiKey);
  const PROFILE_ID = String(window.__CAMPAIO__.profileId || "");

  // ── Module registry (inline) ────────────────────────────────────────────
  // Each module mirrors extension/modules/<id>/module.js. Add new platforms
  // here AND in extension/modules/registry.js to keep the two in sync.

  const ZALO_PERSONAL_SELECTORS = {
    conversationItem: ["[data-id^='zid-']", ".conv-list__item", "#conv-list .conv-list__item"],
    conversationName: [".conv-item-summary__name", ".conv-item__name", ".name"],
    conversationAvatar: [".conv-item-summary__avatar img", ".conv-item__avatar img", ".zavatar img"],
    messageRow: ["[data-id^='msg-']", ".msg-row", ".chat-room__message"],
    messageContent: [".msg-content", ".chat-message__content", ".text"],
    outboundMessageMarker: [".chat-item--out", ".msg-row--me", "[data-direction='outbound']"],
    composeBox: ["#richInput", ".chat-input__textarea", "[contenteditable='true'][data-id='richInput']"],
    sendButton: ["#btnSendMsg", ".btn-send", "button[aria-label='Gửi']"]
  };

  function buildSelectorAccessors(selectors) {
    return {
      $(group, root = document) {
        for (const s of selectors[group] || []) {
          const found = root.querySelector(s);
          if (found) return found;
        }
        return null;
      },
      $$(group, root = document) {
        for (const s of selectors[group] || []) {
          const found = root.querySelectorAll(s);
          if (found && found.length > 0) return [...found];
        }
        return [];
      }
    };
  }

  function wait(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

  function makeZaloPersonalModule() {
    const SEL = ZALO_PERSONAL_SELECTORS;
    const { $, $$ } = buildSelectorAccessors(SEL);

    function extractZaloId(node) {
      const dataId = node.getAttribute("data-id");
      if (dataId && dataId.startsWith("zid-")) return dataId.slice(4);
      const link = node.querySelector("a[href*='#uid=']");
      if (link) {
        const match = link.href.match(/#uid=([^&]+)/);
        if (match) return decodeURIComponent(match[1]);
      }
      return null;
    }
    function isOutboundRow(row) {
      return SEL.outboundMessageMarker.some((s) => row.matches(s) || row.closest(s));
    }
    return {
      id: "zalo_personal",
      match: (url) => /https?:\/\/chat\.zalo\.me/i.test(url),
      async scrape() {
        const contacts = [];
        for (const item of $$( "conversationItem").slice(0, 200)) {
          const externalId = extractZaloId(item);
          if (!externalId) continue;
          const nameNode = SEL.conversationName.map((s) => item.querySelector(s)).find(Boolean);
          const avatarNode = SEL.conversationAvatar.map((s) => item.querySelector(s)).find(Boolean);
          contacts.push({
            externalId,
            name: (nameNode?.textContent || "").trim(),
            avatarUrl: avatarNode?.src || null
          });
        }
        const match = location.hash.match(/uid=([^&]+)/);
        const messages = [];
        if (match) {
          const externalId = decodeURIComponent(match[1]);
          for (const row of $$( "messageRow").slice(-80)) {
            const contentNode = SEL.messageContent.map((s) => row.querySelector(s)).find(Boolean);
            const content = (contentNode?.textContent || "").trim();
            if (!content) continue;
            const direction = isOutboundRow(row) ? "outbound" : "inbound";
            messages.push({
              externalId,
              direction,
              content,
              externalSenderId: direction === "outbound" ? "self" : externalId,
              sentAt: new Date().toISOString(),
              externalMessageId: row.getAttribute("data-id") || ""
            });
          }
        }
        return { contacts, messages };
      },
      async openConversation(externalId) {
        if (location.hash.includes(`uid=${externalId}`)) return;
        location.hash = `#chat/${externalId}`;
        for (let i = 0; i < 30; i += 1) {
          await wait(200);
          if ($( "composeBox")) return;
        }
        throw new Error("Compose box not ready");
      },
      async injectMessage(content) {
        const box = $( "composeBox");
        if (!box) throw new Error("compose box missing");
        box.focus();
        if (box.tagName === "TEXTAREA" || box.tagName === "INPUT") {
          box.value = content;
          box.dispatchEvent(new Event("input", { bubbles: true }));
        } else {
          box.textContent = content;
          box.dispatchEvent(new InputEvent("input", { bubbles: true, data: content, inputType: "insertText" }));
        }
        await wait(120);
        const btn = $( "sendButton");
        if (btn) btn.click();
        else box.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
      }
    };
  }

  // Register modules — add new platforms by appending to this array.
  const MODULES = [makeZaloPersonalModule()];

  function pickModule(url) {
    return MODULES.find((m) => {
      try { return m.match(url); } catch { return false; }
    }) || null;
  }

  const activeModule = pickModule(location.href);
  if (!activeModule) {
    console.warn("[campaio-bridge] no module matched URL:", location.href);
    return;
  }

  // ── HTTP helpers ────────────────────────────────────────────────────────
  async function callTenant(path, init = {}) {
    const response = await fetch(`${TENANT_URL}${path}`, {
      ...init,
      headers: {
        "Content-Type": "application/json",
        "X-Zalo-Personal-Device-Key": API_KEY,
        ...(init.headers || {})
      }
    });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${(await response.text()).slice(0, 200)}`);
    }
    return response.json().catch(() => ({}));
  }

  async function runSync() {
    try {
      const snapshot = await activeModule.scrape();
      if ((snapshot.contacts?.length || 0) === 0 && (snapshot.messages?.length || 0) === 0) return;
      const payload = {
        contacts: snapshot.contacts.map((c) => ({
          zaloId: c.externalId,
          name: c.name,
          avatarUrl: c.avatarUrl
        })),
        messages: snapshot.messages.map((m) => ({
          zaloId: m.externalId,
          direction: m.direction,
          content: m.content,
          externalSenderId: m.externalSenderId,
          sentAt: m.sentAt,
          externalMessageId: m.externalMessageId
        })),
        deviceProfileId: PROFILE_ID || null,
        profileId: PROFILE_ID || null,
        deviceInfo: {
          os: navigator.platform,
          appVersion: "0.2.0",
          module: activeModule.id,
          profileId: PROFILE_ID || null
        }
      };
      const result = await callTenant("/api/integrations/zalo-personal/sync", {
        method: "POST",
        body: JSON.stringify(payload)
      });
      console.log("[campaio-bridge] sync:", result);
    } catch (error) {
      console.warn("[campaio-bridge] sync failed:", error?.message || error);
    }
  }

  async function pollOutbox() {
    try {
      const data = await callTenant("/api/integrations/zalo-personal/outbox?limit=5");
      const items = Array.isArray(data?.items) ? data.items : [];
      for (const item of items) {
        try {
          await activeModule.openConversation(item.recipientZaloId);
          await activeModule.injectMessage(item.content);
          await callTenant(`/api/integrations/zalo-personal/outbox/${item.id}/ack`, {
            method: "POST",
            body: JSON.stringify({ status: "sent" })
          });
        } catch (error) {
          await callTenant(`/api/integrations/zalo-personal/outbox/${item.id}/ack`, {
            method: "POST",
            body: JSON.stringify({ status: "failed", errorMessage: String(error?.message || error).slice(0, 500) })
          }).catch(() => null);
        }
        await wait(1500);
      }
    } catch (error) {
      console.warn("[campaio-bridge] poll failed:", error?.message || error);
    }
  }

  setTimeout(runSync, 4000);
  const syncInterval = setInterval(runSync, 5 * 60 * 1000);
  // Outbox polling is owned by the native Dart OutboxPoller in the Flutter
  // host (lib/src/services/outbox_poller.dart). It runs as long as the
  // desktop app is open, independent of which CEF tab is showing, and
  // routes each item to the right Zalo account session. Running a parallel
  // JS poller would race with the Dart one and double-send.
  window.__CAMPAIO_BRIDGE__ = {
    syncInterval,
    runSync,
    pollOutbox,
    openConversation: activeModule.openConversation,
    injectMessage: activeModule.injectMessage,
    activeModule: activeModule.id
  };
  console.log(`[campaio-bridge] bootstrapped against ${TENANT_URL} module=${activeModule.id}`);
})();
