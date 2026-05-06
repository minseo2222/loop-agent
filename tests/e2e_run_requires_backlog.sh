#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

PROJECT_DIR="$TMP_DIR/project"
BIN_DIR="$TMP_DIR/bin"
CLI_LOG="$TMP_DIR/cli.log"
OUTPUT="$TMP_DIR/output.txt"

mkdir -p "$PROJECT_DIR/.loop-agent" "$BIN_DIR"

for cli in codex gemini; do
  cat > "$BIN_DIR/$cli" <<EOF
#!/usr/bin/env bash
echo "$cli called" >> "$CLI_LOG"
exit 0
EOF
  chmod +x "$BIN_DIR/$cli"
done

set +e
PATH="$BIN_DIR:$PATH" "$ROOT_DIR/loop.sh" run --project "$PROJECT_DIR" --iterations 1 --cli codex > "$OUTPUT" 2>&1
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "Expected run mode to fail when .loop-agent/backlog.md is missing."
  cat "$OUTPUT"
  exit 1
fi

if ! grep -q ".loop-agent/backlog.md" "$OUTPUT"; then
  echo "Expected output to mention .loop-agent/backlog.md."
  cat "$OUTPUT"
  exit 1
fi

if ! grep -q "./loop.sh init" "$OUTPUT"; then
  echo "Expected output to suggest ./loop.sh init."
  cat "$OUTPUT"
  exit 1
fi

if [[ -s "$CLI_LOG" ]]; then
  echo "Expected fake CLI shims not to be invoked."
  cat "$CLI_LOG"
  exit 1
fi
