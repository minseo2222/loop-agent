#!/usr/bin/env bash
# LoopDex · loop.sh
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
ORIGINAL_COMMAND="$0"
for arg in "$@"; do
  printf -v quoted_arg '%q' "$arg"
  ORIGINAL_COMMAND+=" $quoted_arg"
done

# ── User-env snapshots ────────────────────────────────────────
# Capture user-exported env BEFORE any defaults or config loading so that
# precedence (user env > config.env > built-in default) is preserved.
LOOP_USER_CLI_ENV="${LOOP_CLI:-}"
LOOP_USER_CODEX_MODEL="${CODEX_MODEL:-}"
LOOP_USER_GEMINI_MODEL="${LOOP_GEMINI_MODEL:-}"
LOOP_USER_BRANCH_PREFIX="${LOOP_REQUIRE_BRANCH_PREFIX:-}"

# Defaults for config-managed keys are applied AFTER load_or_init_config
# (search for "apply_config_managed_defaults"). Don't set CODEX_MODEL here.

# After Impl Critic PASS, pins the implementation result as a git commit.
# Can be disabled at runtime:
#   COMMIT_ON_PASS=0 ./loop.sh 3 /path/to/project
COMMIT_ON_PASS="${COMMIT_ON_PASS:-1}"

# Verify commands run with a 300 second timeout by default; override with LOOP_VERIFY_TIMEOUT.
LOOP_VERIFY_TIMEOUT="${LOOP_VERIFY_TIMEOUT:-300}"

# A task is blocked after 5 consecutive failures by default; override with LOOP_MAX_ATTEMPTS.
LOOP_MAX_ATTEMPTS="${LOOP_MAX_ATTEMPTS:-5}"

# Keep the newest N loop evidence directories; 0 disables evidence retention.
LOOP_EVIDENCE_KEEP_RUNS="${LOOP_EVIDENCE_KEEP_RUNS:-10}"

# Prune the current loop's evidence directory immediately after a PASS commit.
# Defaults to 1: PASS-loop diffs/verify outputs are redundant with git history,
# so removing them keeps .loop-agent/evidence/ small. Set to 0 to retain
# PASS evidence (e.g. for forensic auditing). FAIL/BLOCKED/proposal evidence
# is never affected by this flag.
LOOP_EVIDENCE_PRUNE_PASS="${LOOP_EVIDENCE_PRUNE_PASS:-1}"

# Risk mode controls built-in CLI bypass flags for unattended execution.
LOOP_RISK_MODE="${LOOP_RISK_MODE:-unattended}"

. "$SCRIPT_DIR/lib/cli_adapters.sh"
. "$SCRIPT_DIR/lib/decision.sh"
. "$SCRIPT_DIR/lib/evidence.sh"

# ── Colors ────────────────────────────────────────────────────
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
CYAN="\033[36m"; GRAY="\033[90m"; BOLD="\033[1m"; RESET="\033[0m"

err()    { echo -e "${RED}Error: $*${RESET}" >&2; }
ok()     { echo -e "${GREEN}✓ $*${RESET}"; }
info()   { echo -e "${GRAY}  $*${RESET}"; }
warn()   { echo -e "${YELLOW}⚠ $*${RESET}"; }

# README defaults (gpt-5.5, gemini-3.1-pro-preview) are placeholders, not real
# model IDs. Detect at startup and in doctor so the user can override before
# any agent call fails and consumes fail_count.
LOOP_PLACEHOLDER_CODEX_MODELS=("gpt-5.5" "gpt-5.4")
LOOP_PLACEHOLDER_GEMINI_MODELS=("gemini-3.1-pro-preview")

is_placeholder_model() {
  local val="$1"; shift
  local m
  for m in "$@"; do
    [[ "$val" == "$m" ]] && return 0
  done
  return 1
}

# ── pick_one: numbered multiple-choice prompt ────────────────
# Usage: pick_one "Prompt text" "choice 1" "choice 2" ...
# Echoes the chosen value to stdout. Exits 1 on EOF.
pick_one() {
  local prompt="$1"; shift
  local -a choices=("$@")
  local i n
  echo "" >&2
  echo "$prompt" >&2
  for ((i=0; i<${#choices[@]}; i++)); do
    printf "  %d) %s\n" "$((i+1))" "${choices[$i]}" >&2
  done
  while true; do
    printf "Choice [1-%d]: " "${#choices[@]}" >&2
    if ! read -r n; then
      echo "" >&2
      return 1
    fi
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#choices[@]} )); then
      printf '%s\n' "${choices[$((n-1))]}"
      return 0
    fi
    echo "  Invalid. Enter a number from 1 to ${#choices[@]}." >&2
  done
}

# ── parse_config_file: source whitelisted KEY=VALUE config ───
# Lines starting with # are comments. Only known keys are exported.
parse_config_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    val="${val#\"}"; val="${val%\"}"
    val="${val#\'}"; val="${val%\'}"
    case "$key" in
      LOOP_CLI|CODEX_MODEL|LOOP_GEMINI_MODEL|LOOP_REQUIRE_BRANCH_PREFIX|LOOP_RISK_MODE|LOOP_BACKLOG_SOURCE)
        export "$key=$val"
        ;;
    esac
  done < "$f"
}

# ── run_config_wizard: interactive multiple-choice setup ─────
# Writes .loop-agent/config.env. Skipped on non-TTY (CI).
run_config_wizard() {
  local cfg="$1"
  local cfg_dir
  cfg_dir="$(dirname "$cfg")"
  mkdir -p "$cfg_dir"

  echo "" >&2
  echo -e "${BOLD}${CYAN}First-time setup for $(basename "$PROJECT_DIR")${RESET}" >&2
  echo -e "${GRAY}Saved to .loop-agent/config.env — edit anytime to change.${RESET}" >&2

  # 1) CLI — auto-pick if only one installed
  local cli=""
  local has_codex=0 has_gemini=0
  command -v codex  >/dev/null 2>&1 && has_codex=1
  command -v gemini >/dev/null 2>&1 && has_gemini=1
  if (( has_codex == 1 && has_gemini == 1 )); then
    cli="$(pick_one "AI CLI to use:" "codex" "gemini")" || return 1
  elif (( has_codex == 1 )); then
    cli="codex"
    info "AI CLI: codex (auto-detected, only one installed)" >&2
  elif (( has_gemini == 1 )); then
    cli="gemini"
    info "AI CLI: gemini (auto-detected, only one installed)" >&2
  else
    cli="$(pick_one "AI CLI to use (neither detected on PATH — install before running):" "codex" "gemini")" || return 1
  fi

  # 2) Model — fixed list + Other escape
  local model=""
  local -a model_options
  case "$cli" in
    codex)
      model_options=("gpt-5" "gpt-5-codex" "gpt-4.1" "gpt-4o" "Other (type manually)")
      ;;
    gemini)
      model_options=("gemini-2.5-pro" "gemini-2.5-flash" "gemini-1.5-pro" "Other (type manually)")
      ;;
  esac
  model="$(pick_one "Model ID for ${cli}:" "${model_options[@]}")" || return 1
  if [[ "$model" == "Other (type manually)" ]]; then
    while [[ -z "$model" || "$model" == "Other (type manually)" ]]; do
      printf "Model ID: " >&2
      read -r model || return 1
    done
  fi

  # 3) Branch prefix
  local prefix_choice
  prefix_choice="$(pick_one "Required git branch prefix (refuse to run on other branches):" \
    "loop/  (recommended)" \
    "(none — allow any branch)" \
    "Other (type manually)")" || return 1
  local prefix=""
  case "$prefix_choice" in
    "loop/  (recommended)") prefix="loop/" ;;
    "(none — allow any branch)") prefix="" ;;
    "Other (type manually)")
      printf "Branch prefix (e.g. work/, feat/, leave empty to skip): " >&2
      read -r prefix || return 1
      ;;
  esac

  # 4) Backlog source — let users skip Setup Agent if they bring their own
  local backlog_choice backlog_source
  backlog_choice="$(pick_one "Backlog source:" \
    "Generate from planning docs (default — Setup Agent reads SPEC.md etc.)" \
    "I'll provide .loop-agent/backlog.md myself (skip Setup Agent)")" || return 1
  case "$backlog_choice" in
    "Generate"*) backlog_source="generated" ;;
    "I'll provide"*) backlog_source="user" ;;
    *) backlog_source="generated" ;;
  esac

  # Write config.env
  {
    echo "# LoopDex per-project config — generated by setup wizard"
    echo "# Edit values or delete this file to re-run the wizard."
    echo ""
    echo "LOOP_CLI=$cli"
    case "$cli" in
      codex)  echo "CODEX_MODEL=$model" ;;
      gemini) echo "LOOP_GEMINI_MODEL=$model" ;;
    esac
    [[ -n "$prefix" ]] && echo "LOOP_REQUIRE_BRANCH_PREFIX=$prefix"
    echo "LOOP_BACKLOG_SOURCE=$backlog_source"
  } > "$cfg"

  ok "Saved $cfg" >&2
  echo "" >&2
}

# ── load_or_init_config: load config.env, run wizard if missing ─
# Run mode + TTY + missing config → wizard.
# Init mode + TTY + missing config → wizard.
# Non-TTY or status/doctor → silently skip wizard, just load if file exists.
load_or_init_config() {
  local cfg="$STATE_DIR/config.env"
  if [[ -f "$cfg" ]]; then
    parse_config_file "$cfg"
    return 0
  fi
  case "$LOOP_MODE" in
    init|run)
      if [[ -t 0 ]] && [[ -t 1 ]]; then
        run_config_wizard "$cfg" || { warn "Setup cancelled."; return 0; }
        parse_config_file "$cfg"
      fi
      ;;
  esac
}

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
  if declare -f release_project_lock >/dev/null 2>&1; then
    release_project_lock 2>/dev/null || true
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
usage() {
  echo "Usage:"
  echo "  ./loop.sh <iterations> <project folder> [cli]"
  echo "  ./loop.sh run --iterations <n> --project <dir> [--cli codex|gemini]"
  echo "  ./loop.sh init --project <dir> [--cli codex|gemini]"
  echo "  ./loop.sh status --project <dir>"
  echo "  ./loop.sh doctor --project <dir>"
  echo "  cli: codex (default), gemini"
}

LOOP_MODE="run"
LOOP_EXPLICIT_SUBCOMMAND=0
MAX_LOOPS=""
MAX_LOOPS_FROM_FLAG=0
PROJECT_DIR=""
LOOP_CLI=""
LOOP_CLI_FROM_FLAG=0

if [[ $# -eq 0 ]]; then
  err "Invalid arguments."
  usage
  exit 1
fi

case "$1" in
  run)
    LOOP_MODE="run"
    LOOP_EXPLICIT_SUBCOMMAND=1
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --iterations|-i)
          if [[ $# -lt 2 ]]; then
            err "Missing value for --iterations."
            exit 1
          fi
          MAX_LOOPS="$2"
          MAX_LOOPS_FROM_FLAG=1
          shift 2
          ;;
        --project)
          if [[ $# -lt 2 ]]; then
            err "Missing value for --project."
            exit 1
          fi
          PROJECT_DIR="$2"
          shift 2
          ;;
        --cli)
          if [[ $# -lt 2 ]]; then
            err "Missing value for --cli."
            exit 1
          fi
          LOOP_CLI="$2"
          LOOP_CLI_FROM_FLAG=1
          shift 2
          ;;
        *)
          err "Unknown run option: $1"
          usage
          exit 1
          ;;
      esac
    done
    if [[ -z "$PROJECT_DIR" ]]; then
      err "Missing project."
      exit 1
    fi
    ;;
  init)
    LOOP_MODE="init"
    LOOP_EXPLICIT_SUBCOMMAND=1
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --project)
          if [[ $# -lt 2 ]]; then
            err "Missing value for --project."
            exit 1
          fi
          PROJECT_DIR="$2"
          shift 2
          ;;
        --cli)
          if [[ $# -lt 2 ]]; then
            err "Missing value for --cli."
            exit 1
          fi
          LOOP_CLI="$2"
          LOOP_CLI_FROM_FLAG=1
          shift 2
          ;;
        *)
          err "Unknown init option: $1"
          usage
          exit 1
          ;;
      esac
    done
    if [[ -z "$PROJECT_DIR" ]]; then
      err "Missing project."
      exit 1
    fi
    ;;
  status|doctor)
    LOOP_MODE="$1"
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --project)
          if [[ $# -lt 2 ]]; then
            err "Missing value for --project."
            exit 1
          fi
          PROJECT_DIR="$2"
          shift 2
          ;;
        --cli)
          if [[ $# -lt 2 ]]; then
            err "Missing value for --cli."
            exit 1
          fi
          LOOP_CLI="$2"
          LOOP_CLI_FROM_FLAG=1
          shift 2
          ;;
        *)
          err "Unknown ${LOOP_MODE} option: $1"
          usage
          exit 1
          ;;
      esac
    done
    if [[ -z "$PROJECT_DIR" ]]; then
      err "Missing project."
      exit 1
    fi
    if [[ ! -d "$PROJECT_DIR" ]]; then
      err "Project folder not found: $PROJECT_DIR"
      exit 1
    fi
    PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
    STATE_DIR_STATUS="$PROJECT_DIR/.loop-agent"

    # Load config so doctor/status can report stored values.
    # Wizard does NOT run for status/doctor — only init/run trigger it.
    DOCTOR_FLAG_CLI=""
    [[ "$LOOP_CLI_FROM_FLAG" == "1" ]] && DOCTOR_FLAG_CLI="$LOOP_CLI"
    if [[ -f "$STATE_DIR_STATUS/config.env" ]]; then
      parse_config_file "$STATE_DIR_STATUS/config.env"
    fi
    # Precedence: CLI flag > user env > config > default
    if [[ -n "$DOCTOR_FLAG_CLI" ]]; then
      LOOP_CLI="$DOCTOR_FLAG_CLI"
    elif [[ -n "$LOOP_USER_CLI_ENV" ]]; then
      LOOP_CLI="$LOOP_USER_CLI_ENV"
    fi
    [[ -n "$LOOP_USER_CODEX_MODEL" ]]   && CODEX_MODEL="$LOOP_USER_CODEX_MODEL"
    [[ -n "$LOOP_USER_GEMINI_MODEL" ]]  && LOOP_GEMINI_MODEL="$LOOP_USER_GEMINI_MODEL"
    [[ -n "$LOOP_USER_BRANCH_PREFIX" ]] && LOOP_REQUIRE_BRANCH_PREFIX="$LOOP_USER_BRANCH_PREFIX"
    LOOP_CLI="${LOOP_CLI:-codex}"
    CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
    LOOP_GEMINI_MODEL="${LOOP_GEMINI_MODEL:-gemini-3.1-pro-preview}"
# Re-sync the cli_adapters cache (GEMINI_MODEL was set at sourcing time before config load).
GEMINI_MODEL="$LOOP_GEMINI_MODEL"

    if [[ "$LOOP_MODE" == "status" ]]; then
      STATUS_BACKLOG="$STATE_DIR_STATUS/backlog.md"
      if [[ -n "${PYTHON:-}" ]]; then
        STATUS_PYTHON=("$PYTHON")
      elif STATUS_PYTHON_PATH="$(command -v python3 2>/dev/null)" && [[ "$STATUS_PYTHON_PATH" != *"WindowsApps"* ]]; then
        STATUS_PYTHON=("python3")
      elif STATUS_PYTHON_PATH="$(command -v python 2>/dev/null)" && [[ "$STATUS_PYTHON_PATH" != *"WindowsApps"* ]]; then
        STATUS_PYTHON=("python")
      else
        err "python not found."
        exit 1
      fi

      echo "loop-agent status"
      echo "Project: $PROJECT_DIR"
      if [[ ! -f "$STATUS_BACKLOG" ]]; then
        err "backlog.md not found: $STATUS_BACKLOG"
        exit 1
      fi
      if ! STATUS_JSON="$(PYTHONUTF8=1 PYTHONIOENCODING=utf-8 "${STATUS_PYTHON[@]}" "$SCRIPT_DIR/backlog_manager.py" status "$STATUS_BACKLOG")"; then
        err "Could not read backlog status."
        exit 1
      fi
      STATUS_JSON="$STATUS_JSON" STATUS_EVENTS="$STATE_DIR_STATUS/events.jsonl" \
      PYTHONUTF8=1 PYTHONIOENCODING=utf-8 "${STATUS_PYTHON[@]}" - <<'PY'
import json
import os

status = json.loads(os.environ["STATUS_JSON"])
print(f"Total tasks: {status.get('total', 0)}")
print(f"Done: {status.get('done', 0)}")
print(f"Pending: {status.get('pending', 0)}")
print(f"Blocked: {status.get('blocked', 0)}")

next_task = status.get("next_task")
if next_task:
    print(f"Next task: {next_task.get('id', '')} - {next_task.get('name', '')}")
else:
    print("Next task: none")

last_decision = None
events_path = os.environ["STATUS_EVENTS"]
if os.path.exists(events_path):
    with open(events_path, "r", encoding="utf-8", errors="replace") as events_file:
        for line in events_file:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("event") == "decision" or event.get("type") == "decision":
                last_decision = event

if last_decision:
    outcome = last_decision.get("outcome") or last_decision.get("status") or "unknown"
    details = []
    for key in ("task_id", "stage", "reason"):
        value = last_decision.get(key)
        if value:
            details.append(f"{key}={value}")
    if details:
        print(f"Last decision: {outcome} ({', '.join(details)})")
    else:
        print(f"Last decision: {outcome}")
else:
    print("Last decision: none")
PY
    else
      if [[ "$LOOP_CLI" != "codex" && "$LOOP_CLI" != "gemini" ]]; then
        err "Invalid CLI value: $LOOP_CLI (supported: codex, gemini)"
        exit 1
      fi

      DOCTOR_BACKLOG="$STATE_DIR_STATUS/backlog.md"
      DOCTOR_PYTHON=()
      if [[ -n "${PYTHON:-}" ]]; then
        DOCTOR_PYTHON=("$PYTHON")
      elif DOCTOR_PYTHON_PATH="$(command -v python3 2>/dev/null)" && [[ "$DOCTOR_PYTHON_PATH" != *"WindowsApps"* ]]; then
        DOCTOR_PYTHON=("python3")
      elif DOCTOR_PYTHON_PATH="$(command -v python 2>/dev/null)" && [[ "$DOCTOR_PYTHON_PATH" != *"WindowsApps"* ]]; then
        DOCTOR_PYTHON=("python")
      fi

      echo "loop-agent doctor"
      echo "Project: $PROJECT_DIR"

      if command -v git >/dev/null 2>&1; then
        echo "Git: available ($(git --version 2>/dev/null || echo "version unknown"))"
      else
        echo "Git: missing"
      fi

      if [[ ${#DOCTOR_PYTHON[@]} -gt 0 ]]; then
        echo "Python: available ($("${DOCTOR_PYTHON[@]}" --version 2>&1 || echo "version unknown"))"
      else
        echo "Python: missing"
      fi

      if [[ -n "${BASH_VERSION:-}" ]]; then
        echo "Bash: available ($BASH_VERSION)"
      elif command -v bash >/dev/null 2>&1; then
        echo "Bash: available ($(bash --version 2>/dev/null | head -n 1 || echo "version unknown"))"
      else
        echo "Bash: missing"
      fi

      if command -v "$LOOP_CLI" >/dev/null 2>&1; then
        echo "AI CLI ($LOOP_CLI): available"
      else
        echo "AI CLI ($LOOP_CLI): missing"
      fi

      case "$LOOP_CLI" in
        codex)
          if is_placeholder_model "${CODEX_MODEL:-}" "${LOOP_PLACEHOLDER_CODEX_MODELS[@]}"; then
            echo "Model: PLACEHOLDER (CODEX_MODEL='$CODEX_MODEL' — override with a real ID)"
          else
            echo "Model: $CODEX_MODEL"
          fi
          ;;
        gemini)
          gem_cur="${GEMINI_MODEL:-${LOOP_GEMINI_MODEL:-}}"
          if is_placeholder_model "$gem_cur" "${LOOP_PLACEHOLDER_GEMINI_MODELS[@]}"; then
            echo "Model: PLACEHOLDER (LOOP_GEMINI_MODEL='$gem_cur' — override with a real ID)"
          else
            echo "Model: $gem_cur"
          fi
          ;;
      esac

      if command -v git >/dev/null 2>&1 && git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        DOCTOR_BRANCH="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
        if [[ "$DOCTOR_BRANCH" =~ ^(main|master|develop|trunk)$ ]] && [[ -z "${LOOP_REQUIRE_BRANCH_PREFIX:-}" ]]; then
          echo "Branch: $DOCTOR_BRANCH (warning: 'run' will commit directly here; consider LOOP_REQUIRE_BRANCH_PREFIX)"
        else
          echo "Branch: $DOCTOR_BRANCH"
        fi
      fi

      if [[ -f "$DOCTOR_BACKLOG" ]]; then
        echo "Backlog: present"
        if [[ ${#DOCTOR_PYTHON[@]} -gt 0 ]]; then
          if DOCTOR_LINT_OUTPUT="$(PYTHONUTF8=1 PYTHONIOENCODING=utf-8 "${DOCTOR_PYTHON[@]}" "$SCRIPT_DIR/backlog_manager.py" lint "$DOCTOR_BACKLOG" 2>&1)"; then
            echo "Backlog lint: passed"
          else
            echo "Backlog lint: failed"
            if [[ -n "$DOCTOR_LINT_OUTPUT" ]]; then
              echo "$DOCTOR_LINT_OUTPUT"
            fi
          fi
        else
          echo "Backlog lint: skipped (python missing)"
        fi
      else
        echo "Backlog: missing"
        echo "Backlog lint: skipped (backlog missing)"
      fi

      if command -v git >/dev/null 2>&1 && git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        if DOCTOR_GIT_STATUS="$(git -C "$PROJECT_DIR" status --porcelain=v1 --untracked-files=all 2>&1)"; then
          if [[ -z "$DOCTOR_GIT_STATUS" ]]; then
            echo "Clean tree: clean"
          else
            echo "Clean tree: dirty"
          fi
        else
          echo "Clean tree: error"
          echo "$DOCTOR_GIT_STATUS"
        fi
      else
        echo "Clean tree: not a git work tree"
      fi
    fi
    exit 0
    ;;
  *)
    if [[ "$1" =~ ^[0-9]+$ ]]; then
      if [[ $# -lt 2 ]] || [[ $# -gt 3 ]]; then
        err "Invalid arguments."
        usage
        exit 1
      fi
      LOOP_MODE="run"
      MAX_LOOPS="$1"
      MAX_LOOPS_FROM_FLAG=1
      PROJECT_DIR="$2"
      if [[ -n "${3:-}" ]]; then
        LOOP_CLI="$3"
        LOOP_CLI_FROM_FLAG=1
      fi
    else
      err "Invalid subcommand: $1"
      usage
      exit 1
    fi
    ;;
esac

# LOOP_CLI / MAX_LOOPS validations are deferred until after load_or_init_config
# so config.env values + interactive prompts can fill in missing pieces.

if [[ "$LOOP_MODE" == "run" ]] && ! [[ "$LOOP_VERIFY_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  err "LOOP_VERIFY_TIMEOUT must be a positive integer: $LOOP_VERIFY_TIMEOUT"
  exit 1
fi

if [[ "$LOOP_MODE" == "run" ]] && ! [[ "$LOOP_MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  err "LOOP_MAX_ATTEMPTS must be a positive integer: $LOOP_MAX_ATTEMPTS"
  exit 1
fi

if [[ "$LOOP_MODE" == "run" ]] && ! [[ "$LOOP_EVIDENCE_KEEP_RUNS" =~ ^[0-9]+$ ]]; then
  err "LOOP_EVIDENCE_KEEP_RUNS must be a non-negative integer (0 disables retention): $LOOP_EVIDENCE_KEEP_RUNS"
  exit 1
fi

if [[ "$LOOP_MODE" == "run" ]]; then
  case "$LOOP_RISK_MODE" in
    safe|unattended) ;;
    *)
      err "Invalid LOOP_RISK_MODE: $LOOP_RISK_MODE (supported: safe, unattended)"
      exit 1
      ;;
  esac
fi

RUN_MODE_NONINTERACTIVE=0
if [[ "$LOOP_MODE" == "run" ]] && [[ "$LOOP_EXPLICIT_SUBCOMMAND" == "1" ]]; then
  RUN_MODE_NONINTERACTIVE=1
fi
CLEAN_TREE_PREFLIGHT_STATUS="not checked"
BRANCH_PREFIX_PREFLIGHT_STATUS="not checked"
BACKLOG_LINT_STATUS="not checked"

clean_tree_preflight_path_allowed() {
  local path="$1"
  path="${path#./}"

  case "$path" in
    .loop-agent|\
    .loop-agent/backlog.md|\
    .loop-agent/backlog_archive.md|\
    .loop-agent/current_task.md|\
    .loop-agent/plan.md|\
    .loop-agent/plan_critique.md|\
    .loop-agent/impl_summary.md|\
    .loop-agent/impl_critique.md|\
    .loop-agent/report.md|\
    .loop-agent/events.jsonl|\
    .loop-agent/progress.txt|\
    .loop-agent/progress_window.md|\
    .loop-agent/file_index_before.md|\
    .loop-agent/file_index_after.md|\
    .loop-agent/current_transaction.json|\
    .loop-agent/codex.log|\
    .loop-agent/setup_agent_rendered.md|\
    .loop-agent/setup_critic_rendered.md|\
    .loop-agent/setup_critic.md|\
    .loop-agent/setup_critique.md|\
    .loop-agent/backlog_draft.md|\
    .loop-agent/loop.lock|\
    .loop-agent/loop.lock.d|\
    .loop-agent/loop.lock.d/*|\
    .loop-agent/evidence|\
    .loop-agent/evidence/*|\
    .loop-agent/proposals|\
    .loop-agent/proposals/*|\
    .loop-agent/*.protected|\
    .loop-agent/.bm_*.tmp)
      return 0
      ;;
  esac

  return 1
}

clean_tree_preflight() {
  if [[ "$RUN_MODE_NONINTERACTIVE" != "1" ]]; then
    CLEAN_TREE_PREFLIGHT_STATUS="not required"
    return 0
  fi

  if [[ "${LOOP_ALLOW_DIRTY:-}" == "1" ]]; then
    CLEAN_TREE_PREFLIGHT_STATUS="bypassed (LOOP_ALLOW_DIRTY=1)"
    warn "LOOP_ALLOW_DIRTY=1 set; dirty tree protection is bypassed."
    return 0
  fi

  if ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    CLEAN_TREE_PREFLIGHT_STATUS="not a git work tree"
    return 0
  fi

  local raw_status
  raw_status="$(mktemp)"
  if ! git -C "$PROJECT_DIR" status --porcelain=v1 -z --untracked-files=all > "$raw_status"; then
    rm -f "$raw_status"
    CLEAN_TREE_PREFLIGHT_STATUS="error"
    err "Could not inspect git status for clean-tree preflight."
    return 1
  fi

  local record status path path2 x y
  local -a dirty_paths=()
  while IFS= read -r -d '' record; do
    [[ -z "$record" ]] && continue

    status="${record:0:2}"
    path="${record:3}"
    x="${status:0:1}"
    y="${status:1:1}"

    if [[ "$x" == "R" || "$y" == "R" || "$x" == "C" || "$y" == "C" ]]; then
      path2=""
      IFS= read -r -d '' path2 || true
      path2="${path2#./}"
      if [[ -n "$path2" ]] && ! clean_tree_preflight_path_allowed "$path2"; then
        dirty_paths+=("$path2")
      fi
    fi

    path="${path#./}"
    if [[ -n "$path" ]] && ! clean_tree_preflight_path_allowed "$path"; then
      dirty_paths+=("$path")
    fi
  done < "$raw_status"
  rm -f "$raw_status"

  if [[ ${#dirty_paths[@]} -eq 0 ]]; then
    CLEAN_TREE_PREFLIGHT_STATUS="clean"
    return 0
  fi

  CLEAN_TREE_PREFLIGHT_STATUS="dirty"
  err "run mode requires a clean working tree."
  echo "Dirty paths:" >&2
  for path in "${dirty_paths[@]}"; do
    echo "  - $path" >&2
  done
  echo "" >&2
  echo "Commit, stash, or revert these changes before running loop-agent." >&2
  echo "To bypass this protection explicitly, rerun with LOOP_ALLOW_DIRTY=1." >&2
  return 1
}

branch_prefix_preflight() {
  if [[ "$RUN_MODE_NONINTERACTIVE" != "1" ]]; then
    BRANCH_PREFIX_PREFLIGHT_STATUS="not required"
    return 0
  fi
  if [[ -z "${LOOP_REQUIRE_BRANCH_PREFIX:-}" ]]; then
    BRANCH_PREFIX_PREFLIGHT_STATUS="not required"
    return 0
  fi

  if ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BRANCH_PREFIX_PREFLIGHT_STATUS="not a git work tree"
    return 0
  fi

  local current_branch
  current_branch="$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || true)"

  if [[ -z "$current_branch" ]]; then
    BRANCH_PREFIX_PREFLIGHT_STATUS="failed (detached HEAD)"
    err "run mode requires branch prefix: $LOOP_REQUIRE_BRANCH_PREFIX"
    echo "Current branch: detached HEAD" >&2
    echo "Required prefix: $LOOP_REQUIRE_BRANCH_PREFIX" >&2
    return 1
  fi

  if [[ "$current_branch" != "$LOOP_REQUIRE_BRANCH_PREFIX"* ]]; then
    BRANCH_PREFIX_PREFLIGHT_STATUS="failed ($current_branch)"
    err "run mode requires branch prefix: $LOOP_REQUIRE_BRANCH_PREFIX"
    echo "Current branch: $current_branch" >&2
    echo "Required prefix: $LOOP_REQUIRE_BRANCH_PREFIX" >&2
    return 1
  fi

  BRANCH_PREFIX_PREFLIGHT_STATUS="passed ($current_branch)"
  return 0
}

print_safety_summary_banner() {
  [[ "$LOOP_MODE" == "run" ]] || return 0

  banner "Run Safety Summary"
  echo -e "  Project path:       ${BOLD}$PROJECT_DIR${RESET}"
  echo -e "  CLI:                ${CYAN}$LOOP_CLI${RESET}"
  echo -e "  Risk mode:          $LOOP_RISK_MODE"
  echo -e "  Clean tree:         $CLEAN_TREE_PREFLIGHT_STATUS"
  echo -e "  Branch requirement: $BRANCH_PREFIX_PREFLIGHT_STATUS"
  echo -e "  Backlog lint:       $BACKLOG_LINT_STATUS"
  echo ""
}

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
# Project folder
if [[ ! -d "$PROJECT_DIR" ]]; then
  add_result "Before start: ERROR (prerequisites failed)"
  print_results
  err "Project folder not found: $PROJECT_DIR"
  exit 1
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
STATE_DIR="$PROJECT_DIR/.loop-agent"

# ── Per-project config: load .loop-agent/config.env, run wizard if missing.
# Precedence: CLI flag > user-exported env > config.env > built-in default.
MAIN_FLAG_CLI=""
[[ "$LOOP_CLI_FROM_FLAG" == "1" ]] && MAIN_FLAG_CLI="$LOOP_CLI"
load_or_init_config
# Precedence restore (config may have overwritten LOOP_CLI; CLI flag must win)
if [[ -n "$MAIN_FLAG_CLI" ]]; then
  LOOP_CLI="$MAIN_FLAG_CLI"
elif [[ -n "$LOOP_USER_CLI_ENV" ]]; then
  LOOP_CLI="$LOOP_USER_CLI_ENV"
fi
[[ -n "$LOOP_USER_CODEX_MODEL" ]]   && CODEX_MODEL="$LOOP_USER_CODEX_MODEL"
[[ -n "$LOOP_USER_GEMINI_MODEL" ]]  && LOOP_GEMINI_MODEL="$LOOP_USER_GEMINI_MODEL"
[[ -n "$LOOP_USER_BRANCH_PREFIX" ]] && LOOP_REQUIRE_BRANCH_PREFIX="$LOOP_USER_BRANCH_PREFIX"

# Apply built-in fallback defaults for anything still empty after config + env
LOOP_CLI="${LOOP_CLI:-codex}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
LOOP_GEMINI_MODEL="${LOOP_GEMINI_MODEL:-gemini-3.1-pro-preview}"
# Re-sync the cli_adapters cache (GEMINI_MODEL was set at sourcing time before config load).
GEMINI_MODEL="$LOOP_GEMINI_MODEL"

# Validate LOOP_CLI now that all sources have contributed
case "$LOOP_CLI" in
  codex|gemini) ;;
  *)
    err "Invalid CLI value: $LOOP_CLI (supported: codex, gemini)"
    exit 1
    ;;
esac

# Iterations: prompt interactively if not given on CLI in run mode + TTY.
# Non-TTY (CI) without --iterations → error.
if [[ "$LOOP_MODE" == "run" ]] && [[ -z "$MAX_LOOPS" ]]; then
  if [[ -t 0 ]] && [[ -t 1 ]]; then
    while true; do
      printf "Iterations to run: " >&2
      read -r MAX_LOOPS || { err "Iterations required for run mode."; exit 1; }
      [[ "$MAX_LOOPS" =~ ^[1-9][0-9]*$ ]] && break
      echo "  Must be a positive integer." >&2
    done
  else
    err "Iterations required for run mode (use --iterations N or -i N)."
    exit 1
  fi
fi

if [[ "$LOOP_MODE" == "run" ]] && ! [[ "$MAX_LOOPS" =~ ^[1-9][0-9]*$ ]]; then
  err "Iterations must be a positive integer: $MAX_LOOPS"
  exit 1
fi

if ! clean_tree_preflight; then
  exit 1
fi

if ! branch_prefix_preflight; then
  exit 1
fi

if [[ "$RUN_MODE_NONINTERACTIVE" == "1" ]] && [[ ! -f "$PROJECT_DIR/.loop-agent/backlog.md" ]]; then
  err "run mode requires .loop-agent/backlog.md. Run ./loop.sh init first."
  exit 1
fi

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

    # Check ChatGPT login (codex uses ChatGPT account login).
    # Skipped when running against the fake CLI (e2e tests set LOOP_FAKE_SCENARIO).
    CODEX_AUTH_FILE="${HOME}/.codex/auth.json"
    if [[ -z "${LOOP_FAKE_SCENARIO:-}" ]] && [[ ! -f "$CODEX_AUTH_FILE" ]]; then
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

LOCK_FILE="$STATE_DIR/loop.lock"
LOCK_DIR="$STATE_DIR/loop.lock.d"
PROJECT_LOCK_HELD=0
EVIDENCE_ROOT="$STATE_DIR/evidence"
EVIDENCE_DIR=""
EVIDENCE_REL=""
PASS_COMMIT_HASH=""
PROJECT_CHANGE_COUNT=0
declare -a PROJECT_ROLLBACK_UNTRACKED_EXCLUDES=()
FILE_INDEX_BEFORE="$STATE_DIR/file_index_before.md"
FILE_INDEX_AFTER="$STATE_DIR/file_index_after.md"
PROGRESS="$STATE_DIR/progress.txt"
EVENTS_LOG="$STATE_DIR/events.jsonl"
PLAN="$STATE_DIR/plan.md"
PLAN_CRITIQUE="$STATE_DIR/plan_critique.md"
IMPL_SUMMARY="$STATE_DIR/impl_summary.md"
IMPL_CRITIQUE="$STATE_DIR/impl_critique.md"
BACKLOG="$STATE_DIR/backlog.md"
BACKLOG_ARCHIVE="$STATE_DIR/backlog_archive.md"
CURRENT_TASK="$STATE_DIR/current_task.md"
REPORT="$STATE_DIR/report.md"
TRANSACTION_FILE="$STATE_DIR/current_transaction.json"
TRANSACTION_SNAPSHOT_COMMIT=""

write_project_lock() {
  local tmp="$LOCK_FILE.$$.$RANDOM.tmp"
  local started_utc
  started_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  {
    printf 'pid=%s\n' "$$"
    printf 'command=%s\n' "$ORIGINAL_COMMAND"
    printf 'started_utc=%s\n' "$started_utc"
  } > "$tmp"
  mv -f "$tmp" "$LOCK_FILE"
}

lock_pid_is_live() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

read_project_lock_pid() {
  local pid=""
  if [[ -f "$LOCK_DIR/pid" ]]; then
    pid="$(head -1 "$LOCK_DIR/pid" 2>/dev/null | tr -d '\r')"
  fi
  if [[ -z "$pid" && -f "$LOCK_FILE" ]]; then
    pid="$(sed -n 's/^pid=//p' "$LOCK_FILE" 2>/dev/null | head -1 | tr -d '\r')"
  fi
  printf '%s\n' "$pid"
}

release_project_lock() {
  local pid
  [[ -n "${LOCK_FILE:-}" && -n "${LOCK_DIR:-}" ]] || return 0
  [[ -f "$LOCK_FILE" || -f "$LOCK_DIR/pid" ]] || return 0
  pid="$(read_project_lock_pid)"
  [[ "$pid" == "$$" ]] || return 0
  rm -f "$LOCK_FILE"
  rm -rf "$LOCK_DIR"
  PROJECT_LOCK_HELD=0
}

acquire_project_lock() {
  local owner_pid attempt
  while true; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      PROJECT_LOCK_HELD=1
      write_project_lock
      return 0
    fi

    owner_pid="$(read_project_lock_pid)"

    if lock_pid_is_live "$owner_pid"; then
      err "Another loop-agent run is active for this project (pid: $owner_pid). Lock: $LOCK_FILE"
      return 1
    fi

    if [[ -z "$owner_pid" ]]; then
      for attempt in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.1
        owner_pid="$(read_project_lock_pid)"
        if lock_pid_is_live "$owner_pid"; then
          err "Another loop-agent run is active for this project (pid: $owner_pid). Lock: $LOCK_FILE"
          return 1
        fi
        [[ -n "$owner_pid" ]] && break
      done
    fi

    warn "Removing stale project lock: $LOCK_FILE"
    rm -f "$LOCK_FILE"
    rm -rf "$LOCK_DIR"
  done
}

if [[ "$LOOP_MODE" == "run" ]]; then
  acquire_project_lock
  trap release_project_lock EXIT
fi

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
    ${LOOP_EVIDENCE_DIR} ${LOOP_EVIDENCE_REL} \
    ${LOOP_PLAN} ${LOOP_PLAN_CRITIQUE} \
    ${LOOP_IMPL_SUMMARY} ${LOOP_IMPL_CRITIQUE} ${LOOP_REPORT}' \
    < "$template" > "$output"
}

transaction_write() {
  local stage="$1"
  local complete="${2:-false}"
  local py_cmd tmp

  [[ -z "${NEXT_TASK_ID:-}" ]] && return 0
  py_cmd="$(get_python_cmd)"
  if [[ -z "$py_cmd" ]]; then
    err "python not found."
    return 1
  fi

  tmp="${TRANSACTION_FILE}.$$.$RANDOM.tmp"
  TRANSACTION_FILE="$TRANSACTION_FILE" \
  TRANSACTION_TMP="$tmp" \
  TRANSACTION_LOOP="$LOOP" \
  TRANSACTION_TASK_ID="$NEXT_TASK_ID" \
  TRANSACTION_TASK_NAME="${NEXT_TASK_NAME:-}" \
  TRANSACTION_STAGE="$stage" \
  TRANSACTION_SNAPSHOT_COMMIT="${TRANSACTION_SNAPSHOT_COMMIT:-}" \
  TRANSACTION_EVIDENCE_DIR="${EVIDENCE_DIR:-}" \
  TRANSACTION_EVIDENCE_REL="${EVIDENCE_REL:-}" \
  TRANSACTION_COMPLETE="$complete" \
  PYTHONUTF8=1 PYTHONIOENCODING=utf-8 \
    $py_cmd - <<'PY'
import datetime
import json
import os

path = os.environ["TRANSACTION_FILE"]
tmp = os.environ["TRANSACTION_TMP"]
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
created_at = now

try:
    with open(path, "r", encoding="utf-8") as f:
        previous = json.load(f)
    if str(previous.get("loop", "")) == os.environ["TRANSACTION_LOOP"] and previous.get("task_id") == os.environ["TRANSACTION_TASK_ID"]:
        created_at = previous.get("created_at") or now
except Exception:
    pass

data = {
    "loop": int(os.environ["TRANSACTION_LOOP"]),
    "task_id": os.environ["TRANSACTION_TASK_ID"],
    "task_name": os.environ["TRANSACTION_TASK_NAME"],
    "stage": os.environ["TRANSACTION_STAGE"],
    "snapshot_commit": os.environ["TRANSACTION_SNAPSHOT_COMMIT"],
    "evidence_dir": os.environ["TRANSACTION_EVIDENCE_DIR"],
    "evidence_rel": os.environ["TRANSACTION_EVIDENCE_REL"],
    "created_at": created_at,
    "updated_at": now,
    "complete": os.environ["TRANSACTION_COMPLETE"].lower() == "true",
}

with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
  mv -f "$tmp" "$TRANSACTION_FILE"
}

append_event() {
  local event_type="$1"
  shift || true

  [[ -z "${EVENTS_LOG:-}" ]] && return 0

  local py_cmd
  py_cmd="$(get_python_cmd)"
  if [[ -z "$py_cmd" ]]; then
    err "python not found."
    return 1
  fi

  mkdir -p "$(dirname "$EVENTS_LOG")"
  EVENTS_LOG="$EVENTS_LOG" \
  EVENT_TYPE="$event_type" \
  EVENT_LOOP="${LOOP:-}" \
  EVENT_TASK_ID="${NEXT_TASK_ID:-}" \
  EVENT_TASK_NAME="${NEXT_TASK_NAME:-}" \
  EVENT_EVIDENCE_DIR="${EVIDENCE_DIR:-}" \
  EVENT_EVIDENCE_REL="${EVIDENCE_REL:-}" \
  EVENT_VERIFY_STATUS="${VERIFY_STATUS:-}" \
  EVENT_VERIFY_RESULT="${VERIFY_RESULT:-}" \
  EVENT_PASS_COMMIT_HASH="${PASS_COMMIT_HASH:-}" \
  EVENT_PROJECT_CHANGE_COUNT="${PROJECT_CHANGE_COUNT:-}" \
  PYTHONUTF8=1 PYTHONIOENCODING=utf-8 \
    $py_cmd - "$@" <<'PY'
import datetime
import json
import os
import sys

path = os.environ["EVENTS_LOG"]
event_type = os.environ["EVENT_TYPE"]
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
int_keys = {"loop", "pending_count", "blocked_count", "project_change_count", "verify_result", "verify_exit_code", "command_count", "exit_code"}

def add_if_present(record, key, value):
    if value == "":
        return
    if key in int_keys:
        try:
            record[key] = int(value)
            return
        except ValueError:
            pass
    if value.lower() == "true":
        record[key] = True
    elif value.lower() == "false":
        record[key] = False
    else:
        record[key] = value

record = {
    "timestamp": now,
    "event": event_type,
    "type": event_type,
}

env_fields = {
    "loop": os.environ.get("EVENT_LOOP", ""),
    "task_id": os.environ.get("EVENT_TASK_ID", ""),
    "task_name": os.environ.get("EVENT_TASK_NAME", ""),
    "evidence_dir": os.environ.get("EVENT_EVIDENCE_DIR", ""),
    "evidence_rel": os.environ.get("EVENT_EVIDENCE_REL", ""),
    "verify_status": os.environ.get("EVENT_VERIFY_STATUS", ""),
    "verify_result": os.environ.get("EVENT_VERIFY_RESULT", ""),
    "commit_hash": os.environ.get("EVENT_PASS_COMMIT_HASH", ""),
    "project_change_count": os.environ.get("EVENT_PROJECT_CHANGE_COUNT", ""),
}
for key, value in env_fields.items():
    add_if_present(record, key, value)

for arg in sys.argv[1:]:
    if "=" not in arg:
        continue
    key, value = arg.split("=", 1)
    if key:
        add_if_present(record, key, value)

with open(path, "a", encoding="utf-8") as f:
    json.dump(record, f, ensure_ascii=False, separators=(",", ":"))
    f.write("\n")
PY
}

transaction_complete() {
  local outcome="$1"
  transaction_write "final_decision:${outcome}" true
  append_event "decision" \
    "outcome=$outcome" \
    "status=$outcome" \
    "stage=final_decision:${outcome}"
}

transaction_load_incomplete() {
  RECOVERY_TASK_ID=""
  RECOVERY_TASK_NAME=""
  RECOVERY_STAGE=""
  RECOVERY_SNAPSHOT_COMMIT=""
  RECOVERY_EVIDENCE_DIR=""
  RECOVERY_EVIDENCE_REL=""

  [[ -f "$TRANSACTION_FILE" ]] || return 1

  local py_cmd
  py_cmd="$(get_python_cmd)"
  if [[ -z "$py_cmd" ]]; then
    return 1
  fi

  local fields=()
  mapfile -t fields < <(
    TRANSACTION_FILE="$TRANSACTION_FILE" \
    PYTHONUTF8=1 PYTHONIOENCODING=utf-8 \
      $py_cmd - <<'PY'
import json
import os
import sys

path = os.environ["TRANSACTION_FILE"]

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

if not isinstance(data, dict) or data.get("complete") is True:
    sys.exit(1)

task_id = str(data.get("task_id") or "").strip()
if not task_id:
    sys.exit(1)

def clean(value):
    if value is None:
        return ""
    return str(value).replace("\r", " ").replace("\n", " ").strip()

for key in ("task_id", "task_name", "stage", "snapshot_commit", "evidence_dir", "evidence_rel"):
    print(clean(data.get(key)))
PY
  )

  [[ "${#fields[@]}" -eq 6 ]] || return 1

  RECOVERY_TASK_ID="${fields[0]%$'\r'}"
  RECOVERY_TASK_NAME="${fields[1]%$'\r'}"
  RECOVERY_STAGE="${fields[2]%$'\r'}"
  RECOVERY_SNAPSHOT_COMMIT="${fields[3]%$'\r'}"
  RECOVERY_EVIDENCE_DIR="${fields[4]%$'\r'}"
  RECOVERY_EVIDENCE_REL="${fields[5]%$'\r'}"
  return 0
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

    # Current LoopDex backlog format
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

get_task_metadata_field() {
  local backlog="$1"
  local task_id="$2"
  local field="$3"

  awk -v tid="$task_id" -v field="$field" '
    BEGIN { found=0 }

    $0 ~ "^- \\[.\\] " tid ":" { found=1; next }
    $0 ~ "^## " tid ":" { found=1; next }

    found && $0 ~ "^- \\[.\\] Task " { exit }
    found && $0 ~ "^## Task " { exit }

    found {
      line=$0
      gsub(/\r/, "", line)
      pattern = "^[[:space:]]*-?[[:space:]]*" field ":[[:space:]]*"
      if (line ~ pattern) {
        sub(pattern, "", line)
        print line
        exit
      }
    }
  ' "$backlog" 2>/dev/null
}

bound_retry_context_value() {
  local value="${1:-none}"

  value="$(printf '%s' "$value" | tr '\r\n\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  if [[ -z "$value" ]]; then
    value="none"
  fi
  if [[ ${#value} -gt 300 ]]; then
    value="${value:0:297}..."
  fi

  printf '%s\n' "$value"
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
      info "[$name] running... (cli: codex, risk: $LOOP_RISK_MODE, model: $model, reasoning: $reasoning)"
      run_codex_agent "$PROJECT_DIR" "$agent_file" "$out_file" "$STATE_DIR/codex.log" "$model" "$reasoning" &
      ;;
    gemini)
      info "[$name] running... (cli: gemini, risk: $LOOP_RISK_MODE, model: $GEMINI_MODEL, flags: ${GEMINI_FLAGS:-none})"
      run_gemini_agent "$PROJECT_DIR" "$agent_file" "$out_file" "$STATE_DIR/codex.log" &
      ;;
  esac
  CODEX_PID=$!

  if wait "$CODEX_PID"; then
    CODEX_PID=""
    ok "[$name] done"
    append_event "agent_done" \
      "agent_role=$name" \
      "status=PASS" \
      "output_file=$out_file"
    return 0
  else
    local exit_code=$?
    CODEX_PID=""
    append_event "agent_done" \
      "agent_role=$name" \
      "status=FAIL" \
      "exit_code=$exit_code" \
      "output_file=$out_file"
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

  transaction_complete "SUSPENDED"
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
declare -a PROTECTED_MISSING=()
declare -a STATE_FILE_PROTECTION_RESTORED=()
declare -a STATE_FILE_PROTECTION_REMOVED=()
STATE_FILE_PROTECTION_VIOLATION_THIS_CALL=0
BACKLOG_SEMANTIC_BEFORE=""
BACKLOG_SEMANTIC_SNAPSHOT_ACTIVE=0
BACKLOG_SEMANTIC_VIOLATION=0
BACKLOG_SEMANTIC_VIOLATION_THIS_CALL=0
BACKLOG_SEMANTIC_VIOLATION_AGENT=""

snapshot_state_files() {
  local agent="${1:-unknown}"
  local allowed_file="${2:-}"
  PROTECTED_BACKUPS=()
  PROTECTED_MISSING=()
  STATE_FILE_PROTECTION_RESTORED=()
  STATE_FILE_PROTECTION_REMOVED=()
  STATE_FILE_PROTECTION_VIOLATION_THIS_CALL=0
  BACKLOG_SEMANTIC_BEFORE=""
  BACKLOG_SEMANTIC_SNAPSHOT_ACTIVE=0
  BACKLOG_SEMANTIC_VIOLATION_THIS_CALL=0
  local files=("$BACKLOG" "$PROGRESS" "$CURRENT_TASK" "$PLAN" "$PLAN_CRITIQUE" "$IMPL_SUMMARY" "$IMPL_CRITIQUE")
  local f backup
  for f in "${files[@]}"; do
    if [[ -n "$allowed_file" ]] && [[ "$f" == "$allowed_file" ]]; then
      continue
    fi
    if [[ -f "$f" ]]; then
      backup="${f}.protected"
      cp "$f" "$backup"
      PROTECTED_BACKUPS+=("$f|$backup")
    else
      PROTECTED_MISSING+=("$f")
    fi
  done
  if [[ -f "$BACKLOG" ]]; then
    BACKLOG_SEMANTIC_BEFORE="$(run_backlog_manager semantic-snapshot "$BACKLOG" 2>/dev/null || echo "__ERROR__")"
  else
    BACKLOG_SEMANTIC_BEFORE="__MISSING__"
  fi
  BACKLOG_SEMANTIC_SNAPSHOT_ACTIVE=1
}

detect_backlog_semantic_mutation() {
  local agent="$1"
  local after

  if [[ "$BACKLOG_SEMANTIC_SNAPSHOT_ACTIVE" != "1" ]]; then
    return 0
  fi

  if [[ -f "$BACKLOG" ]]; then
    after="$(run_backlog_manager semantic-snapshot "$BACKLOG" 2>/dev/null || echo "__ERROR__")"
  else
    after="__MISSING__"
  fi

  if [[ "$BACKLOG_SEMANTIC_BEFORE" != "$after" ]]; then
    BACKLOG_SEMANTIC_VIOLATION=1
    BACKLOG_SEMANTIC_VIOLATION_THIS_CALL=1
    BACKLOG_SEMANTIC_VIOLATION_AGENT="$agent"
    warn "${agent} modified backlog semantics ??restoring"
  fi
}

record_state_file_protection_violation() {
  local agent="$1"
  if [[ "$STATE_FILE_PROTECTION_VIOLATION_THIS_CALL" != "1" ]]; then
    return 0
  fi
  local restored="none"
  local removed="none"
  if [[ ${#STATE_FILE_PROTECTION_RESTORED[@]} -gt 0 ]]; then
    restored="$(IFS=,; echo "${STATE_FILE_PROTECTION_RESTORED[*]}")"
  fi
  if [[ ${#STATE_FILE_PROTECTION_REMOVED[@]} -gt 0 ]]; then
    removed="$(IFS=,; echo "${STATE_FILE_PROTECTION_REMOVED[*]}")"
  fi
  {
    echo ""
    echo "=== Loop ${LOOP}: State File Protection Violation ==="
    echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Phase: $agent"
    echo "Task: ${NEXT_TASK_ID:-unknown} ??${NEXT_TASK_NAME:-unknown}"
    echo "Restored: $restored"
    echo "Removed: $removed"
    echo "Action: Restored protected state files and removed unauthorized state file creations."
    echo ""
  } >> "$PROGRESS"
}

backlog_semantic_guard_failed() {
  local agent="$1"
  if [[ "$BACKLOG_SEMANTIC_VIOLATION_THIS_CALL" != "1" ]] && [[ "$STATE_FILE_PROTECTION_VIOLATION_THIS_CALL" != "1" ]]; then
    return 1
  fi

  case "$agent" in
    Implementer|"Impl Critic")
      git_rollback "state file protection violation ??discard partial implementation"
      ;;
  esac

  add_result "Loop ${LOOP}: FAIL (state file protection - ${agent}) ??${NEXT_TASK_ID:-unknown}"
  return 0
}

restore_state_files_if_modified() {
  local agent="$1"
  local restored=0
  local removed=0
  local entry f backup
  detect_backlog_semantic_mutation "$agent"
  for entry in "${PROTECTED_BACKUPS[@]}"; do
    f="${entry%%|*}"
    backup="${entry##*|}"
    if [[ ! -f "$backup" ]]; then continue; fi
    if [[ ! -f "$f" ]] || ! cmp -s "$f" "$backup" 2>/dev/null; then
      warn "${agent} modified state file: $(basename "$f") → restoring"
      cp "$backup" "$f"
      STATE_FILE_PROTECTION_RESTORED+=("$(basename "$f")")
      STATE_FILE_PROTECTION_VIOLATION_THIS_CALL=1
      restored=$((restored + 1))
    fi
    rm -f "$backup"
  done
  for f in "${PROTECTED_MISSING[@]}"; do
    case "$f" in
      "$EVIDENCE_ROOT"|"$EVIDENCE_ROOT"/*)
        continue
        ;;
    esac
    if [[ -f "$f" ]]; then
      warn "${agent} created state file: $(basename "$f") ??removing"
      rm -f "$f"
      STATE_FILE_PROTECTION_REMOVED+=("$(basename "$f")")
      STATE_FILE_PROTECTION_VIOLATION_THIS_CALL=1
      removed=$((removed + 1))
    fi
  done
  PROTECTED_BACKUPS=()
  PROTECTED_MISSING=()
  if [[ $restored -gt 0 ]] || [[ $removed -gt 0 ]]; then
    warn "${agent}: restored ${restored} and removed ${removed} state file(s)"
  fi
  record_state_file_protection_violation "$agent"
  BACKLOG_SEMANTIC_SNAPSHOT_ACTIVE=0
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

write_proposal_report() {
  local output_file="$1"
  local title="$2"
  local task_id="$3"
  local task_name="$4"
  local verdict="$5"
  local requested_change="$6"
  local reason="$7"
  local evidence_path="${8:-none}"

  [[ -z "$evidence_path" ]] && evidence_path="none"

  {
    echo "# $title"
    echo ""
    echo "Task ID: $task_id"
    echo "Task Name: $task_name"
    echo "Verdict: $verdict"
    echo "Requested Change: $requested_change"
    echo "Reason: $reason"
    echo "Evidence Path: $evidence_path"
    echo ""
    echo "No backlog semantic change was applied."
  } > "$output_file"
}

verify_command_policy_reason() {
  local cmd="$1"
  local lower re
  lower="$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')"

  re='(^|[[:space:];|&\(])sudo([[:space:];|&\)]|$)'
  if [[ "$lower" =~ $re ]]; then
    echo "standalone sudo is not allowed"
    return 0
  fi
  re='(^|[[:space:];|&\(])rm[[:space:]]+-[^[:space:];|&]*r[^[:space:];|&]*f[^[:space:];|&]*[[:space:]]+/(\*|[[:space:];|&]|$)'
  if [[ "$lower" =~ $re ]]; then
    echo "rm -rf / is not allowed"
    return 0
  fi
  re='(^|[[:space:];|&\(])curl[[:space:]][^|]*\|[[:space:]]*(ba)?sh([[:space:];|&\)]|$)'
  if [[ "$lower" =~ $re ]]; then
    echo "curl piped to sh is not allowed"
    return 0
  fi
  re='(^|[[:space:];|&\(])wget[[:space:]][^|]*\|[[:space:]]*(ba)?sh([[:space:];|&\)]|$)'
  if [[ "$lower" =~ $re ]]; then
    echo "wget piped to sh is not allowed"
    return 0
  fi

  return 1
}

check_verify_command_policy() {
  local commands_file="$1"
  local output_file="$2"
  local cmd idx reason blocked

  idx=0
  blocked=0
  {
    echo "# Verify Command Policy"
    echo ""
  } > "$output_file"

  while IFS= read -r cmd || [[ -n "$cmd" ]]; do
    [[ -z "$cmd" ]] && continue
    idx=$((idx + 1))
    if reason="$(verify_command_policy_reason "$cmd")"; then
      blocked=1
      {
        echo "BLOCKED: command $idx: $reason"
        echo '```bash'
        echo "$cmd"
        echo '```'
        echo ""
      } >> "$output_file"
    fi
  done < "$commands_file"

  if [[ "$blocked" -eq 1 ]]; then
    return 1
  fi

  echo "RESULT: PASS" >> "$output_file"
  return 0
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
    if [[ "$status" == "PASS" ]]; then
      if [[ "${LOOP_EVIDENCE_PRUNE_PASS:-1}" == "1" ]] && [[ -n "${PASS_COMMIT_HASH:-}" ]]; then
        echo "**Evidence:** pruned (redundant with commit ${PASS_COMMIT_HASH})  "
      else
        echo "**Evidence:** ${EVIDENCE_REL:-none}  "
      fi
      if [[ -n "${PASS_COMMIT_HASH:-}" ]]; then
        echo "**PASS commit:** ${PASS_COMMIT_HASH}  "
      else
        echo "**PASS commit:** skipped  "
      fi
    fi

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
  if [[ -z "${STATE_DIR:-}" ]] || [[ -z "${PROGRESS:-}" ]]; then
    return
  fi

  local window_file="$STATE_DIR/progress_window.md"
  local window_size=5
  local py_script="$SCRIPT_DIR/progress_window.py"
  local current_task_file="${CURRENT_TASK:-}"

  if [[ ! -f "$PROGRESS" ]]; then
    {
      echo "# Progress Window"
      echo ""
      echo "Bounded Markdown context for agents. Raw \`.loop-agent/progress.txt\` remains the durable log."
      echo ""
      echo "## Recent Loop Summaries (0 of latest ${window_size})"
      echo ""
      echo "- none"
    } > "$window_file"
    return
  fi

  if [[ ! -f "$py_script" ]]; then
    # Fall back to full progress.txt if progress_window.py is missing
    warn "progress_window.py not found → using full progress.txt"
    {
      echo "# Progress Window"
      echo ""
      echo "Bounded Markdown context for agents. Raw \`.loop-agent/progress.txt\` remains the durable log."
      echo ""
      echo "## Hard Constraints"
      echo ""
      echo "- Treat this file as bounded context, not as source of truth."
      echo "- Do not pull full diffs, full logs, or huge verify output into agent context."
    } > "$window_file"
    return
  fi

  {
    :
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
      {
        echo "# Progress Window"
        echo ""
        echo "Bounded Markdown context for agents. Raw \`.loop-agent/progress.txt\` remains the durable log."
        echo ""
        echo "## Hard Constraints"
        echo ""
        echo "- Treat this file as bounded context, not as source of truth."
        echo "- Do not pull full diffs, full logs, or huge verify output into agent context."
      } > "$window_file"
      return
    fi
    local generated_window="${window_file}.tmp"
    PYTHONUTF8=1 PYTHONIOENCODING=utf-8 \
      $py_cmd "$py_script" --markdown "$PROGRESS" "$current_task_file" "$generated_window" "$window_size"
    cat "$generated_window"
    rm -f "$generated_window"
  } > "$window_file"

  local total
  total=$(grep -c "^=== Loop" "$PROGRESS" 2>/dev/null || echo 0)
  info "progress Markdown window: ${window_size} most recent of ${total} total"
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
  export LOOP_PROGRESS_WINDOW="$STATE_DIR/progress_window.md"
  export LOOP_BACKLOG="$BACKLOG"
  export LOOP_CURRENT_TASK="$CURRENT_TASK"
  export LOOP_EVIDENCE_DIR="$EVIDENCE_DIR"
  export LOOP_EVIDENCE_REL="$EVIDENCE_REL"
  export LOOP_PLAN="$PLAN"
  export LOOP_PLAN_CRITIQUE="$PLAN_CRITIQUE"
  export LOOP_IMPL_SUMMARY="$IMPL_SUMMARY"
  export LOOP_IMPL_CRITIQUE="$IMPL_CRITIQUE"
  export LOOP_REPORT="$REPORT"
}

warn_placeholder_model() {
  case "$LOOP_CLI" in
    codex)
      if is_placeholder_model "${CODEX_MODEL:-}" "${LOOP_PLACEHOLDER_CODEX_MODELS[@]}"; then
        warn "CODEX_MODEL='$CODEX_MODEL' is a README placeholder, not a real model ID."
        echo -e "  ${GRAY}• Override before running:  export CODEX_MODEL=<id-your-account-exposes>${RESET}"
        echo -e "  ${GRAY}• Otherwise the codex CLI will fail and fail_count will increment toward BLOCKED.${RESET}"
      fi
      ;;
    gemini)
      if is_placeholder_model "${GEMINI_MODEL:-${LOOP_GEMINI_MODEL:-}}" "${LOOP_PLACEHOLDER_GEMINI_MODELS[@]}"; then
        warn "LOOP_GEMINI_MODEL='${GEMINI_MODEL:-${LOOP_GEMINI_MODEL:-}}' is a README placeholder, not a real model ID."
        echo -e "  ${GRAY}• Override before running:  export LOOP_GEMINI_MODEL=<id-your-account-exposes>${RESET}"
      fi
      ;;
  esac
}

# ── warn_unsafe_branch: warn if running on main/master without branch guard ─
warn_unsafe_branch() {
  local cur_branch
  cur_branch="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  [[ -z "$cur_branch" ]] && return 0
  if [[ "$cur_branch" =~ ^(main|master|develop|trunk)$ ]] && [[ -z "${LOOP_REQUIRE_BRANCH_PREFIX:-}" ]]; then
    warn "Current branch is '$cur_branch'. LoopDex 'run' will commit directly to it on every PASS."
    echo -e "  ${GRAY}• Recommended:  git checkout -b loop/work  &&  export LOOP_REQUIRE_BRANCH_PREFIX=loop/${RESET}"
    echo -e "  ${GRAY}• Set LOOP_REQUIRE_BRANCH_PREFIX to refuse 'run' on unintended branches.${RESET}"
  fi
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

    # .gitignore: exclude embedded git folders and LoopDex state files
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

    # Add language-specific ignore patterns BEFORE the initial add -A so that
    # pre-existing build artifacts (__pycache__/, node_modules/, *.egg-info/,
    # target/, .venv/ ...) are not committed into git history on first init.
    bootstrap_language_gitignore

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

# ── bootstrap_language_gitignore: add standard ignore patterns ─
# Detects common language projects and appends idiomatic ignore
# patterns to .gitignore so verify-tool byproducts (build artifacts,
# caches) don't trip the scope gate. Idempotent via marker comments.
# Called from init mode only — run mode never edits user .gitignore.
bootstrap_language_gitignore() {
  local gi="$PROJECT_DIR/.gitignore"
  [[ -f "$gi" ]] || printf '' > "$gi"
  local added=()

  _gi_add_block() {
    local marker="$1"; shift
    grep -qF "$marker" "$gi" 2>/dev/null && return
    {
      printf '\n%s\n' "$marker"
      printf '%s\n' "$@"
    } >> "$gi"
    added+=("${marker#\# }")
  }

  # Secrets — always added regardless of language. Mirrors the secret_path_guard
  # patterns so the initial git add -A does not commit credentials. Path-based
  # only; review .gitignore for project-specific secret files.
  _gi_add_block "# Secrets" \
    ".env" ".env.*" "!.env.example" "!.env.sample" \
    "*.pem" "*.key" "id_rsa" "id_ed25519" \
    ".ssh/" "*.pfx" "*.p12"

  # Editor / OS metadata — frequently land in working tree from tooling.
  _gi_add_block "# Editor / OS" \
    ".DS_Store" "Thumbs.db" \
    ".idea/" ".vscode/" "*.swp" "*.swo"

  # Python
  if compgen -G "$PROJECT_DIR/pyproject.toml" >/dev/null 2>&1 \
     || compgen -G "$PROJECT_DIR/setup.py" >/dev/null 2>&1 \
     || compgen -G "$PROJECT_DIR/requirements*.txt" >/dev/null 2>&1 \
     || compgen -G "$PROJECT_DIR/*.py" >/dev/null 2>&1; then
    _gi_add_block "# Python" \
      "__pycache__/" "*.py[cod]" "*\$py.class" \
      "*.egg-info/" "*.egg" \
      ".pytest_cache/" ".mypy_cache/" ".ruff_cache/" \
      ".coverage" "htmlcov/" ".tox/" \
      "build/" "dist/" \
      ".venv/" "venv/" "env/"
  fi

  # Node
  if [[ -f "$PROJECT_DIR/package.json" ]]; then
    _gi_add_block "# Node" \
      "node_modules/" "dist/" "build/" ".next/" "coverage/" \
      "*.log" ".env.local"
  fi

  # Rust
  if [[ -f "$PROJECT_DIR/Cargo.toml" ]]; then
    _gi_add_block "# Rust" "target/"
  fi

  # Go
  if [[ -f "$PROJECT_DIR/go.mod" ]]; then
    _gi_add_block "# Go" "vendor/"
  fi

  # Java / Maven
  if [[ -f "$PROJECT_DIR/pom.xml" ]]; then
    _gi_add_block "# Maven" "target/" "*.class"
  fi

  # Java / Gradle
  if compgen -G "$PROJECT_DIR/build.gradle*" >/dev/null 2>&1; then
    _gi_add_block "# Gradle" "build/" ".gradle/"
  fi

  if (( ${#added[@]} > 0 )); then
    info "Bootstrapped .gitignore for: ${added[*]}"
    info "Review and commit the updated .gitignore before running ./loop.sh run"
  fi
}

secret_path_guard_match() {
  local path="$1"
  local lower basename

  path="${path#./}"
  path="${path//\\//}"
  lower="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  basename="${lower##*/}"

  case "$basename" in
    .env|.env.*|*.pem|id_rsa|id_ed25519)
      return 0
      ;;
  esac

  case "$lower" in
    .ssh/id_rsa|*/.ssh/id_rsa|.ssh/id_ed25519|*/.ssh/id_ed25519|*private_key*)
      return 0
      ;;
  esac

  return 1
}

check_secret_path_guard() {
  [[ -z "${EVIDENCE_DIR:-}" ]] && return 0

  local changed_file="$EVIDENCE_DIR/changed_files.txt"
  local secret_file="$EVIDENCE_DIR/secret_paths.txt"
  local guard_file="$EVIDENCE_DIR/secret_path_guard.txt"
  local path count

  : > "$secret_file"
  : > "$guard_file"

  if [[ ! -f "$changed_file" ]]; then
    {
      echo "RESULT: ERROR"
      echo "REASON: changed file evidence is missing"
      echo "TASK: $NEXT_TASK_ID"
    } > "$guard_file"
    return 1
  fi

  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -z "$path" ]] && continue
    if secret_path_guard_match "$path"; then
      printf '%s\n' "$path" >> "$secret_file"
    fi
  done < "$changed_file"

  if [[ -s "$secret_file" ]]; then
    count="$(wc -l < "$secret_file" | tr -d ' \r')"
    {
      echo "RESULT: BLOCKED"
      echo "TASK: $NEXT_TASK_ID"
      echo "SECRET_PATH_COUNT: $count"
      echo "SECRET_PATHS_FILE: ${EVIDENCE_REL}secret_paths.txt"
      echo "SECRET_PATHS:"
      cat "$secret_file"
    } > "$guard_file"
    return 1
  fi

  {
    echo "RESULT: PASS"
    echo "TASK: $NEXT_TASK_ID"
    echo "SECRET_PATH_COUNT: 0"
  } > "$guard_file"
  return 0
}

check_changed_files_scope() {
  [[ -z "${EVIDENCE_DIR:-}" ]] && return 0

  local allowed_file="$EVIDENCE_DIR/allowed_files.txt"
  local changed_file="$EVIDENCE_DIR/changed_files.txt"
  local out_of_scope_file="$EVIDENCE_DIR/out_of_scope.txt"
  local scope_file="$EVIDENCE_DIR/scope_check.txt"
  local allowed_stderr="$EVIDENCE_DIR/allowed_files.stderr"
  local allowed_count changed_count out_count grep_code

  : > "$allowed_file"
  : > "$out_of_scope_file"
  : > "$scope_file"
  : > "$allowed_stderr"

  if ! run_backlog_manager files "$BACKLOG" "$NEXT_TASK_ID" > "$allowed_file" 2> "$allowed_stderr"; then
    {
      echo "RESULT: ERROR"
      echo "REASON: allowed file extraction failed"
      echo "TASK: $NEXT_TASK_ID"
    } > "$scope_file"
    return 1
  fi

  if [[ ! -s "$allowed_file" ]]; then
    {
      echo "RESULT: ERROR"
      echo "REASON: allowed file list is empty"
      echo "TASK: $NEXT_TASK_ID"
    } > "$scope_file"
    return 1
  fi

  if [[ ! -f "$changed_file" ]]; then
    {
      echo "RESULT: ERROR"
      echo "REASON: changed file evidence is missing"
      echo "TASK: $NEXT_TASK_ID"
    } > "$scope_file"
    return 1
  fi

  allowed_count="$(wc -l < "$allowed_file" | tr -d ' \r')"
  changed_count="$(wc -l < "$changed_file" | tr -d ' \r')"

  if [[ ! -s "$changed_file" ]]; then
    {
      echo "RESULT: NO_CHANGES"
      echo "TASK: $NEXT_TASK_ID"
      echo "ALLOWED_COUNT: $allowed_count"
      echo "CHANGED_COUNT: 0"
      echo "OUT_OF_SCOPE_COUNT: 0"
    } > "$scope_file"
    return 0
  fi

  grep -Fvx -f "$allowed_file" "$changed_file" > "$out_of_scope_file" || {
    grep_code=$?
    if [[ "$grep_code" -gt 1 ]]; then
      {
        echo "RESULT: ERROR"
        echo "REASON: scope comparison failed"
        echo "TASK: $NEXT_TASK_ID"
      } > "$scope_file"
      return 1
    fi
  }

  if [[ -s "$out_of_scope_file" ]]; then
    out_count="$(wc -l < "$out_of_scope_file" | tr -d ' \r')"
    {
      echo "RESULT: OUT_OF_SCOPE"
      echo "TASK: $NEXT_TASK_ID"
      echo "ALLOWED_COUNT: $allowed_count"
      echo "CHANGED_COUNT: $changed_count"
      echo "OUT_OF_SCOPE_COUNT: $out_count"
      echo "OUT_OF_SCOPE_FILE: ${EVIDENCE_REL}out_of_scope.txt"
      echo "OUT_OF_SCOPE_FILES:"
      cat "$out_of_scope_file"
    } > "$scope_file"
    return 1
  fi

  {
    echo "RESULT: PASS"
    echo "TASK: $NEXT_TASK_ID"
    echo "ALLOWED_COUNT: $allowed_count"
    echo "CHANGED_COUNT: $changed_count"
    echo "OUT_OF_SCOPE_COUNT: 0"
  } > "$scope_file"
  return 0
}

capture_changed_files_after_implementer() {
  [[ -z "${EVIDENCE_DIR:-}" ]] && return 0

  mkdir -p "$EVIDENCE_DIR"
  local output="$EVIDENCE_DIR/changed_files_after_implementer.txt"
  local stderr_file="$EVIDENCE_DIR/changed_files_after_implementer.stderr"
  local status_file="$EVIDENCE_DIR/changed_files_after_implementer_status.txt"
  local raw_file="$EVIDENCE_DIR/changed_files_after_implementer.raw"

  PROJECT_CHANGE_COUNT=0
  : > "$output"
  : > "$stderr_file"
  : > "$raw_file"

  if git -C "$PROJECT_DIR" status --porcelain --untracked-files=all > "$raw_file" 2> "$stderr_file"; then
    awk '
      {
        path = substr($0, 4)
        if (path !~ /^\.loop-agent(\/|$)/) {
          print $0
        }
      }
    ' "$raw_file" > "$output"
    PROJECT_CHANGE_COUNT="$(wc -l < "$output" | tr -d ' \r')"
    {
      echo "RESULT: PASS"
      echo "PROJECT_CHANGE_COUNT: $PROJECT_CHANGE_COUNT"
      echo "FILE: ${EVIDENCE_REL}changed_files_after_implementer.txt"
    } > "$status_file"
  else
    {
      echo "RESULT: ERROR"
      echo "PROJECT_CHANGE_COUNT: 0"
      echo "STDERR_FILE: ${EVIDENCE_REL}changed_files_after_implementer.stderr"
    } > "$status_file"
  fi
}

run_verify_commands() {
  [[ -z "${EVIDENCE_DIR:-}" ]] && return 0

  local commands_file="$EVIDENCE_DIR/verify_commands.txt"
  local results_file="$EVIDENCE_DIR/verify_results.md"
  local exit_codes_file="$EVIDENCE_DIR/verify_exit_codes.txt"
  local cmd idx code status any_fail stdout_file stderr_file

  [[ ! -f "$commands_file" ]] && return 0

  : > "$results_file"
  : > "$exit_codes_file"

  {
    echo "# Verify Results"
    echo ""
    echo "Timeout seconds: $LOOP_VERIFY_TIMEOUT"
  } >> "$results_file"

  idx=0
  any_fail=0
  while IFS= read -r cmd || [[ -n "$cmd" ]]; do
    [[ -z "$cmd" ]] && continue
    idx=$((idx + 1))
    stdout_file="$EVIDENCE_DIR/verify_command_${idx}.stdout"
    stderr_file="$EVIDENCE_DIR/verify_command_${idx}.stderr"

    if ( cd "$PROJECT_DIR" && timeout "$LOOP_VERIFY_TIMEOUT" bash -lc "$cmd" > "$stdout_file" 2> "$stderr_file" ); then
      code=0
      status="PASS"
    else
      code=$?
      any_fail=1
      if [[ "$code" -eq 124 ]]; then
        status="TIMEOUT"
      else
        status="FAIL"
      fi
    fi

    if [[ "$status" == "TIMEOUT" ]]; then
      echo "command_${idx}=TIMEOUT exit=$code timeout=${LOOP_VERIFY_TIMEOUT}" >> "$exit_codes_file"
    else
      echo "command_${idx}=$status exit=$code" >> "$exit_codes_file"
    fi

    {
      echo ""
      echo "## Command $idx"
      echo ""
      echo "Status: $status"
      echo "Exit code: $code"
      if [[ "$status" == "TIMEOUT" ]]; then
        echo "Timeout seconds: $LOOP_VERIFY_TIMEOUT"
      fi
      echo ""
      echo '```bash'
      echo "$cmd"
      echo '```'
      echo ""
      echo "stdout: ${EVIDENCE_REL}verify_command_${idx}.stdout"
      echo "stderr: ${EVIDENCE_REL}verify_command_${idx}.stderr"
      echo ""
      echo "### stdout"
      echo '```'
      cat "$stdout_file"
      echo '```'
      echo ""
      echo "### stderr"
      echo '```'
      cat "$stderr_file"
      echo '```'
    } >> "$results_file"
  done < "$commands_file"

  {
    echo ""
    echo "Verify results: ${EVIDENCE_REL}verify_results.md"
    echo "Verify exit codes: ${EVIDENCE_REL}verify_exit_codes.txt"
  } >> "$PROGRESS"

  return "$any_fail"
}

append_impl_critic_evidence() {
  local rendered="$1"

  [[ -z "${EVIDENCE_DIR:-}" ]] && return 0

  {
    echo ""
    echo "## Shell Evidence"
    echo ""
    echo "Evidence directory: $EVIDENCE_REL"
    echo "changed_files.txt: ${EVIDENCE_REL}changed_files.txt"
    echo "diff_stat.txt: ${EVIDENCE_REL}diff_stat.txt"
    if [[ -f "$EVIDENCE_DIR/out_of_scope.txt" ]]; then
      echo "out_of_scope.txt: ${EVIDENCE_REL}out_of_scope.txt"
    fi
    if [[ -f "$EVIDENCE_DIR/scope_check.txt" ]]; then
      echo "scope_check.txt: ${EVIDENCE_REL}scope_check.txt"
    fi
    if [[ -f "$EVIDENCE_DIR/verify_results.md" ]]; then
      echo "verify_results.md: ${EVIDENCE_REL}verify_results.md"
    fi
    if [[ -f "$EVIDENCE_DIR/verify_exit_codes.txt" ]]; then
      echo "verify_exit_codes.txt: ${EVIDENCE_REL}verify_exit_codes.txt"
    fi
    echo ""
    echo "### changed_files.txt"
    if [[ -f "$EVIDENCE_DIR/changed_files.txt" ]]; then
      cat "$EVIDENCE_DIR/changed_files.txt"
    else
      echo "(missing)"
    fi
    echo ""
    echo "### diff_stat.txt"
    if [[ -f "$EVIDENCE_DIR/diff_stat.txt" ]]; then
      cat "$EVIDENCE_DIR/diff_stat.txt"
    else
      echo "(missing)"
    fi
    if [[ -f "$EVIDENCE_DIR/out_of_scope.txt" ]]; then
      echo ""
      echo "### out_of_scope.txt"
      cat "$EVIDENCE_DIR/out_of_scope.txt"
    fi
    if [[ -f "$EVIDENCE_DIR/scope_check.txt" ]]; then
      echo ""
      echo "### scope_check.txt"
      cat "$EVIDENCE_DIR/scope_check.txt"
    fi
    if [[ -f "$EVIDENCE_DIR/verify_results.md" ]]; then
      echo ""
      echo "### verify_results.md"
      cat "$EVIDENCE_DIR/verify_results.md"
    fi
    if [[ -f "$EVIDENCE_DIR/verify_exit_codes.txt" ]]; then
      echo ""
      echo "### verify_exit_codes.txt"
      cat "$EVIDENCE_DIR/verify_exit_codes.txt"
    fi
    echo ""
  } >> "$rendered"
}

# ── git_snapshot: snapshot before running Implementer ─────────
capture_project_rollback_untracked_baseline() {
  PROJECT_ROLLBACK_UNTRACKED_EXCLUDES=()

  if ! git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null; then
    return 0
  fi

  local raw_status record status path
  raw_status="$(mktemp)"
  if ! git -C "$PROJECT_DIR" status --porcelain=v1 -z --untracked-files=all > "$raw_status"; then
    rm -f "$raw_status"
    return 0
  fi

  while IFS= read -r -d '' record; do
    [[ -z "$record" ]] && continue
    status="${record:0:2}"
    path="${record:3}"
    path="${path#./}"

    if [[ "$status" == "??" ]]; then
      case "$path" in
        .loop-agent|.loop-agent/*|loop-agent|loop-agent/*) ;;
        *) PROJECT_ROLLBACK_UNTRACKED_EXCLUDES+=("$path") ;;
      esac
    fi
  done < "$raw_status"

  rm -f "$raw_status"
}

git_snapshot() {
  local msg="loop-agent: loop ${LOOP} pre-implementer snapshot"

  # The rollback baseline includes only changes to the implementation target.
  # loop-agent tool files and .loop-agent state files are loop infrastructure
  # and must not be mixed into the pre-implementer snapshot.
  
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" reset -q -- .loop-agent 2>/dev/null || true
  git -C "$PROJECT_DIR" reset -q -- loop-agent 2>/dev/null || true
  if [[ ${#PROJECT_ROLLBACK_UNTRACKED_EXCLUDES[@]} -gt 0 ]]; then
    git -C "$PROJECT_DIR" reset -q -- "${PROJECT_ROLLBACK_UNTRACKED_EXCLUDES[@]}" 2>/dev/null || true
  fi

  # Handle gracefully even when there are no changes
  if ! git -C "$PROJECT_DIR" diff --cached --quiet; then
    git -C "$PROJECT_DIR" commit -q -m "$msg"
  else
    info "git snapshot: no project changes to snapshot"
    return 0
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

    # Exclude the main repo and LoopDex tool repo from nested implementation repo processing.
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

  local -a clean_excludes=(--exclude=.loop-agent/ --exclude=loop-agent/)
  local path
  for path in "${PROJECT_ROLLBACK_UNTRACKED_EXCLUDES[@]}"; do
    clean_excludes+=("--exclude=$path")
  done

  git -C "$repo" clean -fd -q "${clean_excludes[@]}"

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
  append_event "rollback" \
    "status=PASS" \
    "reason=$reason"
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

generate_final_report() {
  local py_cmd
  py_cmd="$(get_python_cmd)"
  if [[ -z "$py_cmd" ]]; then
    warn "final report skipped: python not found."
    return 0
  fi
  if [[ ! -f "$SCRIPT_DIR/scripts/summarize_events.py" ]]; then
    warn "final report skipped: scripts/summarize_events.py not found."
    return 0
  fi
  if ! PYTHONUTF8=1 PYTHONIOENCODING=utf-8 "$py_cmd" "$SCRIPT_DIR/scripts/summarize_events.py" \
    --project "$PROJECT_DIR" \
    --state-dir "$STATE_DIR" \
    --output "$REPORT"; then
    warn "final report generation failed."
    return 0
  fi
  ok "final report generated: $REPORT"
}

build_failure_summary() {
  local stage="$1"
  local verdict="${2:-}"
  local status="${3:-}"
  local evidence_path="${4:-}"
  local summary="$stage failure"
  local suffix prefix_limit

  [[ -n "$verdict" ]] && summary="$summary; verdict=$verdict"
  [[ -n "$status" ]] && summary="$summary; status=$status"
  [[ -n "$evidence_path" ]] && summary="$summary; evidence=$evidence_path"
  summary="$(printf '%s' "$summary" | tr '\r\n\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"

  if [[ ${#summary} -gt 300 ]]; then
    suffix="; evidence=$evidence_path"
    if [[ -n "$evidence_path" && ${#suffix} -lt 300 ]]; then
      prefix_limit=$((300 - ${#suffix} - 3))
      if [[ "$prefix_limit" -gt 0 ]]; then
        summary="${summary:0:$prefix_limit}...$suffix"
      else
        summary="${summary:0:297}..."
      fi
    else
      summary="${summary:0:297}..."
    fi
  fi

  printf '%s\n' "$summary"
}

record_task_failure() {
  local stage="$1"
  local verdict="${2:-}"
  local status="${3:-}"
  local evidence_path="${4:-}"
  local summary

  summary="$(build_failure_summary "$stage" "$verdict" "$status" "$evidence_path")"
  run_backlog_manager fail "$BACKLOG" "$NEXT_TASK_ID" "$LOOP_MAX_ATTEMPTS" "$summary" "$evidence_path"
}

split_task_ids_csv() {
  local specs_file="$1"
  local py_cmd
  py_cmd="$(get_python_cmd)"
  if [[ -z "$py_cmd" || ! -f "$specs_file" ]]; then
    echo ""
    return 0
  fi
  PYTHONUTF8=1 PYTHONIOENCODING=utf-8 $py_cmd - "$specs_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
    specs = json.load(f)
print(", ".join(child.get("id", "") for child in specs if child.get("id")))
PY
}

parse_split_task_specs() {
  local guide_file="$1"
  local output_file="$2"
  local py_cmd
  py_cmd="$(get_python_cmd)"
  if [[ -z "$py_cmd" ]]; then
    echo "python not found"
    return 1
  fi

  PYTHONUTF8=1 PYTHONIOENCODING=utf-8 $py_cmd - "$guide_file" "$output_file" <<'PY'
import json
import re
import sys

guide_path, output_path = sys.argv[1], sys.argv[2]
with open(guide_path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.read().splitlines()

children = []
current = None
current_field = None

def values_from(text):
    ticks = re.findall(r"`([^`]+)`", text)
    if ticks:
        return [value.strip() for value in ticks if value.strip()]
    return [part.strip() for part in text.split(",") if part.strip()]

for line in lines:
    task_match = re.match(r"^\s*(?:[-*]\s+(?:\[[ xX]\]\s*)?|#{3,}\s+)(Task \d+(?:\.\d+)*):\s*(.+?)\s*$", line, re.IGNORECASE)
    if task_match:
        current = {
            "id": task_match.group(1),
            "name": task_match.group(2).strip(),
            "files": [],
            "depends": [],
            "verify": [],
            "completion_criteria": [],
        }
        children.append(current)
        current_field = None
        continue

    if current is None:
        continue

    field_match = re.match(r"^\s+[-*]\s+(File|Files|Depends|Verify|Completion criteria):\s*(.*)$", line, re.IGNORECASE)
    if field_match:
        field = field_match.group(1).lower()
        value = field_match.group(2).strip()
        current_field = field
        if field == "file":
            current["files"].extend(values_from(value))
        elif field == "files":
            current["files"].extend(values_from(value))
        elif field == "depends":
            current["depends"].extend(values_from(value))
        elif field == "verify":
            current["verify"].extend(values_from(value))
        elif field == "completion criteria" and value:
            current["completion_criteria"].append(re.sub(r"^\[[ xX]\]\s*", "", value).strip())
        continue

    item_match = re.match(r"^\s+-\s+(?:\[[ xX]\]\s*)?(.+?)\s*$", line)
    if item_match and current_field == "completion criteria":
        current["completion_criteria"].append(item_match.group(1).strip())

errors = []
if not children:
    errors.append("no child task specs found")
if len(children) > 2:
    errors.append("more than two child task specs found")
for child in children:
    for field in ("id", "name"):
        if not child.get(field):
            errors.append(f"missing {field}")
    for field in ("files", "depends", "verify", "completion_criteria"):
        child[field] = [value for value in child[field] if value]
    for field in ("files", "verify", "completion_criteria"):
        if not child[field]:
            errors.append(f"{child.get('id', 'child')}: missing {field}")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)

with open(output_path, "w", encoding="utf-8") as f:
    json.dump(children, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}

render_current_task_metadata() {
  local py_cmd
  py_cmd="$(get_python_cmd)"
  if [[ -z "$py_cmd" ]]; then
    echo "Current Files: unavailable"
    echo "Current Depends: unavailable"
    echo "Current Verify: unavailable"
    echo "Current Completion criteria: unavailable"
    return 0
  fi

  BACKLOG_PATH="$BACKLOG" \
  TASK_ID="$NEXT_TASK_ID" \
  PYTHONUTF8=1 PYTHONIOENCODING=utf-8 \
    $py_cmd - <<'PY'
import os
import re

backlog = os.environ["BACKLOG_PATH"]
task_id = os.environ["TASK_ID"]
with open(backlog, "r", encoding="utf-8", errors="replace") as f:
    lines = f.read().splitlines()

start = None
end = len(lines)
task_re = re.compile(r"^-\s+\[[ xX!]\]\s+" + re.escape(task_id) + r":")
next_task_re = re.compile(r"^-\s+\[[ xX!]\]\s+Task ")
for i, line in enumerate(lines):
    if task_re.match(line):
        start = i
        continue
    if start is not None and i > start and next_task_re.match(line):
        end = i
        break

block = lines[start:end] if start is not None else []
fields = {"Files": "none", "Depends": "none", "Verify": "none"}
criteria = []
in_criteria = False
for line in block:
    match = re.match(r"^\s+-\s+(Files|Depends|Verify):\s*(.*?)\s*$", line)
    if match:
        fields[match.group(1)] = match.group(2).strip() or "none"
        in_criteria = False
        continue
    match = re.match(r"^\s+-\s+Completion criteria:\s*(.*?)\s*$", line)
    if match:
        value = match.group(1).strip()
        if value:
            criteria.append(re.sub(r"^\[[ xX]\]\s*", "", value).strip())
        in_criteria = True
        continue
    if in_criteria:
        item = re.match(r"^\s+-\s+(?:\[[ xX]\]\s*)?(.+?)\s*$", line)
        if item:
            criteria.append(item.group(1).strip())
        elif line and not line.startswith(" "):
            in_criteria = False

print(f"Current Files: {fields['Files']}")
print(f"Current Depends: {fields['Depends']}")
print(f"Current Verify: {fields['Verify']}")
print("Current Completion criteria: " + ("; ".join(criteria) if criteria else "none"))
PY
}

render_split_task_children() {
  local specs_file="$1"
  local guide="$2"
  local fallback_guide
  local py_cmd
  py_cmd="$(get_python_cmd)"
  if [[ -n "$py_cmd" && -f "$specs_file" ]]; then
    PYTHONUTF8=1 PYTHONIOENCODING=utf-8 $py_cmd - "$specs_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
    specs = json.load(f)

print(f"Suggested child task count: {len(specs)}")
for index, child in enumerate(specs, 1):
    prefix = f"Child {index}"
    print(f"Suggested child task {index}: {child.get('id', '')} - {child.get('name', '')}".strip())
    print(f"{prefix} Files: {', '.join(child.get('files') or ['none'])}")
    print(f"{prefix} Depends: {', '.join(child.get('depends') or ['none'])}")
    print(f"{prefix} Verify: {', '.join(child.get('verify') or ['none'])}")
    print(f"{prefix} Completion criteria: {'; '.join(child.get('completion_criteria') or ['none'])}")
PY
    return 0
  fi

  fallback_guide="$guide"
  if [[ -z "${fallback_guide//[[:space:]]/}" ]]; then
    fallback_guide="No suggested child task descriptions were provided by Impl Critic."
  fi
  echo "Suggested child task count: unknown"
  echo "Suggested child task 1: unparsed split guidance"
  echo "Child 1 Files: unavailable"
  echo "Child 1 Depends: unavailable"
  echo "Child 1 Verify: unavailable"
  echo "Child 1 Completion criteria: $fallback_guide"
}

dependency_task_ids_csv() {
  split_task_ids_csv "$1"
}

parse_dependency_task_specs() {
  parse_split_task_specs "$1" "$2"
}

write_split_task_mutation_evidence() {
  local output_file="$1"
  local outcome="$2"
  local reason="$3"

  {
    echo "# Split Task Mutation Evidence"
    echo ""
    echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
    echo "Mutation type: task_split"
    echo "Outcome: $outcome"
    echo "Reason: $reason"
    echo ""
    echo "## Split guidance"
    if [[ -n "${SPLIT_GUIDE:-}" ]]; then
      printf '%s\n' "$SPLIT_GUIDE"
    else
      echo "none"
    fi
    echo ""
    echo "## Parsed child specs"
    if [[ -f "${SPLIT_SPECS_FILE:-}" ]]; then
      cat "$SPLIT_SPECS_FILE"
    else
      echo "none"
    fi
    echo ""
    echo "## Backlog lint output"
    if [[ -n "${SPLIT_TASK_LINT_OUTPUT:-}" ]]; then
      printf '%s\n' "$SPLIT_TASK_LINT_OUTPUT"
    else
      echo "not run"
    fi
  } > "$output_file"
}

write_dependency_insert_mutation_evidence() {
  local output_file="$1"
  local outcome="$2"
  local reason="$3"

  {
    echo "# Dependency Insert Mutation Evidence"
    echo ""
    echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
    echo "Mutation type: dependency_insert"
    echo "Outcome: $outcome"
    echo "Reason: $reason"
    echo ""
    echo "## Dependency guidance"
    if [[ -n "${DEPENDENCY_GUIDE:-}" ]]; then
      printf '%s\n' "$DEPENDENCY_GUIDE"
    else
      echo "none"
    fi
    echo ""
    echo "## Parsed dependency specs"
    if [[ -f "${DEPENDENCY_SPECS_FILE:-}" ]]; then
      cat "$DEPENDENCY_SPECS_FILE"
    else
      echo "none"
    fi
    echo ""
    echo "## Backlog lint output"
    if [[ -n "${DEPENDENCY_INSERT_LINT_OUTPUT:-}" ]]; then
      printf '%s\n' "$DEPENDENCY_INSERT_LINT_OUTPUT"
    else
      echo "not run"
    fi
  } > "$output_file"
}

scope_expand_paths_csv() {
  local IFS=", "
  printf '%s\n' "$*"
}

scope_expand_reject_reason() {
  local path="$1"
  local check_dir ancestor_found

  path="${path#./}"
  if [[ -z "$path" ]]; then
    echo "empty path"
    return 0
  fi
  if [[ "$path" == /* ]] || [[ "$path" == //* ]] || [[ "$path" == ~* ]] || [[ "$path" =~ ^[A-Za-z]:[\\/] ]]; then
    echo "absolute path"
    return 0
  fi
  if [[ "$path" == *"\\"* ]]; then
    echo "backslash path"
    return 0
  fi
  case "$path" in
    ..|../*|*/..|*/../*)
      echo "parent traversal"
      return 0
      ;;
    .loop-agent|.loop-agent/*|*/.loop-agent|*/.loop-agent/*)
      echo ".loop-agent path"
      return 0
      ;;
  esac
  if secret_path_guard_match "$path"; then
    echo "secret-like path"
    return 0
  fi
  if [[ "$path" != *.* ]] && [[ "$path" != */* ]]; then
    echo "no extension or directory"
    return 0
  fi
  if [[ -e "$PROJECT_DIR/$path" ]]; then
    return 1
  fi

  ancestor_found=0
  check_dir="$(dirname "$path")"
  while [[ "$check_dir" != "." ]] && [[ "$check_dir" != "/" ]] && [[ -n "$check_dir" ]]; do
    if [[ -d "$PROJECT_DIR/$check_dir" ]]; then
      ancestor_found=1
      break
    fi
    check_dir="$(dirname "$check_dir")"
  done
  if [[ $ancestor_found -eq 1 ]] || [[ "$(dirname "$path")" == "." ]]; then
    return 1
  fi

  echo "no existing ancestor in project"
  return 0
}

write_scope_expand_mutation_evidence() {
  local output_file="$1"
  local outcome="$2"
  local reason="$3"

  {
    echo "# Scope Expansion Mutation Evidence"
    echo ""
    echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
    echo "Mutation type: scope_expand"
    echo "Outcome: $outcome"
    echo "Reason: $reason"
    echo ""
    echo "## Requested paths"
    if [[ -n "${EXPAND_RAW:-}" ]]; then
      printf '%s\n' "$EXPAND_RAW" | sed 's/^/- /'
    else
      echo "none"
    fi
    echo ""
    echo "## Accepted paths"
    if [[ ${#EXPAND_ACCEPTED[@]} -gt 0 ]]; then
      for path in "${EXPAND_ACCEPTED[@]}"; do
        echo "- $path"
      done
    else
      echo "none"
    fi
    echo ""
    echo "## Rejected paths"
    if [[ ${#EXPAND_REJECTED[@]} -gt 0 ]]; then
      for path in "${EXPAND_REJECTED[@]}"; do
        echo "- $path"
      done
    else
      echo "none"
    fi
    echo ""
    echo "## Backlog lint output"
    if [[ -n "${SCOPE_EXPAND_LINT_OUTPUT:-}" ]]; then
      printf '%s\n' "$SCOPE_EXPAND_LINT_OUTPUT"
    else
      echo "not run"
    fi
  } > "$output_file"
}

scope_expand_append_backlog_files() {
  [[ $# -gt 0 ]] || return 1

  local py_cmd
  py_cmd="$(get_python_cmd)"
  if [[ -z "$py_cmd" ]]; then
    err "python not found."
    return 1
  fi

  BACKLOG_PATH="$BACKLOG" \
  SCOPE_EXPAND_TASK_ID="$NEXT_TASK_ID" \
  PYTHONUTF8=1 PYTHONIOENCODING=utf-8 \
    $py_cmd - "$@" <<'PY'
import os
import re
import sys

backlog = os.environ["BACKLOG_PATH"]
task_id = os.environ["SCOPE_EXPAND_TASK_ID"]
paths = [p for p in sys.argv[1:] if p]
if not paths:
    print("no paths to append", file=sys.stderr)
    sys.exit(1)

with open(backlog, "r", encoding="utf-8") as f:
    lines = f.readlines()

task_re = re.compile(r"^-\s+\[[ xX]\]\s+" + re.escape(task_id) + r":")
next_task_re = re.compile(r"^-\s+\[[ xX]\]\s+")
start = None
end = len(lines)
for i, line in enumerate(lines):
    if task_re.match(line):
        start = i
        continue
    if start is not None and i > start and next_task_re.match(line):
        end = i
        break

if start is None:
    print(f"task not found: {task_id}", file=sys.stderr)
    sys.exit(2)

files_index = None
files_re = re.compile(r"^(\s*-\s+Files:\s*)(.*?)(\s*)$")
for i in range(start + 1, end):
    if files_re.match(lines[i]):
        files_index = i
        break

if files_index is None:
    print(f"Files line not found for task: {task_id}", file=sys.stderr)
    sys.exit(3)

match = files_re.match(lines[files_index])
prefix, raw, suffix = match.groups()
existing = [item.strip() for item in raw.split(",") if item.strip()]
for path in paths:
    if path not in existing:
        existing.append(path)
lines[files_index] = prefix + ", ".join(existing) + suffix + "\n"

tmp = backlog + ".scope_expand.tmp"
with open(tmp, "w", encoding="utf-8", newline="") as f:
    f.writelines(lines)
os.replace(tmp, backlog)
PY
}

path_in_list() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$needle" == "$item" ]] && return 0
  done
  return 1
}

git_rollback_to_snapshot() {
  local snapshot="$1"
  local reason="${2:-Restore to transaction snapshot}"

  [[ -n "$snapshot" ]] || return 1
  if ! git -C "$PROJECT_DIR" cat-file -e "${snapshot}^{commit}" 2>/dev/null; then
    return 1
  fi

  info "rollback: $reason"

  local state_backup=""
  if [[ -d "$STATE_DIR" ]]; then
    state_backup="$(mktemp -d 2>/dev/null || echo "")"
    if [[ -n "$state_backup" ]]; then
      mkdir -p "$state_backup/.loop-agent"
      cp -a "$STATE_DIR/." "$state_backup/.loop-agent/" 2>/dev/null || true
    fi
  fi

  git -C "$PROJECT_DIR" reset --hard -q "$snapshot"
  git -C "$PROJECT_DIR" clean -fd -q --exclude=.loop-agent/ --exclude=loop-agent/

  if [[ -n "$state_backup" && -d "$state_backup/.loop-agent" ]]; then
    mkdir -p "$STATE_DIR"
    cp -a "$state_backup/.loop-agent/." "$STATE_DIR/" 2>/dev/null || true
    rm -rf "$state_backup"
  fi

  ok "rollback done: transaction snapshot $snapshot"
  append_event "rollback" \
    "status=PASS" \
    "reason=$reason" \
    "snapshot_commit=$snapshot"
  return 0
}

recover_incomplete_transaction() {
  if ! transaction_load_incomplete; then
    return 0
  fi

  NEXT_TASK_ID="$RECOVERY_TASK_ID"
  NEXT_TASK_NAME="$RECOVERY_TASK_NAME"
  EVIDENCE_DIR="$RECOVERY_EVIDENCE_DIR"
  EVIDENCE_REL="$RECOVERY_EVIDENCE_REL"
  TRANSACTION_SNAPSHOT_COMMIT="$RECOVERY_SNAPSHOT_COMMIT"

  local rollback_result="fallback"
  if git_rollback_to_snapshot "$RECOVERY_SNAPSHOT_COMMIT" "Startup recovery to transaction snapshot"; then
    rollback_result="snapshot ${RECOVERY_SNAPSHOT_COMMIT}"
  else
    git_rollback "Startup recovery fallback"
  fi

  local failure_evidence=".loop-agent/current_transaction.json"
  local fail_result
  fail_result="$(record_task_failure "Startup Recovery" "CRASH_RECOVERY" "incomplete stage=${RECOVERY_STAGE:-unknown}" "$failure_evidence" 2>/dev/null || echo "ERROR")"
  if [[ "$fail_result" == "BLOCKED" ]]; then
    warn "Task $NEXT_TASK_ID blocked after startup recovery failure recording."
  fi

  {
    echo ""
    echo "=== Loop 0: Startup Recovery ==="
    echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
    echo "Recovered stage: ${RECOVERY_STAGE:-unknown}"
    echo "Snapshot commit: ${RECOVERY_SNAPSHOT_COMMIT:-none}"
    echo "Rollback: $rollback_result"
    echo "Evidence preserved: ${RECOVERY_EVIDENCE_REL:-none}"
    echo "Backlog fail result: $fail_result"
    echo "Task completion: skipped"
    echo ""
  } >> "$PROGRESS"

  transaction_complete "RECOVERED"
  add_result "Before start: RECOVERED - $NEXT_TASK_ID"
  build_progress_window

  NEXT_TASK_ID=""
  NEXT_TASK_NAME=""
  EVIDENCE_DIR=""
  EVIDENCE_REL=""
  TRANSACTION_SNAPSHOT_COMMIT=""
}

# ── setup_phase: generate backlog.md ──────────────────────────
setup_phase() {
  if [[ "${RUN_MODE_NONINTERACTIVE:-0}" == "1" ]]; then
    err "run mode cannot enter setup. Run ./loop.sh init first."
    exit 1
  fi

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
      echo -e "${YELLOW}  Setup Critic invalid or non-PASS verdict → retrying Setup Agent${RESET}"
      if (( attempt >= max_setup_attempts )); then
        err "Setup Agent did not receive a valid PASS verdict after ${max_setup_attempts} attempts."
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

if [[ "$LOOP_MODE" == "init" ]]; then
  bootstrap_language_gitignore
  warn_placeholder_model
  cleanup_orphaned_backups
  if [[ "${LOOP_BACKLOG_SOURCE:-generated}" == "user" ]]; then
    # User-provided backlog: skip Setup Agent / Setup Critic and lint instead.
    if [[ ! -f "$BACKLOG" ]]; then
      err "LOOP_BACKLOG_SOURCE=user but $BACKLOG is missing."
      echo "  Place your hand-written backlog at $BACKLOG and re-run init," >&2
      echo "  or delete .loop-agent/config.env to re-run the wizard and pick 'Generate'." >&2
      exit 1
    fi
    info "Using user-provided backlog (Setup Agent skipped)"
    if ! BACKLOG_LINT_OUT="$(run_backlog_manager lint "$BACKLOG" 2>&1)"; then
      err "Backlog lint failed for $BACKLOG"
      echo "$BACKLOG_LINT_OUT" >&2
      echo "  Fix the issues above (see backlog_guide.md) and re-run init." >&2
      exit 1
    fi
    ok "Backlog lint: passed"
  else
    setup_phase
  fi
  warn_unsafe_branch
  ok "Init complete. Backlog: $BACKLOG"
  exit 0
fi

# Clean up .protected files left by a prior abnormal exit (SIGKILL, system crash, etc.).
# Called before entering Setup Phase so backlog.md baseline is also protected.
cleanup_orphaned_backups

# ── Setup Phase: auto-run if backlog.md is missing ────────────
if [[ ! -f "$BACKLOG" ]]; then
  if [[ "$RUN_MODE_NONINTERACTIVE" == "1" ]]; then
    err "run mode requires .loop-agent/backlog.md. Run ./loop.sh init first."
    exit 1
  fi
  setup_phase
fi

if [[ "$RUN_MODE_NONINTERACTIVE" == "1" ]]; then
  BACKLOG_LINT_OUTPUT="$(run_backlog_manager lint "$BACKLOG" 2>&1)" || {
    BACKLOG_LINT_STATUS="failed"
    err "Backlog lint failed."
    echo "$BACKLOG_LINT_OUTPUT" >&2
    exit 1
  }
  BACKLOG_LINT_STATUS="passed"
else
  BACKLOG_LINT_STATUS="not required"
fi

print_safety_summary_banner

banner "Loop Agent  ·  ${MAX_LOOPS} loops  ·  $(basename "$PROJECT_DIR")"
echo -e "  Project: ${BOLD}$PROJECT_DIR${RESET}"
echo -e "  Log:     ${GRAY}$STATE_DIR/codex.log${RESET}"
case "$LOOP_CLI" in
  codex)  echo -e "  CLI:      ${CYAN}codex${RESET} (model: $CODEX_MODEL)" ;;
  gemini) echo -e "  CLI:      ${CYAN}gemini${RESET} (model: $GEMINI_MODEL)" ;;
esac
echo -e "  Risk mode: $LOOP_RISK_MODE"

warn_placeholder_model
warn_unsafe_branch

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

recover_incomplete_transaction

# Print initial backlog progress
run_backlog_manager progress "$BACKLOG" 2>/dev/null || true
echo ""

for (( LOOP=1; LOOP<=MAX_LOOPS; LOOP++ )); do

  # ── Check backlog completion/blocked state ───────────────────
  BL_STATUS="$(run_backlog_manager status "$BACKLOG" 2>/dev/null || echo '{}')"
  BL_COMPLETE="$(echo "$BL_STATUS" | grep -o '"complete":[^,}]*' | cut -d: -f2 | tr -d ' "' || echo false)"
  BL_PENDING="$(echo "$BL_STATUS" | grep -o '"pending":[^,}]*' | cut -d: -f2 | tr -d ' "' || echo 1)"
  BL_BLOCKED="$(echo "$BL_STATUS" | grep -o '"blocked":[^,}]*' | cut -d: -f2 | tr -d ' "' || echo 0)"
  append_event "loop_start" \
    "status=STARTED" \
    "backlog_complete=$BL_COMPLETE" \
    "pending_count=$BL_PENDING" \
    "blocked_count=$BL_BLOCKED"

  if [[ "$BL_COMPLETE" == "true" ]]; then
    ok "All tasks complete! Backlog exhausted."
    run_backlog_manager progress "$BACKLOG" 2>/dev/null || true
    {
      echo ""
      echo "=== Loop ${LOOP}: Backlog Complete ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Result: SUCCESS"
      echo "Reason: completed backlog"
      echo "Final decision: PASS (backlog already complete)"
      echo "Exit code: 0"
      echo ""
    } >> "$PROGRESS"
    append_event "run_complete" \
      "status=PASS" \
      "reason=backlog_complete"
    add_result "Loop ${LOOP}: SUCCESS (backlog complete)"
    break
  fi

  if [[ "$BL_PENDING" == "0" ]] && [[ "$BL_BLOCKED" != "0" ]]; then
    echo -e "${YELLOW}⚠ Cannot continue: all remaining tasks are BLOCKED.${RESET}"
    run_backlog_manager progress "$BACKLOG" 2>/dev/null || true
    append_event "decision" \
      "outcome=BLOCKED" \
      "status=BLOCKED" \
      "reason=all_remaining_tasks_blocked" \
      "pending_count=$BL_PENDING" \
      "blocked_count=$BL_BLOCKED"
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

  EVIDENCE_DIR="$EVIDENCE_ROOT/loop-$LOOP"
  EVIDENCE_REL=".loop-agent/evidence/loop-$LOOP/"
  mkdir -p "$EVIDENCE_DIR"
  apply_evidence_retention || warn "Evidence retention failed; continuing."
  TRANSACTION_SNAPSHOT_COMMIT=""
  transaction_write "selected"
  {
    echo ""
    echo "Evidence: $EVIDENCE_REL"
  } >> "$PROGRESS"
  info "Evidence: $EVIDENCE_REL"

  VERIFY_COMMANDS_FILE="$EVIDENCE_DIR/verify_commands.txt"
  VERIFY_COMMANDS_ERR="$EVIDENCE_DIR/verify_commands.stderr"
  VERIFY_COMMANDS_CHECK="$EVIDENCE_DIR/verify_commands_check.txt"
  VERIFY_POLICY_FILE="$EVIDENCE_DIR/verify_command_policy.txt"
  append_event "task_selected" \
    "status=SELECTED" \
    "current_task_path=.loop-agent/current_task.md" \
    "verify_commands_path=${EVIDENCE_REL}verify_commands.txt" \
    "verify_results_path=${EVIDENCE_REL}verify_results.md" \
    "verify_exit_codes_path=${EVIDENCE_REL}verify_exit_codes.txt"
  transaction_write "verify_commands"
  : > "$VERIFY_COMMANDS_FILE"
  : > "$VERIFY_COMMANDS_ERR"
  if ! run_backlog_manager verify "$BACKLOG" "$NEXT_TASK_ID" > "$VERIFY_COMMANDS_FILE" 2> "$VERIFY_COMMANDS_ERR"; then
    {
      echo "RESULT: FAIL"
      echo "REASON: verify command extraction failed"
      echo "TASK: $NEXT_TASK_ID"
      echo "STDERR_FILE: ${EVIDENCE_REL}verify_commands.stderr"
    } > "$VERIFY_COMMANDS_CHECK"
    {
      echo ""
      echo "=== Loop ${LOOP}: Verify command extraction BLOCKED ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID — $NEXT_TASK_NAME"
      echo "Result: FAIL"
      echo "Reason: verify command extraction failed"
      echo "Evidence: $EVIDENCE_REL"
      echo "Verify commands: ${EVIDENCE_REL}verify_commands.txt"
      echo "Verify check: ${EVIDENCE_REL}verify_commands_check.txt"
      echo ""
    } >> "$PROGRESS"
    add_result "Loop ${LOOP}: BLOCKED (missing verify command) — $NEXT_TASK_ID"
    print_results
    transaction_complete "BLOCKED"
    err "Verify command extraction failed for $NEXT_TASK_ID. Evidence: ${EVIDENCE_REL}verify_commands_check.txt"
    exit 1
  fi
  if [[ ! -s "$VERIFY_COMMANDS_FILE" ]]; then
    {
      echo "RESULT: FAIL"
      echo "REASON: verify command list is empty"
      echo "TASK: $NEXT_TASK_ID"
      echo "VERIFY_COMMANDS_FILE: ${EVIDENCE_REL}verify_commands.txt"
    } > "$VERIFY_COMMANDS_CHECK"
    {
      echo ""
      echo "=== Loop ${LOOP}: Verify command extraction BLOCKED ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID — $NEXT_TASK_NAME"
      echo "Result: FAIL"
      echo "Reason: verify command list is empty"
      echo "Evidence: $EVIDENCE_REL"
      echo "Verify commands: ${EVIDENCE_REL}verify_commands.txt"
      echo "Verify check: ${EVIDENCE_REL}verify_commands_check.txt"
      echo ""
    } >> "$PROGRESS"
    add_result "Loop ${LOOP}: BLOCKED (missing verify command) — $NEXT_TASK_ID"
    print_results
    transaction_complete "BLOCKED"
    err "Verify command list is empty for $NEXT_TASK_ID. Evidence: ${EVIDENCE_REL}verify_commands_check.txt"
    exit 1
  fi
  if ! check_verify_command_policy "$VERIFY_COMMANDS_FILE" "$VERIFY_POLICY_FILE"; then
    PROPOSALS_DIR="$STATE_DIR/proposals"
    mkdir -p "$PROPOSALS_DIR"
    SAFE_TASK_ID="${NEXT_TASK_ID//[^A-Za-z0-9_.-]/_}"
    PROPOSAL_FILE="$PROPOSALS_DIR/verify_command_policy_loop_${LOOP}_${SAFE_TASK_ID}.md"
    POLICY_REASON="$(grep -m1 "^BLOCKED:" "$VERIFY_POLICY_FILE" 2>/dev/null | sed 's/^BLOCKED: //' || echo "verify command policy blocked a command")"
    write_proposal_report \
      "$PROPOSAL_FILE" \
      "Verify Command Policy Blocked" \
      "$NEXT_TASK_ID" \
      "$NEXT_TASK_NAME" \
      "BLOCKED" \
      "Review or replace the denied verify command." \
      "$POLICY_REASON" \
      "${EVIDENCE_REL}verify_command_policy.txt"
    {
      echo ""
      echo "## Denied verify commands"
      cat "$VERIFY_POLICY_FILE"
    } >> "$PROPOSAL_FILE"
    {
      echo "RESULT: FAIL"
      echo "REASON: verify command policy blocked a command"
      echo "TASK: $NEXT_TASK_ID"
      echo "VERIFY_COMMANDS_FILE: ${EVIDENCE_REL}verify_commands.txt"
      echo "POLICY_FILE: ${EVIDENCE_REL}verify_command_policy.txt"
      echo "PROPOSAL_FILE: $PROPOSAL_FILE"
    } > "$VERIFY_COMMANDS_CHECK"
    {
      echo ""
      echo "=== Loop ${LOOP}: Verify command policy BLOCKED ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID ??$NEXT_TASK_NAME"
      echo "Result: FAIL"
      echo "Reason: $POLICY_REASON"
      echo "Evidence: $EVIDENCE_REL"
      echo "Verify commands: ${EVIDENCE_REL}verify_commands.txt"
      echo "Policy file: ${EVIDENCE_REL}verify_command_policy.txt"
      echo "Proposal: $PROPOSAL_FILE"
      echo ""
    } >> "$PROGRESS"
    add_result "Loop ${LOOP}: BLOCKED (verify command policy) ??$NEXT_TASK_ID"
    print_results
    transaction_complete "BLOCKED"
    err "Verify command policy blocked $NEXT_TASK_ID. Evidence: ${EVIDENCE_REL}verify_command_policy.txt"
    exit 1
  fi
  {
    echo "RESULT: PASS"
    echo "TASK: $NEXT_TASK_ID"
    echo "VERIFY_COMMANDS_FILE: ${EVIDENCE_REL}verify_commands.txt"
    echo "POLICY_FILE: ${EVIDENCE_REL}verify_command_policy.txt"
  } > "$VERIFY_COMMANDS_CHECK"
  {
    echo "Verify commands: ${EVIDENCE_REL}verify_commands.txt"
  } >> "$PROGRESS"
  info "Verify commands: ${EVIDENCE_REL}verify_commands.txt"

  TASK_FAIL_COUNT="$(get_task_fail_count "$BACKLOG" "$NEXT_TASK_ID")"
  TASK_FAIL_COUNT="${TASK_FAIL_COUNT:-0}"
  TASK_LAST_FAILURE_SUMMARY="$(bound_retry_context_value "$(get_task_metadata_field "$BACKLOG" "$NEXT_TASK_ID" "Last failure summary")")"
  TASK_EVIDENCE_PATH="$(bound_retry_context_value "$(get_task_metadata_field "$BACKLOG" "$NEXT_TASK_ID" "Evidence path")")"
  {
    printf '\n## Retry context (bounded)\n\n'
    printf '%s\n' "- Fail count: $TASK_FAIL_COUNT"
    printf '%s\n' "- Last failure summary: $TASK_LAST_FAILURE_SUMMARY"
    printf '%s\n' "- Evidence path: $TASK_EVIDENCE_PATH"
  } >> "$CURRENT_TASK"
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
  transaction_write "scan_before"
  scan_project "$FILE_INDEX_BEFORE" "before"
  truncate_progress_if_large  # prevent unbounded growth (keep 50 most recent if over 512KB)
  build_progress_window  # progress.txt → extract most recent 3 sections
  # Reset temp files for current loop
  rm -f "$PLAN" "$PLAN_CRITIQUE" "$IMPL_SUMMARY" "$IMPL_CRITIQUE"

  # ────────────────────────────────────────────────────────────
  # Phase 1: Planner
  # ────────────────────────────────────────────────────────────
  phase "Phase 1 · Planner"
  transaction_write "planner"
  snapshot_state_files "Planner" "$PLAN"
  render "$AGENTS_DIR/planner.md" "$STATE_DIR/planner_rendered.md"

  if ! run_agent "Planner" "$STATE_DIR/planner_rendered.md" "$PLAN" "$PLANNER_EFFORT"; then
    restore_state_files_if_modified "Planner"
    if detect_rate_limit; then
      suspend_for_rate_limit "Planner"
    fi
    add_result "Loop ${LOOP}: ERROR (codex error - Planner)"
    print_results
    transaction_complete "ERROR"
    err "Planner codex process failed. Log: $STATE_DIR/codex.log"
    exit 1
  fi
  restore_state_files_if_modified "Planner"
  if backlog_semantic_guard_failed "Planner"; then
    transaction_complete "FAIL"
    continue
  fi

  # Print Planner summary (Goal line)
  PLAN_GOAL=$(grep "^## Goal" -A1 "$PLAN" 2>/dev/null | tail -1 || echo "(no goal)")
  info "Plan goal: $PLAN_GOAL"

  # Check for codex errors first, then detect ERROR: in plan.md
  if grep -q "^ERROR:" "$PLAN" 2>/dev/null; then
    add_result "Loop ${LOOP}: ERROR (no dev document)"
    print_results
    transaction_complete "ERROR"
    err "Dev document not found. Check plan.md:"
    err "  cat $PLAN"
    exit 1
  fi

  # ────────────────────────────────────────────────────────────
  # Phase 2: Plan Critic
  # ────────────────────────────────────────────────────────────
  phase "Phase 2 · Plan Critic"
  transaction_write "plan_critic"
  snapshot_state_files "Plan Critic" "$PLAN_CRITIQUE"
  render "$AGENTS_DIR/plan_critic.md" "$STATE_DIR/plan_critic_rendered.md"

  if ! run_agent "Plan Critic" "$STATE_DIR/plan_critic_rendered.md" "$PLAN_CRITIQUE" "$PLAN_CRITIC_EFFORT"; then
    restore_state_files_if_modified "Plan Critic"
    if detect_rate_limit; then
      suspend_for_rate_limit "Plan Critic"
    fi
    add_result "Loop ${LOOP}: ERROR (codex error - Plan Critic)"
    print_results
    transaction_complete "ERROR"
    err "Plan Critic codex process failed. Log: $STATE_DIR/codex.log"
    exit 1
  fi
  restore_state_files_if_modified "Plan Critic"
  if backlog_semantic_guard_failed "Plan Critic"; then
    transaction_complete "FAIL"
    continue
  fi

  PLAN_VERDICT="$(check_verdict "$PLAN_CRITIQUE")"
  info "Plan verdict: $PLAN_VERDICT"

  if decision_is_invalid_verdict "$PLAN_VERDICT"; then
    add_result "Loop ${LOOP}: ERROR (missing or malformed VERDICT - Plan Critic)"
    print_results
    transaction_complete "ERROR"
    err "Plan Critic did not output a valid final VERDICT."
    exit 1
  fi

  if [[ "$PLAN_VERDICT" == "FAIL" ]]; then
    echo -e "${YELLOW}  Plan FAIL → increment fail count + record in progress.txt → next loop${RESET}"

    FAIL_RESULT="$(record_task_failure "Plan Critic" "$PLAN_VERDICT" "FAIL loop=$LOOP" ".loop-agent/plan_critique.md" 2>/dev/null || echo "ERROR")"
    if [[ "$FAIL_RESULT" == "BLOCKED" ]]; then
      echo -e "${RED}  Task $NEXT_TASK_ID BLOCKED ($LOOP_MAX_ATTEMPTS consecutive failures)${RESET}"
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
    transaction_complete "FAIL"
    continue
  fi
  

  # Print Plan Critic Notes
  PLAN_NOTES=$(grep "^## Notes" -A2 "$PLAN_CRITIQUE" 2>/dev/null | grep -v "^## Notes" | head -1 || echo "none")
  ok "Plan PASS (Notes: $PLAN_NOTES)"

  # ────────────────────────────────────────────────────────────
  # Phase 3: Implementer
  # ────────────────────────────────────────────────────────────
  phase "Phase 3 · Implementer"
  capture_project_rollback_untracked_baseline
  git_snapshot  # git snapshot before running Implementer
  TRANSACTION_SNAPSHOT_COMMIT="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "")"
  transaction_write "implementer_snapshot"
  transaction_write "implementer"
  snapshot_state_files "Implementer" "$IMPL_SUMMARY"
  render "$AGENTS_DIR/implementer.md" "$STATE_DIR/implementer_rendered.md"

  if ! run_agent "Implementer" "$STATE_DIR/implementer_rendered.md" "$IMPL_SUMMARY" "$IMPLEMENTER_EFFORT"; then
    restore_state_files_if_modified "Implementer"  # restore even on failure
    if detect_rate_limit; then
      suspend_for_rate_limit "Implementer"
    fi
    add_result "Loop ${LOOP}: ERROR (codex error - Implementer)"
    print_results
    transaction_complete "ERROR"
    err "Implementer codex process failed. Log: $STATE_DIR/codex.log"
    exit 1
  fi
  restore_state_files_if_modified "Implementer"  # restore on normal exit too
  if backlog_semantic_guard_failed "Implementer"; then
    transaction_complete "FAIL"
    continue
  fi
  capture_git_evidence
  capture_changed_files_after_implementer
  transaction_write "secret_path_guard"
  if ! check_secret_path_guard; then
    FAIL_RESULT="$(record_task_failure "Secret Path Guard" "FAIL" "blocked secret path loop=$LOOP" "${EVIDENCE_REL}secret_path_guard.txt" 2>/dev/null || echo "ERROR")"
    if [[ "$FAIL_RESULT" == "BLOCKED" ]]; then
      echo -e "${RED}  Task $NEXT_TASK_ID BLOCKED ($LOOP_MAX_ATTEMPTS consecutive failures)${RESET}"
    fi

    {
      echo ""
      echo "=== Loop ${LOOP}: Secret Path Guard FAIL ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
      cat "$EVIDENCE_DIR/secret_path_guard.txt"
      echo "Evidence: $EVIDENCE_REL"
      echo "Secret paths: ${EVIDENCE_REL}secret_paths.txt"
      echo "Backlog fail result: $FAIL_RESULT"
      echo "Final decision: FAIL (secret path guard blocked implementation)"
      echo ""
    } >> "$PROGRESS"

    git_rollback "secret path guard - discard partial implementation"
    append_shell_report "FAIL" "Secret Path Guard"
    {
      echo "### Secret Path Guard"
      echo ""
      echo "- Final decision: FAIL (secret path guard blocked implementation)"
      echo "- Secret paths: ${EVIDENCE_REL}secret_paths.txt"
      echo "- Rollback: implementation changes discarded"
      echo "- PASS commit: skipped"
      echo ""
    } >> "$REPORT"
    add_result "Loop ${LOOP}: FAIL (secret path guard) - $NEXT_TASK_ID"
    transaction_complete "FAIL"
    continue
  fi
  transaction_write "scope_check"
  SCOPE_CHECK_FAILED=0
  if ! check_changed_files_scope; then
    SCOPE_CHECK_FAILED=1
    phase "Phase 4 - Impl Critic"
    transaction_write "impl_critic"
    snapshot_state_files "Impl Critic" "$IMPL_CRITIQUE"
    render "$AGENTS_DIR/impl_critic.md" "$STATE_DIR/impl_critic_rendered.md"
    append_impl_critic_evidence "$STATE_DIR/impl_critic_rendered.md"

    if ! run_agent "Impl Critic" "$STATE_DIR/impl_critic_rendered.md" "$IMPL_CRITIQUE" "$IMPL_CRITIC_EFFORT"; then
      restore_state_files_if_modified "Impl Critic"
      if detect_rate_limit; then
        suspend_for_rate_limit "Impl Critic"
      fi
    else
      restore_state_files_if_modified "Impl Critic"
    fi
    if backlog_semantic_guard_failed "Impl Critic"; then
      transaction_complete "FAIL"
      continue
    fi
    IMPL_VERDICT="$(check_verdict "$IMPL_CRITIQUE")"
    if [[ "$IMPL_VERDICT" == "MALFORMED" ]] && grep -q '^VERDICT: SCOPE_EXPAND' "$IMPL_CRITIQUE" 2>/dev/null; then
      IMPL_VERDICT="SCOPE_EXPAND"
    elif [[ "$IMPL_VERDICT" == "MALFORMED" ]] && grep -q '^VERDICT: SPLIT_TASK' "$IMPL_CRITIQUE" 2>/dev/null; then
      IMPL_VERDICT="SPLIT_TASK"
    fi
    info "Implementation verdict: $IMPL_VERDICT"
    if [[ "$IMPL_VERDICT" == "SCOPE_EXPAND" || "$IMPL_VERDICT" == "SPLIT_TASK" ]]; then
      echo -e "${YELLOW}  Scope check deferred to ${IMPL_VERDICT} policy${RESET}"
    else
      FAIL_RESULT="$(record_task_failure "Scope Check" "OUT_OF_SCOPE" "FAIL loop=$LOOP" "${EVIDENCE_REL}scope_check.txt" 2>/dev/null || echo "ERROR")"
      if [[ "$FAIL_RESULT" == "BLOCKED" ]]; then
        echo -e "${RED}  Task $NEXT_TASK_ID BLOCKED ($LOOP_MAX_ATTEMPTS consecutive failures)${RESET}"
      fi
    git_rollback "scope check failure — discard partial implementation"
    {
      echo ""
      echo "=== Loop ${LOOP}: Scope Check Rollback ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID — $NEXT_TASK_NAME"
      echo "Result: FAIL"
      echo "Rollback: implementation changes discarded"
      echo "PASS commit: skipped"
      echo "Evidence preserved: $EVIDENCE_REL"
      echo "Out of scope file: ${EVIDENCE_REL}out_of_scope.txt"
      echo "Backlog fail result: $FAIL_RESULT"
      echo ""
    } >> "$PROGRESS"
    append_shell_report "FAIL" "Scope Check"
    add_result "Loop ${LOOP}: FAIL (scope check) — $NEXT_TASK_ID"
    transaction_complete "FAIL"
    continue
    fi
  fi

  if [[ "$SCOPE_CHECK_FAILED" != "1" ]]; then
  VERIFY_RESULT=0
  VERIFY_STATUS="PASS"
  transaction_write "verify"
  if run_verify_commands; then
    info "Verify results: ${EVIDENCE_REL}verify_results.md"
  else
    VERIFY_RESULT=$?
    if grep -q "TIMEOUT" "$EVIDENCE_DIR/verify_exit_codes.txt" 2>/dev/null; then
      VERIFY_STATUS="TIMEOUT"
    else
      VERIFY_STATUS="FAIL"
    fi
    warn "Verify command(s) failed. Evidence: ${EVIDENCE_REL}verify_results.md"
  fi
  VERIFY_COMMAND_COUNT="$(awk 'NF {count++} END {print count+0}' "$EVIDENCE_DIR/verify_commands.txt" 2>/dev/null || echo 0)"
  append_event "verify_result" \
    "status=$VERIFY_STATUS" \
    "verify_exit_code=$VERIFY_RESULT" \
    "command_count=$VERIFY_COMMAND_COUNT" \
    "verify_commands_path=${EVIDENCE_REL}verify_commands.txt" \
    "verify_results_path=${EVIDENCE_REL}verify_results.md" \
    "verify_exit_codes_path=${EVIDENCE_REL}verify_exit_codes.txt"

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
  transaction_write "impl_critic"
  snapshot_state_files "Impl Critic" "$IMPL_CRITIQUE"
  render "$AGENTS_DIR/impl_critic.md" "$STATE_DIR/impl_critic_rendered.md"
  append_impl_critic_evidence "$STATE_DIR/impl_critic_rendered.md"

  if ! run_agent "Impl Critic" "$STATE_DIR/impl_critic_rendered.md" "$IMPL_CRITIQUE" "$IMPL_CRITIC_EFFORT"; then
    restore_state_files_if_modified "Impl Critic"
    if detect_rate_limit; then
      suspend_for_rate_limit "Impl Critic"
    fi
    add_result "Loop ${LOOP}: ERROR (codex error - Impl Critic)"
    print_results
    transaction_complete "ERROR"
    err "Impl Critic codex process failed. Log: $STATE_DIR/codex.log"
    exit 1
  fi
  restore_state_files_if_modified "Impl Critic"
  if backlog_semantic_guard_failed "Impl Critic"; then
    transaction_complete "FAIL"
    continue
  fi

  IMPL_VERDICT="$(check_verdict "$IMPL_CRITIQUE")"
  if [[ "$IMPL_VERDICT" == "MALFORMED" ]] && grep -q '^VERDICT: SCOPE_EXPAND' "$IMPL_CRITIQUE" 2>/dev/null; then
    IMPL_VERDICT="SCOPE_EXPAND"
  elif [[ "$IMPL_VERDICT" == "MALFORMED" ]] && grep -q '^VERDICT: SPLIT_TASK' "$IMPL_CRITIQUE" 2>/dev/null; then
    IMPL_VERDICT="SPLIT_TASK"
  fi
  info "Implementation verdict: $IMPL_VERDICT"
  fi

  if decision_is_invalid_verdict "$IMPL_VERDICT" && [[ "$IMPL_VERDICT" != "SPLIT_TASK" ]]; then
    echo -e "${YELLOW}  Impl Critic verdict invalid -> rollback + record failure -> next loop${RESET}"
    FAIL_RESULT="$(record_task_failure "Impl Critic" "$IMPL_VERDICT" "invalid verdict loop=$LOOP" ".loop-agent/impl_critique.md" 2>/dev/null || echo "ERROR")"
    git_rollback "Impl Critic invalid verdict - discard partial implementation"
    if [[ "$FAIL_RESULT" == "BLOCKED" ]]; then
      echo -e "${RED}  Task $NEXT_TASK_ID BLOCKED ($LOOP_MAX_ATTEMPTS consecutive failures)${RESET}"
    fi
    {
      echo ""
      echo "=== Loop ${LOOP}: Impl Critic Invalid Verdict ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
      echo "Impl Critic verdict: $IMPL_VERDICT"
      cat "$IMPL_CRITIQUE"
      echo "Backlog fail result: $FAIL_RESULT"
      echo "Final decision: FAIL (missing or malformed Impl Critic VERDICT)"
      echo "PASS commit: skipped"
      echo ""
    } >> "$PROGRESS"
    append_shell_report "FAIL" "Impl Critic Verdict"
    add_result "Loop ${LOOP}: FAIL (Impl Critic verdict) - $NEXT_TASK_ID"
    transaction_complete "FAIL"
    continue
  fi

  if [[ "$IMPL_VERDICT" == "PASS" ]] && [[ "${VERIFY_RESULT:-0}" -ne 0 ]]; then
    echo -e "${YELLOW}  Shell verify ${VERIFY_STATUS} overrides Impl Critic PASS${RESET}"
    FAIL_RESULT="$(record_task_failure "Shell Verify" "PASS" "$VERIFY_STATUS loop=$LOOP" "${EVIDENCE_REL}verify_results.md" 2>/dev/null || echo "ERROR")"
    if [[ "$FAIL_RESULT" == "BLOCKED" ]]; then
      echo -e "${RED}  Task $NEXT_TASK_ID BLOCKED ($LOOP_MAX_ATTEMPTS consecutive failures)${RESET}"
    fi

    {
      echo ""
      echo "=== Loop ${LOOP}: Shell Verify FAIL ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID ??$NEXT_TASK_NAME"
      echo "Impl Critic verdict: PASS"
      echo "Verify result: $VERIFY_STATUS"
      echo "Evidence: $EVIDENCE_REL"
      echo "Verify results: ${EVIDENCE_REL}verify_results.md"
      echo "Verify exit codes: ${EVIDENCE_REL}verify_exit_codes.txt"
      echo "Backlog fail result: $FAIL_RESULT"
      echo "Final decision: FAIL (shell verify overrides Impl Critic PASS)"
      echo ""
    } >> "$PROGRESS"

    git_rollback "shell verify ${VERIFY_STATUS} ??discard partial implementation"
    append_shell_report "FAIL" "Shell Verify"
    {
      echo "### Shell Verify Override"
      echo ""
      echo "- Final decision: FAIL (shell verify overrides Impl Critic PASS)"
      echo "- Verify result: $VERIFY_STATUS"
      echo "- Verify results: ${EVIDENCE_REL}verify_results.md"
      echo "- Verify exit codes: ${EVIDENCE_REL}verify_exit_codes.txt"
      echo "- Rollback: implementation changes discarded"
      echo "- PASS commit: skipped"
      echo ""
    } >> "$REPORT"
    add_result "Loop ${LOOP}: FAIL (shell verify) ??$NEXT_TASK_ID"
    transaction_complete "FAIL"
    continue
  fi

  if [[ "$IMPL_VERDICT" == "PASS" ]] && [[ "${PROJECT_CHANGE_COUNT:-0}" -eq 0 ]]; then
    echo -e "${YELLOW}  No-change result overrides Impl Critic PASS${RESET}"
    FAIL_RESULT="$(record_task_failure "No-change" "PASS" "no project changes loop=$LOOP" "${EVIDENCE_REL}no_change_failure.md" 2>/dev/null || echo "ERROR")"
    if [[ "$FAIL_RESULT" == "BLOCKED" ]]; then
      echo -e "${RED}  Task $NEXT_TASK_ID BLOCKED ($LOOP_MAX_ATTEMPTS consecutive failures)${RESET}"
    fi

    {
      echo "# No-change Failure"
      echo ""
      echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
      echo "Impl Critic verdict: PASS"
      echo "Project change count after Implementer: 0"
      echo "Changed-file evidence: ${EVIDENCE_REL}changed_files_after_implementer.txt"
      echo "Final decision: FAIL (no project files changed after Implementer)"
      echo "PASS commit: skipped"
    } > "$EVIDENCE_DIR/no_change_failure.md"

    {
      echo ""
      echo "=== Loop ${LOOP}: No-change FAIL ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID ??$NEXT_TASK_NAME"
      echo "Impl Critic verdict: PASS"
      echo "Project change count after Implementer: 0"
      echo "Changed-file evidence: ${EVIDENCE_REL}changed_files_after_implementer.txt"
      echo "No-change failure: ${EVIDENCE_REL}no_change_failure.md"
      echo "Backlog fail result: $FAIL_RESULT"
      echo "Final decision: FAIL (no project files changed after Implementer)"
      echo ""
    } >> "$PROGRESS"

    git_rollback "no-change result ??discard partial implementation"
    append_shell_report "FAIL" "No-change"
    {
      echo "### No-change Override"
      echo ""
      echo "- Final decision: FAIL (no project files changed after Implementer)"
      echo "- Changed-file evidence: ${EVIDENCE_REL}changed_files_after_implementer.txt"
      echo "- No-change failure: ${EVIDENCE_REL}no_change_failure.md"
      echo "- Rollback: implementation changes discarded"
      echo "- PASS commit: skipped"
      echo ""
    } >> "$REPORT"
    add_result "Loop ${LOOP}: FAIL (no-change) ??$NEXT_TASK_ID"
    transaction_complete "FAIL"
    continue
  fi

  if [[ "$IMPL_VERDICT" == "BLOCKED" ]]; then
    BLOCK_EVIDENCE_FILE="$EVIDENCE_DIR/blocked_reason.md"
    BLOCK_REASON="$(decision_extract_block_reason "$IMPL_CRITIQUE" "Impl Critic returned BLOCKED.")"

    {
      echo "# Impl Critic BLOCKED"
      echo ""
      echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
      echo "Verdict: $IMPL_VERDICT"
      echo "Reason: $BLOCK_REASON"
      echo "Evidence directory: $EVIDENCE_REL"
      echo ""
      echo "## Critique"
      if [[ -f "$IMPL_CRITIQUE" ]]; then
        head -c 12000 "$IMPL_CRITIQUE"
        echo ""
      else
        echo "impl_critique.md was not found."
      fi
    } > "$BLOCK_EVIDENCE_FILE"

    echo -e "${YELLOW}  Implementation BLOCKED -> rollback + mark task blocked -> next loop${RESET}"
    git_rollback "Impl Critic BLOCKED - discard partial implementation"
    BLOCK_RESULT="$(run_backlog_manager block "$BACKLOG" "$NEXT_TASK_ID" "$BLOCK_REASON" "$IMPL_VERDICT" "$EVIDENCE_REL" 2>/dev/null || echo "ERROR")"
    {
      echo ""
      echo "=== Loop ${LOOP}: Impl BLOCKED ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
      echo "Impl Critic verdict: $IMPL_VERDICT"
      echo "Blocked reason: $BLOCK_REASON"
      echo "Evidence: $EVIDENCE_REL"
      echo "Blocked evidence: ${EVIDENCE_REL}blocked_reason.md"
      echo "Backlog block result: $BLOCK_RESULT"
      echo "Rollback: implementation changes discarded"
      echo "Final decision: BLOCKED (Impl Critic verdict was BLOCKED)"
      echo "PASS commit: skipped"
      echo ""
    } >> "$PROGRESS"
    append_shell_report "BLOCKED" "Impl Critic BLOCKED"
    {
      echo "### BLOCKED lifecycle"
      echo ""
      echo "- Evidence: ${EVIDENCE_REL}"
      echo "- Blocked evidence: ${EVIDENCE_REL}blocked_reason.md"
      echo "- Blocked reason: $BLOCK_REASON"
      echo "- Backlog block result: $BLOCK_RESULT"
      echo "- Rollback: implementation changes discarded"
      echo "- PASS commit: skipped"
      echo ""
    } >> "$REPORT"
    add_result "Loop ${LOOP}: BLOCKED (Impl Critic) - $NEXT_TASK_ID"
    transaction_complete "BLOCKED"
    continue
  fi

  if [[ "$IMPL_VERDICT" == "SPLIT_TASK" ]]; then
    echo -e "${YELLOW}  Split proposal requested${RESET}"
    SPLIT_GUIDE="$(awk '
      BEGIN{f=0}
      tolower($0) ~ /^## split task/ || tolower($0) ~ /^## suggested child tasks/ || tolower($0) ~ /^## suggested tasks/ {f=1; next}
      f && /^## / {exit}
      f {print}
    ' "$IMPL_CRITIQUE" | tr -d '\r')"
    if [[ -z "$SPLIT_GUIDE" ]]; then
      SPLIT_GUIDE="$(tr -d '\r' < "$IMPL_CRITIQUE")"
    fi
    PROPOSALS_DIR="$STATE_DIR/proposals"
    mkdir -p "$PROPOSALS_DIR"
    SAFE_TASK_ID="${NEXT_TASK_ID//[^A-Za-z0-9_.-]/_}"
    PROPOSAL_FILE="$PROPOSALS_DIR/split_task_loop_${LOOP}_${SAFE_TASK_ID}.md"
    PROPOSAL_EVIDENCE_FILE="$EVIDENCE_DIR/proposal_verdict.md"
    SPLIT_GUIDE_FILE="$EVIDENCE_DIR/split_task_guidance.md"
    SPLIT_SPECS_FILE="$EVIDENCE_DIR/split_task_specs.json"
    SPLIT_TASK_EVIDENCE_FILE="$EVIDENCE_DIR/split_task_mutation.md"
    SPLIT_TASK_LINT_OUTPUT=""
    SPLIT_TASK_EVENT_OUTCOME="rejected"
    SPLIT_TASK_REASON="split task requires review before backlog task list changes"
    printf '%s\n' "$SPLIT_GUIDE" > "$SPLIT_GUIDE_FILE"
    if ! SPLIT_TASK_LINT_OUTPUT="$(parse_split_task_specs "$SPLIT_GUIDE_FILE" "$SPLIT_SPECS_FILE" 2>&1)"; then
      rm -f "$SPLIT_SPECS_FILE"
    fi
    SPLIT_TASK_CURRENT_METADATA="$(render_current_task_metadata)"
    SPLIT_TASK_CHILD_DETAILS="$(render_split_task_children "$SPLIT_SPECS_FILE" "$SPLIT_GUIDE")"
    SPLIT_TASK_CHILD_IDS="$(split_task_ids_csv "$SPLIT_SPECS_FILE")"
    [[ -n "$SPLIT_TASK_CHILD_IDS" ]] || SPLIT_TASK_CHILD_IDS="$NEXT_TASK_ID"
    SPLIT_TASK_CHILD_COUNT="unknown"
    if [[ -f "$SPLIT_SPECS_FILE" ]]; then
      SPLIT_TASK_COUNT_PY="$(get_python_cmd)"
      if [[ -n "$SPLIT_TASK_COUNT_PY" ]]; then
        SPLIT_TASK_CHILD_COUNT="$(PYTHONUTF8=1 PYTHONIOENCODING=utf-8 $SPLIT_TASK_COUNT_PY - "$SPLIT_SPECS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
    print(len(json.load(f)))
PY
)"
      fi
    fi
    [[ -n "$SPLIT_TASK_CHILD_COUNT" ]] || SPLIT_TASK_CHILD_COUNT="unknown"

    append_event "mutation" \
      "mutation_type=task_split" \
      "outcome=attempted" \
      "status=attempted" \
      "reason=impl_critic_split_task" \
      "affected_paths=$SPLIT_TASK_CHILD_IDS" \
      "evidence_location=${EVIDENCE_REL}split_task_mutation.md"

    write_split_task_mutation_evidence "$SPLIT_TASK_EVIDENCE_FILE" "$SPLIT_TASK_EVENT_OUTCOME" "$SPLIT_TASK_REASON"
    append_event "mutation" \
      "mutation_type=task_split" \
      "outcome=$SPLIT_TASK_EVENT_OUTCOME" \
      "status=$SPLIT_TASK_EVENT_OUTCOME" \
      "reason=$SPLIT_TASK_REASON" \
      "affected_paths=$(split_task_ids_csv "$SPLIT_SPECS_FILE")" \
      "evidence_location=${EVIDENCE_REL}split_task_mutation.md"

    write_proposal_report \
      "$PROPOSAL_FILE" \
      "Split Task Proposal" \
      "$NEXT_TASK_ID" \
      "$NEXT_TASK_NAME" \
      "SPLIT_TASK" \
      "Split the current task into reviewed child tasks." \
      "Impl Critic reported that the task should be split before more implementation." \
      "$EVIDENCE_REL"
    {
      echo ""
      echo "No backlog task list, Files, Depends, verify command, or completion criteria change was applied."
      echo ""
      echo "## Current task metadata"
      printf '%s\n' "$SPLIT_TASK_CURRENT_METADATA"
      echo ""
      echo "## Reason and split guidance"
      if [[ -n "$SPLIT_GUIDE" ]]; then
        echo "$SPLIT_GUIDE"
      else
        echo "No split guidance was provided by Impl Critic."
      fi
      echo ""
      echo "## Suggested child tasks"
      printf '%s\n' "$SPLIT_TASK_CHILD_DETAILS"
      echo ""
      echo "## Mutation outcome"
      echo "$SPLIT_TASK_EVENT_OUTCOME"
      echo ""
      echo "## Mutation reason"
      echo "$SPLIT_TASK_REASON"
    } >> "$PROPOSAL_FILE"
    {
      echo "# Proposal Verdict Evidence"
      echo ""
      echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
      echo "Verdict: $IMPL_VERDICT"
      echo "Proposal: $PROPOSAL_FILE"
      echo "Evidence directory: $EVIDENCE_REL"
      echo "Mutation evidence: ${EVIDENCE_REL}split_task_mutation.md"
      echo ""
      echo "## Critique"
      if [[ -f "$IMPL_CRITIQUE" ]]; then
        head -c 12000 "$IMPL_CRITIQUE"
        echo ""
      else
        echo "impl_critique.md was not found."
      fi
    } > "$PROPOSAL_EVIDENCE_FILE"
    BLOCK_REASON="Split task proposal requires review before more implementation."
    BLOCK_RESULT="$(run_backlog_manager block "$BACKLOG" "$NEXT_TASK_ID" "$BLOCK_REASON" "$IMPL_VERDICT" "$EVIDENCE_REL" 2>/dev/null || echo "ERROR")"
    git_rollback "SPLIT_TASK - discard partial implementation"
    {
      echo ""
      echo "=== Loop ${LOOP}: Split Task Proposal ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
      echo "Proposal: $PROPOSAL_FILE"
      echo "Evidence: $EVIDENCE_REL"
      echo "Proposal evidence: ${EVIDENCE_REL}proposal_verdict.md"
      echo "Mutation evidence: ${EVIDENCE_REL}split_task_mutation.md"
      echo "Mutation outcome: $SPLIT_TASK_EVENT_OUTCOME"
      echo "Mutation reason: $SPLIT_TASK_REASON"
      echo "Original task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
      echo "Blocked reason: $BLOCK_REASON"
      echo "Verdict source: Impl Critic SPLIT_TASK"
      printf '%s\n' "$SPLIT_TASK_CURRENT_METADATA"
      printf '%s\n' "$SPLIT_TASK_CHILD_DETAILS"
      echo "Backlog block result: $BLOCK_RESULT"
      echo "Fail count unchanged: ${TASK_FAIL_COUNT:-0}"
      echo "Semantic backlog fields unchanged: Files, Depends, verify command, and completion criteria"
      echo "Recommended action: Review the split proposal and manually replace the blocked task with child tasks if appropriate."
      echo "Rollback: implementation changes discarded"
      echo "No backlog task list, Files, Depends, verify command, or completion criteria change was applied."
      echo "PASS commit: skipped"
      echo ""
    } >> "$PROGRESS"
    append_shell_report "BLOCKED" "Impl Critic SPLIT_TASK"
    {
      echo "### BLOCKED: SPLIT_TASK"
      echo ""
      echo "- Reason: $BLOCK_REASON"
      echo "- Original task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
      echo "- Fail count unchanged: ${TASK_FAIL_COUNT:-0}"
      echo "- Suggested child task count: $SPLIT_TASK_CHILD_COUNT"
      echo "- Action required: Review the split proposal and manually replace the blocked task with child tasks if appropriate."
      echo "- Recommended action: Review the split proposal and manually replace the blocked task with child tasks if appropriate."
      echo ""
      echo "### SPLIT_TASK proposal lifecycle"
      echo ""
      echo "- Evidence: ${EVIDENCE_REL}"
      echo "- Proposal evidence: ${EVIDENCE_REL}proposal_verdict.md"
      echo "- Mutation evidence: ${EVIDENCE_REL}split_task_mutation.md"
      echo "- Mutation outcome: $SPLIT_TASK_EVENT_OUTCOME"
      echo "- Mutation reason: $SPLIT_TASK_REASON"
      echo "- Proposal: $PROPOSAL_FILE"
      echo "- Blocked reason: $BLOCK_REASON"
      echo "- Backlog block result: $BLOCK_RESULT"
      echo "- Rollback: implementation changes discarded"
      echo "- PASS commit: skipped"
      echo ""
    } >> "$REPORT"
    ok "split task proposal written: $PROPOSAL_FILE"
    warn "BLOCKED (SPLIT_TASK): $BLOCK_REASON"
    echo "  BLOCKED: SPLIT_TASK"
    echo "  Action required: Review the split proposal and manually replace the blocked task with child tasks if appropriate."
    echo "  Fail count unchanged: ${TASK_FAIL_COUNT:-0}"
    add_result "Loop ${LOOP}: SPLIT_TASK proposal - $NEXT_TASK_ID"
    append_event "blocked" \
      "outcome=BLOCKED" \
      "status=BLOCKED" \
      "task_id=$NEXT_TASK_ID" \
      "block_type=SPLIT_TASK" \
      "reason=$BLOCK_REASON" \
      "recommended_action=Review the split proposal and manually replace the blocked task with child tasks if appropriate." \
      "suggested_child_task_count=$SPLIT_TASK_CHILD_COUNT" \
      "fail_count_unchanged=true"
    transaction_complete "SPLIT_TASK"
    continue
  fi

  if [[ "$IMPL_VERDICT" == "DEPENDENCY_INSERT" ]]; then
    echo -e "${YELLOW}  Dependency insertion requested${RESET}"
    DEPENDENCY_GUIDE="$(awk '
      BEGIN{f=0}
      /^## Dependency insertion/ || /^## Dependency insert/ {f=1; next}
      f && /^## / {exit}
      f {print}
    ' "$IMPL_CRITIQUE" | tr -d '\r')"
    git_rollback "DEPENDENCY_INSERT - discard partial implementation"
    PROPOSALS_DIR="$STATE_DIR/proposals"
    mkdir -p "$PROPOSALS_DIR"
    SAFE_TASK_ID="${NEXT_TASK_ID//[^A-Za-z0-9_.-]/_}"
    PROPOSAL_FILE="$PROPOSALS_DIR/dependency_insert_loop_${LOOP}_${SAFE_TASK_ID}.md"
    PROPOSAL_EVIDENCE_FILE="$EVIDENCE_DIR/proposal_verdict.md"
    DEPENDENCY_GUIDE_FILE="$EVIDENCE_DIR/dependency_insert_guidance.md"
    DEPENDENCY_SPECS_FILE="$EVIDENCE_DIR/dependency_insert_specs.json"
    DEPENDENCY_INSERT_EVIDENCE_FILE="$EVIDENCE_DIR/dependency_insert_mutation.md"
    DEPENDENCY_INSERT_LINT_OUTPUT=""
    DEPENDENCY_INSERT_EVENT_OUTCOME="rejected"
    DEPENDENCY_INSERT_REASON="LOOP_ALLOW_AUTO_DEPENDENCY_INSERT is not 1"
    DEPENDENCY_INSERT_CAN_MUTATE=0
    printf '%s\n' "$DEPENDENCY_GUIDE" > "$DEPENDENCY_GUIDE_FILE"

    append_event "mutation" \
      "mutation_type=dependency_insert" \
      "outcome=attempted" \
      "status=attempted" \
      "reason=impl_critic_dependency_insert" \
      "affected_paths=$NEXT_TASK_ID" \
      "evidence_location=${EVIDENCE_REL}dependency_insert_mutation.md"

    if [[ "${LOOP_ALLOW_AUTO_DEPENDENCY_INSERT:-}" == "1" ]]; then
      if ! DEPENDENCY_PARSE_OUTPUT="$(parse_dependency_task_specs "$DEPENDENCY_GUIDE_FILE" "$DEPENDENCY_SPECS_FILE" 2>&1)"; then
        DEPENDENCY_INSERT_REASON="invalid dependency guidance: $DEPENDENCY_PARSE_OUTPUT"
        DEPENDENCY_INSERT_EVENT_OUTCOME="rejected"
      else
        DEPENDENCY_INSERT_CAN_MUTATE=1
        DEPENDENCY_INSERT_REASON="accepted"
        DEPENDENCY_INSERT_EVENT_OUTCOME="accepted"
      fi
    fi

    if [[ "$DEPENDENCY_INSERT_CAN_MUTATE" == "1" ]]; then
      BACKLOG_DEPENDENCY_INSERT_BACKUP="$EVIDENCE_DIR/backlog_before_dependency_insert.md"
      cp "$BACKLOG" "$BACKLOG_DEPENDENCY_INSERT_BACKUP"
      if ! DEPENDENCY_INSERT_MUTATE_OUTPUT="$(run_backlog_manager insert-dependency "$BACKLOG" "$NEXT_TASK_ID" "$DEPENDENCY_SPECS_FILE" "Dependency inserted before current task." "$IMPL_VERDICT" "$EVIDENCE_REL" 2>&1)"; then
        cp "$BACKLOG_DEPENDENCY_INSERT_BACKUP" "$BACKLOG"
        DEPENDENCY_INSERT_REASON="backlog dependency insertion failed: $DEPENDENCY_INSERT_MUTATE_OUTPUT"
        DEPENDENCY_INSERT_EVENT_OUTCOME="blocked"
        DEPENDENCY_INSERT_CAN_MUTATE=0
      elif ! DEPENDENCY_INSERT_LINT_OUTPUT="$(run_backlog_manager lint "$BACKLOG" 2>&1)"; then
        cp "$BACKLOG_DEPENDENCY_INSERT_BACKUP" "$BACKLOG"
        DEPENDENCY_INSERT_REASON="backlog lint failed"
        DEPENDENCY_INSERT_EVENT_OUTCOME="blocked"
        DEPENDENCY_INSERT_CAN_MUTATE=0
      else
        write_dependency_insert_mutation_evidence "$DEPENDENCY_INSERT_EVIDENCE_FILE" "$DEPENDENCY_INSERT_EVENT_OUTCOME" "$DEPENDENCY_INSERT_REASON"
        append_event "mutation" \
          "mutation_type=dependency_insert" \
          "outcome=accepted" \
          "status=accepted" \
          "reason=$DEPENDENCY_INSERT_REASON" \
          "affected_paths=$(dependency_task_ids_csv "$DEPENDENCY_SPECS_FILE")" \
          "evidence_location=${EVIDENCE_REL}dependency_insert_mutation.md"
        {
          echo ""
          echo "=== Loop ${LOOP}: Dependency Insert Accepted ==="
          echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
          echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
          echo "Evidence: $EVIDENCE_REL"
          echo "Mutation evidence: ${EVIDENCE_REL}dependency_insert_mutation.md"
          echo "Inserted tasks: $(dependency_task_ids_csv "$DEPENDENCY_SPECS_FILE")"
          echo "Backlog lint: passed"
          echo "Rollback: implementation changes discarded"
          echo "PASS commit: skipped"
          echo ""
        } >> "$PROGRESS"
        {
          echo "### DEPENDENCY_INSERT accepted"
          echo ""
          echo "- Evidence: ${EVIDENCE_REL}"
          echo "- Mutation evidence: ${EVIDENCE_REL}dependency_insert_mutation.md"
          echo "- Inserted tasks: $(dependency_task_ids_csv "$DEPENDENCY_SPECS_FILE")"
          echo "- Backlog lint: passed"
          echo "- Rollback: implementation changes discarded"
          echo "- PASS commit: skipped"
          echo ""
        } >> "$REPORT"
        ok "dependency insertion accepted: $(dependency_task_ids_csv "$DEPENDENCY_SPECS_FILE")"
        add_result "Loop ${LOOP}: DEPENDENCY_INSERT accepted - $NEXT_TASK_ID"
        transaction_complete "DEPENDENCY_INSERT"
        continue
      fi
    fi

    write_dependency_insert_mutation_evidence "$DEPENDENCY_INSERT_EVIDENCE_FILE" "$DEPENDENCY_INSERT_EVENT_OUTCOME" "$DEPENDENCY_INSERT_REASON"
    append_event "mutation" \
      "mutation_type=dependency_insert" \
      "outcome=$DEPENDENCY_INSERT_EVENT_OUTCOME" \
      "status=$DEPENDENCY_INSERT_EVENT_OUTCOME" \
      "reason=$DEPENDENCY_INSERT_REASON" \
      "affected_paths=$(dependency_task_ids_csv "$DEPENDENCY_SPECS_FILE")" \
      "evidence_location=${EVIDENCE_REL}dependency_insert_mutation.md"

    BLOCK_REASON="Dependency insertion proposal requires review before more implementation."
    write_proposal_report \
      "$PROPOSAL_FILE" \
      "Dependency Insert Proposal" \
      "$NEXT_TASK_ID" \
      "$NEXT_TASK_NAME" \
      "DEPENDENCY_INSERT" \
      "Insert reviewed dependency tasks before the current task." \
      "Impl Critic reported that dependency work is required before more implementation." \
      "$EVIDENCE_REL"
    {
      echo ""
      echo "No backlog task list, Files, Depends, verify command, or completion criteria change was applied."
      echo ""
      echo "## Reason and dependency guidance"
      if [[ -n "$DEPENDENCY_GUIDE" ]]; then
        echo "$DEPENDENCY_GUIDE"
      else
        echo "No dependency guidance was provided by Impl Critic."
      fi
      echo ""
      echo "## Mutation outcome"
      echo "$DEPENDENCY_INSERT_EVENT_OUTCOME"
      echo ""
      echo "## Mutation reason"
      echo "$DEPENDENCY_INSERT_REASON"
    } >> "$PROPOSAL_FILE"
    {
      echo "# Proposal Verdict Evidence"
      echo ""
      echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
      echo "Verdict: $IMPL_VERDICT"
      echo "Proposal: $PROPOSAL_FILE"
      echo "Evidence directory: $EVIDENCE_REL"
      echo "Mutation evidence: ${EVIDENCE_REL}dependency_insert_mutation.md"
      echo ""
      echo "## Critique"
      if [[ -f "$IMPL_CRITIQUE" ]]; then
        head -c 12000 "$IMPL_CRITIQUE"
        echo ""
      else
        echo "impl_critique.md was not found."
      fi
    } > "$PROPOSAL_EVIDENCE_FILE"
    BLOCK_RESULT="$(run_backlog_manager block "$BACKLOG" "$NEXT_TASK_ID" "$BLOCK_REASON" "$IMPL_VERDICT" "$EVIDENCE_REL" 2>/dev/null || echo "ERROR")"
    {
      echo ""
      echo "=== Loop ${LOOP}: Dependency Insert Proposal ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
      echo "Proposal: $PROPOSAL_FILE"
      echo "Evidence: $EVIDENCE_REL"
      echo "Proposal evidence: ${EVIDENCE_REL}proposal_verdict.md"
      echo "Mutation evidence: ${EVIDENCE_REL}dependency_insert_mutation.md"
      echo "Mutation outcome: $DEPENDENCY_INSERT_EVENT_OUTCOME"
      echo "Mutation reason: $DEPENDENCY_INSERT_REASON"
      echo "Blocked reason: $BLOCK_REASON"
      echo "Backlog block result: $BLOCK_RESULT"
      echo "Rollback: implementation changes discarded"
      echo "No backlog task list, Files, Depends, verify command, or completion criteria change was applied."
      echo "PASS commit: skipped"
      echo ""
    } >> "$PROGRESS"
    append_shell_report "BLOCKED" "Impl Critic DEPENDENCY_INSERT"
    {
      echo "### DEPENDENCY_INSERT proposal lifecycle"
      echo ""
      echo "- Evidence: ${EVIDENCE_REL}"
      echo "- Proposal evidence: ${EVIDENCE_REL}proposal_verdict.md"
      echo "- Mutation evidence: ${EVIDENCE_REL}dependency_insert_mutation.md"
      echo "- Mutation outcome: $DEPENDENCY_INSERT_EVENT_OUTCOME"
      echo "- Mutation reason: $DEPENDENCY_INSERT_REASON"
      echo "- Proposal: $PROPOSAL_FILE"
      echo "- Blocked reason: $BLOCK_REASON"
      echo "- Backlog block result: $BLOCK_RESULT"
      echo "- Rollback: implementation changes discarded"
      echo "- PASS commit: skipped"
      echo ""
    } >> "$REPORT"
    ok "dependency insertion proposal written: $PROPOSAL_FILE"
    add_result "Loop ${LOOP}: DEPENDENCY_INSERT proposal - $NEXT_TASK_ID"
    transaction_complete "DEPENDENCY_INSERT"
    continue
  fi

  if [[ "$IMPL_VERDICT" == "SCOPE_EXPAND" ]]; then
    echo -e "${YELLOW}  Scope expansion requested${RESET}"

    EXPAND_ITEMS="$(awk '
      BEGIN{f=0}
      /^## Scope expansion needed/ || /^## Requested files/ || /^## Additional files needed/ {f=1; next}
      f && /^## / {exit}
      f && /^- / {print}
    ' "$IMPL_CRITIQUE" | tr -d '\r')"

    EXPAND_RAW="$(awk '
      BEGIN{f=0}
      /^## Scope expansion needed/ || /^## Requested files/ || /^## Additional files needed/ {f=1; next}
      f && /^## / {exit}
      f && /^- / {
        if (match($0, /`[^`]+`/)) {
          path = substr($0, RSTART+1, RLENGTH-2)
          print path
          next
        }
        path = $0
        sub(/^- /, "", path)
        sub(/[[:space:]].*$/, "", path)
        if (path != "") {
          print path
        }
      }
    ' "$IMPL_CRITIQUE" | tr -d '\r' | sort -u)"

    EXPAND_VALID=()
    EXPAND_ACCEPTED=()
    EXPAND_REJECTED=()
    EXPAND_REQUESTED=()
    SCOPE_EXPAND_LINT_OUTPUT=""
    SCOPE_EXPAND_EVIDENCE_FILE="$EVIDENCE_DIR/scope_expand_mutation.md"
    SCOPE_EXPAND_EVENT_OUTCOME="rejected"
    SCOPE_EXPAND_REASON="scope expansion requires review before backlog Files change"
    SCOPE_EXPAND_ALLOWED_FILES="none"
    if SCOPE_EXPAND_ALLOWED_RAW="$(run_backlog_manager files "$BACKLOG" "$NEXT_TASK_ID" 2>/dev/null)"; then
      SCOPE_EXPAND_ALLOWED_FILES="$(printf '%s\n' "$SCOPE_EXPAND_ALLOWED_RAW" | awk 'NF { printf "%s`%s`", sep, $0; sep=", " } END { if (sep == "") print "none"; else print "" }')"
    else
      SCOPE_EXPAND_ALLOWED_FILES="unavailable"
    fi
    SCOPE_EXPAND_REQUESTED_FILES="$(printf '%s\n' "$EXPAND_RAW" | awk 'NF { printf "%s`%s`", sep, $0; sep=", " } END { if (sep == "") print "none"; else print "" }')"
    mapfile -t EXPAND_REQUESTED <<< "$EXPAND_RAW"

    append_event "mutation" \
      "mutation_type=scope_expand" \
      "outcome=attempted" \
      "status=attempted" \
      "reason=impl_critic_scope_expand" \
      "affected_paths=$(scope_expand_paths_csv "${EXPAND_REQUESTED[@]}")" \
      "evidence_location=${EVIDENCE_REL}scope_expand_mutation.md"

    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      if reject_reason="$(scope_expand_reject_reason "$path")"; then
        EXPAND_REJECTED+=("$path ($reject_reason)")
      else
        EXPAND_VALID+=("$path")
      fi
    done <<< "$EXPAND_RAW"

    PROPOSALS_DIR="$STATE_DIR/proposals"
    mkdir -p "$PROPOSALS_DIR"
    SAFE_TASK_ID="${NEXT_TASK_ID//[^A-Za-z0-9_.-]/_}"
    PROPOSAL_FILE="$PROPOSALS_DIR/scope_expand_loop_${LOOP}_${SAFE_TASK_ID}.md"
    PROPOSAL_EVIDENCE_FILE="$EVIDENCE_DIR/proposal_verdict.md"

    if [[ ${#EXPAND_REJECTED[@]} -gt 0 ]]; then
      warn "SCOPE_EXPAND rejected ${#EXPAND_REJECTED[@]} item(s):"
      for r in "${EXPAND_REJECTED[@]}"; do
        echo "    - $r"
      done
    fi

    write_scope_expand_mutation_evidence "$SCOPE_EXPAND_EVIDENCE_FILE" "$SCOPE_EXPAND_EVENT_OUTCOME" "$SCOPE_EXPAND_REASON"
    append_event "mutation" \
      "mutation_type=scope_expand" \
      "outcome=$SCOPE_EXPAND_EVENT_OUTCOME" \
      "status=$SCOPE_EXPAND_EVENT_OUTCOME" \
      "reason=$SCOPE_EXPAND_REASON" \
      "affected_paths=$(scope_expand_paths_csv "${EXPAND_ACCEPTED[@]}")" \
      "evidence_location=${EVIDENCE_REL}scope_expand_mutation.md"

    BLOCK_REASON="Scope expansion proposal requires review before more implementation."
    write_proposal_report \
      "$PROPOSAL_FILE" \
      "Scope Expansion Proposal" \
      "$NEXT_TASK_ID" \
      "$NEXT_TASK_NAME" \
      "SCOPE_EXPAND" \
      "Expand the task Files scope for reviewed requested files." \
      "Impl Critic requested files outside the approved task scope." \
      "$EVIDENCE_REL"
    {
      echo ""
      echo "No backlog Files, Depends, verify command, or completion criteria change was applied."
      echo ""
      echo "## Requested files"
      if [[ -n "$EXPAND_ITEMS" ]]; then
        echo "$EXPAND_ITEMS"
      else
        echo "none"
      fi
      echo ""
      echo "## Valid requested files"
      if [[ ${#EXPAND_VALID[@]} -gt 0 ]]; then
        for path in "${EXPAND_VALID[@]}"; do
          echo "- \`$path\`"
        done
      else
        echo "none"
      fi
      echo ""
      echo "## Rejected requested files"
      if [[ ${#EXPAND_REJECTED[@]} -gt 0 ]]; then
        for path in "${EXPAND_REJECTED[@]}"; do
          echo "- $path"
        done
      else
        echo "none"
      fi
    } >> "$PROPOSAL_FILE"
    {
      echo "# Proposal Verdict Evidence"
      echo ""
      echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
      echo "Verdict: $IMPL_VERDICT"
      echo "Proposal: $PROPOSAL_FILE"
      echo "Evidence directory: $EVIDENCE_REL"
      echo "Mutation evidence: ${EVIDENCE_REL}scope_expand_mutation.md"
      echo ""
      echo "## Critique"
      if [[ -f "$IMPL_CRITIQUE" ]]; then
        head -c 12000 "$IMPL_CRITIQUE"
        echo ""
      else
        echo "impl_critique.md was not found."
      fi
    } > "$PROPOSAL_EVIDENCE_FILE"
    BLOCK_RESULT="$(run_backlog_manager block "$BACKLOG" "$NEXT_TASK_ID" "$BLOCK_REASON" "$IMPL_VERDICT" "$EVIDENCE_REL" 2>/dev/null || echo "ERROR")"
    git_rollback "SCOPE_EXPAND - discard partial implementation"
    {
      echo ""
      echo "=== Loop ${LOOP}: Scope Expand Proposal ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
      echo "Proposal: $PROPOSAL_FILE"
      echo "Evidence: $EVIDENCE_REL"
      echo "Evidence directory: $EVIDENCE_REL"
      echo "Proposal evidence: ${EVIDENCE_REL}proposal_verdict.md"
      echo "Mutation evidence: ${EVIDENCE_REL}scope_expand_mutation.md"
      echo "Mutation outcome: $SCOPE_EXPAND_EVENT_OUTCOME"
      echo "Mutation reason: $SCOPE_EXPAND_REASON"
      echo "Blocked reason: $BLOCK_REASON"
      echo "Verdict source: Impl Critic SCOPE_EXPAND"
      echo "Current allowed Files: $SCOPE_EXPAND_ALLOWED_FILES"
      echo "Requested additional files: $SCOPE_EXPAND_REQUESTED_FILES"
      echo "Backlog block result: $BLOCK_RESULT"
      echo "Fail count unchanged: ${TASK_FAIL_COUNT:-0}"
      echo "Semantic backlog fields unchanged: Files, Depends, verify command, and completion criteria"
      echo "Recommended action: Review the scope expansion proposal and manually update backlog.md Files if appropriate."
      echo "Rollback: implementation changes discarded"
      echo "No backlog Files, Depends, verify command, or completion criteria change was applied."
      echo "PASS commit: skipped"
      echo ""
    } >> "$PROGRESS"
    append_shell_report "BLOCKED" "Impl Critic SCOPE_EXPAND"
    {
      echo "### BLOCKED: SCOPE_EXPAND"
      echo ""
      echo "- Reason: $BLOCK_REASON"
      echo "- Requested files: $SCOPE_EXPAND_REQUESTED_FILES"
      echo "- Fail count unchanged: ${TASK_FAIL_COUNT:-0}"
      echo "- Action required: Review the scope expansion proposal and manually update backlog.md Files if appropriate."
      echo "- Recommended action: Review the scope expansion proposal and manually update backlog.md Files if appropriate."
      echo ""
      echo "### SCOPE_EXPAND proposal lifecycle"
      echo ""
      echo "- Evidence: ${EVIDENCE_REL}"
      echo "- Proposal evidence: ${EVIDENCE_REL}proposal_verdict.md"
      echo "- Mutation evidence: ${EVIDENCE_REL}scope_expand_mutation.md"
      echo "- Mutation outcome: $SCOPE_EXPAND_EVENT_OUTCOME"
      echo "- Mutation reason: $SCOPE_EXPAND_REASON"
      echo "- Proposal: $PROPOSAL_FILE"
      echo "- Blocked reason: $BLOCK_REASON"
      echo "- Backlog block result: $BLOCK_RESULT"
      echo "- Rollback: implementation changes discarded"
      echo "- PASS commit: skipped"
      echo ""
    } >> "$REPORT"
    ok "scope expansion proposal written: $PROPOSAL_FILE"
    warn "BLOCKED (SCOPE_EXPAND): $BLOCK_REASON"
    echo "  BLOCKED: SCOPE_EXPAND"
    echo "  Action required: Review the scope expansion proposal and manually update backlog.md Files if appropriate."
    echo "  Fail count unchanged: ${TASK_FAIL_COUNT:-0}"
    add_result "Loop ${LOOP}: SCOPE_EXPAND proposal - $NEXT_TASK_ID"
    append_event "blocked" \
      "outcome=BLOCKED" \
      "status=BLOCKED" \
      "block_type=SCOPE_EXPAND" \
      "reason=$BLOCK_REASON" \
      "recommended_action=Review the scope expansion proposal and manually update backlog.md Files if appropriate." \
      "requested_files=$(scope_expand_paths_csv "${EXPAND_REQUESTED[@]}")" \
      "fail_count_unchanged=true"
    transaction_complete "SCOPE_EXPAND"
    continue
  fi

  if [[ "$IMPL_VERDICT" == "FAIL" ]]; then
    FAIL_EVIDENCE_FILE="$EVIDENCE_DIR/impl_fail_reason.md"
    {
      echo "# Impl Critic FAIL"
      echo ""
      echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
      echo "Verdict: $IMPL_VERDICT"
      echo ""
      echo "## Failure Evidence"
      if [[ -f "$IMPL_CRITIQUE" ]]; then
        head -c 12000 "$IMPL_CRITIQUE"
        echo ""
      else
        echo "impl_critique.md was not found."
      fi
    } > "$FAIL_EVIDENCE_FILE"

    echo -e "${YELLOW}  Implementation FAIL -> rollback + increment Fail count -> next loop${RESET}"
    # Increment backlog fail count first.
    # Note: git_rollback preserves .loop-agent/, so call order does not strictly matter,
    # but incrementing state metadata (fail_count) before git ops is done for consistency.
    FAIL_RESULT="$(record_task_failure "Impl Critic" "$IMPL_VERDICT" "FAIL loop=$LOOP" "${EVIDENCE_REL}impl_fail_reason.md" 2>/dev/null || echo "ERROR")"
    git_rollback "Impl Critic FAIL - discard partial implementation"  # restore to pre-Implementer state
    if [[ "$FAIL_RESULT" == "BLOCKED" ]]; then
      echo -e "${RED}  Task $NEXT_TASK_ID BLOCKED ($LOOP_MAX_ATTEMPTS consecutive failures)${RESET}"
    fi
    {
      echo ""
      echo "=== Loop ${LOOP}: Impl FAIL ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID — $NEXT_TASK_NAME"
      echo "Impl Critic verdict: $IMPL_VERDICT"
      echo "Failure evidence: ${EVIDENCE_REL}impl_fail_reason.md"
      echo "Backlog fail result: $FAIL_RESULT"
      echo "Rollback: implementation changes discarded"
      echo "Evidence preserved: $EVIDENCE_REL"
      echo "Final decision: FAIL (Impl Critic verdict was FAIL)"
      echo "PASS commit: skipped"
      echo ""
    } >> "$PROGRESS"
    append_shell_report "FAIL" "Impl Critic FAIL"
    {
      echo "### FAIL lifecycle"
      echo ""
      echo "- Evidence: ${EVIDENCE_REL}"
      echo "- Failure evidence: ${EVIDENCE_REL}impl_fail_reason.md"
      echo "- Backlog fail result: $FAIL_RESULT"
      echo "- Rollback: implementation changes discarded"
      echo "- PASS commit: skipped"
      echo ""
    } >> "$REPORT"
    add_result "Loop ${LOOP}: FAIL (Impl Critic) — $NEXT_TASK_ID"
    transaction_complete "FAIL"
    continue
  fi

  if [[ "$IMPL_VERDICT" != "PASS" ]]; then
    echo -e "${YELLOW}  Impl Critic ${IMPL_VERDICT} is not PASS -> rollback + record failure -> next loop${RESET}"
    FAIL_RESULT="$(record_task_failure "Impl Critic" "$IMPL_VERDICT" "non-PASS loop=$LOOP" ".loop-agent/impl_critique.md" 2>/dev/null || echo "ERROR")"
    git_rollback "Impl Critic ${IMPL_VERDICT} - discard partial implementation"
    if [[ "$FAIL_RESULT" == "BLOCKED" ]]; then
      echo -e "${RED}  Task $NEXT_TASK_ID BLOCKED ($LOOP_MAX_ATTEMPTS consecutive failures)${RESET}"
    fi
    {
      echo ""
      echo "=== Loop ${LOOP}: Impl Non-PASS ==="
      echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
      echo "Impl Critic verdict: $IMPL_VERDICT"
      cat "$IMPL_CRITIQUE"
      echo "Backlog fail result: $FAIL_RESULT"
      echo "Final decision: FAIL (Impl Critic verdict was not PASS)"
      echo "PASS commit: skipped"
      echo ""
    } >> "$PROGRESS"
    append_shell_report "FAIL" "Impl Critic ${IMPL_VERDICT}"
    add_result "Loop ${LOOP}: FAIL (Impl Critic ${IMPL_VERDICT}) - $NEXT_TASK_ID"
    transaction_complete "FAIL"
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
  transaction_write "scan_after"
  scan_project "$FILE_INDEX_AFTER" "after"

  # ────────────────────────────────────────────────────────────
  # Phase 4.6: PASS commit
  # ────────────────────────────────────────────────────────────
  PASS_COMMIT_HASH=""
  if [[ "$COMMIT_ON_PASS" == "1" ]]; then
    phase "Phase 4.6 · PASS commit"
    transaction_write "pass_commit"
    if ! git_commit_pass; then
      {
        echo ""
        echo "=== Loop ${LOOP}: PASS Commit FAIL ==="
        echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Task: $NEXT_TASK_ID — $NEXT_TASK_NAME"
        echo "Evidence: $EVIDENCE_REL"
        echo "Backlog completion: skipped"
        echo ""
      } >> "$PROGRESS"
      err "PASS commit failed for $NEXT_TASK_ID. Backlog completion skipped."
      transaction_complete "ERROR"
      exit 1
    fi
    if ! PASS_COMMIT_HASH="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)" || [[ -z "$PASS_COMMIT_HASH" ]]; then
      {
        echo ""
        echo "=== Loop ${LOOP}: PASS Commit Hash FAIL ==="
        echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Task: $NEXT_TASK_ID — $NEXT_TASK_NAME"
        echo "Evidence: $EVIDENCE_REL"
        echo "Backlog completion: skipped"
        echo ""
      } >> "$PROGRESS"
      err "Could not capture PASS commit hash for $NEXT_TASK_ID. Backlog completion skipped."
      transaction_complete "ERROR"
      exit 1
    fi
    append_event "commit" \
      "status=PASS" \
      "commit_hash=$PASS_COMMIT_HASH"
  else
    info "Automatic PASS commit disabled (COMMIT_ON_PASS=$COMMIT_ON_PASS)"
  fi

  # ────────────────────────────────────────────────────────────
  # Phase 5: Shell Report
  # ────────────────────────────────────────────────────────────
  phase "Phase 5 · Shell Report"
  transaction_write "shell_report"
  {
    echo "# PASS Result"
    echo ""
    echo "Task: $NEXT_TASK_ID - $NEXT_TASK_NAME"
    echo "Evidence: $EVIDENCE_REL"
    if [[ -n "$PASS_COMMIT_HASH" ]]; then
      echo "PASS commit: $PASS_COMMIT_HASH"
    else
      echo "PASS commit: skipped"
    fi
  } > "$EVIDENCE_DIR/pass_result.md"
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
    if [[ "${LOOP_EVIDENCE_PRUNE_PASS:-1}" == "1" ]] && [[ -n "$PASS_COMMIT_HASH" ]]; then
      echo "Evidence: pruned (redundant with commit $PASS_COMMIT_HASH)"
    else
      echo "Evidence: $EVIDENCE_REL"
    fi
    if [[ -n "$PASS_COMMIT_HASH" ]]; then
      echo "PASS commit: $PASS_COMMIT_HASH"
    else
      echo "PASS commit: skipped"
    fi
    if [[ "${LOOP_EVIDENCE_PRUNE_PASS:-1}" != "1" ]] || [[ -z "$PASS_COMMIT_HASH" ]]; then
      echo "PASS result: ${EVIDENCE_REL}pass_result.md"
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
  transaction_complete "PASS"
  info "progress.txt updated"

  # Prune PASS evidence — diffs/verify outputs are redundant with git history.
  # Only runs after a successful commit; FAIL/BLOCKED/proposal evidence is untouched.
  if [[ "$LOOP_EVIDENCE_PRUNE_PASS" == "1" ]] \
     && [[ -n "$PASS_COMMIT_HASH" ]] \
     && [[ -n "${EVIDENCE_DIR:-}" ]] \
     && [[ -d "$EVIDENCE_DIR" ]]; then
    case "$EVIDENCE_DIR" in
      "$EVIDENCE_ROOT"/loop-*)
        rm -rf -- "$EVIDENCE_DIR" \
          && info "PASS evidence pruned: $EVIDENCE_REL (set LOOP_EVIDENCE_PRUNE_PASS=0 to retain)" \
          || warn "PASS evidence prune failed: $EVIDENCE_DIR"
        ;;
    esac
  fi

  sleep 2  # prevent rate limiting

done

# ═══════════════════════════════════════════════════════════════
#  Exit after N loops
# ═══════════════════════════════════════════════════════════════
generate_final_report
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
  echo -e "${GREEN}${BOLD}All tasks complete. Project implementation finished successfully.${RESET}"
  echo "Completed backlog: SUCCESS (exit code 0)."
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

if [[ "$PASS_COUNT" -eq 0 && "$BL_COMPLETE" != "true" ]]; then
  echo -e "${YELLOW}All ${MAX_LOOPS} loops exhausted with no PASS.${RESET}"
  echo "Review progress.txt and backlog.md."
  echo "  cat $PROGRESS"
  echo "  cat $BACKLOG"
  echo ""
  exit 1
fi

exit 0
