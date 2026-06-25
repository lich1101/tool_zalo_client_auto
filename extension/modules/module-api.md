# Campaio Bridge — Module API

Mỗi platform (Zalo cá nhân, Messenger cá nhân, TikTok DM, v.v.) là một **module** đóng gói riêng. Module chỉ cần biết cách scrape DOM của site đó và inject một message vào ô compose — toàn bộ logic auth + outbox polling + sync HTTP nằm trong core (`background.js` + `content.js`).

## Cấu trúc thư mục

```
modules/
├── registry.js          ← Đăng ký tất cả module ở đây
├── module-api.md        ← File này
├── zalo_personal/
│   ├── module.js        ← export default { id, match, scrape, openConversation, injectMessage }
│   └── selectors.json   ← CSS selectors riêng của module
└── <new_module>/
    ├── module.js
    └── selectors.json
```

## Module interface

```js
{
  // Định danh duy nhất, dùng làm channel name ở tenant. Phải khớp giá trị
  // `module` truyền cho POST /integrations/zalo-personal/outbox (sau khi
  // backend support multi-channel sẽ đổi sang /integrations/personal-bridge/outbox).
  id: "zalo_personal",

  // Trả true nếu URL hiện tại thuộc về module này. Core dùng cái này để chọn
  // module mỗi khi content script bootstrap.
  match: (url) => /https?:\/\/chat\.zalo\.me/i.test(url),

  // Đọc DOM trả về snapshot tối thiểu để post lên tenant.
  // Phải pure-read — KHÔNG được modify DOM.
  scrape: async () => ({
    contacts: [{ externalId, name, avatarUrl? }, ...],
    messages: [{
      externalId,                       // ID người chat (uid, psid, …)
      direction: "inbound" | "outbound",
      content,
      externalSenderId?,
      sentAt?,                          // ISO date string nếu trích được
      externalMessageId?                // ID stable trong DOM nếu có
    }, ...]
  }),

  // Điều hướng UI tới conversation với externalId. Phải đợi compose box xuất
  // hiện hoặc throw nếu không tìm thấy.
  openConversation: async (externalId) => {},

  // Fill compose box rồi click Send. Throw nếu DOM không sẵn sàng.
  injectMessage: async (content) => {}
}
```

## Thêm module mới

1. Tạo `modules/<name>/module.js` + `selectors.json` (tách selectors để update không cần đụng code).
2. Import + add vào array `MODULES` trong `modules/registry.js`.
3. Thêm host pattern vào `host_permissions` + `content_scripts.matches` trong `manifest.json` ở root extension.
4. (Backend) đăng ký channel mới trong `packages/shared/src/constants.js` `CHANNEL_TYPES`.
5. (Backend) đăng ký channel definition + label trong `apps/tenant/frontend/src/App.jsx` (`channelDisplayNames` + `channelDefinitions`).
6. (Optional) Thêm bảng outbox/sync riêng nếu schema khác. Hiện tại tất cả module dùng chung `ZaloPersonalOutboxItem` — sẽ rename khi có module thứ hai.

## Không cần làm

- Không cần viết HTTP/poll/auth logic — core lo.
- Không cần handle settings UI — chung options page.
- Không cần manifest riêng từng module — chỉ thêm pattern vào manifest gốc.

## Lưu ý ToS

Hầu hết platform cấm automation gửi message từ tài khoản cá nhân. Mỗi module nên expose 1 setting `autoSend` để user có thể chọn fill-only (không bấm send) thay vì full auto-send.
