#!/usr/bin/env bash
# Build the SenClaw Space App and stage it as turbo-fieldfare-app.zip, the
# flat layout the SenClaw daemon installs:
#
#   release-senclaw/
#     turbo-fieldfare-senclaw            (release binary; manifest start = ./…)
#     senclaw-manifest.json
#     web/                               (static UI)
#     TurboFieldfare_*.bundle/           (SPM resource bundles — the Metal
#                                         shader sources load from here)
#   turbo-fieldfare-app.zip              (artifact for install-zip / hub publish)
#
# The zip name matches the manifest id (`<id>-app.zip`), which is where
# `senclaw hub publish` looks by default. The hub caps uploads at 20 MB.
#
# Usage: Scripts/senclaw_pack.sh [--skip-build]
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_directory/.."

STAGE="release-senclaw"
ZIP="turbo-fieldfare-app.zip"
BIN=".build/release/turbo-fieldfare-senclaw"

if [[ "${1:-}" != "--skip-build" ]]; then
  echo "==> swift build -c release --product turbo-fieldfare-senclaw"
  swift build -c release --product turbo-fieldfare-senclaw
fi

[[ -f "$BIN" ]] || { echo "error: missing $BIN — build first" >&2; exit 1; }

echo "==> staging $STAGE/"
rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"
cp "$BIN" "$STAGE/turbo-fieldfare-senclaw"
chmod +x "$STAGE/turbo-fieldfare-senclaw"
cp senclaw-manifest.json "$STAGE/"
cp -R web "$STAGE/web"

# Resource bundles for the linked TurboFieldfare targets. The Metal sources are
# compiled at runtime from the TurboFieldfare bundle; without it the engine
# cannot create a pipeline.
bundle_count=0
for bundle in .build/release/TurboFieldfare_*.bundle; do
  [[ -d "$bundle" ]] || continue
  cp -R "$bundle" "$STAGE/$(basename "$bundle")"
  bundle_count=$((bundle_count + 1))
done
if [[ $bundle_count -eq 0 ]]; then
  echo "error: no TurboFieldfare_*.bundle in .build/release — Metal shaders would be missing" >&2
  exit 1
fi

echo "==> zipping -> $ZIP"
(cd "$STAGE" && zip -rqX "../$ZIP" . -x '*.DS_Store')

# The 20 MB cap applies only to hub uploads; a local install-zip or a GitHub
# Release can still ship a bigger artifact, so warn without failing the build.
size_bytes=$(stat -f%z "$ZIP" 2>/dev/null || stat -c%s "$ZIP")
echo "done: $ZIP ($((size_bytes / 1024 / 1024)) MB)"
if (( size_bytes > 20 * 1024 * 1024 )); then
  echo "warning: artifact exceeds the hub's 20 MB upload cap — hub publish will 413" >&2
fi
