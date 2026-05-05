#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_FILE="$(mktemp)"

cleanup() {
  rm -f "$OUTPUT_FILE"
}
trap cleanup EXIT

cd "$ROOT_DIR"

bash scripts/run_benchmarks.sh > "$OUTPUT_FILE" 2>&1

grep -q '^Scenario result:' "$OUTPUT_FILE"
grep -q '^Benchmark summary$' "$OUTPUT_FILE"
grep -q '^Total scenarios:' "$OUTPUT_FILE"
grep -q '^Exit-code failures:' "$OUTPUT_FILE"
grep -q '^Committed scenarios:' "$OUTPUT_FILE"
grep -q '^False PASS count:' "$OUTPUT_FILE"
grep -q '^False PASS rate:' "$OUTPUT_FILE"
grep -q '^Using fake provider CLIs only$' "$OUTPUT_FILE"

if grep -q 'progress_window.md' "$OUTPUT_FILE"; then
  echo "benchmark runner output must not reference progress_window.md" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi
