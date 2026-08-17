# TurboFieldfare làm SenClaw Space App

Repo này (fork `turbo-fieldfare` → `turbo-fieldfare-senclaw`) thêm đúng **một
sản phẩm mới**: app SenClaw Space cung cấp Gemma 4 26B-A4B như một LLM
provider chuẩn OpenAI cho daemon SenClaw — kiểu như `apps/mlx-lm` trong
monorepo SenClaw, nhưng chạy bằng engine TurboFieldfare (Swift + Metal, stream
expert từ SSD, chạy được máy 8 GB).

```
daemon SenClaw ──spawn──► ./turbo-fieldfare-senclaw   (PORT do daemon gán)
                             │
                             ├─ /health                    trả lời ngay, không đợi model
                             ├─ /v1/models,/v1/chat/…      SenclawSpace SDK render OpenAI wire
                             │      └─ SenClawProvider ──► SenClawEngine (actor)
                             │             │                   └─ ServerModelSession  ← TurboFieldfareServerCore,
                             │             │                       (validate, template,     KHÔNG sửa dòng nào
                             │             │                        tool decode, prompt cache)
                             │             └─ decode [String:Any] → OpenAIChatRequest → validate
                             ├─ /api/model,/api/settings   REST cho web UI (tải/hủy/resume/xoá, knobs)
                             └─ /                          web/index.html (iframe trong SenClaw)
```

## Các mảnh và trách nhiệm

| Đường dẫn | Vai trò |
|---|---|
| `Vendor/SenclawSpace/` | SDK Space App **vendor nguyên văn** (SPM không trỏ được vào thư mục con của monorepo). Không sửa gì trong đó — xem README trong thư mục để biết commit nguồn và cách refresh. |
| `Sources/TurboFieldfareSenClaw/` | Toàn bộ code mới. `SenClawProvider` (LlmProvider → engine), `SenClawEngine` (actor giữ `ServerModelSession` + `ServerCoordinator`, nạp lười, giải phóng khi rảnh), `SenClawModelStore` (cài/hủy/resume/xoá qua `RepackModelInstallerClient`), `SenClawSettings*` (JSON cạnh thư mục model), `SenClawRoutes` (REST), `BlockingBridge` (cầu sync↔async cho server thread-per-connection của SDK). |
| `Tests/TurboFieldfareSenClaw/` | Test settings/paths/provider/store + pin `senclaw-manifest.json` qua validator của SDK. |
| `web/index.html` | UI tĩnh (tiếng Việt): tải model có tiến trình/ETA, tạm dừng/tiếp tục, nạp/giải phóng RAM, «Dùng làm LLM», chỉnh runtime. |
| `senclaw-manifest.json` | Manifest runtime daemon đọc: id `turbo-fieldfare`, port 4841, `llm.adapt: openai`, mode `session` (idle 900 s). |
| `senclaw-hub.json` | Metadata hub: version artifact, permissions (khai thật các host HuggingFace installer gọi), platform `darwin-arm64`. |
| `Scripts/senclaw_pack.sh` | Build release + đóng `turbo-fieldfare-app.zip` layout phẳng (binary + manifest + `web/` + `TurboFieldfare_*.bundle` chứa nguồn Metal). |
| `.github/workflows/senclaw-app.yml` | PR: test + pack. Tag `senclaw-v*`: GitHub Release + publish hub qua `POST /api/v1/publish` (cần secret `SENCLAW_HUB_TOKEN`). |

Model tải về nằm ở `~/Library/Application Support/TurboFieldfare/gemma4.gturbo`
(**dùng chung** với app Mac của repo — một lần tải phục vụ cả hai; trong
checkout dev thì là `scratch/gemma4.gturbo`, override được bằng
`TURBO_FIELDFARE_MODEL_DIR`). Settings nằm cạnh đó
(`senclaw-app-settings.json`) nên sống qua update/reinstall app.

## Chạy dev

```bash
swift run turbo-fieldfare-senclaw          # PORT mặc định 4841, cwd = repo root
# hoặc đăng ký vào daemon đang chạy:
curl -X POST http://127.0.0.1:18788/api/space/apps/register-local \
  -H 'Content-Type: application/json' -d "{\"path\": \"$(pwd)\"}"
```

Lưu ý dạng session-app: daemon chỉ khởi động app khi có người mở UI hoặc model
được gọi, và dừng sau `idleTimeoutSecs` rảnh. **Giữ trang UI mở khi đang tải
model** — nếu app bị dừng giữa chừng, bản tải dở + checkpoint vẫn còn, mở lại
bấm «Tải tiếp» là chạy tiếp (cơ chế resume của `RemoteStreamingRepacker`).

## Đóng gói & phát hành

```bash
Scripts/senclaw_pack.sh                    # → turbo-fieldfare-app.zip (~5 MB, trần hub 20 MB)
curl -F "file=@turbo-fieldfare-app.zip" http://127.0.0.1:18788/api/space/apps/install-zip   # thử cục bộ
```

Phát hành chính thức: sửa `version` trong `senclaw-hub.json` → commit → tag
`senclaw-v<version>` → push tag. Workflow tự build, tạo GitHub Release và
publish lên `https://senclaw.bacnd.com` (version trên hub là bất biến — sai thì
bump patch, tag lại). Secret cần có: `SENCLAW_HUB_TOKEN` (scope publish).

## Nguyên tắc "diff tối thiểu" để merge upstream dễ

Mọi thứ ở trên là **file mới**. File có sẵn bị đụng đúng ba chỗ, đều là phần
append:

1. `Package.swift` — thêm 1 product + 3 target (`SenclawSpace`,
   `TurboFieldfareSenClaw`, `TurboFieldfareSenClawTests`).
2. `.gitignore` — thêm 3 dòng cuối file (staging/zip/`.senclaw/`).
3. `README.md` — một mục ngắn trỏ sang tài liệu này.

Không sửa dòng nào trong `Sources/TurboFieldfare*`, `Tests/` cũ, `ci.yml`, hay
`Scripts/test.sh` (test target mới tự chạy trong CI cũ vì `swift test` chạy cả
package). Khi upstream `turbo-fieldfare` đổi, merge về gần như không thể
conflict; nếu `ServerModelSession.load` hay `OpenAIRequestValidator` đổi chữ
ký, chỗ vá duy nhất là `SenClawEngine`/`SenClawProvider`.

## Những quyết định đáng biết (và các bẫy đã né)

- **Tái dùng nguyên `TurboFieldfareServerCore` cho suy luận.** App không tự
  render template/parse tool: decode body `[String: Any]` của SDK →
  `OpenAIChatRequest` (Codable) → `OpenAIRequestValidator` →
  `ServerModelSession.generate` rồi map `ServerInferenceEvent` →
  `Chunk.text/.toolCall` của SDK. SDK lo phần wire SSE (index tool-call, usage
  chunk, `[DONE]`) — hai phía đều là code đã có test riêng.
- **Nạp lười, health trả lời ngay.** Daemon health-gate 30 s; `Model.load` với
  `integrityPolicy: .fullSha256` (bên trong `ServerModelSession.load`) hash cả
  14 GB (~10 s NVMe) nên tuyệt đối không nạp lúc khởi động. Lượt chat đầu sau
  mỗi lần app thức dậy chịu độ trễ nạp này.
- **Một model resident, đổi cấu hình = release trước, construct sau**
  (`SenClawEngine.backend`): key nạp gồm đúng các trường định hình session;
  đang bận thì từ chối reload thay vì để hai model cùng sống.
- **SIGTERM ở bản release**: `Serve` của SDK giữ dispatch-source bằng
  `_ = sources`, optimizer bản release được phép kết thúc lifetime ngay → chỉ
  còn `SIG_IGN`, app trơ với SIGTERM (debug không lộ vì lifetime kéo tới cuối
  scope). App tự cài source riêng (global, sống mãi) trước khi gọi `Serve`:
  cancel installer (checkpoint đã bền sau mỗi range) rồi `exit(0)` — kịp trước
  SIGKILL +2 s của daemon. Đáng upstream một bản vá `withExtendedLifetime`.
- **`.senclaw/llm-models.json`** publish lúc khởi động + sau mỗi install; sau
  khi xoá model thì **xoá file cache** (SDK từ chối publish danh sách rỗng, mà
  để nguyên thì picker quảng cáo model không còn chạy được).
- **`vision: false` là bắt buộc đúng** — pipeline repack bỏ tensor đa phương
  thức; khai `true` là daemon gửi image block và fail nguyên lượt.
- **Không nhận `mode: background`** dù tải model lâu: session là đúng nghĩa
  (app chỉ chạy khi được dùng); trade-off là download cần trang UI mở, đổi lại
  không chiếm một process suốt đời daemon.
- **Giới hạn kế thừa từ SDK — phát hiện client ngắt kết nối**: `SSEWriter.isClosed`
  chỉ bật sau một lần *ghi thất bại*, và path non-stream không có tín hiệu nào.
  App đã chặn được turn xếp hàng mà stream đã đứt (check ở ranh giới slot) và
  hủy giữa các token, nhưng một turn bị bỏ rơi khi **chưa stream gì** (đang
  prefill dài) vẫn chạy hết lượt. Server SwiftNIO độc lập không dính giới hạn
  này (hủy theo `channelInactive`) — dùng nó khi cần QoS chặt. Sửa tận gốc cần
  SDK expose tín hiệu đóng kết nối chủ động.
- **`queueLimit`** là knob duy nhất chỉ áp dụng khi app khởi động lại
  (`ServerCoordinator` bất biến sau khi tạo); API trả `restartRequired` và UI
  hiển thị rõ thay vì im lặng.
