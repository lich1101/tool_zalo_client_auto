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

  if (window.__CAMPAIO_BRIDGE__ && window.__CAMPAIO_BRIDGE__.syncInterval) clearInterval(window.__CAMPAIO_BRIDGE__.syncInterval);
  if (window.__CAMPAIO_BRIDGE__ && window.__CAMPAIO_BRIDGE__.pollInterval) clearInterval(window.__CAMPAIO_BRIDGE__.pollInterval);

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
    sendButton: ["#btnSendMsg", ".btn-send", "button[aria-label='Gửi']"],
    searchInput: ["#contact-search-input", "input#contactSearch", "input[placeholder*='Tìm kiếm']", "input[placeholder*='Tìm bạn']", "input[type='search']", ".search-input input"],
    searchResultsContainer: ["#search-result", ".search-result", ".global-search-result", "#global-search-result"],
    searchResultItem: ["#search-result [data-id^='zid-']", ".search-result .search-item", ".global-search-result .contact-item", ".search-list__item", "[data-id^='zid-'].search-item"],
    searchByPhoneResult: ["[data-translate-inner='STR_FINDING_BY_PHONE']", ".search-result__phone .contact-item", ".search-global-result__friend .contact-item", "#global-search-result .contact-item"],
    searchNoResult: [".search-result__empty", ".no-result", "[data-translate-inner='STR_NO_RESULT']", ".search-empty"],
    findFriendMessageButton: [".profile-action button[title='Nhắn tin']", "button[title='Nhắn tin']", ".find-friend__action button.send-message", ".profile__action--message"],
    conversationHeaderName: [".chat-info__name", ".header-title__name", ".chat-header__name", "#header .name"],
    conversationHeaderAvatar: [".chat-info__avatar img", ".chat-header__avatar img", "#header .zavatar img"]
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

  async function waitFor(predicate, opts) {
    const { timeout = 6000, interval = 200 } = opts || {};
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      let value = null;
      try { value = predicate(); } catch { value = null; }
      if (value) return value;
      await wait(interval);
    }
    return null;
  }

  function setNativeValue(input, value) {
    const proto = input.tagName === "TEXTAREA" ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, "value") && Object.getOwnPropertyDescriptor(proto, "value").set;
    if (setter) setter.call(input, value); else input.value = value;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function currentHashUid() {
    const m = location.hash.match(/uid=([^&]+)/);
    return m ? decodeURIComponent(m[1]) : null;
  }

  function makeZaloPersonalModule() {
    const SEL = ZALO_PERSONAL_SELECTORS;
    const { $, $$ } = buildSelectorAccessors(SEL);

    function activeConversationInfo() {
      const zaloId = currentHashUid();
      if (!zaloId) return null;
      const nameNode = SEL.conversationHeaderName.map((s) => document.querySelector(s)).find(Boolean);
      const avatarNode = SEL.conversationHeaderAvatar.map((s) => document.querySelector(s)).find(Boolean);
      return {
        zaloId,
        name: (nameNode && nameNode.textContent || "").trim() || null,
        avatarUrl: (avatarNode && avatarNode.src) || null
      };
    }

    function isVisibleElement(el) {
      if (!el || !el.getClientRects || el.getClientRects().length === 0) return false;
      const style = window.getComputedStyle ? window.getComputedStyle(el) : null;
      return !style || (style.display !== "none" && style.visibility !== "hidden" && Number(style.opacity || "1") > 0);
    }

    function clickableContainer(el) {
      if (!el || !el.closest) return el || null;
      return el.closest('[role="button"], [role="option"], a, button, li, [data-id], .search-item, .contact-item') || el;
    }

    function visibleNoResult() {
      return SEL.searchNoResult
        .map((s) => document.querySelector(s))
        .find((n) => isVisibleElement(n)) || null;
    }

    function findSearchInput() {
      for (const selector of SEL.searchInput) {
        const nodes = Array.prototype.slice.call(document.querySelectorAll(selector));
        const visible = nodes.find((node) => {
          if (!isVisibleElement(node)) return false;
          const tag = (node.tagName || "").toUpperCase();
          const type = String(node.getAttribute("type") || "").toLowerCase();
          return tag === "INPUT" && ["hidden", "password", "checkbox", "radio"].indexOf(type) === -1;
        });
        if (visible) return visible;
      }
      return $( "searchInput");
    }

    async function fillSearchInput(input, value) {
      input.focus();
      if (typeof input.select === "function") input.select();
      setNativeValue(input, "");
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Backspace", code: "Backspace", bubbles: true }));
      input.dispatchEvent(new KeyboardEvent("keyup", { key: "Backspace", code: "Backspace", bubbles: true }));
      await wait(120);

      const chars = String(value).split("");
      for (const char of chars) {
        input.dispatchEvent(new KeyboardEvent("keydown", { key: char, bubbles: true }));
        const before = String(input.value || "");
        let inserted = false;
        try {
          inserted = document.execCommand && document.execCommand("insertText", false, char);
        } catch (e) {
          inserted = false;
        }
        if (!inserted || String(input.value || "") === before) {
          setNativeValue(input, before + char);
        } else {
          input.dispatchEvent(new Event("input", { bubbles: true }));
          input.dispatchEvent(new Event("change", { bubbles: true }));
        }
        input.dispatchEvent(new KeyboardEvent("keyup", { key: char, bubbles: true }));
        await wait(35);
      }

      const typedDigits = String(input.value || "").replace(/\D/g, "");
      const expectedDigits = String(value || "").replace(/\D/g, "");
      if (typedDigits.indexOf(expectedDigits) === -1) {
        setNativeValue(input, String(value));
      }
    }

    function preparePhoneSearch(phone) {
      const normalized = String(phone || "").trim();
      if (!normalized) throw new Error("phone is empty");
      const input = findSearchInput();
      if (!input) throw new Error("search box not found");
      input.focus();
      if (typeof input.select === "function") input.select();
      setNativeValue(input, "");
      rememberLookupDebug("prepared_native_search", normalized);
      return { ok: true };
    }

    function rememberLookupDebug(stage, phone, extra) {
      const digits = String(phone || "").replace(/\D/g, "");
      const inputNodes = Array.prototype.slice.call(document.querySelectorAll("input"));
      const visibleInputs = inputNodes
        .filter(isVisibleElement)
        .slice(0, 8)
        .map((input) => ({
          id: input.id || "",
          className: String(input.className || "").slice(0, 120),
          ariaLabel: input.getAttribute("aria-label") || "",
          type: input.type || "text",
          placeholder: input.getAttribute("placeholder") || "",
          hasDigits: digits ? String(input.value || "").replace(/\D/g, "").indexOf(digits) !== -1 : false
        }));
      const candidates = Array.prototype.slice.call(document.querySelectorAll("button, a, li, [role='button'], [role='option'], [data-id], div, span"));
      let candidateCount = 0;
      for (const node of candidates) {
        if (!isVisibleElement(node)) continue;
        const text = node.innerText || node.textContent || "";
        if (text.length <= 500 && digits && text.replace(/\D/g, "").indexOf(digits) !== -1) candidateCount += 1;
      }
      const bodyText = document.body ? (document.body.innerText || document.body.textContent || "") : "";
      const debug = Object.assign({
        stage: stage,
        at: new Date().toISOString(),
        hash: location.hash || "",
        inputCount: visibleInputs.length,
        inputs: visibleInputs,
        visibleNoResult: !!visibleNoResult(),
        bodyHasDigits: digits ? bodyText.replace(/\D/g, "").indexOf(digits) !== -1 : false,
        candidateCount: candidateCount
      }, extra || {});
      window.__CAMPAIO_LAST_LOOKUP_DEBUG__ = debug;
      return debug;
    }

    // Heuristic, class-name-independent: the "Tìm bạn qua số điện thoại" result
    // can be either a contact card with avatar or a compact row containing the
    // phone. Find the tightest clickable container whose visible text has it.
    function findPhoneCard(phone) {
      const digits = String(phone).replace(/\D/g, "");
      if (!digits) return null;

      const targetedSelectors = []
        .concat(SEL.searchByPhoneResult || [])
        .concat(SEL.searchResultItem || [])
        .concat(SEL.searchResultsContainer || []);
      for (const selector of targetedSelectors) {
        const nodes = Array.prototype.slice.call(document.querySelectorAll(selector));
        for (const node of nodes) {
          if (!isVisibleElement(node)) continue;
          const textDigits = (node.innerText || node.textContent || "").replace(/\D/g, "");
          if (textDigits.indexOf(digits) !== -1) return clickableContainer(node);
        }
      }

      let best = null;
      const textNodes = Array.prototype.slice.call(document.querySelectorAll("button, a, li, [role='button'], [role='option'], [data-id], div, span"));
      for (const node of textNodes) {
        if (!isVisibleElement(node)) continue;
        const text = node.innerText || node.textContent || "";
        if (text.length > 500) continue;
        if (text.replace(/\D/g, "").indexOf(digits) === -1) continue;
        const candidate = clickableContainer(node);
        if (!candidate || candidate === document.body || candidate === document.documentElement) continue;
        if (!best || (candidate.innerText || candidate.textContent || "").length < (best.innerText || best.textContent || "").length) {
          best = candidate;
        }
      }
      if (best) return best;

      const imgs = Array.prototype.slice.call(document.querySelectorAll("img"));
      for (const img of imgs) {
        let el = img;
        for (let depth = 0; depth < 6 && el; depth += 1) {
          el = el.parentElement;
          if (!el) break;
          if (!isVisibleElement(el)) break;
          const txt = (el.textContent || "").replace(/\D/g, "");
          if (txt.indexOf(digits) !== -1) {
            return clickableContainer(el);
          }
        }
      }
      return null;
    }

    function extractCardInfo(card, phone) {
      const digits = String(phone).replace(/\D/g, "");
      let zaloId = null;
      const dataIdEl = (card.matches && card.matches("[data-id]")) ? card : (card.querySelector && card.querySelector("[data-id]"));
      const dataId = dataIdEl && dataIdEl.getAttribute("data-id");
      if (dataId && dataId.indexOf("zid-") === 0) zaloId = dataId.slice(4);
      if (!zaloId && card.querySelector) {
        const link = card.querySelector("a[href*='uid=']");
        if (link) { const m = link.href.match(/uid=([^&]+)/); if (m) zaloId = decodeURIComponent(m[1]); }
      }
      const img = card.querySelector && card.querySelector("img");
      const avatarUrl = img ? img.src : null;
      let name = null;
      const lines = ((card.innerText || card.textContent || "")).split("\n").map((s) => s.trim()).filter(Boolean);
      for (const line of lines) {
        if (line.replace(/\D/g, "").indexOf(digits) !== -1) continue; // phone line
        if (/^(số điện thoại|tìm bạn|nhắn tin|kết bạn)/i.test(line)) continue; // labels/buttons
        name = line; break;
      }
      return { name: name, avatarUrl: avatarUrl, zaloId: zaloId };
    }

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
            name: ((nameNode && nameNode.textContent) || "").trim(),
            avatarUrl: (avatarNode && avatarNode.src) || null
          });
        }
        const match = location.hash.match(/uid=([^&]+)/);
        const messages = [];
        if (match) {
          const externalId = decodeURIComponent(match[1]);
          for (const row of $$( "messageRow").slice(-80)) {
            const contentNode = SEL.messageContent.map((s) => row.querySelector(s)).find(Boolean);
            const content = ((contentNode && contentNode.textContent) || "").trim();
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
      },
      preparePhoneSearch,
      async searchByPhone(phone, opts) {
        opts = opts || {};
        const normalized = String(phone || "").trim();
        if (!normalized) throw new Error("phone is empty");
        const initialUid = currentHashUid();
        const input = await waitFor(() => findSearchInput(), { timeout: 8000 });
        if (!input) throw new Error("search box not found");
        if (!opts.preparedSearch) {
          await fillSearchInput(input, normalized);
          await wait(300);
          input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", bubbles: true }));
          input.dispatchEvent(new KeyboardEvent("keyup", { key: "Enter", code: "Enter", bubbles: true }));
        } else {
          input.focus();
          rememberLookupDebug("waiting_native_search", normalized);
        }

        // Poll for: an already-open chat, an explicit no-result indicator, or a
        // result card matched heuristically (avatar + phone digits).
        const startedAt = Date.now();
        const found = await waitFor(() => {
          const card = findPhoneCard(normalized);
          if (card) return { card: card };
          const uid = currentHashUid();
          if (uid && uid !== initialUid && $( "composeBox")) return { opened: true };
          const noResult = visibleNoResult();
          if (noResult && Date.now() - startedAt > 8000) return { empty: true };
          return null;
        }, { timeout: 12000, interval: 300 });

        if (!found) return { found: false, reason: "timeout", debug: rememberLookupDebug("timeout", normalized) };
        if (found.empty) return { found: false, reason: "no_result", debug: rememberLookupDebug("no_result", normalized) };

        // Read identity from the card before clicking (the click may navigate).
        let info = { name: null, avatarUrl: null, zaloId: null };
        if (found.card) {
          info = extractCardInfo(found.card, normalized);
          rememberLookupDebug("card_found", normalized, { hasName: !!info.name, hasZaloId: !!info.zaloId });
        }

        // Try to open the conversation to capture the stable uid + header.
        if (found.card) {
          const btn = SEL.findFriendMessageButton
            .map((s) => found.card.querySelector && found.card.querySelector(s))
            .find(Boolean);
          try { (btn || found.card).click(); } catch (e) { /* ignore */ }
        }
        const uid = await waitFor(() => {
          const currentUid = currentHashUid();
          if (!currentUid || !$( "composeBox")) return null;
          if (currentUid !== initialUid) return currentUid;
          if (info.zaloId && info.zaloId === currentUid) return currentUid;
          return null;
        }, { timeout: 8000, interval: 300 });
        if (uid) {
          const conv = activeConversationInfo();
          rememberLookupDebug("chat_opened", normalized, { uidChanged: uid !== initialUid });
          return {
            found: true,
            zaloId: uid,
            name: (conv && conv.name) || info.name,
            avatarUrl: (conv && conv.avatarUrl) || info.avatarUrl
          };
        }
        // Found in search but couldn't open a chat (stranger profile modal etc.).
        // Still report found so the backend saves the customer by phone + name.
        rememberLookupDebug("card_without_chat", normalized, { hasName: !!info.name, hasZaloId: !!info.zaloId });
        return { found: true, zaloId: info.zaloId, name: info.name, avatarUrl: info.avatarUrl };
      },
      async openByPhone(phone, opts) {
        const result = await this.searchByPhone(phone, opts || {});
        if (!result.found) throw new Error("Không tìm thấy Zalo cho số " + phone + " (" + (result.reason || "no_result") + ")");
        return result;
      },
      async fetchHistory(opts) {
        const { phone, recipientZaloId, limit } = opts || {};
        let zaloId = recipientZaloId || null;
        if (zaloId) {
          await this.openConversation(zaloId);
        } else if (phone) {
          const opened = await this.openByPhone(phone, { preparedSearch: !!(opts && opts.preparedSearch) });
          zaloId = opened.zaloId;
        }
        zaloId = zaloId || currentHashUid();
        if (!zaloId) throw new Error("No conversation open to read history");
        await waitFor(() => $$( "messageRow").length > 0, { timeout: 5000 });
        const snapshot = await this.scrape();
        const messages = (snapshot.messages || []).slice(-(limit || 80));
        return { zaloId, messages };
      },
      async sendByPhone(opts) {
        const { phone, recipientZaloId, content } = opts || {};
        if (!content) throw new Error("content is empty");
        let zaloId = recipientZaloId || null;
        if (zaloId) {
          await this.openConversation(zaloId);
        } else {
          const opened = await this.openByPhone(phone, { preparedSearch: !!(opts && opts.preparedSearch) });
          zaloId = opened.zaloId;
        }
        await this.injectMessage(content);
        return { ok: true, zaloId: zaloId || currentHashUid() };
      },
      async runTask(task) {
        const t = task || {};
        if (t.taskType === "lookup_by_phone") {
          return this.searchByPhone(t.phone, { preparedSearch: !!t.preparedSearch });
        }
        if (t.taskType === "fetch_history") {
          return this.fetchHistory({ phone: t.phone, recipientZaloId: t.recipientZaloId, limit: t.payload && t.payload.limit, preparedSearch: !!t.preparedSearch });
        }
        if (t.taskType === "send_message") {
          return this.sendByPhone({ phone: t.phone, recipientZaloId: t.recipientZaloId, content: t.content, preparedSearch: !!t.preparedSearch });
        }
        throw new Error("Unknown taskType: " + t.taskType);
      },
      // Async tasks can't return through executeJavaScript (CEF can't serialize
      // a Promise, so evaluateJavascript yields null). Instead we run the task in
      // the background and stash the result in a page global that the native
      // Dart poller reads with a *synchronous* expression. Returns "started"
      // immediately.
      runTaskAsync(taskId, task) {
        const store = (window.__CAMPAIO_TASK_RESULTS__ = window.__CAMPAIO_TASK_RESULTS__ || {});
        store[taskId] = { status: "running" };
        const self = this;
        Promise.resolve()
          .then(() => self.runTask(task))
          .then((result) => { store[taskId] = { status: "done", ok: true, result: result || {} }; })
          .catch((error) => { store[taskId] = { status: "done", ok: false, error: String(error && error.message || error) }; });
        return "started";
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
      if (((snapshot.contacts && snapshot.contacts.length) || 0) === 0 && ((snapshot.messages && snapshot.messages.length) || 0) === 0) return;
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
      console.warn("[campaio-bridge] sync failed:", (error && error.message) || error);
    }
  }

  async function pollOutbox() {
    try {
      const data = await callTenant("/api/integrations/zalo-personal/outbox?limit=5");
      const items = Array.isArray(data && data.items) ? data.items : [];
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
            body: JSON.stringify({ status: "failed", errorMessage: String((error && error.message) || error).slice(0, 500) })
          }).catch(() => null);
        }
        await wait(1500);
      }
    } catch (error) {
      console.warn("[campaio-bridge] poll failed:", (error && error.message) || error);
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
    openConversation: activeModule.openConversation.bind(activeModule),
    injectMessage: activeModule.injectMessage.bind(activeModule),
    // Phone-driven automation, called by the native Dart TaskPoller via
    // evaluateToString. Each returns a plain object the Dart side JSON-encodes.
    searchByPhone: activeModule.searchByPhone.bind(activeModule),
    openByPhone: activeModule.openByPhone.bind(activeModule),
    fetchHistory: activeModule.fetchHistory.bind(activeModule),
    sendByPhone: activeModule.sendByPhone.bind(activeModule),
    preparePhoneSearch: activeModule.preparePhoneSearch.bind(activeModule),
    runTask: activeModule.runTask.bind(activeModule),
    runTaskAsync: activeModule.runTaskAsync.bind(activeModule),
    activeModule: activeModule.id
  };
  console.log(`[campaio-bridge] bootstrapped against ${TENANT_URL} module=${activeModule.id}`);
})();
