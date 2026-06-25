// Zalo Personal module — implements the Campaio Bridge module interface for
// chat.zalo.me. Each module exports a single registerModule(api) function
// that the core loader calls once at content-script bootstrap.
//
// Module interface (see ../module-api.md):
//   {
//     id: string,                              // matches backend outbox.module
//     match: (url: string) => boolean,         // does this module own the page?
//     scrape: () => Promise<{
//       contacts: Array<{ externalId, name, avatarUrl? }>,
//       messages: Array<{ externalId, direction, content, externalSenderId?, sentAt? }>
//     }>,
//     openConversation: (externalId) => Promise<void>,
//     injectMessage: (content) => Promise<void>
//   }
//
// All DOM selectors live in selectors.json so updates do not require a code
// change.

import SELECTORS from "./selectors.json" with { type: "json" };

function $(group, root = document) {
  for (const selector of SELECTORS[group] || []) {
    const found = root.querySelector(selector);
    if (found) return found;
  }
  return null;
}
function $$(group, root = document) {
  for (const selector of SELECTORS[group] || []) {
    const found = root.querySelectorAll(selector);
    if (found && found.length > 0) return [...found];
  }
  return [];
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
  return SELECTORS.outboundMessageMarker.some((selector) => row.matches(selector) || row.closest(selector));
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Poll for a predicate to become truthy. Returns the predicate's value (or
// null on timeout). Used everywhere instead of fixed sleeps so the flow adapts
// to Zalo's variable SPA render time.
async function waitFor(predicate, { timeout = 6000, interval = 200 } = {}) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    let value = null;
    try { value = predicate(); } catch { value = null; }
    if (value) return value;
    await wait(interval);
  }
  return null;
}

// React/Vue-controlled inputs ignore a plain `.value =` assignment because the
// framework caches the previous value. Go through the native setter + fire an
// input event so the search box actually registers the typed phone number.
function setNativeValue(input, value) {
  const proto = input.tagName === "TEXTAREA" ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
  if (setter) setter.call(input, value);
  else input.value = value;
  // React caches the last value in _valueTracker; reset it so dispatching
  // "input" actually fires onChange and the SPA search runs.
  if (input._valueTracker) input._valueTracker.setValue(" ");
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
}

function currentHashUid() {
  const match = location.hash.match(/uid=([^&]+)/);
  return match ? decodeURIComponent(match[1]) : null;
}

function phoneExternalId(phone) {
  const digits = String(phone || "").replace(/\D/g, "");
  return digits ? `phone:${digits}` : null;
}

function recipientPhone(recipient) {
  const value = String(recipient || "").trim();
  return value.startsWith("phone:") ? value.slice(6) : null;
}

function activeConversationInfo(fallbackId = null) {
  const zaloId = currentHashUid() || fallbackId;
  if (!zaloId) return null;
  const nameNode = SELECTORS.conversationHeaderName.map((s) => document.querySelector(s)).find(Boolean);
  const avatarNode = SELECTORS.conversationHeaderAvatar.map((s) => document.querySelector(s)).find(Boolean);
  return {
    zaloId,
    name: (nameNode?.textContent || "").trim() || null,
    avatarUrl: avatarNode?.src || null
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
  return SELECTORS.searchNoResult
    .map((s) => document.querySelector(s))
    .find((n) => isVisibleElement(n)) || null;
}

function findSearchInput() {
  for (const selector of SELECTORS.searchInput) {
    const nodes = [...document.querySelectorAll(selector)];
    const visible = nodes.find((node) => {
      if (!isVisibleElement(node)) return false;
      const tag = (node.tagName || "").toUpperCase();
      const type = String(node.getAttribute("type") || "").toLowerCase();
      return tag === "INPUT" && !["hidden", "password", "checkbox", "radio"].includes(type);
    });
    if (visible) return visible;
  }
  return $("searchInput");
}

async function fillSearchInput(input, value) {
  input.focus();
  if (typeof input.select === "function") input.select();
  // setNativeValue resets React's _valueTracker so the "input" event triggers
  // the SPA phone search reliably — char-by-char typing was intermittent.
  setNativeValue(input, "");
  await wait(80);
  setNativeValue(input, String(value));
  triggerPhoneSearchEvents(input);
}

function triggerPhoneSearchEvents(input) {
  if (!input) return;
  input.focus();
  try { input.dispatchEvent(new InputEvent("beforeinput", { bubbles: true, data: input.value || "", inputType: "insertText" })); } catch { /* ignore */ }
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
  input.dispatchEvent(new KeyboardEvent("keyup", { key: String(input.value || "").slice(-1) || "0", bubbles: true }));
  input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", bubbles: true }));
  input.dispatchEvent(new KeyboardEvent("keyup", { key: "Enter", code: "Enter", bubbles: true }));
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

function rememberLookupDebug(stage, phone, extra = {}) {
  const digits = String(phone || "").replace(/\D/g, "");
  const visibleInputs = [...document.querySelectorAll("input")]
    .filter(isVisibleElement)
    .slice(0, 8)
    .map((input) => ({
      id: input.id || "",
      className: String(input.className || "").slice(0, 120),
      ariaLabel: input.getAttribute("aria-label") || "",
      type: input.type || "text",
      placeholder: input.getAttribute("placeholder") || "",
      hasDigits: digits ? String(input.value || "").replace(/\D/g, "").includes(digits) : false
    }));
  const candidateCount = [...document.querySelectorAll("button, a, li, [role='button'], [role='option'], [data-id], div, span")]
    .filter((node) => {
      if (!isVisibleElement(node)) return false;
      const text = node.innerText || node.textContent || "";
      return text.length <= 500 && digits && text.replace(/\D/g, "").includes(digits);
    })
    .length;
  const debug = {
    stage,
    at: new Date().toISOString(),
    hash: location.hash || "",
    inputCount: visibleInputs.length,
    inputs: visibleInputs,
    visibleNoResult: !!visibleNoResult(),
    bodyHasDigits: digits ? (document.body.innerText || document.body.textContent || "").replace(/\D/g, "").includes(digits) : false,
    candidateCount,
    ...extra
  };
  window.__CAMPAIO_LAST_LOOKUP_DEBUG__ = debug;
  return debug;
}

// Heuristic, class-name-independent: the "Tìm bạn qua số điện thoại" result can
// be either a contact card with avatar or a compact row containing the phone.
// Find the tightest clickable container whose visible text contains the digits.
function findPhoneCard(phone) {
  const digits = String(phone).replace(/\D/g, "");
  if (!digits) return null;

  const targetedSelectors = [
    ...SELECTORS.searchByPhoneResult,
    ...SELECTORS.searchResultItem,
    ...SELECTORS.searchResultsContainer
  ];
  for (const selector of targetedSelectors) {
    for (const node of [...document.querySelectorAll(selector)]) {
      if (!isVisibleElement(node)) continue;
      const textDigits = (node.innerText || node.textContent || "").replace(/\D/g, "");
      if (textDigits.includes(digits)) return clickableContainer(node);
    }
  }

  let best = null;
  for (const node of [...document.querySelectorAll("button, a, li, [role='button'], [role='option'], [data-id], div, span")]) {
    if (!isVisibleElement(node)) continue;
    const text = node.innerText || node.textContent || "";
    if (text.length > 500) continue;
    if (!text.replace(/\D/g, "").includes(digits)) continue;
    const candidate = clickableContainer(node);
    if (!candidate || candidate === document.body || candidate === document.documentElement) continue;
    if (!best || (candidate.innerText || candidate.textContent || "").length < (best.innerText || best.textContent || "").length) {
      best = candidate;
    }
  }
  if (best) return best;

  for (const img of [...document.querySelectorAll("img")]) {
    let el = img;
    for (let depth = 0; depth < 6 && el; depth += 1) {
      el = el.parentElement;
      if (!el || !isVisibleElement(el)) break;
      if ((el.textContent || "").replace(/\D/g, "").includes(digits)) return clickableContainer(el);
    }
  }
  return null;
}

function extractCardInfo(card, phone) {
  const digits = String(phone).replace(/\D/g, "");
  let zaloId = null;
  const dataIdEl = card.matches?.("[data-id]") ? card : card.querySelector?.("[data-id]");
  const dataId = dataIdEl?.getAttribute("data-id");
  if (dataId?.startsWith("zid-")) zaloId = dataId.slice(4);
  if (!zaloId) {
    const link = card.querySelector?.("a[href*='uid=']");
    const m = link?.href.match(/uid=([^&]+)/);
    if (m) zaloId = decodeURIComponent(m[1]);
  }
  const avatarUrl = card.querySelector?.("img")?.src || null;
  let name = null;
  for (const line of (card.innerText || card.textContent || "").split("\n").map((s) => s.trim()).filter(Boolean)) {
    if (line.replace(/\D/g, "").includes(digits)) continue;
    if (/^(số điện thoại|tìm bạn|nhắn tin|kết bạn)/i.test(line)) continue;
    name = line;
    break;
  }
  return { name, avatarUrl, zaloId };
}

// Deterministic find-by-phone extractor: anchor on the "Số điện thoại: <phone>"
// line Zalo renders; the display name is the line directly above it, the avatar
// the nearest enclosing img. Mirrors integration_bridge.js.
function extractPhoneResult(phone) {
  const digits = String(phone).replace(/\D/g, "");
  if (!digits) return null;
  let phoneNode = null;
  let bestDesc = Infinity;
  for (const n of document.querySelectorAll("span, div, p")) {
    const t = n.textContent || "";
    if (!/số điện thoại/i.test(t)) continue;
    if (t.replace(/\D/g, "").indexOf(digits) === -1) continue;
    if (t.length > 80) continue;
    const d = n.querySelectorAll("*").length;
    if (d < bestDesc) { bestDesc = d; phoneNode = n; if (d === 0) break; }
  }
  if (!phoneNode) return null;
  let name = null;
  const lines = (document.body.innerText || "").split("\n").map((s) => s.trim());
  for (let i = 1; i < lines.length; i += 1) {
    if (/số điện thoại/i.test(lines[i]) && lines[i].replace(/\D/g, "").indexOf(digits) !== -1) {
      const prev = lines[i - 1];
      if (prev && prev.length <= 60
          && !/^(tìm bạn|nhắn tin|kết bạn|số điện thoại|sử dụng|người lạ|không có nhóm)/i.test(prev)
          && prev.replace(/\D/g, "").indexOf(digits) === -1) {
        name = prev;
      }
      break;
    }
  }
  let card = phoneNode;
  for (let i = 0; i < 8 && card.parentElement; i += 1) {
    card = card.parentElement;
    if (card.querySelector?.("img")) break;
  }
  return { card: clickableContainer(card), name, avatarUrl: card.querySelector?.("img")?.src || null };
}

// Find a Zalo user by phone number. Strategy:
//   1. Type the phone into the global search box.
//   2. Wait for a result row (existing conv or "tìm bạn qua SĐT" card) and click
//      it (or its "Nhắn tin" button) to open the conversation.
//   3. The authoritative success signal is the chat opening — location.hash
//      gaining `uid=<zaloId>` and the compose box appearing. We read identity
//      from the conversation header, which is stable regardless of result markup.
// Returns { found, zaloId, name, avatarUrl } — found=false when Zalo shows no
// match (or the phone has no Zalo account).
async function searchByPhone(phone, opts = {}) {
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
    triggerPhoneSearchEvents(input);
    rememberLookupDebug("waiting_native_search", normalized);
  }

  // Poll for: an already-open chat, an explicit no-result indicator, or a result
  // card matched heuristically (avatar + phone digits) — independent of Zalo's
  // exact class names.
  const startedAt = Date.now();
  const found = await waitFor(() => {
    const byLabel = extractPhoneResult(normalized);
    if (byLabel?.card) return { card: byLabel.card, byLabel };
    const card = findPhoneCard(normalized);
    if (card) return { card };
    const uid = currentHashUid();
    if (uid && uid !== initialUid && $("composeBox")) return { opened: true };
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
    if (found.byLabel) {
      info.name = found.byLabel.name || info.name;
      info.avatarUrl = found.byLabel.avatarUrl || info.avatarUrl;
    }
    rememberLookupDebug("card_found", normalized, { hasName: !!info.name, hasZaloId: !!info.zaloId });
  }

  if (found.card) {
    const btn = SELECTORS.findFriendMessageButton.map((s) => found.card.querySelector?.(s)).find(Boolean);
    try { (btn || found.card).click(); } catch { /* ignore */ }
  }
  const fallbackId = info.zaloId || phoneExternalId(normalized);
  const uid = await waitFor(() => {
    const currentUid = currentHashUid();
    if (!$("composeBox")) return null;
    if (!currentUid) return fallbackId;
    if (currentUid !== initialUid) return currentUid;
    if (info.zaloId && info.zaloId === currentUid) return currentUid;
    return null;
  }, { timeout: 8000, interval: 300 });
  if (uid) {
    const conv = activeConversationInfo(uid);
    rememberLookupDebug("chat_opened", normalized, { uidChanged: uid !== initialUid });
    return { found: true, zaloId: uid, name: conv?.name || info.name, avatarUrl: conv?.avatarUrl || info.avatarUrl };
  }
  // Found in search but couldn't open a chat (stranger profile modal etc.).
  rememberLookupDebug("card_without_chat", normalized, { hasName: !!info.name, hasZaloId: !!info.zaloId });
  return { found: true, zaloId: info.zaloId || phoneExternalId(normalized), name: info.name, avatarUrl: info.avatarUrl };
}

// Open the conversation for a phone (search → open) and return identity.
async function openByPhone(phone, opts = {}) {
  const result = await searchByPhone(phone, opts);
  if (!result.found) throw new Error(`Không tìm thấy Zalo cho số ${phone} (${result.reason || "no_result"})`);
  return result;
}

// Scrape recent messages of the currently-open conversation (or open one first
// by phone / known zalo id). Returns { zaloId, messages }.
async function fetchHistory({ phone, recipientZaloId, limit = 80, preparedSearch = false } = {}) {
  let zaloId = recipientZaloId || null;
  if (zaloId) {
    const phoneFromRecipient = recipientPhone(zaloId);
    if (phoneFromRecipient) {
      const opened = await openByPhone(phoneFromRecipient, { preparedSearch });
      zaloId = opened.zaloId || zaloId;
    } else {
      await openConversation(zaloId);
    }
  } else if (phone) {
    const opened = await openByPhone(phone, { preparedSearch });
    zaloId = opened.zaloId;
  }
  zaloId = currentHashUid() || zaloId || phoneExternalId(phone);
  if (!zaloId) throw new Error("No conversation open to read history");
  // Wait until at least one message row renders before scraping.
  window.__CAMPAIO_ACTIVE_FALLBACK_ID__ = zaloId;
  await waitFor(() => $$("messageRow").length > 0, { timeout: 5000 });
  const messages = scrapeActiveConversationMessages().slice(-limit);
  return { zaloId, messages };
}

// Find a user by phone (or use a known id), then send a text message into the
// opened conversation. Returns { ok, zaloId }.
async function sendByPhone({ phone, recipientZaloId, content, preparedSearch = false }) {
  if (!content) throw new Error("content is empty");
  let zaloId = recipientZaloId || null;
  if (zaloId) {
    const phoneFromRecipient = recipientPhone(zaloId);
    if (phoneFromRecipient) {
      const opened = await openByPhone(phoneFromRecipient, { preparedSearch });
      zaloId = opened.zaloId || zaloId;
    } else {
      await openConversation(zaloId);
    }
  } else {
    const opened = await openByPhone(phone, { preparedSearch });
    zaloId = opened.zaloId;
  }
  await injectMessage(content);
  return { ok: true, zaloId: currentHashUid() || zaloId || phoneExternalId(phone) };
}

// Dispatch a backend task to the right automation. Mirrors the inline CEF
// bridge's runTask so module.js + integration_bridge.js stay in sync.
async function runTask(task = {}) {
  if (task.taskType === "lookup_by_phone") return searchByPhone(task.phone, { preparedSearch: !!task.preparedSearch });
  if (task.taskType === "fetch_history") {
    return fetchHistory({ phone: task.phone, recipientZaloId: task.recipientZaloId, limit: task.payload?.limit, preparedSearch: !!task.preparedSearch });
  }
  if (task.taskType === "send_message") {
    return sendByPhone({ phone: task.phone, recipientZaloId: task.recipientZaloId, content: task.content, preparedSearch: !!task.preparedSearch });
  }
  throw new Error(`Unknown taskType: ${task.taskType}`);
}

// Background-run a task and stash the result in a page global. Lets a native
// host (CEF) read the result via a synchronous expression, since async eval
// can't return a Promise value across the bridge.
function runTaskAsync(taskId, task) {
  const store = (window.__CAMPAIO_TASK_RESULTS__ = window.__CAMPAIO_TASK_RESULTS__ || {});
  store[taskId] = { status: "running" };
  Promise.resolve()
    .then(() => runTask(task))
    .then((result) => { store[taskId] = { status: "done", ok: true, result: result || {} }; })
    .catch((error) => { store[taskId] = { status: "done", ok: false, error: String(error?.message || error) }; });
  return "started";
}

function scrapeContacts() {
  const items = $$( "conversationItem");
  const contacts = [];
  for (const item of items.slice(0, 200)) {
    const externalId = extractZaloId(item);
    if (!externalId) continue;
    const nameNode = SELECTORS.conversationName.map((s) => item.querySelector(s)).find(Boolean);
    const avatarNode = SELECTORS.conversationAvatar.map((s) => item.querySelector(s)).find(Boolean);
    contacts.push({
      externalId,
      name: (nameNode?.textContent || "").trim(),
      avatarUrl: avatarNode?.src || null
    });
  }
  return contacts;
}

function scrapeActiveConversationMessages() {
  const match = location.hash.match(/uid=([^&]+)/);
  const externalId = match ? decodeURIComponent(match[1]) : (window.__CAMPAIO_ACTIVE_FALLBACK_ID__ || null);
  if (!externalId) return [];
  const rows = $$( "messageRow");
  const messages = [];
  for (const row of rows.slice(-80)) {
    const contentNode = SELECTORS.messageContent.map((s) => row.querySelector(s)).find(Boolean);
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
  return messages;
}

async function openConversation(externalId) {
  const phone = recipientPhone(externalId);
  if (phone) {
    await openByPhone(phone);
    return;
  }
  if (location.hash.includes(`uid=${externalId}`)) return;
  location.hash = `#chat/${externalId}`;
  for (let i = 0; i < 30; i += 1) {
    await wait(200);
    if ($( "composeBox")) return;
  }
  throw new Error("Compose box not ready");
}

async function injectMessage(content) {
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
  await wait(200);
  // Zalo's send control is an unlabelled primary icon button in the compose
  // row. Try configured selectors, then scope to the compose row, then Enter.
  let btn = $( "sendButton");
  if (!btn) {
    let row = box;
    for (let i = 0; i < 6 && row.parentElement; i += 1) {
      row = row.parentElement;
      const cand = row.querySelector(".z--btn--v2.btn-tertiary-primary, .btn-tertiary-primary");
      if (cand) { btn = cand; break; }
    }
  }
  if (btn) {
    btn.click();
  } else {
    box.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true }));
    box.dispatchEvent(new KeyboardEvent("keyup", { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true }));
  }
  await wait(300);
}

export const zaloPersonalModule = {
  id: "zalo_personal",
  match: (url) => /https?:\/\/chat\.zalo\.me/i.test(url),
  async scrape() {
    return {
      contacts: scrapeContacts(),
      messages: scrapeActiveConversationMessages()
    };
  },
  openConversation,
  injectMessage,
  searchByPhone,
  openByPhone,
  fetchHistory,
  sendByPhone,
  preparePhoneSearch,
  runTask,
  runTaskAsync
};

export default zaloPersonalModule;
