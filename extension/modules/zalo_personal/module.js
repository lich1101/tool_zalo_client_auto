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
  if (!match) return [];
  const externalId = decodeURIComponent(match[1]);
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
  await wait(120);
  const btn = $( "sendButton");
  if (btn) btn.click();
  else box.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
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
  injectMessage
};

export default zaloPersonalModule;
