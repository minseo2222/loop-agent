#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

make_fake_codex() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

count_file="${SECRET_GUARD_COUNT_FILE:?}"
target_path="${SECRET_GUARD_PATH:?}"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "-" ]]; then
    cat >/dev/null
    break
  fi
  shift
done

case "$count" in
  1)
    cat <<PLAN
# Plan

## Tasks

### Task 1: Secret fixture
- File: \`$PWD/$target_path\`
- What to do: Create the requested fixture file.
- Completion criteria:
  - [ ] verify: \`true\`
PLAN
    ;;
  2)
    cat <<'CRITIC'
# Plan Review

## Notes
none

VERDICT: PASS
CRITIC
    ;;
  3)
    mkdir -p "$(dirname "$target_path")"
    printf 'secret fixture\n' > "$target_path"
    cat <<'SUMMARY'
# Implementation Summary

## Tasks completed
- [x] Task 1: Secret fixture - created the requested file.

## Completion criteria status
- [x] verify: `true`
SUMMARY
    ;;
  *)
    cat <<'CRITIC'
# Impl Critic

## Notes
none

VERDICT: PASS
CRITIC
    ;;
esac
SH
  chmod +x "$bin_dir/codex"
}

make_project() {
  local project="$1"
  local secret_path="$2"

  mkdir -p "$project/.loop-agent"
  cat > "$project/.loop-agent/backlog.md" <<EOF
# Backlog

## Tasks

- [ ] Task 1: Secret fixture
  - Files:
    - \`$secret_path\`
  - Depends: none
  - Completion criteria:
    - [ ] Create the requested fixture file.
    - [ ] verify: \`true\`
  - Fail count: 0
EOF
  {
    echo "# Project"
    echo "fixture"
  } > "$project/README.md"
  git -C "$project" init -q
  git -C "$project" config user.email "test@example.com"
  git -C "$project" config user.name "Test User"
  git -C "$project" add README.md
  git -C "$project" commit -q -m "initial"
}

assert_case() {
  local name="$1"
  local secret_path="$2"
  local project="$TMP_ROOT/$name/project"
  local bin_dir="$TMP_ROOT/$name/bin"
  local home_dir="$TMP_ROOT/$name/home"
  local output="$TMP_ROOT/$name/output.txt"
  local count_file="$TMP_ROOT/$name/count.txt"

  mkdir -p "$TMP_ROOT/$name" "$home_dir/.codex"
  printf '{}\n' > "$home_dir/.codex/auth.json"
  make_project "$project" "$secret_path"
  make_fake_codex "$bin_dir"

  set +e
  PATH="$bin_dir:$PATH" \
  HOME="$home_dir" \
  SECRET_GUARD_COUNT_FILE="$count_file" \
  SECRET_GUARD_PATH="$secret_path" \
  LOOP_MAX_ATTEMPTS=1 \
    bash "$ROOT/loop.sh" run --iterations 1 --project "$project" > "$output" 2>&1
  local code=$?
  set -e

  if [[ "$code" -eq 0 ]]; then
    echo "expected non-zero exit for $secret_path"
    cat "$output"
    exit 1
  fi

  if git -C "$project" log --format=%s | grep -q '^loop-agent: PASS'; then
    echo "unexpected PASS commit for $secret_path"
    git -C "$project" log --oneline
    exit 1
  fi

  if [[ -e "$project/$secret_path" ]]; then
    echo "secret path remained after rollback: $secret_path"
    cat "$output"
    exit 1
  fi

  if [[ ! -f "$project/.loop-agent/evidence/loop-1/secret_paths.txt" ]]; then
    echo "missing secret path evidence for $secret_path"
    cat "$output"
    exit 1
  fi

  if ! grep -Fxq "$secret_path" "$project/.loop-agent/evidence/loop-1/secret_paths.txt"; then
    echo "secret path evidence did not include $secret_path"
    cat "$project/.loop-agent/evidence/loop-1/secret_paths.txt"
    exit 1
  fi

  if ! grep -Eq 'Secret Path Guard|Fail count: 1|BLOCKED|Blocked' "$project/.loop-agent/backlog.md" "$project/.loop-agent/progress.txt"; then
    echo "failure/block record missing for $secret_path"
    cat "$project/.loop-agent/backlog.md"
    cat "$project/.loop-agent/progress.txt"
    exit 1
  fi
}

assert_case "env" ".env"
assert_case "pem" "cert.pem"
assert_case "ssh" ".ssh/id_rsa"
assert_case "private-key" "private_key.pem"

echo "e2e_secret_path_guard: PASS"
