# LoopDex

**Run an AI coding agent against a multi-task backlog overnight, with independent critic processes and per-task git rollback — using your existing ChatGPT Plus or Gemini subscription, no API keys, no Docker.**

Supported CLIs: **OpenAI Codex** (default), **Google Gemini**

Main supported entrypoint: `./loop.sh init` to create and approve a backlog, then `./loop.sh run` to execute it. Legacy `run.sh` document-driven workflows are retained only for compatibility and are documented in [`docs/legacy_run.md`](docs/legacy_run.md).

---

## Why this exists

Most autonomous coding tools fall into one of two camps:

- **Single-shot or interactive** (`aider`, Codex CLI `/goal`, Cursor) — great for one task, but on long backlogs the context drifts and the same model "self-reviews" its own work inside one session.
- **Heavy autonomous frameworks** (OpenHands, MetaGPT, Devin) — powerful, but require Docker, API keys, per-token billing, and a lot of setup.

LoopDex sits in a narrow gap between them:

- You have **a backlog of tasks**, not a single goal.
- You want the agent to run **for hours, unattended**, picking tasks one by one.
- You want **review independence** — a separate process that did not see the implementer's reasoning.
- You want **per-task review gates**: each task either passes review and commits, or LoopDex attempts a git-based rollback within the project.
- You want to **pay nothing per token** — your ChatGPT Plus or Gemini OAuth quota covers it.

If that matches you, LoopDex is built for that exact loop.

---

## What makes it different

### 1. Independent-process critics, not self-review

The Planner, Plan Critic, Implementer, and Impl Critic each run as a **fresh process** with its own context. The Critic never sees what the Planner or Implementer "thought" — it only sees the artifact (`plan.md`, the diff, the verify output).

In single-context loops (including Codex `/goal`), the model that wrote the code also reviews it, carrying its own justifications forward. Here, the reviewer comes in cold.

### 2. Per-task commit / rollback boundary

After the deterministic final decision gates pass, the change is committed. On FAIL, LoopDex attempts to roll back the project working tree to the last good state. After 5 consecutive failures the task is marked BLOCKED and the loop moves on. You can wake up to a clear list of what passed, what was skipped, and why.

### 3. Resume-safe rate-limit handling

When ChatGPT or Gemini rate-limits you, LoopDex rolls back any in-progress task, exits with code 2, and leaves state intact. Re-running the same command after the limit resets resumes from the next pending task. Failure count is not incremented.

### 4. Failure-pattern feedback loop

[`TASK_PLANNING_FAILURE_PATTERNS.md`](TASK_PLANNING_FAILURE_PATTERNS.md) is a living document of recurring planning failures observed across real runs — task scope too broad, missing verify commands, keyword-only validation, BLOCKED mishandling, and more. The Setup Agent and Setup Critic both consult this file when generating and validating backlogs, so the same mistake is less likely to repeat.

### 5. Subscription-based cost model

No `OPENAI_API_KEY` or `ANTHROPIC_API_KEY`. The loop drives the official `codex` or `gemini` CLI, which authenticates against your existing ChatGPT Plus subscription or Google account OAuth. A long overnight run costs you whatever you already pay monthly — not a token bill.

### 6. Bash, no daemon, no Docker

Two shell scripts, two Python helpers, six prompt files. You can read the entire orchestration in an afternoon and modify it in place.

---

## When LoopDex is **not** the right tool

Be honest with yourself. If any of these match, use something else:

- **A single, well-scoped task.** Use Codex `/goal` or `aider` — one command beats a backlog.
- **You want interactive, conversational coding.** Use `aider` or Claude Code.
- **You don't have planning docs and don't want to write any.** Use `gpt-engineer` or describe-and-go tools.
- **You need a sandboxed VM with a web UI.** Use OpenHands.
- **Your account / employer pays per token via API.** OpenHands, AutoGen, or any direct-API agent will give you more flexibility than wrapping a CLI.

LoopDex shines specifically when you have a *multi-task backlog* and want it ground through *unattended* with *hard review gates*.

---

## ⚠️ Safety notice — read before running

LoopDex runs AI agents **autonomously** and **executes code they generate without human approval at each step**. By default, `LOOP_RISK_MODE=unattended` keeps permissive CLI flags so the loop can run unattended:

- The bundled `.claude/settings.json` sets `"defaultMode": "bypassPermissions"`.
- Codex runs with `--dangerously-bypass-approvals-and-sandbox`.
- The default Gemini flags include `--yolo`, which bypasses the CLI's sandbox/approval prompts.
- The loop calls `git commit` and `git rollback` on the target project automatically.

Set `LOOP_RISK_MODE=safe` to avoid LoopDex's built-in Codex and Gemini bypass flags where the wrapped CLI supports that. Safe mode is not a sandbox; the agent and verify commands still run with your shell permissions.

See [`docs/security.md`](docs/security.md) for security boundaries and known limitations.

Because of this, you should:

1. **Run only against a dedicated project directory** under version control. Never point it at your home directory, system folders, or a repo with uncommitted work you cannot afford to lose.
2. **Start run mode from a clean tree.** Explicit `run` requires no uncommitted project changes before agent work begins, so rollback has a clear pre-task snapshot.
3. **Run unattended work on a dedicated git branch.** LoopDex does not switch branches by default; create and switch to the branch yourself before running it. Optionally set `LOOP_REQUIRE_BRANCH_PREFIX` to enforce a branch prefix before explicit `run` starts.
3. **Prefer an isolated environment** (a fresh VM, container, or throwaway workspace) — at minimum a dedicated user account.
4. **Choose `LOOP_RISK_MODE=safe` or review `.claude/settings.json` and `LOOP_GEMINI_FLAGS`** if you do not want built-in bypass-permission flags.
5. **Treat planning docs as untrusted input** if they came from outside your team — prompt-injected docs can steer the agent.

The authors provide this software **as-is, with no warranty**. You are responsible for what the agent does on your machine.

---

## How it works

## architecture summary

`loop.sh` is the runtime orchestrator. It selects the next backlog task, writes the agent input files, runs the Planner, Plan Critic, Implementer, and Impl Critic as separate CLI processes, executes backlog verify commands, applies deterministic PASS/FAIL gates, and commits or rolls back the project at the task boundary.

The current architecture keeps the CLI boundary explicit: Codex and Gemini are adapters selected by `--cli`, with risk-mode flags and model settings normalized before each agent call. The intended extraction work is still tracked separately, so these adapter boundaries may still live in the shell runtime until that cleanup lands.

Evidence responsibilities are separated from decision responsibilities. Evidence helpers collect shell facts such as verify output, changed files, diff stats, out-of-scope paths, and retained evidence directories. Decision helpers use that evidence plus critic verdicts, backlog scope, state-file protection, transaction state, and commit results to decide PASS, FAIL, BLOCKED, rollback, or proposal-only outcomes. See [`docs/dogfood.md`](docs/dogfood.md) for repository self-upgrade workflow notes and [`docs/security.md`](docs/security.md) for security boundaries.

### Setup Phase (first run only)

Runs automatically when `backlog.md` doesn't exist.

```
Setup Agent  — reads all planning docs and code, generates the full task list (backlog.md)
Setup Critic — validates quality (file paths, verify commands, dependency order)
Human review — enter y / e / n
```

### Loop Phase (repeats N times)

Picks tasks from `backlog.md` one at a time.

```
1. Select next task from backlog (first with all dependencies satisfied)
2. Planner     — breaks the task into steps and writes a plan
3. Plan Critic — independently reviews the plan
4. Implementer — writes code and runs the verify command
5. Impl Critic — independently reviews the implementation
6. Shell Report — shell accumulates the report automatically
```

Each stage runs as an **independent process** — no context from the previous stage carries over, which is what makes the critic stages meaningful.

PASS → final gates pass + commit + mark task complete + print progress
FAIL → git rollback + failure count +1 (5 failures → BLOCKED)

---

## Exit conditions

| Situation | Behavior | Exit code |
|-----------|----------|-----------|
| All backlog tasks done | Exits immediately 🎉 | 0 |
| N iterations exhausted, tasks remain | Prints progress + resume instructions | 0 |
| Only BLOCKED tasks remain | Prints environment guidance | 1 |
| **Rate limit reached** | Safe exit + auto rollback | **2** |
| Ctrl+C | State files auto-restored | 130 |

Completed backlog is a successful terminal state: when there is no pending work, LoopDex reports success and exits 0 even if no task ran in that invocation.

Ordinary `FAIL` is reserved for implementation, review, verify, scope-gate, or no-change failures that roll back work and increment `Fail count`. `SCOPE_EXPAND` and `SPLIT_TASK` are blocked policy outcomes, not ordinary failures. They create review proposals, block the active task, report the reason and action required, and leave `Fail count` unchanged.

Explicit `run` mode does not automatically modify semantic backlog fields for these outcomes. `SCOPE_EXPAND` blocks without incrementing `Fail count`; it records a proposal instead of editing `Files`, `Depends`, verify commands, completion criteria, description, or ordering constraints. `SPLIT_TASK` also blocks without incrementing `Fail count`; it records a split proposal instead of inserting child tasks or rewriting backlog structure. A human must review the proposal and intentionally edit or leave the backlog blocked before the task is retried.

---

## Prerequisites

- macOS / Linux / Windows (Git Bash)
- Node.js 18+
- Python 3.8+ (`python` command — Microsoft Store launcher on Windows is not supported)
- Depending on your CLI:
  - **codex**: ChatGPT Plus or higher subscription
  - **gemini**: Gemini CLI authenticated. Supports Google account OAuth or `GEMINI_API_KEY` / Vertex AI. API key and Vertex AI usage may incur charges.

---

## Installation

### A. Using Codex CLI (default)

```bash
npm install -g @openai/codex
codex login   # opens browser for ChatGPT account login
```

### B. Using Gemini CLI

LoopDex does not call the Gemini API directly — it runs the `gemini` CLI command.

Authentication method determines quota and cost:

- Google account OAuth login: uses Gemini CLI / Code Assist account quota
- `GEMINI_API_KEY`: uses Google AI Studio / Gemini API key, may apply free tier limits or charges
- Vertex AI: billed under your Google Cloud / Vertex AI project

Avoid unexpected charges by verifying which authentication method is active.

### Install LoopDex

```bash
git clone https://github.com/minseo2222/LoopDex.git
cd LoopDex
chmod +x loop.sh    # not needed on Windows Git Bash
```

---

## Usage

### Prepare planning docs

Place your requirements or design documents in the project folder. File names don't matter.

```
myproject/
  SPEC.md              ← Setup Agent reads these
  REQUIREMENTS.md        automatically
  docs/design/*.md
```

See [example_doc.md](example_doc.md) for a concrete example.

### Run

Start by generating and approving the backlog:

```bash
./loop.sh init --project <project> --cli codex
```

Then run the loop against that backlog:

```bash
./loop.sh run --project <project> --iterations 5 --cli codex
```

`--cli` is optional, defaults to `codex`. Options: `codex` | `gemini`.

```bash
# Codex
./loop.sh init --project /path/to/myproject --cli codex
./loop.sh run --project /path/to/myproject --iterations 5 --cli codex

# Gemini
./loop.sh init --project /path/to/myproject --cli gemini
./loop.sh run --project /path/to/myproject --iterations 5 --cli gemini

# Windows (Git Bash)
./loop.sh init --project "/c/Users/yourname/myproject" --cli gemini
./loop.sh run --project "/c/Users/yourname/myproject" --iterations 5 --cli gemini
```

Explicit `run` requires an existing `.loop-agent/backlog.md`. If the backlog does not exist yet, run `init` first.

Explicit `run` is unattended and does not ask for human input while executing tasks.

At startup, `run` prints an informational, non-interactive safety summary before agent work begins. It reports the normalized project path, selected CLI, `LOOP_RISK_MODE`, clean-tree preflight status, branch-prefix requirement status, and backlog lint status. This banner is a visibility aid only; it is not a sandbox, permission prompt, or approval gate.

Explicit `run` mode requires a clean tree before agent calls begin. Commit or stash your own work first; this keeps user edits out of task rollback boundaries.

Dedicated branch example:

```bash
git checkout -b loop/my-work
LOOP_REQUIRE_BRANCH_PREFIX=loop/ ./loop.sh run --project <project> --iterations 5 --cli codex
```

LoopDex does not switch branches by default. `LOOP_REQUIRE_BRANCH_PREFIX` is optional; when set for explicit `run`, startup fails unless the current git branch starts with the configured prefix.

Risk mode examples:

```bash
# Default: preserves built-in bypass flags for unattended runs
LOOP_RISK_MODE=unattended ./loop.sh run --project /path/to/myproject --iterations 5 --cli codex

# Avoids LoopDex's built-in bypass flags where the wrapped CLI supports that
LOOP_RISK_MODE=safe ./loop.sh run --project /path/to/myproject --iterations 5 --cli gemini
```

The legacy compatibility syntax is still supported, but explicit `init` and `run` are recommended:

```bash
./loop.sh <iterations> <project-folder> [cli]
```

Legacy status: `loop.sh init` and `loop.sh run` are the supported entry points. `run.sh` and older prompt compatibility surfaces are retained for existing workflows and tests, but new usage should prefer the explicit commands above. See [`docs/legacy_run.md`](docs/legacy_run.md) for the retained `run.sh` behavior. Keep security-sensitive usage aligned with [`docs/security.md`](docs/security.md); repository self-runs are covered by [`docs/dogfood.md`](docs/dogfood.md).

Status and doctor commands:

```bash
./loop.sh status --project <project>
./loop.sh doctor --project <project>
```

`status` reports the current run state from backlog and event data, including task progress and blocked work.

`doctor` checks the local environment, backlog lint, and git cleanliness before you start or resume a run.

---

## Development testing

See [`tests/README.md`](tests/README.md) for E2E test notes. The fake CLI tests use local deterministic test doubles and do not require Codex or Gemini.

For using LoopDex to upgrade this repository itself, see the [dogfood guide](docs/dogfood.md).

Run the happy-path E2E test:

```bash
bash tests/e2e_pass_fake_cli.sh
```

Run the archive compaction regression after changes to backlog archive compaction, cleanup, or lint behavior:

```bash
bash tests/e2e_archive_compaction_fake_cli.sh
```

Run the CI-equivalent local checks:

```bash
bash -n loop.sh run.sh && python -m py_compile backlog_manager.py progress_window.py && bash tests/e2e_pass_fake_cli.sh && bash tests/e2e_rate_limit_fake_cli.sh && bash tests/e2e_archive_compaction_fake_cli.sh
```

The fake CLI is for deterministic testing only, not production use.

### Benchmarks

The benchmark runner exercises known PASS and FAIL scenarios and reports whether the loop made the correct final decision. A key metric is the false PASS rate: cases where LoopDex incorrectly accepts a bad implementation. Benchmark reporting derives metrics from machine-readable events, backlog state, and git commits, not from `.loop-agent/progress_window.md`.

---

## Backlog generation

The backlog is the single source of truth for what LoopDex builds. Four files are involved:

| File | Role |
|------|------|
| [`backlog_guide.md`](backlog_guide.md) | Human-readable spec: backlog format, task sizing rules, quality checklist. Read this to understand or manually edit a backlog. |
| [`agents/setup_agent.md`](agents/setup_agent.md) | Prompt that drives the Setup Agent. Reads your planning docs and generates `.loop-agent/backlog.md` automatically. |
| [`agents/setup_critic.md`](agents/setup_critic.md) | Prompt that drives the Setup Critic. Validates the generated backlog and requests a retry if quality checks fail. |
| [`TASK_PLANNING_FAILURE_PATTERNS.md`](TASK_PLANNING_FAILURE_PATTERNS.md) | Living document of recurring failure patterns. Both Setup Agent and Setup Critic reference this when generating and validating backlogs. |

### Backlog task markers

Backlog tasks use `[ ]` for pending work, `[x]` for completed work, and `[!]` for blocked work that needs manual action. During archive compaction, completed task bodies move out of the active backlog, and active `backlog.md` should not retain empty repeated `## Tasks` headings or other empty task headings after completed work is archived.

### Markdown backlog lint contract

LoopDex retains the current markdown backlog format in `.loop-agent/backlog.md`. Each task must have a valid task ID and these fields: `Size`, `Files`, `Description`, `Completion criteria`, `Depends`, `Fail count`, and at least one `verify:` command in the completion criteria. `Size` must be `Small` or `Medium`, and `Files` must list non-empty relative project paths.

Check a backlog before running it with:

```bash
python backlog_manager.py lint .loop-agent/backlog.md
```

Explicit `run` mode performs this lint check before agent calls. If backlog lint fails, the run stops before Planner, Implementer, or Critic processes are started.

### Generating manually with Claude Code

If you prefer to generate the backlog yourself instead of running the Setup Phase:

1. Open your project folder in Claude Code
2. Copy the contents of [`backlog_guide.md`](backlog_guide.md) into the conversation
3. Claude will analyze your planning docs and write `.loop-agent/backlog.md`
4. Review and edit as needed, then run `./loop.sh run --project . --iterations N` to start looping

---

## Environment variables

### Common

| Variable | Default | Purpose |
|----------|---------|---------|
| `COMMIT_ON_PASS` | `1` | Auto-commit on PASS. Set to `0` to accumulate in working tree |
| `LOOP_RISK_MODE` | `unattended` | `unattended` preserves built-in bypass flags; `safe` avoids those built-in bypass flags where supported |
| `LOOP_REQUIRE_BRANCH_PREFIX` | unset | Optional explicit `run` preflight requiring the current git branch to start with this prefix |
| `LOOP_EVIDENCE_KEEP_RUNS` | `10` | Keep the newest N loop evidence directories; set to `0` to disable evidence retention |
| `PROGRESS_SIZE_THRESHOLD` | `524288` (512KB) | Trim progress.txt when it exceeds this size |
| `PROGRESS_KEEP_ENTRIES` | `50` | Number of recent sections to keep after trim |

### Codex only

| Variable | Default | Purpose |
|----------|---------|---------|
| `CODEX_MODEL` | `gpt-5.5` | Codex model to use (override to whatever ID your account currently has) |

```bash
CODEX_MODEL=gpt-5.4 ./loop.sh run --project . --iterations 5 --cli codex
```

### Gemini only

| Variable | Default | Purpose |
|----------|---------|---------|
| `LOOP_GEMINI_MODEL` | `gemini-3.1-pro-preview` | Model ID (override to a model your account has) |
| `LOOP_GEMINI_FLAGS` | `--yolo` in unattended mode, empty in safe mode | Explicit Gemini flags; set this to override the risk-mode default |
| `LOOP_GEMINI_MODEL_FLAG` | `--model` | Flag used to specify the model |
| `LOOP_GEMINI_USE_PROMPT_ARG` | `0` | Set to `1` to pass prompt via `-p` instead of stdin |

```bash
# Different model
LOOP_GEMINI_MODEL=gemini-2.5-pro ./loop.sh run --project . --iterations 5 --cli gemini

# For versions that don't support stdin
LOOP_GEMINI_USE_PROMPT_ARG=1 ./loop.sh run --project . --iterations 5 --cli gemini
```

> The default model identifiers above are placeholders. Use whatever IDs your subscription currently exposes.

---

## Safety mechanisms

### Deterministic final decision gates

Task completion is decided by deterministic runtime gates, not by agent text alone. The final gate order is:

1. Proposal verdicts (`SCOPE_EXPAND` or `SPLIT_TASK`) create proposal files for review and block the task without applying backlog semantic changes.
2. Impl Critic must return critic PASS.
3. Shell verify commands from the backlog must pass.
4. Scope and state-file gates must pass.
5. If `COMMIT_ON_PASS=1`, the git commit must succeed.
6. The runtime updates lifecycle state only after the previous gates pass.

critic PASS is necessary but not sufficient. A task cannot complete on critic PASS alone; verify failure, out-of-scope changes, state-file modification, malformed or non-PASS verdicts, and commit failure all prevent PASS. FAIL paths roll back implementation changes as appropriate, preserve shell evidence, record the failure, and update lifecycle state.

### Rate limit handling

When a ChatGPT or Gemini rate limit is detected:
- If in Implementer or Impl Critic stage, auto git rollback to the pre-task snapshot
- Failure count is not incremented
- Exits safely with code 2
- Resume with the same command after the limit resets

This is recovery from a provider quota interruption, not a task failure.

### Task attempts and BLOCKED tasks

Each task may fail up to five consecutive implementation/review attempts. After the fifth consecutive failure, the runtime marks the task BLOCKED, records the reason, and moves on to the next runnable task. BLOCKED tasks are not retried automatically in the same run; update the backlog or task scope intentionally before trying them again.

### Transaction recovery

The loop records in-progress lifecycle updates in `.loop-agent/current_transaction.json`. If a previous run exits during a state transition, the next startup checks that transaction file and either finishes or rolls back the pending state change before selecting another task. This protects loop-owned state transitions, but it is not a guarantee of perfect crash recovery for every possible OS, disk, or git failure.

### Project lock

Each run acquires `.loop-agent/loop.lock` before modifying loop state. A second run against the same project exits instead of racing the active run. Normal exits remove the lock; stale locks from dead processes are cleaned up on startup when the owning process is no longer running.

### Rollback boundaries

Rollback is per task and git-based. On implementation failure, verify failure, critic failure, out-of-scope changes, state-file modification, or rate-limit exit during implementation/review, LoopDex restores the project to the pre-task working tree state. Shell evidence and loop-owned reports under `.loop-agent/` may be preserved for debugging, and files that were already committed by earlier passed tasks are not rolled back. Rollback depends on git state and the current working tree; it is not protection against commands that affect files outside the project, external services, credentials, system settings, or changes already committed in earlier passed tasks.

Safety failures are recorded in raw `.loop-agent/progress.txt` evidence. When `.loop-agent/progress_window.md` is available, it summarizes recent progress and failure context for agent prompts, but it is not the system source of truth.

### State file protection

If an agent modifies state files under `.loop-agent/` (backlog, progress, etc.), they are automatically restored. Legitimate agent outputs (plan.md, impl_summary.md, etc.) are not affected.

### Secret path guard

After Implementer runs, LoopDex blocks changes to obvious secret-like paths such as `.env`, private key filenames, and paths containing `private_key`. This guard is path-based only: it does not scan file contents for credentials, does not catch every secret naming pattern, and does not make LoopDex a sandbox.

### Verify command gate

Backlog `Verify` commands in `.loop-agent/backlog.md` are authoritative. Planner output, Implementer summaries, and critic summaries cannot override, replace, or skip the backlog-defined verify command.

After implementation, the loop runs the verify command from the user's shell and records the shell evidence. A nonzero exit code or verify timeout is treated as verify failure and prevents PASS, even if the Impl Critic says PASS.

This verify policy is a PASS gate, not a complete security sandbox. Dangerous commands in trusted backlog verify fields can still run with the user's shell permissions, so backlog verify commands must be reviewed before running the loop.

### Scope gate evidence

Each loop writes an evidence directory under `.loop-agent/` for shell-collected review data. This evidence includes git data such as changed files, diff stats, and out-of-scope files, and the evidence directory is preserved for inspection even when implementation changes are rolled back.

Evidence retention keeps the current loop evidence directory and the newest `LOOP_EVIDENCE_KEEP_RUNS` loop evidence directories. Older unprotected loop evidence is archived as `.tar.gz` files, or compacted to a summary file if archiving is unavailable. Evidence referenced by blocked tasks is preserved by default.

The scope gate uses git shell evidence as the authoritative source for actual changed files. The backlog `Files` field defines the approved write scope; out-of-scope changes prevent PASS. `impl_summary.md` is an agent report, not the source of truth for changed files.

### Run-mode backlog immutability

Explicit `run` mode treats backlog semantics as immutable. A semantic mutation is any change that alters what a backlog task means, including task scope, `Files`, `Depends`, verify commands, completion criteria, description, or ordering constraints. Runtime lifecycle fields such as status, fail count, and completion state are loop-owned execution state; they may change as the loop runs, but they do not redefine the task.

Run mode preserves task meaning by refusing automatic edits to scope, `Files`, `Depends`, verify commands, or completion criteria. If implementation discovers that a task needs more files or a different dependency shape, the agent reports that need instead of changing the backlog. This keeps review boundaries stable: `Files` remains the approved write scope, and `Depends` remains the approved execution order.

Semantic backlog mutation is disabled by default, and mutation verdicts are proposal-only by default. `SCOPE_EXPAND` and `SPLIT_TASK` recommendations create standardized proposal files for review; they do not automatically expand scope, split tasks, insert dependencies, or apply backlog semantic changes by default. Deeper rules are documented in [`docs/design_invariants.md`](docs/design_invariants.md).

`SCOPE_EXPAND` is proposal-only in normal `run` mode. It blocks the active task and records the requested scope change for review, but it does not mutate semantic fields such as `Files`, `Depends`, verify commands, completion criteria, or description, and it does not increment `Fail count`. A human must intentionally update the backlog scope or dependencies before retrying the task.

`SPLIT_TASK` is also proposal-only in normal `run` mode. It is used when the active task is too broad or discovery shows that ordered child tasks are needed. The loop blocks the active task for human review, does not increment `Fail count`, and does not automatically split the task, insert child tasks, rewrite dependencies, or otherwise change backlog structure. A human must edit the backlog intentionally before retrying.

Future automatic scope expansion, task splitting, or dependency insertion remains disabled by default and is governed by [`docs/backlog_mutation_policy.md`](docs/backlog_mutation_policy.md). The experimental flags `LOOP_ALLOW_AUTO_SCOPE_EXPAND=1`, `LOOP_ALLOW_AUTO_TASK_SPLIT=1`, and `LOOP_ALLOW_AUTO_DEPENDENCY_INSERT=1` exist only for guarded experiments and are not recommended for normal users.

### Interrupt handling

- Ctrl+C restores any in-progress changes automatically
- If SIGKILL or a system crash prevented cleanup, the next run cleans up leftover backups on startup

### Atomic writes

`backlog.md` updates use a temp file + `os.replace` pattern. Interruptions or disk-full conditions cannot corrupt the file.

---

## Output during a run

```
╔══════════════════════════════════════╗
║  Setup Phase  ·  generating backlog.md
╚══════════════════════════════════════╝

── Setup Agent ──
  [Setup Agent] running... (cli: codex, model: gpt-5.5, reasoning: high)
✓ [Setup Agent] done

Approve (y/e/n): y
✓ backlog.md approved.

Progress: ░░░░░░░░░░░░░░░░░░░░ 0/12 Tasks (0%)

╔══════════════════════════════════════╗
║  Loop 1 / 5
╚══════════════════════════════════════╝

  Current task: Task 1.1 — Define core models
── Phase 1 · Planner ──
  Plan goal: Add GenreProfile schema
✓ Plan PASS

── Phase 3 · Implementer ──
  Completed steps:
  ✓ Task 1: Add tropeEmphasis field to GenreProfile schema
✓ Implementation PASS

✓ backlog updated: Task 1.1 complete
Progress: ██░░░░░░░░░░░░░░░░░░ 1/12 Tasks (8%)
```

Blocked proposal outcomes are reported as blocked progress, not ordinary failures:

```text
Task 3.2 blocked with SCOPE_EXPAND
Blocked reason: implementation requires docs/api_contract.md, which is outside the approved Files scope.
Evidence/proposal: .loop-agent/evidence/loop-4/scope_expand_proposal.md
Human action required: accept by editing backlog Files or dependencies, or reject by revising/leaving the task blocked before retry.
Fail count: unchanged at 0.
```

```text
Task 5.1 blocked with SPLIT_TASK
Blocked reason: current task requires separate storage and UI changes that need ordered child tasks.
Evidence/proposal: .loop-agent/evidence/loop-7/split_task_proposal.md
Human action required: accept by replacing the backlog task with reviewed child tasks, or reject by revising/leaving the task blocked before retry.
Fail count: unchanged at 1.
```

---

## Observability and output files

The backlog and `.loop-agent/events.jsonl` are the durable inputs for `status` and final reports. Reports and status output should use backlog state and machine-readable events, not parse agent-facing Markdown.

`.loop-agent/progress.txt` is the raw per-loop progress and debug log. It is useful when investigating a failure, and it may be trimmed when it exceeds the configured size threshold.

`.loop-agent/progress_window.md` is bounded Markdown context for agents. It summarizes recent progress and failure context for prompts, but it is not the source of truth for status, reporting, or task state.

`.loop-agent/events.jsonl` is the machine-readable system event log for run lifecycle, task progress, blocked-task state, and report/status generation.

`.loop-agent/current_transaction.json` is recovery state for in-progress lifecycle updates. It lets startup finish or roll back a pending state transition before another task is selected.

Final report files, including `.loop-agent/report.md` and per-loop files under `.loop-agent/reports/` when present, summarize completed work, failures, blocked tasks, verify results, and evidence pointers after a run.

Loop evidence is stored under `.loop-agent/evidence/`. Evidence retention keeps the current loop evidence directory and the newest `LOOP_EVIDENCE_KEEP_RUNS` loop evidence directories. Evidence referenced by blocked tasks is preserved by default. Older unprotected loop evidence may be archived as `.tar.gz` files or compacted to a summary file if archiving is unavailable. Retention is for recent debugging context, not permanent archival.

```
myproject/
  .loop-agent/
    backlog.md          ← full task list + completion status
    progress.txt        ← raw per-loop progress/debug log (auto-trimmed)
    progress_window.md  ← bounded Markdown context window for agents; not system truth
    report.md           ← cumulative report
    codex.log           ← agent stderr log (for debugging)
    events.jsonl        ← machine-readable system event log
    current_transaction.json  ← recovery state for pending lifecycle updates
    reports/            ← per-loop detail (when present)
```

---

## Troubleshooting

### `ChatGPT login required`
```bash
codex login
```

### `Gemini authentication not detected`
```bash
export GEMINI_API_KEY=<your_key>
# or
gemini   # OAuth login
```

### `codex/gemini CLI not found`
```bash
npm install -g @openai/codex       # codex
npm install -g @google/gemini-cli  # gemini
```

### `python not found`
Install Python 3.8+. On Windows, the Microsoft Store launcher (`WindowsApps/python3`) is not supported.

### `gemini --version failed`
Likely a CLI version compatibility issue. Override flags with `LOOP_GEMINI_*` environment variables.

### pnpm not found in Windows Git Bash
```bash
echo 'export PATH="$PATH:/c/Users/yourname/AppData/Roaming/npm"' >> ~/.bashrc
source ~/.bashrc
```

### Resuming after a rate limit exit

If the process exited with code 2, wait for the limit to reset and run the same command again. Already-completed tasks are skipped automatically.

```bash
./loop.sh run --project ./myproject --iterations 5 --cli codex   # hits rate limit, exit 2
# (wait)
./loop.sh run --project ./myproject --iterations 5 --cli codex   # resumes where it left off
```

---

## File structure

```
LoopDex/
  loop.sh                              ← entry point
  backlog_manager.py                   ← backlog.md parsing and atomic updates
  progress_window.py                   ← progress.txt sliding window + truncation
  backlog_guide.md                     ← backlog format spec and generation instructions
  TASK_PLANNING_FAILURE_PATTERNS.md    ← recurring failure patterns and how to avoid them
  agents/
    setup_agent.md     ← reads planning docs, generates backlog.md
    setup_critic.md    ← validates backlog.md quality
    planner.md         ← breaks task into steps
    plan_critic.md     ← reviews the plan independently
    implementer.md     ← writes code and runs verify
    impl_critic.md     ← reviews implementation independently
```

---

## Usage limits

### Codex (ChatGPT Plus)

Each loop triggers up to 5 Codex calls. The Plus plan has usage limits — many iterations may hit the cap. The agent exits safely on detection, and you can resume after the limit resets.

### Gemini

Watch usage and cost when using an API key. The free tier has per-minute request limits.

---

## Comparison with related tools

| | LoopDex | Codex `/goal` | aider | OpenHands | gpt-engineer |
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

`/goal`, `aider`, OpenHands, and gpt-engineer are all excellent at what they do. LoopDex fills the specific slot of *unattended multi-task batches with hard review gates on top of subscription CLIs*.

---

## Legal & disclaimers

- **Third-party services.** LoopDex invokes external CLIs (OpenAI Codex, Google Gemini, and optionally Anthropic Claude Code). Your planning documents, source code, and prompts are transmitted to those providers under their own privacy and usage policies. Do not feed sensitive personal data, regulated information, or third-party confidential material unless your use of those providers permits it.
- **Terms of Service.** You are responsible for ensuring that your use of LoopDex — including automated, looped invocation of paid CLIs — complies with the Terms of Service of OpenAI, Google, Anthropic, and any other upstream provider. The authors of LoopDex do not represent that any particular usage pattern is permitted by those providers, and accept no liability for account suspensions, billing, or other consequences arising from such use.
- **Trademarks.** "ChatGPT", "Codex", "GPT" are trademarks of OpenAI. "Gemini", "Vertex AI", "Google Cloud", "Google AI Studio" are trademarks of Google LLC. "Claude", "Claude Code" are trademarks of Anthropic, PBC. "Windows", "Microsoft Store" are trademarks of Microsoft Corporation. All other product names mentioned are property of their respective owners. Use here is nominative and does not imply endorsement or affiliation.
- **Model names.** Default model identifiers in this repository (e.g. `gpt-5.5`, `gemini-3.1-pro-preview`) are examples and may not match the model IDs your account currently has access to. Override them via the documented environment variables.
- **Autonomous execution.** As stated in the Safety notice above, LoopDex runs AI agents that generate and execute code without per-step human approval. The user is solely responsible for selecting an appropriate target directory and runtime environment.
- **Input content.** You retain ownership of any planning documents and source code you provide. By running LoopDex you confirm you have the right to share that content with the upstream LLM providers you have configured.

---

## License

MIT — see [LICENSE](LICENSE).

The software is provided "as is", without warranty of any kind, express or implied. See LICENSE for full terms.
