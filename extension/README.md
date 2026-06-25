# Campaio Bridge — Chrome Extension

Manifest v3 extension cài vào trình duyệt Chromium (gồm CEF của Flutter app `tool_zalo_client_auto`). Cầu nối 2 chiều giữa các nền tảng chat cá nhân và tenant Campaio.

Extension đóng gói **theo module**: mỗi platform là một module dưới `modules/<platform>/`. Hiện có:

| Module | Site | ID |
|---|---|---|
| `zalo_personal` | chat.zalo.me | `zalo_personal` |
| _(planned)_ Messenger cá nhân | facebook.com/messages | `facebook_personal` |
| _(planned)_ TikTok DM | tiktok.com | `tiktok_personal` |

Cách thêm module mới: xem [`modules/module-api.md`](modules/module-api.md).

## Luồng

1. **Sync** (extension → tenant): Mỗi 5 phút (hoặc khi user bấm "Đồng bộ ngay") content script load module phù hợp URL, gọi `module.scrape()` lấy `{contacts, messages}`, POST `/api/integrations/zalo-personal/sync`.
2. **Outbox** (tenant → extension): Background service worker poll `/api/integrations/zalo-personal/outbox` mỗi 30s, dispatch từng item xuống content script. Module hiện hành mở conversation theo `externalId`, fill compose box, click Send. Sau khi gửi xong POST `/outbox/:id/ack`.

## Cấu trúc

```
campaio-bridge-extension/
├── manifest.json             ← khai báo permissions + content_scripts matches
├── background.js             ← service worker (settings, alarm poll, dispatch)
├── content.js                ← entry: dynamic import registry → bind module
├── popup.html/.js
├── options.html/.js
└── modules/
    ├── registry.js           ← danh sách module + findModuleForUrl/ById
    ├── module-api.md         ← spec interface khi viết module mới
    └── zalo_personal/
        ├── module.js         ← scrape + injectMessage + openConversation
        └── selectors.json    ← CSS selectors riêng (đổi không cần build lại)
```

## Cấu hình

1. Bấm icon extension → "Cấu hình tenant URL + API key".
2. Nhập:
   - **Tenant URL** — domain workspace, ví dụ `https://giaidoan1.chatplus.io.vn`.
   - **API key** — tạo tại web Campaio: **Tích hợp → Zalo cá nhân → Tạo thiết bị mới**. Key chỉ hiển thị một lần.
3. Bấm **Lưu** rồi **Test kết nối**.

## Permissions

- `storage` — settings local.
- `alarms` — schedule poll outbox.
- `scripting` — dynamic import module files.
- `host_permissions` — chỉ chạy trên site được khai báo trong manifest.

## Rủi ro

Tự động hoá DOM của Zalo/Facebook/TikTok có thể vi phạm ToS của họ. Mỗi module nên expose tuỳ chọn `autoSend=false` cho user chọn "chỉ fill compose, không click send" để giảm rủi ro account bị limit.
