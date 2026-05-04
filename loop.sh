#!/usr/bin/env bash
# loop-agent · loop.sh
#
# Usage: ./loop.sh N /path/to/myproject
# Example: ./loop.sh 3 /path/to/myproject
#
# Prerequisites:
#   - codex CLI: npm install -g @openai/codex
#   - ChatGPT account login: codex login (Plus subscription or higher required)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$SCRIPT_DIR/agents"

# ── Codex model/effort defaults ───────────────────────────────
# Explicitly sets the model used by loop-agent rather than relying solely on config.toml defaults.
# Can be overridden at runtime via environment variable:
#   CODEX_MODEL=gpt-5.4 ./loop.sh 3 /path/to/project
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"

# After Impl Critic PASS, pins the implementation result as a git commit.
# Can be disabled at runtime:
#   COMMIT_ON_PASS=0 ./loop.sh 3 /path/to/project
COMMIT_ON_PASS="${COMMIT_ON_PASS:-1}"

# ── Colors ────────────────────────────────────────────────────
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
CYAN="\033[36m"; GRAY="\033[90m"; BOLD="\033[1m"; RESET="\033[0m"

err()    { echo -e "${RED}Error: $*${RESET}" >&2; }
ok()     { echo -e "${GREEN}✓ $*${RESET}"; }
info()   { echo -e "${GRAY}  $*${RESET}"; }
warn()   { echo -e "${YELLOW}⚠ $*${RESET}"; }
phase()  { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }
banner() { echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════╗${RESET}"
           echo -e "${BOLD}${CYAN}║  $*${RESET}"
           echo -e "${BOLD}${CYAN}╚══════════════════════════════════════╝${RESET}"; }

# ── RESULTS array ─────────────────────────────────────────────
RESULTS=()
LOOP=0  # Loop number. Initial value to prevent undefined variable in prerequisites/Ctrl+C

add_result() {
  RESULTS+=("$1")
  # Immediately update window after writing to progress.txt
  build_progress_window 2>/dev/null || true
}

print_results() {
  echo -e "\n${BOLD}=== Summary ===${RESET}"
  for r in "${RESULTS[@]}"; do
    echo -e "  $r"
  done
  echo ""
  if [[ -n "${PROJECT_DIR:-}" ]]; then
    echo -e "  State files: ${GRAY}${PROJECT_DIR}/.loop-agent/${RESET}"
    echo -e "  Report:      ${CYAN}${PROJECT_DIR}/.loop-agent/report.md${RESET}"
  fi
  echo ""
}

# ── Ctrl+C handler ────────────────────────────────────────────
cleanup() {
  echo ""
  # LOOP=0 means interrupted during prerequisite checks
  if [[ "$LOOP" -eq 0 ]]; then
    add_result "Before start: INTERRUPTED"
  else
    add_result "Loop ${LOOP}: INTERRUPTED"
  fi
  # Kill any running agent process
  if [[ -n "${CODEX_PID:-}" ]]; then
    kill "$CODEX_PID" 2>/dev/null || true
  fi
  # Restore protected state files that were in progress at interrupt time
  # - If PROTECTED_BACKUPS is empty, no-op (before snapshot or already restored)
  # - If not empty, restore from .protected and clean up → preserves next-run baseline
  if declare -f restore_state_files_if_modified >/dev/null 2>&1; then
    restore_state_files_if_modified "Interrupted (loop ${LOOP})" 2>/dev/null || true
  fi
  print_results
  echo -e "${YELLOW}Interrupted.${RESET}"
  echo ""
  echo "Temporary files from the current loop (plan.md, impl_summary.md, etc.)"
  echo "may remain in .loop-agent/."
  echo "These files are not carried over between loops and will be"
  echo "re-initialized in Phase 0 on the next run."
  echo ""
  echo "Planner reads both progress.txt and the current project file state."
  echo "If Implementer modified files before the interrupt,"
  echo "progress.txt and the project file state may be out of sync."
  echo "In that case, Planner prioritizes the actual file state."
  exit 130
}
trap cleanup INT TERM

# ── Argument check ────────────────────────────────────────────
if [[ $# -lt 2 ]] || [[ $# -gt 3 ]]; then
  err "Invalid arguments."
  echo "Usage: ./loop.sh <iterations> <project folder> [cli]"
  echo "  cli: codex (default), gemini"
  echo "Example: ./loop.sh 3 /path/to/myproject"
  echo "         ./loop.sh 3 /path/to/myproject gemini"
  exit 1
fi

MAX_LOOPS="$1"
PROJECT_DIR="$2"
LOOP_CLI="${3:-codex}"

case "$LOOP_CLI" in
  codex|gemini) ;;
  *)
    err "Unsupported CLI: $LOOP_CLI (supported: codex, gemini)"
    exit 1
    ;;
esac

# ── Windows PATH merge (fix for pnpm etc. not found in Git Bash) ──
# Git Bash may omit parts of the Windows PATH
# Merge Windows PATH into Git Bash PATH via cmd //c path
if [[ -n "${WINDIR:-}" ]] || [[ "$(uname -s)" == MINGW* ]] || [[ "$(uname -s)" == MSYS* ]]; then
  # Add npm global path directly (instead of parsing cmd PATH — avoids encoding issues)
  NPM_PREFIX="$(npm config get prefix 2>/dev/null || true)"
  if [[ -n "$NPM_PREFIX" ]]; then
    NPM_UNIX="$(cygpath -u "$NPM_PREFIX" 2>/dev/null || echo "")"
    if [[ -n "$NPM_UNIX" ]] && [[ ":$PATH:" != *":$NPM_UNIX:"* ]]; then
      export PATH="$PATH:$NPM_UNIX"
    fi
  fi
  # Also add AppData/Roaming/npm (for pnpm etc.)
  if [[ -n "${APPDATA:-}" ]]; then
    APPDATA_NPM="$(cygpath -u "$APPDATA/npm" 2>/dev/null || echo "")"
    if [[ -n "$APPDATA_NPM" ]] && [[ ":$PATH:" != *":$APPDATA_NPM:"* ]]; then
      export PATH="$PATH:$APPDATA_NPM"
    fi
  fi
fi

# ── Prerequisites ─────────────────────────────────────────────
# Validate N
if ! [[ "$MAX_LOOPS" =~ ^[1-9][0-9]*$ ]]; then
  add_result "Before start: ERROR (prerequisites failed)"
  print_results
  err "Iterations must be a positive integer: $MAX_LOOPS"
  exit 1
fi

# Project folder
if [[ ! -d "$PROJECT_DIR" ]]; then
  add_result "Before start: ERROR (prerequisites failed)"
  print_results
  err "Project folder not found: $PROJECT_DIR"
  exit 1
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# envsubst (CLI-agnostic)
if ! command -v envsubst &>/dev/null; then
  add_result "Before start: ERROR (prerequisites failed)"
  print_results
  err "envsubst is not installed."
  echo "  In Git Bash, the gettext package or a package that includes envsubst is required."
  echo "  Alternatively, replace the render function in loop.sh with a Python-based substitution."
  exit 1
fi

# CLI-specific prerequisites (install + auth)
case "$LOOP_CLI" in
  codex)
    if ! command -v codex &>/dev/null; then
      add_result "Before start: ERROR (prerequisites failed)"
      print_results
      err "codex CLI is not installed."
      echo "  Install: npm install -g @openai/codex"
      exit 1
    fi

    # Check ChatGPT login (codex uses ChatGPT account login)
    CODEX_AUTH_FILE="${HOME}/.codex/auth.json"
    if [[ ! -f "$CODEX_AUTH_FILE" ]]; then
      add_result "Before start: ERROR (prerequisites failed)"
      print_results
      err "ChatGPT login required."
      echo ""
      echo "  Log in first with the following command:"
      echo "    codex login"
      echo ""
      echo "  When the browser opens, log in with your ChatGPT account."
      echo "  (ChatGPT Plus subscription or higher required)"
      exit 1
    fi
    ;;
  gemini)
    if ! command -v gemini &>/dev/null; then
      add_result "Before start: ERROR (prerequisites failed)"
      print_results
      err "gemini CLI is not installed."
      echo "  Install: npm install -g @google/gemini-cli"
      exit 1
    fi

    # Startup sanity check — verify gemini can run at all
    # (not full argument compatibility, but catches installation defects early)
    if ! gemini --version &>/dev/null && ! gemini -v &>/dev/null; then
      warn "gemini --version call failed. CLI functionality is suspect."
      echo "  Continuing, but the first call may fail."
      echo "  Override arguments via LOOP_GEMINI_FLAGS / LOOP_GEMINI_MODEL_FLAG if needed."
    fi

    # Check Gemini auth (API key or OAuth login cache)
    if [[ -z "${GEMINI_API_KEY:-}" ]] && [[ ! -d "${HOME}/.gemini" ]]; then
      warn "Gemini authentication not confirmed."
      echo ""
      echo "  Set one of the following:"
      echo "    1) export GEMINI_API_KEY=<your_key>"
      echo "    2) gemini  (run once then complete OAuth login)"
      echo ""
      echo "  Continuing, but the first call may fail."
    fi
    ;;
esac

# ── Initialize state directory ────────────────────────────────
STATE_DIR="$PROJECT_DIR/.loop-agent"
mkdir -p "$STATE_DIR"

FILE_INDEX_BEFORE="$STATE_DIR/file_index_before.md"
FILE_INDEX_AFTER="$STATE_DIR/file_index_after.md"
PROGRESS="$STATE_DIR/progress.txt"
PLAN="$STATE_DIR/plan.md"
PLAN_CRITIQUE="$STATE_DIR/plan_critique.md"
IMPL_SUMMARY="$STATE_DIR/impl_summary.md"
IMPL_CRITIQUE="$STATE_DIR/impl_critique.md"
BACKLOG="$STATE_DIR/backlog.md"
BACKLOG_ARCHIVE="$STATE_DIR/backlog_archive.md"
CURRENT_TASK="$STATE_DIR/current_task.md"
REPORT="$STATE_DIR/report.md"

# Initialize progress.txt on first run
if [[ ! -f "$PROGRESS" ]]; then
  printf '# Loop Agent Progress\nProject: %s\nStarted: %s\n---\n' \
    "$PROJECT_DIR" "$(date '+%Y-%m-%d %H:%M:%S')" > "$PROGRESS"
fi

# ── render: substitutes only $LOOP_* variables ────────────────
render() {
  local template="$1"
  local output="$2"
  envsubst '${LOOP_N} ${LOOP_MAX} ${LOOP_PROJECT_DIR} ${LOOP_STATE_DIR} \
    ${LOOP_FILE_INDEX_BEFORE} ${LOOP_FILE_INDEX_AFTER} \
    ${LOOP_PROGRESS} ${LOOP_PROGRESS_WINDOW} \
    ${LOOP_BACKLOG} ${LOOP_CURRENT_TASK} \
    ${LOOP_PLAN} ${LOOP_PLAN_CRITIQUE} \
    ${LOOP_IMPL_SUMMARY} ${LOOP_IMPL_CRITIQUE} ${LOOP_REPORT}' \
    < "$template" > "$output"
}

# ── Per-task effort calculation ──────────────────────────────
get_task_fail_count() {
  local backlog="$1"
  local task_id="$2"

  # The format produced by backlog_manager.py is generally:
  #   - [ ] Task 6.3: ...
  #     - Fail count: 2
  # Legacy format is also supported:
  #   ## Task 6.3: ...
  #   FAIL_COUNT: 2
  awk -v tid="$task_id" '
    BEGIN { found=0 }

    # Current loop-agent backlog format
    $0 ~ "^- \\[.\\] " tid ":" { found=1; next }

    # Legacy markdown heading format
    $0 ~ "^## " tid ":" { found=1; next }

    # Stop when reaching the next task
    found && $0 ~ "^- \\[.\\] Task " { exit }
    found && $0 ~ "^## Task " { exit }

    # English "Fail count:" format (backlog_manager.py)
    found && $0 ~ /^[[:space:]]*-?[[:space:]]*Fail count:[[:space:]]*/ {
      sub(/^[[:space:]]*-?[[:space:]]*Fail count:[[:space:]]*/, "", $0)
      gsub(/[^0-9].*$/, "", $0)
      gsub(/\r/, "", $0)
      print ($0 == "" ? 0 : $0)
      exit
    }

    # Legacy English FAIL_COUNT format
    found && $0 ~ /^[[:space:]]*FAIL_COUNT:[[:space:]]*/ {
      sub(/^[[:space:]]*FAIL_COUNT:[[:space:]]*/, "", $0)
      gsub(/[^0-9].*$/, "", $0)
      gsub(/\r/, "", $0)
      print ($0 == "" ? 0 : $0)
      exit
    }
  ' "$backlog" 2>/dev/null
}

get_effort_for_task() {
  local role="$1"
  local fail_count="${2:-0}"

  case "$role" in
    planner)
      if [[ "$fail_count" -ge 2 ]]; then
        echo "high"
      else
        echo "medium"
      fi
      ;;
    plan_critic)
      echo "medium"
      ;;
    implementer)
      echo "high"
      ;;
    impl_critic)
      echo "high"
      ;;
    reporter)
      echo "none"
      ;;
    *)
      echo "medium"
      ;;
  esac
}

# ── run_agent: independent CLI process (codex / gemini) ───────
# Key: new process per call → fresh context (no prior agent conversation)
# File artifacts are readable (independence = conversation isolation, not file access isolation)
GEMINI_MODEL="${LOOP_GEMINI_MODEL:-gemini-3.1-pro-preview}"
# gemini CLI argument overrides (exposed as env vars because flags differ between CLI versions)
#   LOOP_GEMINI_FLAGS      — default sandbox/approval bypass flags (default "--yolo")
#   LOOP_GEMINI_MODEL_FLAG — model specification flag (default "--model")
#   LOOP_GEMINI_USE_PROMPT_ARG=1 — pass prompt via -p argument instead of stdin
GEMINI_FLAGS="${LOOP_GEMINI_FLAGS:---yolo}"
GEMINI_MODEL_FLAG="${LOOP_GEMINI_MODEL_FLAG:---model}"
CODEX_PID=""
run_agent() {
  local name="$1"
  local agent_file="$2"
  local out_file="$3"
  local reasoning="${4:-medium}"   # 4th arg: reasoning effort (codex only)
  local model="${5:-}"             # 5th arg: explicit model (omit to use CLI default)

  case "$LOOP_CLI" in
    codex)
      model="${model:-$CODEX_MODEL}"
      info "[$name] running... (cli: codex, model: $model, reasoning: $reasoning)"
      ( cd "$PROJECT_DIR" && codex exec \
        --dangerously-bypass-approvals-and-sandbox \
        -m "$model" \
        -c "model_reasoning_effort=\"$reasoning\"" \
        - < "$agent_file" \
        > "$out_file" \
        2>> "$STATE_DIR/codex.log" ) &
      ;;
    gemini)
      info "[$name] running... (cli: gemini, model: $GEMINI_MODEL)"
      # gemini CLI call. Can be overridden via env vars (LOOP_GEMINI_*).
      # Default: stdin input + --yolo + --model
      # If stdin is not supported in some versions, set LOOP_GEMINI_USE_PROMPT_ARG=1 to use -p
      if [[ "${LOOP_GEMINI_USE_PROMPT_ARG:-0}" == "1" ]]; then
        ( cd "$PROJECT_DIR" && gemini \
          $GEMINI_FLAGS \
          $GEMINI_MODEL_FLAG "$GEMINI_MODEL" \
          -p "$(cat "$agent_file")" \
          > "$out_file" \
          2>> "$STATE_DIR/codex.log" ) &
      else
        ( cd "$PROJECT_DIR" && gemini \
          $GEMINI_FLAGS \
          $GEMINI_MODEL_FLAG "$GEMINI_MODEL" \
          < "$agent_file" \
          > "$out_file" \
          2>> "$STATE_DIR/codex.log" ) &
      fi
      ;;
  esac
  CODEX_PID=$!

  if wait "$CODEX_PID"; then
    CODEX_PID=""
    ok "[$name] done"
    return 0
  else
    local exit_code=$?
    CODEX_PID=""
    return $exit_code
  fi
}

# ── detect_rate_limit: scan end of codex.log for limit patterns ──
# codex.log is a stderr dump and is not fed into model input (verified)
detect_rate_limit() {
  local log_file="$STATE_DIR/codex.log"
  [[ ! -f "$log_file" ]] && return 1

  # Keywords that appear in stderr when a CLI hits its limit
  # codex/ChatGPT: rate limit, usage limit, plan limit, etc.
  # gemini: RESOURCE_EXHAUSTED, quota exceeded, etc.
  if tail -80 "$log_file" 2>/dev/null | grep -qiE \
      'rate.?limit|usage.?limit|429|quota.?exceeded|too.?many.?requests|limit.?reached|exceeded.*limit|usage.?cap|plan.?limit|resource.?exhausted'; then
    return 0
  fi
  return 1
}

# ── suspend_for_rate_limit: safe exit on limit exceeded ────────
# Implementer/Impl Critic phases discard partial changes via git_rollback.
# Fail count is not incremented (not the user's fault).
suspend_for_rate_limit() {
  local phase_name="$1"

  warn "Usage limit exceeded detected (phase: $phase_name)"

  case "$phase_name" in
    Implementer|"Impl Critic")
      git_rollback "limit exceeded → discard partial implementation"
      ;;
  esac

  add_result "Loop ${LOOP}: SUSPENDED (limit exceeded) — ${NEXT_TASK_ID:-unknown}"

  if [[ -f "$PROGRESS" ]]; then
    {
      echo ""
      echo "=== Loop ${LOOP}: SUSPENDED (limit exceeded) ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Phase: $phase_name"
      echo "Task: ${NEXT_TASK_ID:-unknown} — ${NEXT_TASK_NAME:-unknown}"
      echo "Note: Safe exit due to usage limit. Fail count not incremented."
      echo ""
    } >> "$PROGRESS"
  fi

  print_results

  echo ""
  echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${YELLOW}  ⚠ ${LOOP_CLI} usage limit reached${RESET}"
  echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  echo "  • Exited safely (rolled back if in Implementer/Impl Critic phase)"
  echo "  • Fail count not incremented"
  echo "  • After limit resets, resume with the same command:"
  echo "      ./loop.sh ${MAX_LOOPS} \"${PROJECT_DIR}\" ${LOOP_CLI}"
  echo ""
  echo "  Detailed log: $STATE_DIR/codex.log"
  echo ""

  exit 2
}

# ── State file protection: prevent Implementer/Impl Critic from corrupting .loop-agent/ ──
# Background:
#   Because git_rollback preserves .loop-agent/, if an agent modifies state files
#   like backlog.md or progress.txt, those changes survive even on FAIL.
#   Example: Implementer marks its own Task [x] in backlog.md → Impl Critic FAIL
#       → rollback fires → but .loop-agent/ is preserved so [x] remains
#       → next loop incorrectly concludes "all tasks complete".
# Policy:
#   Only loop.sh modifies state files. Agents write only their own output (stdout).
#   Snapshot before agent call → auto-restore on detected change after call (regardless of verdict).
declare -a PROTECTED_BACKUPS=()

snapshot_state_files() {
  PROTECTED_BACKUPS=()
  # Protected targets: read-only input files for all phases.
  # Each agent's legitimate output is written directly via run_agent's stdout redirect,
  # so it does not exist just before the call → automatically excluded by snapshot's [[ -f ]] check.
  local files=("$BACKLOG" "$PROGRESS" "$CURRENT_TASK" "$PLAN" "$PLAN_CRITIQUE" "$IMPL_SUMMARY")
  local f backup
  for f in "${files[@]}"; do
    if [[ -f "$f" ]]; then
      backup="${f}.protected"
      cp "$f" "$backup"
      PROTECTED_BACKUPS+=("$f|$backup")
    fi
  done
}

restore_state_files_if_modified() {
  local agent="$1"
  local restored=0
  local entry f backup
  for entry in "${PROTECTED_BACKUPS[@]}"; do
    f="${entry%%|*}"
    backup="${entry##*|}"
    if [[ ! -f "$backup" ]]; then continue; fi
    if [[ -f "$f" ]] && ! cmp -s "$f" "$backup" 2>/dev/null; then
      warn "${agent} modified state file: $(basename "$f") → restoring"
      cp "$backup" "$f"
      restored=$((restored + 1))
    fi
    rm -f "$backup"
  done
  PROTECTED_BACKUPS=()
  if [[ $restored -gt 0 ]]; then
    warn "${agent}: restored ${restored} state file(s) (preventing rollback bypass)"
  fi
}

# ── cleanup_orphaned_backups: clean up .protected files left by a prior abnormal exit ──
# Guards against SIGKILL, system crash, bash crash, etc. where cleanup trap did not run.
# Policy:
#   - If .protected is older than the original → stale → remove
#   - If .protected differs from original → restore .protected as baseline (block suspicious changes)
#   - If .protected matches original → simple cleanup
cleanup_orphaned_backups() {
  if [[ ! -d "$STATE_DIR" ]]; then return 0; fi
  shopt -s nullglob

  # 1. Handle leftover snapshot/.protected files (cleanup trap did not run)
  local orphan original recovered=0
  for orphan in "$STATE_DIR"/*.protected; do
    original="${orphan%.protected}"
    if [[ -f "$original" ]] && ! cmp -s "$original" "$orphan" 2>/dev/null; then
      warn "Backup left by prior interrupt found → restoring baseline: $(basename "$original")"
      cp "$orphan" "$original"
      recovered=$((recovered + 1))
    fi
    rm -f "$orphan"
  done

  # 2. Clean up backlog_manager.py atomic write temp files (.bm_*.tmp)
  # These disappear immediately after os.replace in normal flow, but may linger after a crash.
  local tmp_orphan tmp_count=0
  for tmp_orphan in "$STATE_DIR"/.bm_*.tmp; do
    rm -f "$tmp_orphan"
    tmp_count=$((tmp_count + 1))
  done

  shopt -u nullglob

  if [[ $recovered -gt 0 ]]; then
    warn "Restored ${recovered} orphaned backup(s) (traces of prior abnormal exit)"
  fi
  if [[ $tmp_count -gt 0 ]]; then
    info "Cleaned up ${tmp_count} atomic write temp file(s)"
  fi
}

# ── check_verdict: extract from first line starting with VERDICT: ──
# Trailing newline and case are ignored.
check_verdict() {
  local file="$1"
  grep -m1 "^VERDICT:" "$file" 2>/dev/null \
    | grep -oiE 'PASS|FAIL|SCOPE_EXPAND|SPLIT_TASK' \
    | head -1 \
    || echo "UNKNOWN"
}

# ── append_shell_report: write cumulative report without calling Reporter Codex ──
append_shell_report() {
  local status="$1"
  local failed_phase="${2:-none}"
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"

  {
    echo ""
    echo "---"
    echo ""
    echo "## ${now} · Loop ${LOOP} · ${status}"
    echo ""
    echo "**Task:** ${NEXT_TASK_ID} — ${NEXT_TASK_NAME}  "
    local report_model
    case "$LOOP_CLI" in
      codex)  report_model="${CODEX_MODEL:-unknown} (codex)" ;;
      gemini) report_model="${GEMINI_MODEL:-unknown} (gemini)" ;;
      *)      report_model="unknown" ;;
    esac
    echo "**Model:** ${report_model}  "
    echo "**Effort:** planner=${PLANNER_EFFORT}, plan_critic=${PLAN_CRITIC_EFFORT}, implementer=${IMPLEMENTER_EFFORT}, impl_critic=${IMPL_CRITIC_EFFORT}, reporter=none  "

    if [[ "$failed_phase" != "none" ]]; then
      echo "**Failed phase:** ${failed_phase}  "
    fi

    echo ""

    if [[ -f "$PLAN_CRITIQUE" ]]; then
      local plan_verdict
      plan_verdict="$(check_verdict "$PLAN_CRITIQUE")"

      echo "### Plan Critic"
      echo ""
      echo "- Verdict: ${plan_verdict}"

      local plan_notes
      plan_notes="$(grep "^## Notes" -A4 "$PLAN_CRITIQUE" 2>/dev/null | grep -v "^## Notes" | head -4 || true)"
      if [[ -n "$plan_notes" ]]; then
        echo "- Notes: ${plan_notes//$'\n'/ }"
      fi

      echo ""
    fi

    if [[ -f "$IMPL_CRITIQUE" ]]; then
      local impl_verdict
      impl_verdict="$(check_verdict "$IMPL_CRITIQUE")"

      echo "### Impl Critic"
      echo ""
      echo "- Verdict: ${impl_verdict}"

      local impl_notes
      impl_notes="$(grep "^## Notes" -A5 "$IMPL_CRITIQUE" 2>/dev/null | grep -v "^## Notes" | head -5 || true)"
      if [[ -n "$impl_notes" ]]; then
        echo "- Notes: ${impl_notes//$'\n'/ }"
      fi

      echo ""
    fi

    if [[ -f "$IMPL_SUMMARY" ]]; then
      echo "### Completed steps"
      echo ""

      local completed
      completed="$(grep "^\- \[x\]" "$IMPL_SUMMARY" 2>/dev/null | sed 's/^- \[x\] /- /' || true)"

      if [[ -n "$completed" ]]; then
        echo "$completed"
      else
        echo "- none"
      fi

      echo ""
      echo "### Validation"
      echo ""

      local validations
      validations="$(grep -iE 'verify:|pnpm |npm |vitest|typecheck|tsc ' "$IMPL_SUMMARY" 2>/dev/null | head -10 || true)"

      if [[ -n "$validations" ]]; then
        echo "$validations" | sed 's/^/- /'
      else
        echo "- not recorded"
      fi

      echo ""
    fi

    echo "### Latest artifacts"
    echo ""
    echo "- .loop-agent/current_task.md"
    echo "- .loop-agent/plan.md"
    echo "- .loop-agent/plan_critique.md"
    echo "- .loop-agent/impl_summary.md"
    echo "- .loop-agent/impl_critique.md"
    echo ""
  } >> "$REPORT"
}

# ── truncate_progress_if_large: prevent unbounded growth of progress.txt ──
# Policy:
#   - Triggers when file exceeds PROGRESS_SIZE_THRESHOLD
#   - Keeps only header + the most recent PROGRESS_KEEP_ENTRIES sections
#   - Atomic write (progress_window.py --truncate)
PROGRESS_SIZE_THRESHOLD="${PROGRESS_SIZE_THRESHOLD:-524288}"   # 512KB
PROGRESS_KEEP_ENTRIES="${PROGRESS_KEEP_ENTRIES:-50}"

truncate_progress_if_large() {
  if [[ ! -f "$PROGRESS" ]]; then return 0; fi

  local size
  size=$(wc -c < "$PROGRESS" 2>/dev/null | tr -d ' \r' || echo 0)
  if [[ -z "$size" ]] || ! [[ "$size" =~ ^[0-9]+$ ]]; then return 0; fi
  if (( size < PROGRESS_SIZE_THRESHOLD )); then return 0; fi

  local py_cmd
  py_cmd="$(get_python_cmd)"
  if [[ -z "$py_cmd" ]]; then return 0; fi

  local result
  result="$(PYTHONUTF8=1 PYTHONIOENCODING=utf-8 \
    $py_cmd "$SCRIPT_DIR/progress_window.py" --truncate \
    "$PROGRESS" "$PROGRESS_KEEP_ENTRIES" 2>/dev/null || true)"

  if [[ "$result" == TRUNCATED:* ]]; then
    local removed="${result#TRUNCATED: }"
    info "progress.txt trimmed: removed ${removed} old section(s) (${size} bytes → trim)"
  fi
}

# ── build_progress_window: extract only the most recent 5 sections ──
# Slices the last 5 === Loop N: ... === sections from progress.txt
# Uses a separate script file instead of a Python heredoc (Git Bash compatible)
build_progress_window() {
  local window_file="$STATE_DIR/progress_window.txt"
  local window_size=5
  local py_script="$SCRIPT_DIR/progress_window.py"

  if [[ ! -f "$PROGRESS" ]]; then
    echo "(no progress.txt - first loop)" > "$window_file"
    return
  fi

  if [[ ! -f "$py_script" ]]; then
    # Fall back to full progress.txt if progress_window.py is missing
    warn "progress_window.py not found → using full progress.txt"
    cp "$PROGRESS" "$window_file"
    return
  fi

  {
    sed -n "1,/^---$/p" "$PROGRESS"
    echo ""
    echo "# Recent ${window_size} loop results (sliding window)"
    echo ""
    # Try python if python3 is unavailable (python3 may be a fake launcher on Windows)
    # WindowsApps path is Microsoft Store fake launcher → skip
    local py_cmd=""
    local py3_path
    py3_path="$(command -v python3 2>/dev/null || true)"
    if [[ -n "$py3_path" ]] && [[ "$py3_path" != *"WindowsApps"* ]]; then
      py_cmd="python3"
    else
      local py_path
      py_path="$(command -v python 2>/dev/null || true)"
      if [[ -n "$py_path" ]] && [[ "$py_path" != *"WindowsApps"* ]]; then
        py_cmd="python"
      fi
    fi
    if [[ -z "$py_cmd" ]]; then
      warn "python not found. Using full progress.txt."
      cp "$PROGRESS" "$window_file"
      return
    fi
    PYTHONUTF8=1 PYTHONIOENCODING=utf-8 $py_cmd "$py_script" "$PROGRESS" "$window_size"
  } > "$window_file"

  local total
  total=$(grep -c "^=== Loop" "$PROGRESS" 2>/dev/null || echo 0)
  info "progress sliding window: ${window_size} most recent of ${total} total"
}

# ── scan: scan project folder → file_index ────────────────────
scan_project() {
  local output_file="$1"
  local label="$2"
  info "Scanning ($label)..."
  {
    echo "# File Index ($label)"
    echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Project: $PROJECT_DIR"
    echo ""
    echo "## File list"
    find "$PROJECT_DIR" \
      -not -path "$PROJECT_DIR/.loop-agent/*" \
      -not -path "$PROJECT_DIR/.git/*" \
      -not -path "$PROJECT_DIR/node_modules/*" \
      -not -path "$PROJECT_DIR/__pycache__/*" \
      -not -path "$PROJECT_DIR/.venv/*" \
      -type f \
      | sort \
      | sed "s|$PROJECT_DIR/||"
  } > "$output_file"
}

# ── export_vars: variables passed to agents ───────────────────
export_vars() {
  export LOOP_N="$LOOP"
  export LOOP_MAX="$MAX_LOOPS"
  export LOOP_PROJECT_DIR="$PROJECT_DIR"
  export LOOP_STATE_DIR="$STATE_DIR"
  export LOOP_FILE_INDEX_BEFORE="$FILE_INDEX_BEFORE"
  export LOOP_FILE_INDEX_AFTER="$FILE_INDEX_AFTER"
  export LOOP_PROGRESS="$PROGRESS"
  export LOOP_PROGRESS_WINDOW="$STATE_DIR/progress_window.txt"
  export LOOP_BACKLOG="$BACKLOG"
  export LOOP_CURRENT_TASK="$CURRENT_TASK"
  export LOOP_PLAN="$PLAN"
  export LOOP_PLAN_CRITIQUE="$PLAN_CRITIQUE"
  export LOOP_IMPL_SUMMARY="$IMPL_SUMMARY"
  export LOOP_IMPL_CRITIQUE="$IMPL_CRITIQUE"
  export LOOP_REPORT="$REPORT"
}

# ── git_init: initialize git if not present ───────────────────
git_ensure_init() {
  if ! git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null; then
    info "No git found. Initializing..."
    git -C "$PROJECT_DIR" init -q

    # Suppress LF/CRLF warnings (Windows Git Bash)
    git -C "$PROJECT_DIR" config core.autocrlf false

    # .gitattributes: keep LF
    printf '* text=auto eol=lf\n' > "$PROJECT_DIR/.gitattributes" 

    # .gitignore: exclude embedded git folders and loop-agent state files
    # Do not overwrite an existing .gitignore
    if [[ ! -f "$PROJECT_DIR/.gitignore" ]]; then
      printf '# loop-agent state files (no git tracking needed)\n.loop-agent/\n' > "$PROJECT_DIR/.gitignore"
    else
      # Append .loop-agent/ if not already in existing .gitignore
      if ! grep -q "^\.loop-agent/" "$PROJECT_DIR/.gitignore" 2>/dev/null; then
        echo ".loop-agent/" >> "$PROJECT_DIR/.gitignore"
      fi
    fi

    # Auto-detect embedded git folders (subdirs containing .git) and add to .gitignore
    while IFS= read -r -d '' subgit; do
      subdir="${subgit%/.git}"
      subdir="${subdir#$PROJECT_DIR/}"
      if ! grep -q "^${subdir}/" "$PROJECT_DIR/.gitignore" 2>/dev/null; then
        echo "${subdir}/" >> "$PROJECT_DIR/.gitignore"
        info "Excluding embedded git folder: $subdir/"
      fi
    done < <(find "$PROJECT_DIR" -mindepth 2 -name ".git" -not -path "$PROJECT_DIR/.git" -print0 2>/dev/null)

    git -C "$PROJECT_DIR" add -A
    git -C "$PROJECT_DIR" commit -q -m "loop-agent: initial commit before loop 1"
    ok "git initialized"
  else
    # Ensure .loop-agent/ is not tracked even when git already exists
    if ! grep -q "^\.loop-agent/" "$PROJECT_DIR/.gitignore" 2>/dev/null; then
      echo ".loop-agent/" >> "$PROJECT_DIR/.gitignore"
    fi
    # Set core.autocrlf false
    git -C "$PROJECT_DIR" config core.autocrlf false
  fi
}

# ── git_snapshot: snapshot before running Implementer ─────────
git_snapshot() {
  local msg="loop-agent: loop ${LOOP} pre-implementer snapshot"

  # The rollback baseline includes only changes to the implementation target.
  # loop-agent tool files and .loop-agent state files are loop infrastructure
  # and must not be mixed into the pre-implementer snapshot.
  
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" reset -q -- .loop-agent loop-agent 2>/dev/null || true

  # Handle gracefully even when there are no changes
  if ! git -C "$PROJECT_DIR" diff --cached --quiet; then
    git -C "$PROJECT_DIR" commit -q -m "$msg"
  else
    # No changes — create empty commit
    git -C "$PROJECT_DIR" commit -q --allow-empty -m "$msg"
  fi
  info "git snapshot: $msg"
}


# ── git_commit_pass: pin Impl Critic PASS result as a commit ──
git_commit_if_dirty() {
  local repo="$1"
  local msg="$2"
  local exclude_loop_agent="${3:-0}"

  if ! git -C "$repo" rev-parse --git-dir &>/dev/null; then
    return 0
  fi

  if [[ "$exclude_loop_agent" == "1" ]]; then
    git -C "$repo" add -A
    git -C "$repo" reset -q -- .loop-agent loop-agent 2>/dev/null || true
  else
    git -C "$repo" add -A
    git -C "$repo" reset -q -- .loop-agent 2>/dev/null || true
  fi

  if git -C "$repo" diff --cached --quiet; then
    info "No changes to commit for PASS: $repo"
    return 0
  fi

  git -C "$repo" commit -q -m "$msg"
  ok "PASS commit done: $repo"
}

git_commit_pass() {
  local msg="loop-agent: PASS ${NEXT_TASK_ID} loop ${LOOP}"
  local committed_nested=0

  # If a separate git repo exists inside PROJECT_DIR, commit its changes first.
  # Example: PROJECT_DIR=parent folder, actual implementation target=inkos/
  while IFS= read -r -d '' git_marker; do
    local subrepo
    subrepo="${git_marker%/.git}"
    if [[ -f "$git_marker" ]]; then
      subrepo="$(dirname "$git_marker")"
    fi

    # Exclude the main repo and loop-agent tool repo from nested implementation repo processing.
    if [[ "$subrepo" == "$PROJECT_DIR" ]]; then
      continue
    fi
    case "$subrepo" in
      "$PROJECT_DIR/loop-agent"|"$PROJECT_DIR/loop-agent/"*)
        continue
        ;;
    esac

    git_commit_if_dirty "$subrepo" "$msg" "0"
    committed_nested=1
  done < <(find "$PROJECT_DIR" -mindepth 2 \
    \( -path "$PROJECT_DIR/.loop-agent" -o -path "$PROJECT_DIR/node_modules" -o -path "$PROJECT_DIR/.venv" -o -path "$PROJECT_DIR/__pycache__" \) -prune -o \
    -name ".git" \( -type d -o -type f \) -print0 2>/dev/null)

  if [[ "$committed_nested" == "1" ]]; then
    info "nested git repo PASS commit confirmed"
  fi

  # Finally, commit changes in PROJECT_DIR itself.
  # Exclude loop-agent tool files and .loop-agent state files.
  git_commit_if_dirty "$PROJECT_DIR" "$msg" "1"
}

# ── git_rollback: restore to snapshot on Impl Critic FAIL ─────
git_reset_clean_nested_repo() {
  local repo="$1"

  if ! git -C "$repo" rev-parse --git-dir &>/dev/null; then
    return 0
  fi

  # nested implementation repo is not a loop tool, so fully restore to HEAD.
  git -C "$repo" reset --hard -q HEAD
  git -C "$repo" clean -fd -q --exclude=.loop-agent/

  ok "rollback done: $repo"
}

git_reset_clean_project_repo() {
  local repo="$1"

  if ! git -C "$repo" rev-parse --git-dir &>/dev/null; then
    return 0
  fi

  # When rolling back PROJECT_DIR itself, preserve loop-agent tools and .loop-agent state files.
  # clean --exclude only prevents deletion of untracked files, so reset/checkout must also
  # use pathspec excludes to protect those paths.
  git -C "$repo" reset -q HEAD -- \
    . \
    ':(exclude).loop-agent' ':(exclude).loop-agent/**' \
    ':(exclude)loop-agent' ':(exclude)loop-agent/**'

  git -C "$repo" checkout -q HEAD -- \
    . \
    ':(exclude).loop-agent' ':(exclude).loop-agent/**' \
    ':(exclude)loop-agent' ':(exclude)loop-agent/**'

  git -C "$repo" clean -fd -q --exclude=.loop-agent/ --exclude=loop-agent/

  ok "rollback done: $repo"
}

git_rollback() {
  local reason="${1:-Restore to state before Implementer changes}"
  info "rollback: $reason"

  local rolled_nested=0

  # Rollback any separate git repos inside PROJECT_DIR first.
  # Example: PROJECT_DIR=parent folder, actual implementation target=inkos/
  while IFS= read -r -d '' git_marker; do
    local subrepo
    subrepo="${git_marker%/.git}"
    if [[ -f "$git_marker" ]]; then
      subrepo="$(dirname "$git_marker")"
    fi

    if [[ "$subrepo" == "$PROJECT_DIR" ]]; then
      continue
    fi

    case "$subrepo" in
      "$PROJECT_DIR/loop-agent"|"$PROJECT_DIR/loop-agent/"*)
        continue
        ;;
    esac

    git_reset_clean_nested_repo "$subrepo"
    rolled_nested=1
  done < <(find "$PROJECT_DIR" -mindepth 2 \
    \( -path "$PROJECT_DIR/.loop-agent" -o -path "$PROJECT_DIR/node_modules" -o -path "$PROJECT_DIR/.venv" -o -path "$PROJECT_DIR/__pycache__" \) -prune -o \
    -name ".git" \( -type d -o -type f \) -print0 2>/dev/null)

  if [[ "$rolled_nested" == "1" ]]; then
    info "nested git repo rollback confirmed"
  fi

  # Finally, rollback PROJECT_DIR itself.
  # Preserve loop-agent tool files and .loop-agent state files.
  git_reset_clean_project_repo "$PROJECT_DIR"

  ok "rollback done (tracked/untracked changes cleared, .loop-agent and loop-agent preserved)"
}

# ── python_cmd: auto-detect python/python3 ────────────────────
get_python_cmd() {
  local py3_path
  py3_path="$(command -v python3 2>/dev/null || true)"
  if [[ -n "$py3_path" ]] && [[ "$py3_path" != *"WindowsApps"* ]]; then
    echo "python3"
    return
  fi
  local py_path
  py_path="$(command -v python 2>/dev/null || true)"
  if [[ -n "$py_path" ]] && [[ "$py_path" != *"WindowsApps"* ]]; then
    echo "python"
    return
  fi
  echo ""
}

# ── run_backlog_manager: run backlog_manager.py ────────────────
run_backlog_manager() {
  local py_cmd
  py_cmd="$(get_python_cmd)"
  if [[ -z "$py_cmd" ]]; then
    err "python not found."
    return 1
  fi
  PYTHONUTF8=1 PYTHONIOENCODING=utf-8     $py_cmd "$SCRIPT_DIR/backlog_manager.py" "$@"
}

# ── setup_phase: generate backlog.md ──────────────────────────
setup_phase() {
  banner "Setup Phase  ·  generating backlog.md"
  echo -e "  Project: ${BOLD}$PROJECT_DIR${RESET}"
  echo ""

  local max_setup_attempts=3
  local attempt=0

  scan_project "$FILE_INDEX_BEFORE" "setup"

  while (( attempt < max_setup_attempts )); do
    attempt=$(( attempt + 1 ))
    phase "Setup Agent (attempt $attempt / $max_setup_attempts)"

    local setup_rendered="$STATE_DIR/setup_agent_rendered.md"
    local setup_critique="$STATE_DIR/setup_critique.md"
    local backlog_draft="$STATE_DIR/backlog_draft.md"

    render "$AGENTS_DIR/setup_agent.md" "$setup_rendered"

    if ! run_agent "Setup Agent" "$setup_rendered" "$backlog_draft" "high"; then
      if detect_rate_limit; then
        suspend_for_rate_limit "Setup Agent"
      fi
      err "Setup Agent failed. Log: $STATE_DIR/codex.log"
      exit 1
    fi

    phase "Setup Critic (attempt $attempt / $max_setup_attempts)"

    # Temporarily set BACKLOG to backlog_draft so Setup Critic can read it
    local orig_backlog="$BACKLOG"
    BACKLOG="$backlog_draft"
    export LOOP_BACKLOG="$BACKLOG"

    render "$AGENTS_DIR/setup_critic.md" "$STATE_DIR/setup_critic_rendered.md"
    BACKLOG="$orig_backlog"
    export LOOP_BACKLOG="$BACKLOG"

    if ! run_agent "Setup Critic" "$STATE_DIR/setup_critic_rendered.md" "$setup_critique" "high"; then
      if detect_rate_limit; then
        suspend_for_rate_limit "Setup Critic"
      fi
      err "Setup Critic failed. Log: $STATE_DIR/codex.log"
      exit 1
    fi

    local verdict
    verdict="$(check_verdict "$setup_critique")"
    info "Setup Critic verdict: $verdict"

    if [[ "$verdict" == "PASS" ]]; then
      cp "$backlog_draft" "$BACKLOG"
      ok "backlog.md generated"
      break
    else
      echo -e "${YELLOW}  Setup Critic FAIL → retrying Setup Agent${RESET}"
      if (( attempt >= max_setup_attempts )); then
        err "Setup Agent did not receive PASS after ${max_setup_attempts} attempts."
        echo "  Review backlog_draft.md, edit it manually, then save as backlog.md:"
        echo "    cat $STATE_DIR/backlog_draft.md"
        exit 1
      fi
    fi
  done

  # Human approval
  echo ""
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}  Please review and approve backlog.md${RESET}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  echo "  File location: $BACKLOG"
  echo ""
  echo "  After reviewing, enter one of the following:"
  echo -e "  ${GREEN}y${RESET} = approve and start loop"
  echo -e "  ${YELLOW}e${RESET} = edit then re-check"
  echo -e "  ${RED}n${RESET} = cancel"
  echo ""

  while true; do
    printf "Approve (y/e/n): "
    read -r approval
    case "$approval" in
      y|Y)
        ok "backlog.md approved. Starting loop."
        echo ""
        break
        ;;
      e|E)
        echo "  Edit backlog.md then enter y again."
        echo "  Location: $BACKLOG"
        ;;
      n|N)
        echo "Cancelled."
        exit 0
        ;;
      *)
        echo "  Please enter y, e, or n."
        ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════
#  Main loop
# ═══════════════════════════════════════════════════════════════
git_ensure_init

# Clean up .protected files left by a prior abnormal exit (SIGKILL, system crash, etc.).
# Called before entering Setup Phase so backlog.md baseline is also protected.
cleanup_orphaned_backups

# ── Setup Phase: auto-run if backlog.md is missing ────────────
if [[ ! -f "$BACKLOG" ]]; then
  setup_phase
fi

banner "Loop Agent  ·  ${MAX_LOOPS} loops  ·  $(basename "$PROJECT_DIR")"
echo -e "  Project: ${BOLD}$PROJECT_DIR${RESET}"
echo -e "  Log:     ${GRAY}$STATE_DIR/codex.log${RESET}"
case "$LOOP_CLI" in
  codex)  echo -e "  CLI:      ${CYAN}codex${RESET} (model: $CODEX_MODEL)" ;;
  gemini) echo -e "  CLI:      ${CYAN}gemini${RESET} (model: $GEMINI_MODEL)" ;;
esac

# COMMIT_ON_PASS=0 accumulates PASS results in the working tree.
# The next loop's git_snapshot absorbs them into the baseline, which may
# bundle changes at an unintended point.
if [[ "$COMMIT_ON_PASS" != "1" ]]; then
  echo ""
  warn "COMMIT_ON_PASS=$COMMIT_ON_PASS — automatic PASS commit disabled"
  echo -e "  ${GRAY}• PASS results accumulate in the working tree without being committed${RESET}"
  echo -e "  ${GRAY}• The next loop's git_snapshot will include prior PASSes in the baseline${RESET}"
  echo -e "  ${GRAY}• Set COMMIT_ON_PASS=1 to isolate commits per task${RESET}"
fi
echo ""

# Print initial backlog progress
run_backlog_manager progress "$BACKLOG" 2>/dev/null || true
echo ""

for (( LOOP=1; LOOP<=MAX_LOOPS; LOOP++ )); do

  # ── Check backlog completion/blocked state ───────────────────
  BL_STATUS="$(run_backlog_manager status "$BACKLOG" 2>/dev/null || echo '{}')"
  BL_COMPLETE="$(echo "$BL_STATUS" | grep -o '"complete":[^,}]*' | cut -d: -f2 | tr -d ' "' || echo false)"
  BL_PENDING="$(echo "$BL_STATUS" | grep -o '"pending":[^,}]*' | cut -d: -f2 | tr -d ' "' || echo 1)"
  BL_BLOCKED="$(echo "$BL_STATUS" | grep -o '"blocked":[^,}]*' | cut -d: -f2 | tr -d ' "' || echo 0)"

  if [[ "$BL_COMPLETE" == "true" ]]; then
    ok "All tasks complete! Backlog exhausted."
    run_backlog_manager progress "$BACKLOG" 2>/dev/null || true
    break
  fi

  if [[ "$BL_PENDING" == "0" ]] && [[ "$BL_BLOCKED" != "0" ]]; then
    echo -e "${YELLOW}⚠ Cannot continue: all remaining tasks are BLOCKED.${RESET}"
    run_backlog_manager progress "$BACKLOG" 2>/dev/null || true
    echo ""
    echo "Review backlog.md, resolve the BLOCKED cause, then retry."
    echo "  cat $BACKLOG"
    print_results
    exit 1
  fi

  # ── Select next task ─────────────────────────────────────────
  NEXT_TASK_JSON="$(run_backlog_manager next "$BACKLOG" 2>/dev/null || echo '{}')"
  # JSON parsing: "id": "value" format (space after colon may vary)
  NEXT_TASK_ID="$(echo "$NEXT_TASK_JSON" | grep -oE '"id": ?"[^"]+"' | grep -oE '"[^"]+"$' | tr -d '"' || echo "")"
  NEXT_TASK_NAME="$(echo "$NEXT_TASK_JSON" | grep -oE '"name": ?"[^"]+"' | grep -oE '"[^"]+"$' | tr -d '"' || echo "")"

  if [[ -z "$NEXT_TASK_ID" ]]; then
    info "No next task found. Check dependencies."
    break
  fi

  # Write current task info to current_task.md
  {
    printf '# Current Task

'
    printf 'Task ID: %s
' "$NEXT_TASK_ID"
    printf 'Task Name: %s

' "$NEXT_TASK_NAME"
    printf '## Details (from backlog.md)

'
    printf 'Read the %s section in backlog.md.
' "$NEXT_TASK_ID"
  } > "$CURRENT_TASK"

  info "Current task: $NEXT_TASK_ID — $NEXT_TASK_NAME"

  TASK_FAIL_COUNT="$(get_task_fail_count "$BACKLOG" "$NEXT_TASK_ID")"
  TASK_FAIL_COUNT="${TASK_FAIL_COUNT:-0}"
  info "Current task fail count: $TASK_FAIL_COUNT"

  PLANNER_EFFORT="$(get_effort_for_task planner "$TASK_FAIL_COUNT")"
  PLAN_CRITIC_EFFORT="$(get_effort_for_task plan_critic "$TASK_FAIL_COUNT")"
  IMPLEMENTER_EFFORT="$(get_effort_for_task implementer "$TASK_FAIL_COUNT")"
  IMPL_CRITIC_EFFORT="$(get_effort_for_task impl_critic "$TASK_FAIL_COUNT")"
  REPORTER_EFFORT="$(get_effort_for_task reporter "$TASK_FAIL_COUNT")"
  info "effort: planner=$PLANNER_EFFORT, plan_critic=$PLAN_CRITIC_EFFORT, implementer=$IMPLEMENTER_EFFORT, impl_critic=$IMPL_CRITIC_EFFORT, reporter=$REPORTER_EFFORT"

  banner "Loop $LOOP / $MAX_LOOPS"
  export_vars

  # ────────────────────────────────────────────────────────────
  # Phase 0: Scan (before)
  # ────────────────────────────────────────────────────────────
  phase "Phase 0 · Scan (before)"
  scan_project "$FILE_INDEX_BEFORE" "before"
  truncate_progress_if_large  # prevent unbounded growth (keep 50 most recent if over 512KB)
  build_progress_window  # progress.txt → extract most recent 3 sections
  # Reset temp files for current loop
  rm -f "$PLAN" "$PLAN_CRITIQUE" "$IMPL_SUMMARY" "$IMPL_CRITIQUE"

  # ────────────────────────────────────────────────────────────
  # Phase 1: Planner
  # ────────────────────────────────────────────────────────────
  phase "Phase 1 · Planner"
  snapshot_state_files  # protect .loop-agent/ state files (Planner is read-only)
  render "$AGENTS_DIR/planner.md" "$STATE_DIR/planner_rendered.md"

  if ! run_agent "Planner" "$STATE_DIR/planner_rendered.md" "$PLAN" "$PLANNER_EFFORT"; then
    restore_state_files_if_modified "Planner"
    if detect_rate_limit; then
      suspend_for_rate_limit "Planner"
    fi
    add_result "Loop ${LOOP}: ERROR (codex error - Planner)"
    print_results
    err "Planner codex process failed. Log: $STATE_DIR/codex.log"
    exit 1
  fi
  restore_state_files_if_modified "Planner"

  # Print Planner summary (Goal line)
  PLAN_GOAL=$(grep "^## Goal" -A1 "$PLAN" 2>/dev/null | tail -1 || echo "(no goal)")
  info "Plan goal: $PLAN_GOAL"

  # Check for codex errors first, then detect ERROR: in plan.md
  if grep -q "^ERROR:" "$PLAN" 2>/dev/null; then
    add_result "Loop ${LOOP}: ERROR (no dev document)"
    print_results
    err "Dev document not found. Check plan.md:"
    err "  cat $PLAN"
    exit 1
  fi

  # ────────────────────────────────────────────────────────────
  # Phase 2: Plan Critic
  # ────────────────────────────────────────────────────────────
  phase "Phase 2 · Plan Critic"
  snapshot_state_files  # protect .loop-agent/ state files (Plan Critic is also read-only)
  render "$AGENTS_DIR/plan_critic.md" "$STATE_DIR/plan_critic_rendered.md"

  if ! run_agent "Plan Critic" "$STATE_DIR/plan_critic_rendered.md" "$PLAN_CRITIQUE" "$PLAN_CRITIC_EFFORT"; then
    restore_state_files_if_modified "Plan Critic"
    if detect_rate_limit; then
      suspend_for_rate_limit "Plan Critic"
    fi
    add_result "Loop ${LOOP}: ERROR (codex error - Plan Critic)"
    print_results
    err "Plan Critic codex process failed. Log: $STATE_DIR/codex.log"
    exit 1
  fi
  restore_state_files_if_modified "Plan Critic"

  PLAN_VERDICT="$(check_verdict "$PLAN_CRITIQUE")"
  info "Plan verdict: $PLAN_VERDICT"

  if [[ "$PLAN_VERDICT" == "UNKNOWN" ]]; then
    add_result "Loop ${LOOP}: ERROR (no VERDICT - Plan Critic)"
    print_results
    err "Plan Critic did not output a VERDICT."
    exit 1
  fi

  if [[ "$PLAN_VERDICT" == "FAIL" ]]; then
    echo -e "${YELLOW}  Plan FAIL → increment fail count + record in progress.txt → next loop${RESET}"

    FAIL_RESULT="$(run_backlog_manager fail "$BACKLOG" "$NEXT_TASK_ID" 2>/dev/null || echo "ERROR")"
    if [[ "$FAIL_RESULT" == "BLOCKED" ]]; then
      echo -e "${RED}  Task $NEXT_TASK_ID BLOCKED (5 consecutive failures)${RESET}"
    fi

    {
      echo ""
      echo "=== Loop ${LOOP}: Plan FAIL ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID — $NEXT_TASK_NAME"
      cat "$PLAN_CRITIQUE"
      echo ""
    } >> "$PROGRESS"

    add_result "Loop ${LOOP}: FAIL (Plan Critic) — $NEXT_TASK_ID"
    continue
  fi
  

  # Print Plan Critic Notes
  PLAN_NOTES=$(grep "^## Notes" -A2 "$PLAN_CRITIQUE" 2>/dev/null | grep -v "^## Notes" | head -1 || echo "none")
  ok "Plan PASS (Notes: $PLAN_NOTES)"

  # ────────────────────────────────────────────────────────────
  # Phase 3: Implementer
  # ────────────────────────────────────────────────────────────
  phase "Phase 3 · Implementer"
  git_snapshot  # git snapshot before running Implementer
  snapshot_state_files  # protect .loop-agent/ state files (prevent rollback bypass)
  render "$AGENTS_DIR/implementer.md" "$STATE_DIR/implementer_rendered.md"

  if ! run_agent "Implementer" "$STATE_DIR/implementer_rendered.md" "$IMPL_SUMMARY" "$IMPLEMENTER_EFFORT"; then
    restore_state_files_if_modified "Implementer"  # restore even on failure
    if detect_rate_limit; then
      suspend_for_rate_limit "Implementer"
    fi
    add_result "Loop ${LOOP}: ERROR (codex error - Implementer)"
    print_results
    err "Implementer codex process failed. Log: $STATE_DIR/codex.log"
    exit 1
  fi
  restore_state_files_if_modified "Implementer"  # restore on normal exit too

  # Print Implementer completed tasks
  DONE_TASKS=$(grep "^\- \[x\]" "$IMPL_SUMMARY" 2>/dev/null | sed 's/- \[x\] /  ✓ /' || echo "  (none)")
  info "Completed tasks:"
  echo "$DONE_TASKS"
  FAILED_TASKS=$(grep "^\- \[ \]" "$IMPL_SUMMARY" 2>/dev/null | sed 's/- \[ \] /  ✗ /' || true)
  if [[ -n "$FAILED_TASKS" ]]; then
    echo -e "${YELLOW}Incomplete tasks:${RESET}"
    echo "$FAILED_TASKS"
  fi

  # ────────────────────────────────────────────────────────────
  # Phase 4: Impl Critic
  # ────────────────────────────────────────────────────────────
  phase "Phase 4 · Impl Critic"
  snapshot_state_files  # protect .loop-agent/ state files (Critic is also read-only)
  render "$AGENTS_DIR/impl_critic.md" "$STATE_DIR/impl_critic_rendered.md"

  if ! run_agent "Impl Critic" "$STATE_DIR/impl_critic_rendered.md" "$IMPL_CRITIQUE" "$IMPL_CRITIC_EFFORT"; then
    restore_state_files_if_modified "Impl Critic"
    if detect_rate_limit; then
      suspend_for_rate_limit "Impl Critic"
    fi
    add_result "Loop ${LOOP}: ERROR (codex error - Impl Critic)"
    print_results
    err "Impl Critic codex process failed. Log: $STATE_DIR/codex.log"
    exit 1
  fi
  restore_state_files_if_modified "Impl Critic"

  IMPL_VERDICT="$(check_verdict "$IMPL_CRITIQUE")"
  info "Implementation verdict: $IMPL_VERDICT"

  if [[ "$IMPL_VERDICT" == "UNKNOWN" ]]; then
    add_result "Loop ${LOOP}: ERROR (no VERDICT - Impl Critic)"
    print_results
    err "Impl Critic did not output a VERDICT."
    exit 1
  fi

  if [[ "$IMPL_VERDICT" == "SPLIT_TASK" ]]; then
    echo -e "${YELLOW}  Task too large → splitting required → record in progress.txt and require human review${RESET}"
    # Record Impl Critic's split guide in progress.txt
    SPLIT_GUIDE="$(awk 'BEGIN{f=0} /^## Scope expansion needed/{f=1;next} f && /^## /{exit} f{print}' "$IMPL_CRITIQUE" | tr -d '\r')"
    git_rollback "SPLIT_TASK → discard partial implementation"
    {
      echo ""
      echo "=== Loop ${LOOP}: Split Task Required ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID — $NEXT_TASK_NAME"
      echo ""
      echo "Split guide:"
      echo "$SPLIT_GUIDE"
      echo ""
      echo "⚠ Manually split this task in backlog.md."
      echo ""
    } >> "$PROGRESS"
    add_result "Loop ${LOOP}: SPLIT_TASK — $NEXT_TASK_ID"
    # Also increment fail count (will keep failing without splitting)
    run_backlog_manager fail "$BACKLOG" "$NEXT_TASK_ID" 2>/dev/null || true
    continue
  fi

  if [[ "$IMPL_VERDICT" == "SCOPE_EXPAND" ]]; then
    echo -e "${YELLOW}  Scope expansion needed → increment fail count + rollback + update task file scope in backlog → retry next loop${RESET}"

    # SCOPE_EXPAND also means this loop did not complete, so increment fail count.
    # Repeated scope issues on the same task will cause planner effort to increase.
    FAIL_RESULT="$(run_backlog_manager fail "$BACKLOG" "$NEXT_TASK_ID" 2>/dev/null || echo "ERROR")"
    if [[ "$FAIL_RESULT" == "BLOCKED" ]]; then
      echo -e "${RED}  Task $NEXT_TASK_ID BLOCKED (5 consecutive failures)${RESET}"
    fi

    # SCOPE_EXPAND is not PASS, so discard partial Implementer changes.
    git_rollback "SCOPE_EXPAND → discard partial implementation and retry with expanded scope"

    # Extract file paths from impl_critique.md "## Scope expansion needed" section.
    # Only strict format allowed: line must exactly match "- `<path>` — <reason>" pattern.
    # Not extracted from free-form text, so false positives are blocked.
    # Additional validation:
    #   - Reject absolute paths (/, ~)
    #   - Reject parent directory traversal (..)
    #   - Require file or at least an ancestor directory to exist inside PROJECT_DIR
    EXPAND_RAW="$(awk '
      BEGIN{f=0}
      /^## Scope expansion needed/ {f=1; next}
      f && /^## / {exit}
      f && /^- `[^`]+`[[:space:]]*[—–-]/ {
        # Extract only the path inside the first backtick pair
        match($0, /`[^`]+`/)
        if (RSTART > 0) {
          path = substr($0, RSTART+1, RLENGTH-2)
          print path
        }
      }
    ' "$IMPL_CRITIQUE" | tr -d '\r' | sort -u)"

    EXPAND_VALID=()
    EXPAND_REJECTED=()
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      # Reject absolute paths / home directory / path traversal
      if [[ "$path" == /* ]] || [[ "$path" == ~* ]] || [[ "$path" == *..* ]]; then
        EXPAND_REJECTED+=("$path (unsafe path)")
        continue
      fi
      # Must contain a slash or dot to be considered a file path
      if [[ "$path" != *.* ]] && [[ "$path" != */* ]]; then
        EXPAND_REJECTED+=("$path (no extension or directory)")
        continue
      fi
      # Pass if the file itself or at least one ancestor directory exists
      # (Allow new directory + new file case. E.g. for src/new-feature/api.ts,
      #  src/new-feature/ may not exist but src/ does → pass)
      if [[ -e "$PROJECT_DIR/$path" ]]; then
        EXPAND_VALID+=("$path")
      else
        ancestor_found=0
        check_dir="$(dirname "$path")"
        while [[ "$check_dir" != "." ]] && [[ "$check_dir" != "/" ]] && [[ -n "$check_dir" ]]; do
          if [[ -d "$PROJECT_DIR/$check_dir" ]]; then
            ancestor_found=1
            break
          fi
          check_dir="$(dirname "$check_dir")"
        done
        # Pass if path is a simple filename (e.g. README.md) or an ancestor was found
        if [[ $ancestor_found -eq 1 ]] || [[ "$(dirname "$path")" == "." ]]; then
          EXPAND_VALID+=("$path")
        else
          EXPAND_REJECTED+=("$path (no existing ancestor in project)")
        fi
      fi
    done <<< "$EXPAND_RAW"

    if [[ ${#EXPAND_REJECTED[@]} -gt 0 ]]; then
      warn "SCOPE_EXPAND rejected ${#EXPAND_REJECTED[@]} item(s):"
      for r in "${EXPAND_REJECTED[@]}"; do
        echo "    - $r"
      done
    fi

    if [[ ${#EXPAND_VALID[@]} -gt 0 ]]; then
      EXPAND_FILES="$(IFS=,; echo "${EXPAND_VALID[*]}")"
      EXPAND_RESULT="$(run_backlog_manager expand "$BACKLOG" "$NEXT_TASK_ID" "$EXPAND_FILES" 2>/dev/null || echo "ERROR")"
      ok "backlog scope expanded: ${#EXPAND_VALID[@]} file(s) — $EXPAND_RESULT"
    else
      info "No valid files for scope expansion (Impl Critic may not have followed the format)"
      EXPAND_FILES=""
    fi
    {
      echo ""
      echo "=== Loop ${LOOP}: Scope Expand ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID — $NEXT_TASK_NAME"
      echo "Added files: $EXPAND_FILES"
      echo ""
    } >> "$PROGRESS"
    add_result "Loop ${LOOP}: SCOPE_EXPAND — $NEXT_TASK_ID"
    continue
  fi

  if [[ "$IMPL_VERDICT" == "FAIL" ]]; then
    echo -e "${YELLOW}  Implementation FAIL → rollback + record in progress.txt → next loop${RESET}"
    # Increment backlog fail count first.
    # Note: git_rollback preserves .loop-agent/, so call order does not strictly matter,
    # but incrementing state metadata (fail_count) before git ops is done for consistency.
    FAIL_RESULT="$(run_backlog_manager fail "$BACKLOG" "$NEXT_TASK_ID" 2>/dev/null || echo "ERROR")"
    git_rollback "Impl Critic FAIL → discard partial implementation"  # restore to pre-Implementer state
    if [[ "$FAIL_RESULT" == "BLOCKED" ]]; then
      echo -e "${RED}  Task $NEXT_TASK_ID BLOCKED (5 consecutive failures)${RESET}"
    fi
    {
      echo ""
      echo "=== Loop ${LOOP}: Impl FAIL ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID — $NEXT_TASK_NAME"
      cat "$IMPL_CRITIQUE"
      echo ""
    } >> "$PROGRESS"
    add_result "Loop ${LOOP}: FAIL (Impl Critic) — $NEXT_TASK_ID"
    continue
  fi

  # Print Impl Critic Notes
  IMPL_NOTES=$(grep "^## Notes" -A2 "$IMPL_CRITIQUE" 2>/dev/null | grep -v "^## Notes" | head -1 || echo "none")
  ok "Implementation PASS (Notes: $IMPL_NOTES)"

  # ────────────────────────────────────────────────────────────
  # Phase 4.5: Scan (after)
  # ────────────────────────────────────────────────────────────
  phase "Phase 4.5 · Scan (after)"
  # Always run even with no changes — for consistent shell report and final state check
  scan_project "$FILE_INDEX_AFTER" "after"

  # ────────────────────────────────────────────────────────────
  # Phase 4.6: PASS commit
  # ────────────────────────────────────────────────────────────
  if [[ "$COMMIT_ON_PASS" == "1" ]]; then
    phase "Phase 4.6 · PASS commit"
    git_commit_pass
  else
    info "Automatic PASS commit disabled (COMMIT_ON_PASS=$COMMIT_ON_PASS)"
  fi

  # ────────────────────────────────────────────────────────────
  # Phase 5: Shell Report
  # ────────────────────────────────────────────────────────────
  phase "Phase 5 · Shell Report"
  append_shell_report "PASS"
  ok "Report appended: $REPORT"

  # ────────────────────────────────────────────────────────────
  # Phase 5.5: loop.sh post-processing
  # ────────────────────────────────────────────────────────────
  # Extract [x] items from impl_summary.md (names only, no file paths)
  COMPLETED_TASKS=""
  if grep -q "^\- \[x\]" "$IMPL_SUMMARY" 2>/dev/null; then
    COMPLETED_TASKS=$(grep "^\- \[x\]" "$IMPL_SUMMARY" \
      | sed 's/^- \[x\] /- /' \
      | sed 's/ — .*//')
  fi

  {
    echo ""
    echo "=== Loop ${LOOP}: PASS ==="
    echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Task: $NEXT_TASK_ID — $NEXT_TASK_NAME"
    if [[ -z "$COMPLETED_TASKS" ]]; then
      echo "Completed steps: none"
    else
      echo "Completed steps:"
      echo "$COMPLETED_TASKS"
    fi
    echo "Report: .loop-agent/report.md"
    echo ""
  } >> "$PROGRESS"

  # Mark backlog task complete
  COMPLETE_RESULT="$(run_backlog_manager complete "$BACKLOG" "$NEXT_TASK_ID" 2>/dev/null || echo "ERROR")"
  if [[ "$COMPLETE_RESULT" == "OK" ]]; then
    ok "backlog updated: $NEXT_TASK_ID complete"
  fi

  COMPACT_RESULT="$(run_backlog_manager compact "$BACKLOG" "$BACKLOG_ARCHIVE" 2>/dev/null || echo "ERROR")"
  case "$COMPACT_RESULT" in
    COMPACTED:*)
      ok "backlog compacted: ${COMPACT_RESULT#COMPACTED: } → $BACKLOG_ARCHIVE"
      ;;
    NO_CHANGE:*)
      info "backlog compact: ${COMPACT_RESULT#NO_CHANGE: }"
      ;;
    *)
      warn "backlog compact failed: $COMPACT_RESULT"
      ;;
  esac

  # Print progress
  run_backlog_manager progress "$BACKLOG" 2>/dev/null || true

  add_result "Loop ${LOOP}: PASS — $NEXT_TASK_ID"
  info "progress.txt updated"

  sleep 2  # prevent rate limiting

done

# ═══════════════════════════════════════════════════════════════
#  Exit after N loops
# ═══════════════════════════════════════════════════════════════
print_results

# Final backlog progress
echo -e "${BOLD}=== Backlog progress ===${RESET}"
run_backlog_manager progress "$BACKLOG" 2>/dev/null || true
echo ""

# Remaining task guidance
BL_STATUS="$(run_backlog_manager status "$BACKLOG" 2>/dev/null || echo '{}')"
BL_PENDING="$(echo "$BL_STATUS" | grep -o '"pending":[^,}]*' | cut -d: -f2 | tr -d ' "' || echo 0)"
BL_COMPLETE="$(echo "$BL_STATUS" | grep -o '"complete":[^,}]*' | cut -d: -f2 | tr -d ' "' || echo false)"

if [[ "$BL_COMPLETE" == "true" ]]; then
  echo -e "${GREEN}${BOLD}🎉 All tasks complete! Project implementation finished.${RESET}"
  echo ""
elif [[ "$BL_PENDING" != "0" ]]; then
  echo -e "${YELLOW}${MAX_LOOPS} loops exhausted but tasks remain.${RESET}"
  echo "To continue, run again:"
  echo "  ./loop.sh $MAX_LOOPS ."
  echo ""
fi

PASS_COUNT=0
for r in "${RESULTS[@]}"; do
  [[ "$r" == *": PASS"* ]] && (( PASS_COUNT++ )) || true
done

if [[ "$PASS_COUNT" -eq 0 ]]; then
  echo -e "${YELLOW}All ${MAX_LOOPS} loops exhausted with no PASS.${RESET}"
  echo "Review progress.txt and backlog.md."
  echo "  cat $PROGRESS"
  echo "  cat $BACKLOG"
  echo ""
  exit 1
fi

exit 0
