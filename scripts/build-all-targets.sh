#!/usr/bin/env bash
# Build zponder release binaries for all supported platforms.
# Run from the project root. Requires Zig 0.16.0+.
#
# Usage:
#   bash scripts/build-all-targets.sh
#
# Output:
#   npm/zponder/bin/darwin-arm64/zponder   (Apple Silicon)
#   npm/zponder/bin/darwin-x64/zponder     (Intel Mac)
#   npm/zponder/bin/linux-x64/zponder      (Linux x86_64)
#   npm/zponder/bin/linux-arm64/zponder    (Linux ARM64)

set -euo pipefail
cd "$(dirname "$0")/.."

TARGETS=(
  "aarch64-macos-none:darwin-arm64"
  "x86_64-macos-none:darwin-x64"
  "x86_64-linux-musl:linux-x64"
  "aarch64-linux-musl:linux-arm64"
)

echo "=== Building zponder release binaries ==="

for entry in "${TARGETS[@]}"; do
  TARGET_TRIPLE="${entry%%:*}"
  PLATFORM_DIR="${entry##*:}"
  OUT_DIR="npm/zponder/bin/$PLATFORM_DIR"

  echo ""
  echo "--- Building for $PLATFORM_DIR ($TARGET_TRIPLE) ---"

  mkdir -p "$OUT_DIR"

  zig build -Doptimize=ReleaseFast -Dtarget="$TARGET_TRIPLE" 2>&1 || {
    echo "WARNING: Failed to build for $PLATFORM_DIR — skipping"
    continue
  }

  cp zig-out/bin/zponder "$OUT_DIR/zponder"
  chmod +x "$OUT_DIR/zponder"
  ls -lh "$OUT_DIR/zponder"
done

echo ""
echo "=== Done ==="
echo "Binaries placed in npm/zponder/bin/"
echo ""
echo "To publish:"
echo "  cd npm/zponder && npm publish"
