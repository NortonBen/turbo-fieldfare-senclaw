#!/usr/bin/env bash
# Smoke test: chứng minh app SenClaw TurboFieldfare CÓ RESPONSE trên mọi mặt
# tiếp xúc mà daemon dùng. Chạy được lặp lại bất kỳ lúc nào:
#
#   Scripts/senclaw_smoke.sh                       # qua daemon proxy (mặc định)
#   BASE=http://127.0.0.1:4841 Scripts/senclaw_smoke.sh   # thẳng vào app
#
# Yêu cầu: model đã cài. Lượt đầu sau khi app thức dậy phải nạp model
# (~10-20s, đã tính trong timeout). PASS hết = app phục vụ đúng hợp đồng
# OpenAI; chat chậm với agent full-tool là chuyện kích thước prompt
# (xem docs/SENCLAW_APP.md), không phải app không chạy.
set -u

BASE="${BASE:-http://127.0.0.1:18788/api/space/apps/turbo-fieldfare/proxy}"
MODEL="gemma-4-26b-a4b-it"
pass=0; fail=0

check() { # name, condition, detail
  if [ "$2" = "0" ]; then
    printf '  \033[32mPASS\033[0m %s%s\n' "$1" "${3:+ — $3}"; pass=$((pass+1))
  else
    printf '  \033[31mFAIL\033[0m %s%s\n' "$1" "${3:+ — $3}"; fail=$((fail+1))
  fi
}

t() { python3 -c 'import time; print(f"{time.time():.1f}")'; }
elapsed() { python3 -c "print(f'{$2 - $1:.1f}s')"; }

echo "== TurboFieldfare SenClaw smoke @ $BASE"

# 1. Health — phải trả lời ngay, kể cả khi model chưa nạp.
s=$(t)
body=$(curl -s -m 30 "$BASE/health")
check "health" "$([ "$(echo "$body" | grep -c '"ok"')" -ge 1 ] && echo 0 || echo 1)" "$(elapsed "$s" "$(t)")"

# 2. /v1/models — model card hiện diện (điều kiện để daemon route turn).
s=$(t)
body=$(curl -s -m 30 "$BASE/v1/models")
check "GET /v1/models có $MODEL" "$([ "$(echo "$body" | grep -c "$MODEL")" -ge 1 ] && echo 0 || echo 1)" "$(elapsed "$s" "$(t)")"

# 3. Chat non-stream — lượt sinh thật (bao gồm nạp model nếu nguội).
s=$(t)
body=$(curl -s -m 300 -X POST "$BASE/v1/chat/completions" -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":24,\"messages\":[{\"role\":\"user\",\"content\":\"Nói đúng một từ: pong\"}]}")
content=$(echo "$body" | python3 -c "import json,sys
try: print(json.load(sys.stdin)['choices'][0]['message']['content'] or '')
except Exception as e: print('')" 2>/dev/null)
check "chat non-stream có nội dung" "$([ -n "$content" ] && echo 0 || echo 1)" "reply='${content:0:40}' $(elapsed "$s" "$(t)")"

# 4. Chat stream — phải thấy role chunk, content delta và [DONE].
s=$(t)
stream=$(curl -s -N -m 300 -X POST "$BASE/v1/chat/completions" -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"stream\":true,\"max_tokens\":24,\"messages\":[{\"role\":\"user\",\"content\":\"Đếm: một hai ba\"}]}")
have_role=$(echo "$stream" | grep -c '"role":"assistant"')
have_content=$(echo "$stream" | grep -c '"content"')
have_done=$(echo "$stream" | grep -c '^data: \[DONE\]')
check "chat stream (role+delta+[DONE])" "$([ "$have_role" -ge 1 ] && [ "$have_content" -ge 1 ] && [ "$have_done" -ge 1 ] && echo 0 || echo 1)" "$(elapsed "$s" "$(t)")"

# 5. Tool call — model phải gọi được function tool.
s=$(t)
body=$(curl -s -m 300 -X POST "$BASE/v1/chat/completions" -H 'content-type: application/json' -d "{
  \"model\":\"$MODEL\",\"max_tokens\":48,
  \"messages\":[{\"role\":\"user\",\"content\":\"Dùng tool get_time để xem giờ hiện tại.\"}],
  \"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_time\",\"description\":\"Đọc giờ hiện tại\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}}]}")
tool_called=$(echo "$body" | python3 -c "import json,sys
try:
    calls=json.load(sys.stdin)['choices'][0]['message'].get('tool_calls') or []
    print(1 if any(c['function']['name']=='get_time' for c in calls) else 0)
except Exception: print(0)" 2>/dev/null)
check "tool call get_time" "$([ "$tool_called" = "1" ] && echo 0 || echo 1)" "$(elapsed "$s" "$(t)")"

# 6. Lỗi phải là lỗi CÓ KIỂU, không phải treo: model sai → 404 ngay.
s=$(t)
code=$(curl -s -o /dev/null -w '%{http_code}' -m 30 -X POST "$BASE/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d '{"model":"khong-ton-tai","messages":[{"role":"user","content":"x"}]}')
check "model lạ trả 404 tức thì" "$([ "$code" = "404" ] && echo 0 || echo 1)" "HTTP $code $(elapsed "$s" "$(t)")"

echo "== KẾT QUẢ: $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
