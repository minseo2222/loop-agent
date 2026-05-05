#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE_CLI_DIR="$ROOT/tests/fake_cli"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PATH="$FAKE_CLI_DIR:$PATH"
export PATH
export LOOP_RISK_MODE=unattended

. "$ROOT/lib/cli_adapters.sh"

command -v run_codex_agent >/dev/null
command -v run_gemini_agent >/dev/null

[[ "$(command -v codex)" == "$FAKE_CLI_DIR/codex" ]]
[[ "$(command -v gemini)" == "$FAKE_CLI_DIR/gemini" ]]

codex --self-test
gemini --self-test

PROJECT_DIR="$TMP_DIR/project"
mkdir -p "$PROJECT_DIR"
export LOOP_FAKE_PROJECT_DIR="$PROJECT_DIR"
PROMPT_FILE="$TMP_DIR/prompt.md"
OUT_FILE="$TMP_DIR/out.md"
LOG_FILE="$TMP_DIR/codex.log"
printf 'fake prompt\n' > "$PROMPT_FILE"

LOOP_FAKE_SCENARIO=pass run_codex_agent "$PROJECT_DIR" "$PROMPT_FILE" "$OUT_FILE" "$LOG_FILE" "gpt-test" "medium"
[[ -s "$OUT_FILE" ]]

: > "$OUT_FILE"
: > "$LOG_FILE"
LOOP_FAKE_SCENARIO=pass run_gemini_agent "$PROJECT_DIR" "$PROMPT_FILE" "$OUT_FILE" "$LOG_FILE"
[[ -s "$OUT_FILE" ]]

: > "$OUT_FILE"
: > "$LOG_FILE"
if LOOP_FAKE_SCENARIO=rate_limit run_codex_agent "$PROJECT_DIR" "$PROMPT_FILE" "$OUT_FILE" "$LOG_FILE" "gpt-test" "medium"; then
  echo "expected codex rate limit scenario to fail" >&2
  exit 1
fi
grep -qiE 'rate.?limit|usage.?limit|429|quota.?exceeded|too.?many.?requests|limit.?reached|exceeded.*limit|usage.?cap|plan.?limit|resource.?exhausted' "$LOG_FILE"

: > "$OUT_FILE"
: > "$LOG_FILE"
if LOOP_FAKE_SCENARIO=rate_limit run_gemini_agent "$PROJECT_DIR" "$PROMPT_FILE" "$OUT_FILE" "$LOG_FILE"; then
  echo "expected gemini rate limit scenario to fail" >&2
  exit 1
fi
grep -qiE 'rate.?limit|usage.?limit|429|quota.?exceeded|too.?many.?requests|limit.?reached|exceeded.*limit|usage.?cap|plan.?limit|resource.?exhausted' "$LOG_FILE"

echo "e2e_cli_adapters: PASS"
