# Vendored: SenclawSpace (senclaw-app-sdk-swift)

Bản sao nguyên văn của SDK Space App cho Swift, vendor vào repo này vì Swift
Package Manager không thể khai `url:` dependency trỏ vào **thư mục con** của
monorepo SenClaw, và repo mirror `NortonBen/senclaw-app-sdk-swift` chưa tồn tại
tại thời điểm vendor.

- Nguồn: <https://github.com/NortonBen/SenClaw/tree/main/senclaw-sdk/senclaw-app-sdk-swift> (`Sources/SenclawSpace/`)
- Commit nguồn: `25c22953fdd36864729db4b53d9221da19df909a` (2026-08-17)
- Giấy phép: xem [LICENSE](LICENSE) (copy từ gói gốc)

## Quy tắc

- **Không sửa file trong thư mục này.** Mọi thay đổi hành vi đặt ở
  `Sources/TurboFieldfareSenClaw/`. Nhờ vậy refresh SDK chỉ là copy đè.
- Target này build ở **Swift 5 language mode** (khai trong `Package.swift`) —
  đúng chủ đích của SDK gốc (server thread-per-connection + semaphore, không
  cần strict concurrency).

## Cách refresh khi SDK gốc đổi

```bash
cp /path/to/SenClaw/senclaw-sdk/senclaw-app-sdk-swift/Sources/SenclawSpace/*.swift Vendor/SenclawSpace/
# rồi cập nhật commit nguồn ở README này và chạy swift test
```

Nếu sau này mirror `https://github.com/NortonBen/senclaw-app-sdk-swift.git`
được tạo và gắn tag, có thể xoá thư mục này và thay bằng
`.package(url: ..., from: "0.1.0")` trong `Package.swift`.
