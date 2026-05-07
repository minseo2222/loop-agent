# LoopDex

**Run an AI coding agent against a multi-task backlog overnight, with independent critic processes and per-task git rollback — using your existing ChatGPT Plus or Gemini subscription. No API keys, no Docker.**

Supported CLIs: **OpenAI Codex** (default) · **Google Gemini**

---

## Quick start

```bash
# 1. Install a CLI (pick one)
npm install -g @openai/codex && codex login        # Codex
npm install -g @google/gemini-cli && gemini        # Gemini

# 2. Install LoopDex
git clone https://github.com/minseo2222/LoopDex.git
cd LoopDex && chmod +x loop.sh

# 3. Drop your planning docs into a project folder, then:
./loop.sh init --project /path/to/myproject     # first run launches a setup wizard
./loop.sh run  --project /path/to/myproject     # asks for iterations interactively
```

The first `init` or `run` opens a multiple-choice wizard for **CLI**, **model ID**, and **required branch prefix**, and saves the answers to `.loop-agent/config.env`. From the second run onward you just type `./loop.sh run --project <dir>` and it asks only for iteration count. Edit or delete `config.env` to change settings.

Precedence: **CLI flag** > **exported env var** > **config.env** > **built-in default**.

`init` also bootstraps your project: initializes git if missing, and **auto-fills `.gitignore`** with:
- A Secrets block (`.env`, `*.pem`, `*.key`, `id_rsa`, …) so the initial commit can't accidentally include credentials.
- Editor/OS metadata (`.DS_Store`, `.idea/`, `.vscode/`, …).
- Language-specific patterns for whatever it detects (Python, Node, Rust, Go, Java/Maven, Java/Gradle).

This runs **before** the initial `git add -A`, so pre-existing `__pycache__/`, `node_modules/`, `.env`, etc. are not committed and won't trip the scope gate later.

> ⚠️ LoopDex executes AI-generated code without per-step approval. Read [Safety](#safety) before pointing it at anything you care about.

### First run, step by step

1. **Install + log in** to your CLI of choice (`codex login` or `gemini`).
2. **Make a project folder** with your planning docs (`SPEC.md`, `REQUIREMENTS.md`, `docs/*.md` — names don't matter).
3. **`./loop.sh init --project <dir>`** — runs the setup wizard, bootstraps `.gitignore`, then has the Setup Agent generate `backlog.md` and the Setup Critic review it. You approve with `y`.
4. **(Recommended) move to a dedicated branch** in the project:  `cd <dir> && git checkout -b loop/work`. If you picked `loop/` as the required prefix in the wizard, this is required before `run`.
5. **`./loop.sh run --project <dir>`** — type the iteration count when prompted (or pass `-i N`). The loop starts.
6. **(Optional) `./loop.sh doctor --project <dir>`** before step 5 to pre-flight check git / Python / CLI / model / branch / backlog lint.

To change settings later: edit `.loop-agent/config.env`, or delete it to re-run the wizard on next invocation.

---

## Why it exists

Most autonomous coding tools fall into one of two camps:

- **Single-shot or interactive** (`aider`, Codex `/goal`, Cursor) — great for one task, but on long backlogs the same model "self-reviews" its own work inside one session.
- **Heavy autonomous frameworks** (OpenHands, MetaGPT, Devin) — powerful, but require Docker, API keys, per-token billing, and a lot of setup.

LoopDex sits in the gap:

- You have **a backlog**, not a single goal.
- You want it to grind for hours, **unattended**.
- You want **independent-process review** — a separate process that didn't see the implementer's reasoning.
- You want **per-task commit-or-rollback gates**.
- You want to pay nothing per token — your Plus / Gemini quota covers it.

### When LoopDex is *not* the right tool

| Situation | Use instead |
|---|---|
| Single well-scoped task | Codex `/goal`, `aider` |
| Interactive conversational coding | `aider`, Claude Code |
| Sandboxed VM with web UI | OpenHands |
| Token-billed direct-API usage | OpenHands, AutoGen |

---

## How it works

```
init  ─►  Setup Agent ─► Setup Critic ─► human y/e/n ─► backlog.md
                                                            │
                                                            ▼
run   ─►  ┌─ pick next runnable task ───────────────────┐
          │  Planner ─► Plan Critic ─► Implementer       │  per-task
          │  ─► Impl Critic ─► verify ─► scope gate      │  commit OR rollback
          └──────────────────────────────────────────────┘
```

Each stage runs as a **separate CLI process**. The critic never sees the implementer's reasoning — only the artifact (`plan.md`, the diff, verify output). That's what makes the review meaningful.

**Final decision gates** (deterministic, in order):
1. Proposal verdicts (`SCOPE_EXPAND`, `SPLIT_TASK`) → block for human review, no fail count.
2. Impl Critic must return PASS.
3. Backlog `verify:` commands must pass.
4. Scope gate (changed files ⊆ backlog `Files`) and state-file gate must pass.
5. If `COMMIT_ON_PASS=1`, `git commit` must succeed.

Critic PASS is necessary but not sufficient. Any gate failure → rollback, fail count +1. **5 consecutive failures → BLOCKED, loop moves on.**

---

## Exit conditions

| Situation | Exit code |
|---|---|
| All tasks complete | 0 |
| Iterations exhausted, tasks remain | 0 |
| Only BLOCKED tasks remain | 1 |
| Rate limit hit (auto-rollback, resume-safe) | 2 |
| Ctrl+C (state restored) | 130 |

After a rate-limit exit, just re-run the same command once the limit resets. Already-completed tasks are skipped.

---

## Commands

```bash
./loop.sh init   --project <dir> [--cli codex|gemini]
./loop.sh run    --project <dir> [--cli codex|gemini] [--iterations N | -i N]
./loop.sh status --project <dir>
./loop.sh doctor --project <dir>
```

If `.loop-agent/config.env` is missing on `init` or `run` (and stdin is a TTY), a multiple-choice wizard runs once and stores your CLI / model / branch-prefix preferences. Subsequent runs read it automatically. CI / non-TTY skip the wizard and rely on built-in defaults.

`run` requires iterations: pass `--iterations N` / `-i N`, or be prompted interactively. CI must pass the flag. It also requires:
- An existing `.loop-agent/backlog.md` (run `init` first)
- A clean working tree (commit/stash your own work)
- Backlog passes `python backlog_manager.py lint`

Optional: enforce a dedicated branch with `LOOP_REQUIRE_BRANCH_PREFIX=loop/` (the wizard offers `loop/` as a recommended option).

---

## Configuration

For typical use, the **setup wizard** handles `LOOP_CLI`, `CODEX_MODEL` / `LOOP_GEMINI_MODEL`, and `LOOP_REQUIRE_BRANCH_PREFIX` — values get stored in `.loop-agent/config.env`. The env vars below are for one-off overrides (CLI flag > env var > config.env > built-in default) or for behavior the wizard doesn't cover.

### Common

| Variable | Default | Purpose |
|---|---|---|
| `COMMIT_ON_PASS` | `1` | Auto-commit on PASS. `0` = accumulate in working tree |
| `LOOP_RISK_MODE` | `unattended` | `unattended` keeps built-in bypass flags; `safe` strips them |
| `LOOP_REQUIRE_BRANCH_PREFIX` | unset | Refuse to start `run` unless current branch matches |
| `LOOP_EVIDENCE_KEEP_RUNS` | `10` | Keep newest N evidence dirs (`0` = disable) |
| `LOOP_EVIDENCE_PRUNE_PASS` | `1` | Delete a loop's evidence dir after PASS commit. Set `0` to retain (forensic auditing). FAIL/BLOCKED/proposal evidence is unaffected |
| `PROGRESS_SIZE_THRESHOLD` | `524288` | Trim `progress.txt` past this size |
| `PROGRESS_KEEP_ENTRIES` | `50` | Recent sections to retain after trim |

### Codex

| Variable | Default | Purpose |
|---|---|---|
| `CODEX_MODEL` | `gpt-5.5` (placeholder) | Model ID — **must be overridden** to a real ID your account exposes; LoopDex warns at startup and in `doctor` if left as the placeholder |

### Gemini

| Variable | Default | Purpose |
|---|---|---|
| `LOOP_GEMINI_MODEL` | `gemini-3.1-pro-preview` (placeholder) | Model ID — **must be overridden** to a real ID; LoopDex warns at startup and in `doctor` if left as the placeholder |
| `LOOP_GEMINI_FLAGS` | `--yolo` (unattended) / empty (safe) | Override CLI flags |
| `LOOP_GEMINI_MODEL_FLAG` | `--model` | Flag used to specify the model |
| `LOOP_GEMINI_USE_PROMPT_ARG` | `0` | `1` = pass prompt via `-p` instead of stdin |

> Default model IDs are placeholders. Override them.

---

## Safety

LoopDex executes AI-generated code without per-step approval. By default:

- `.claude/settings.json` uses `"defaultMode": "bypassPermissions"`
- Codex runs with `--dangerously-bypass-approvals-and-sandbox`
- Gemini default flags include `--yolo`
- The loop calls `git commit` and rollback automatically

Set `LOOP_RISK_MODE=safe` to strip LoopDex's built-in bypass flags where supported. **This is not a sandbox** — agent and verify commands still run with your shell permissions.

### Operating rules

1. **Dedicated project directory under git.** Never point at `$HOME` or a repo with uncommitted work you cannot lose.
2. **Dedicated branch.** Create and check out the branch yourself; LoopDex does not switch branches.
3. **Clean tree before `run`.** Commit/stash your edits so rollback boundaries are well-defined.
4. **Treat external planning docs as untrusted input** — prompt injection can steer the agent.
5. **Isolated environment** (fresh VM, container, or throwaway user account) when possible.

See [`docs/security.md`](docs/security.md) for boundaries and known limitations.

### Built-in safety mechanisms

- **Per-task git rollback** on any gate failure — restores pre-task working tree.
- **Rate-limit recovery** — exit code 2, no fail-count increment, resume on next run.
- **Transaction recovery** — `current_transaction.json` tracks in-progress lifecycle updates and finishes/rolls back on next startup.
- **Project lock** — second run against the same project exits instead of racing.
- **State-file protection** — agents cannot modify `.loop-agent/` artifacts that the loop owns.
- **Secret-path guard** — blocks writes to `.env`, `private_key`, etc. (path-based only, not content-scanning).
- **Verify gate** — backlog `Verify` commands are authoritative; agent text cannot bypass them.
- **Scope gate** — changed files (from `git status`, not agent self-report) must be a subset of backlog `Files`.
- **Atomic backlog writes** via temp-file + `os.replace`.
- **Run-mode backlog immutability** — scope/Files/Depends/verify/criteria are not auto-mutated. `SCOPE_EXPAND` and `SPLIT_TASK` produce review proposals only. See [`docs/backlog_mutation_policy.md`](docs/backlog_mutation_policy.md).

---

## Project files

```
myproject/
  .loop-agent/
    config.env             ← per-project wizard answers (CLI / model / branch prefix)
    backlog.md             ← task list + completion status (source of truth)
    events.jsonl           ← machine-readable event log (status/reports source)
    progress.txt           ← raw per-loop debug log (auto-trimmed)
    progress_window.md     ← bounded Markdown context for agents (not source of truth)
    report.md              ← cumulative report
    current_transaction.json
    evidence/loop-N/       ← per-loop verify/scope/diff evidence (FAIL/BLOCKED only by default)
    reports/               ← per-loop detail
    codex.log              ← agent stderr
```

`status` and final reports derive from `backlog.md` + `events.jsonl`. Don't parse `progress_window.md` — it's agent-facing context, not authoritative.

---

## Backlog

The backlog is the source of truth. Four files govern it:

| File | Role |
|---|---|
| [`backlog_guide.md`](backlog_guide.md) | Format spec, sizing rules, quality checklist |
| [`agents/setup_agent.md`](agents/setup_agent.md) | Generates `backlog.md` from your planning docs |
| [`agents/setup_critic.md`](agents/setup_critic.md) | Validates the generated backlog |
| [`TASK_PLANNING_FAILURE_PATTERNS.md`](TASK_PLANNING_FAILURE_PATTERNS.md) | Living catalog of recurring planning failures |

Each task needs an ID and these fields: `Size` (`Small` or `Medium`), `Files`, `Description`, `Completion criteria` (with at least one `verify:` command), `Depends`, `Fail count`. Markers: `[ ]` pending, `[x]` done, `[!]` blocked.

Lint a backlog manually:
```bash
python backlog_manager.py lint .loop-agent/backlog.md
```

You can also generate the backlog yourself in Claude Code by pasting `backlog_guide.md` and pointing it at your planning docs, then running `./loop.sh run` directly.

---

## Prerequisites

- macOS / Linux / Windows (Git Bash)
- Node.js 18+
- Python 3.8+ (`python` command — Microsoft Store launcher on Windows is not supported)
- One of:
  - **Codex**: ChatGPT Plus or higher
  - **Gemini**: OAuth (uses Code Assist quota), `GEMINI_API_KEY` (may incur charges), or Vertex AI

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ChatGPT login required` | `codex login` |
| `Gemini authentication not detected` | `gemini` (OAuth) or `export GEMINI_API_KEY=...` |
| `codex/gemini CLI not found` | `npm install -g @openai/codex` / `@google/gemini-cli` |
| `python not found` | Install Python 3.8+ (avoid Windows Store launcher) |
| `gemini --version failed` | Override flags via `LOOP_GEMINI_*` |
| pnpm not found in Git Bash | Add `/c/Users/<you>/AppData/Roaming/npm` to `PATH` |
| `Iterations required for run mode` | Pass `-i N` (CI/non-TTY) or run from an interactive terminal to be prompted |
| Want to change CLI / model / branch prefix later | Edit `.loop-agent/config.env`, or delete it to re-run the wizard |
| `CODEX_MODEL='gpt-5.5' is a README placeholder` | Re-run `init` (wizard sets a real ID) or `export CODEX_MODEL=<your-real-id>` |
| Scope gate keeps flagging build artifacts | Re-run `./loop.sh init` to refresh `.gitignore`, or add the standard language patterns manually. If files are already tracked, `git rm --cached <path>` |
| Exit code 2 (rate limit) | Wait, then re-run the same command — completed tasks are skipped |
| Not sure if the environment is ready | `./loop.sh doctor --project <dir>` reports git / Python / CLI / model / branch / backlog status |

---

## Testing

```bash
# Happy-path E2E (uses fake CLI, no Codex/Gemini needed)
bash tests/e2e_pass_fake_cli.sh

# Full local CI equivalent
bash -n loop.sh run.sh \
  && python -m py_compile backlog_manager.py progress_window.py \
  && bash tests/e2e_pass_fake_cli.sh \
  && bash tests/e2e_rate_limit_fake_cli.sh \
  && bash tests/e2e_archive_compaction_fake_cli.sh
```

The fake CLI is for deterministic regression tests only — never use it for real work.

For self-upgrading this repo with LoopDex, see [`docs/dogfood.md`](docs/dogfood.md).

---

## Comparison

|  | LoopDex | Codex `/goal` | aider | OpenHands | gpt-engineer |
|---|---|---|---|---|---|
| Multi-task backlog from docs | ✅ | ❌ | ❌ | partial | ❌ |
| Independent-process critic | ✅ | ❌ | ❌ | ❌ | ❌ |
| Per-task git rollback | ✅ | ❌ | partial | ❌ | ❌ |
| Resume on rate limit | ✅ | ❌ | n/a | n/a | n/a |
| Multi-vendor (Codex + Gemini) | ✅ | ❌ | ✅ | ✅ | ❌ |
| Subscription-only billing | ✅ | ✅ | ❌ | ❌ | ❌ |
| Zero-Docker install | ✅ | ✅ | ✅ | ❌ | ✅ |
| Web UI / dashboard | ❌ | ❌ | ❌ | ✅ | ❌ |
| Interactive conversation | ❌ | partial | ✅ | ✅ | ❌ |

`/goal`, `aider`, OpenHands, and gpt-engineer are all excellent at what they do. LoopDex fills the slot of *unattended multi-task batches with hard review gates on top of subscription CLIs*.

---

## File structure

```
LoopDex/
  loop.sh                              ← entry point
  backlog_manager.py                   ← backlog parsing + atomic updates
  progress_window.py                   ← progress.txt sliding window
  backlog_guide.md                     ← backlog format spec
  TASK_PLANNING_FAILURE_PATTERNS.md    ← failure pattern catalog
  agents/
    setup_agent.md   setup_critic.md   ← Setup Phase
    planner.md       plan_critic.md    ← Planning stage
    implementer.md   impl_critic.md    ← Implementation stage
  docs/
    security.md      dogfood.md        backlog_mutation_policy.md
    design_invariants.md               legacy_run.md
```

The legacy `run.sh` document-driven workflow is retained for compatibility; see [`docs/legacy_run.md`](docs/legacy_run.md). New usage should prefer `init` + `run`.

---

## Legal & disclaimers

- **Third-party services.** LoopDex invokes external CLIs (OpenAI Codex, Google Gemini, optionally Anthropic Claude Code). Your docs, source, and prompts are transmitted under those providers' policies. Don't feed sensitive or regulated data unless your provider terms permit.
- **Terms of service.** You are responsible for ensuring looped, automated CLI invocation complies with each provider's ToS. The authors make no representation that any usage pattern is permitted, and accept no liability for suspensions or charges.
- **Trademarks.** "ChatGPT", "Codex", "GPT" — OpenAI. "Gemini", "Vertex AI", "Google Cloud" — Google LLC. "Claude", "Claude Code" — Anthropic. Use here is nominative; no endorsement implied.
- **Model names.** Defaults like `gpt-5.5` and `gemini-3.1-pro-preview` are placeholders — override via env vars to match your account.
- **Autonomous execution.** LoopDex runs AI-generated code without per-step approval. You choose the target directory and runtime environment.
- **Input content.** You retain ownership of your docs and code. By running LoopDex you confirm you have the right to share that content with your configured providers.

---

## License

MIT — see [LICENSE](LICENSE). Provided "as is", without warranty of any kind.
