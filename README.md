<div align="center">

# 🌀 LoopDex

### *Run a coding agent against a backlog overnight — and wake up to commits, not chaos.*

**A subscription-friendly orchestrator for [OpenAI Codex](https://github.com/openai/codex) and [Google Gemini CLI](https://github.com/google-gemini/gemini-cli)**, with independent-process critics, per-task git rollback, and rate-limit-safe resume.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
[![Codex](https://img.shields.io/badge/CLI-OpenAI%20Codex-10A37F?style=flat-square&logo=openai&logoColor=white)](https://github.com/openai/codex)
[![Gemini](https://img.shields.io/badge/CLI-Google%20Gemini-4285F4?style=flat-square&logo=google&logoColor=white)](https://github.com/google-gemini/gemini-cli)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey?style=flat-square)](#prerequisites)
[![Status](https://img.shields.io/badge/status-experimental-orange?style=flat-square)](#-honest-positioning)

```bash
./loop.sh init --project ./myproject
./loop.sh run  --project ./myproject -i 30
# go to bed.
```

</div>

---

## 🎯 What this actually is

LoopDex is **not** a new coding agent. It is a small, opinionated **outer loop** that takes the coding agents you already pay for — Codex on ChatGPT Plus, Gemini on its free / Code Assist quota — and pushes them through a backlog of tasks one by one, with checks between each task.

The pitch in one breath:

> Drop your planning docs into a folder, set an iteration count, and a multi-stage pipeline (**Plan → Critic → Implement → Critic → verify → scope gate → commit-or-rollback**) chews through the backlog while you sleep. Each stage is a **separate CLI process** so the critic never sees the implementer's reasoning — only the diff.

If the next task fails the gates, the working tree is **rolled back** and the loop moves on. If the provider rate-limits you, the loop **exits clean** and resumes when you re-run.

That's the whole product. It's a hundred lines of bash, some Python, and a lot of small decisions.

---

## 🧭 Honest positioning

LoopDex is a **shell-level orchestrator**, not a sandbox, not a new agent, not a replacement for Codex / Claude Code / Gemini CLI. It executes AI-generated code **with your shell permissions**, on your machine, against a git repo.

**You should consider it when:**

- ✅ You have a personal repo with **decent test coverage**
- ✅ You want to grind a **multi-task backlog unattended** (overnight, weekend)
- ✅ You'd rather pay a flat **ChatGPT Plus / Gemini subscription** than per-token
- ✅ You're comfortable running coding agents in a **dedicated branch** of a project you can throw away

**You should pick something else when:**

| If you want… | Use |
|---|---|
| One sharp interactive task | `aider`, Claude Code, Codex `/goal` |
| Sandboxed cloud execution + PR workflow | [GitHub Copilot coding agent](https://docs.github.com/copilot/concepts/agents/coding-agent/about-coding-agent), [OpenHands](https://www.openhands.dev/) |
| A polished GUI with logs and review | OpenHands, Cursor |
| Strict isolation (Docker / VM / RBAC) | OpenHands, Codex Cloud |
| Issues-as-source-of-truth | Copilot agent on GitHub Issues |

LoopDex deliberately occupies a narrow slice: **subscription-billed, multi-task, unattended, local, with hard gates between tasks**. If that slice isn't yours, please use one of the excellent tools above.

---

## ⚡ Quick start

```bash
# 1) Install one CLI you already have a subscription for
npm install -g @openai/codex     && codex login         # OR
npm install -g @google/gemini-cli && gemini             # OAuth login

# 2) Get LoopDex
git clone https://github.com/minseo2222/LoopDex.git
cd LoopDex && chmod +x loop.sh

# 3) Point it at a project that has planning docs (SPEC.md, REQUIREMENTS.md, …)
./loop.sh init --project /path/to/myproject     # one-time wizard
./loop.sh run  --project /path/to/myproject     # asks for iteration count
```

The first run launches a **4-question wizard**: CLI · model ID · branch prefix · backlog source. Answers persist to `.loop-agent/config.env`. Subsequent runs only ask how many iterations.

> **Precedence:** `--flag` > exported env var > `config.env` > built-in default.

`init` also bootstraps a sensible `.gitignore` (secrets block, editor metadata, language-specific patterns) **before** the first commit, so `__pycache__/`, `node_modules/`, `.env`, etc. never leak into history.

---

## 🔁 The loop

```
            ┌──────────────────────────────────────────────────────────┐
 init  ──►  │   Setup Agent  ─►  Setup Critic  ─►  human y/e/n         │
            └────────────────────────────────┬─────────────────────────┘
                                             ▼
                                     .loop-agent/backlog.md
                                             │
            ┌────────────────────────────────┴─────────────────────────┐
 run   ──►  │  pick next runnable task                                 │
            │                                                          │
            │  Planner ─► Plan Critic ─► Implementer ─► Impl Critic    │
            │                                                          │
            │  ─►  verify command  ─►  scope gate  ─►  commit OR roll  │
            └──────────────────────────────────────────────────────────┘
                          │
                          └─►  next task, or exit on rate-limit / done
```

Each stage is a **separate CLI invocation**. The Plan Critic only sees `plan.md`. The Impl Critic only sees the diff and the verify output. Neither sees the implementer's chain of thought. That's the whole point — the same model can review itself when it's not allowed to remember why it made a choice.

### Final decision gates *(deterministic, in order)*

1. Proposal verdicts (`SCOPE_EXPAND`, `SPLIT_TASK`) → block for human review, no fail count
2. Impl Critic must return PASS
3. Backlog `verify:` commands must pass (real, non-LLM checks)
4. Scope gate (changed files ⊆ backlog `Files`) and state-file gate must pass
5. If `COMMIT_ON_PASS=1`, `git commit` must succeed

Critic PASS is **necessary but not sufficient.** Any gate failure → rollback, fail count +1. **5 consecutive failures → BLOCKED, the loop moves on.**

---

## 🛡️ Safety — read this before you point it at anything

LoopDex is **not a sandbox.** It runs agent and verify commands with **your shell permissions**, by design.

By default it runs in `unattended` mode, which means:

- `.claude/settings.json` uses `"defaultMode": "bypassPermissions"`
- Codex runs with `--dangerously-bypass-approvals-and-sandbox`
- Gemini default flags include `--yolo`
- The loop calls `git commit` and rollback automatically without asking

This is what makes overnight runs possible. It is also what makes LoopDex dangerous if pointed at the wrong directory. **Treat the agent like an unsupervised intern with shell access.**

### Operating rules (non-negotiable)

| # | Rule |
|---|---|
| 1 | **Dedicated git project directory.** Never `$HOME`, never a repo with uncommitted work you can't lose. |
| 2 | **Dedicated branch.** `git checkout -b loop/work` before `run`. |
| 3 | **Clean tree before run.** Commit/stash your edits — rollback boundaries depend on it. |
| 4 | **Treat planning docs as untrusted input.** Prompt injection can steer the agent. |
| 5 | **Run inside a fresh VM / container / throwaway user account** when possible. |

`LOOP_RISK_MODE=safe` strips the bypass flags where supported. It does **not** add a sandbox. See [`docs/security.md`](docs/security.md) for the full boundary list.

### What's actually built in

- 🧯 **Per-task git rollback** on any gate failure
- ⏸️ **Rate-limit recovery** — exit code 2, no fail-count increment, resume on next run
- 🔁 **Transaction recovery** — `current_transaction.json` finishes or rolls back on next startup
- 🔒 **Project lock** — second run against the same project exits cleanly instead of racing
- 📁 **State-file protection** — agents cannot modify `.loop-agent/` artifacts the loop owns
- 🚫 **Secret-path guard** — blocks writes to `.env`, `private_key`, etc. *(path-based, not content-scanning)*
- ✅ **Verify gate** — backlog `Verify` commands are authoritative; agent text cannot bypass them
- 📐 **Scope gate** — changed files (from `git status`, not agent self-report) must ⊆ backlog `Files`
- 🪪 **Atomic backlog writes** via temp-file + `os.replace`

---

## 🧪 Exit conditions

| Situation | Code |
|---|---|
| All tasks complete | `0` |
| Iterations exhausted, tasks remain | `0` |
| Only BLOCKED tasks remain | `1` |
| **Rate limit hit** (auto-rollback, resume-safe) | `2` |
| Ctrl+C (state restored) | `130` |

After a rate-limit exit, **just re-run the same command** once the limit resets. Already-completed tasks are skipped.

---

## ⌨️ Commands

```bash
./loop.sh init   --project <dir> [--cli codex|gemini]
./loop.sh run    --project <dir> [--cli codex|gemini] [-i N]
./loop.sh status --project <dir>
./loop.sh doctor --project <dir>
```

`run` requires:

- An existing `.loop-agent/backlog.md` (run `init` first)
- A clean working tree
- Backlog passes `python backlog_manager.py lint`
- Iteration count via `-i N` or interactive prompt (CI must pass `-i`)

Optional: `LOOP_REQUIRE_BRANCH_PREFIX=loop/` refuses to start unless you're on a matching branch.

---

## ⚙️ Configuration

The wizard handles the common cases. The env vars below are for one-off overrides.

<details>
<summary><b>Common</b></summary>

| Variable | Default | Purpose |
|---|---|---|
| `COMMIT_ON_PASS` | `1` | Auto-commit on PASS. `0` = accumulate in working tree |
| `LOOP_RISK_MODE` | `unattended` | `unattended` keeps bypass flags; `safe` strips them |
| `LOOP_REQUIRE_BRANCH_PREFIX` | unset | Refuse to start `run` unless current branch matches |
| `LOOP_EVIDENCE_KEEP_RUNS` | `10` | Keep newest N evidence dirs (`0` = disable) |
| `LOOP_EVIDENCE_PRUNE_PASS` | `1` | Delete a loop's evidence dir after PASS commit |
| `PROGRESS_SIZE_THRESHOLD` | `524288` | Trim `progress.txt` past this size |
| `PROGRESS_KEEP_ENTRIES` | `50` | Recent sections to retain after trim |

</details>

<details>
<summary><b>Codex</b></summary>

| Variable | Default | Purpose |
|---|---|---|
| `CODEX_MODEL` | `gpt-5.5` | Wizard offers `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex`, `gpt-5.3-codex-spark`, `gpt-5.2`, plus an "Other" escape. |

</details>

<details>
<summary><b>Gemini</b></summary>

| Variable | Default | Purpose |
|---|---|---|
| `LOOP_GEMINI_MODEL` | `gemini-3.1-pro-preview` | Wizard offers Gemini 3.1 Pro / Flash / Lite previews and 2.5 Pro / Flash, plus "Other". |
| `LOOP_GEMINI_FLAGS` | `--yolo` (unattended) / empty (safe) | Override CLI flags |
| `LOOP_GEMINI_MODEL_FLAG` | `--model` | Flag used to specify the model |
| `LOOP_GEMINI_USE_PROMPT_ARG` | `0` | `1` = pass prompt via `-p` instead of stdin |

</details>

---

## 📂 Project layout

```
myproject/
└── .loop-agent/
    ├── config.env             ← per-project wizard answers
    ├── backlog.md             ← task list + status (source of truth)
    ├── events.jsonl           ← machine-readable event log
    ├── progress.txt           ← per-loop debug log (auto-trimmed)
    ├── progress_window.md     ← bounded context for agents
    ├── report.md              ← cumulative report
    ├── current_transaction.json
    ├── evidence/loop-N/       ← per-loop verify/scope/diff evidence
    ├── reports/               ← per-loop detail
    └── codex.log              ← agent stderr
```

`status` and final reports derive from `backlog.md` + `events.jsonl`. **Don't parse `progress_window.md`** — it's agent-facing context, not authoritative.

---

## 📋 Backlog format

The backlog is the source of truth. Four files govern it:

| File | Role |
|---|---|
| [`backlog_guide.md`](backlog_guide.md) | Format spec, sizing rules, quality checklist |
| [`agents/setup_agent.md`](agents/setup_agent.md) | Generates `backlog.md` from your planning docs |
| [`agents/setup_critic.md`](agents/setup_critic.md) | Validates the generated backlog |
| [`TASK_PLANNING_FAILURE_PATTERNS.md`](TASK_PLANNING_FAILURE_PATTERNS.md) | Living catalog of recurring planning failures |

Each task needs an **ID**, **Size** (`Small` or `Medium`), **Files**, **Description**, **Completion criteria** (with at least one `verify:` command), **Depends**, and **Fail count**. Markers: `[ ]` pending, `[x]` done, `[!]` blocked.

```bash
python backlog_manager.py lint .loop-agent/backlog.md
```

You can also write `backlog.md` yourself in Claude Code by pasting `backlog_guide.md` and pointing it at your docs, then jumping straight to `./loop.sh run`.

---

## 🧰 Prerequisites

- macOS / Linux / Windows (Git Bash)
- Node.js 18+
- Python 3.8+ — *the `python` command, not the Microsoft Store launcher*
- One of:
  - **Codex** → ChatGPT Plus or higher
  - **Gemini** → OAuth (Code Assist quota), `GEMINI_API_KEY`, or Vertex AI

---

## 🩹 Troubleshooting

| Symptom | Fix |
|---|---|
| `ChatGPT login required` | `codex login` |
| `Gemini authentication not detected` | `gemini` (OAuth) or `export GEMINI_API_KEY=...` |
| `codex/gemini CLI not found` | `npm install -g @openai/codex` / `@google/gemini-cli` |
| `python not found` | Install Python 3.8+ (avoid the Windows Store launcher) |
| `gemini --version failed` | Override flags via `LOOP_GEMINI_*` |
| pnpm not found in Git Bash | Add `/c/Users/<you>/AppData/Roaming/npm` to `PATH` |
| `Iterations required for run mode` | Pass `-i N` or run from an interactive terminal |
| Want to change CLI / model / branch prefix | Edit or delete `.loop-agent/config.env` |
| Scope gate keeps flagging build artifacts | Re-run `init` to refresh `.gitignore`; if files are tracked, `git rm --cached <path>` |
| Exit code 2 (rate limit) | Wait, then re-run the same command |
| Not sure if the environment is ready | `./loop.sh doctor --project <dir>` |

---

## 🧬 Testing

```bash
# Happy-path E2E (uses fake CLI — no real provider calls)
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

## ⚖️ How LoopDex compares

The other tools below are excellent. LoopDex isn't trying to replace them — it just fills one specific slot they don't.

|  | LoopDex | Codex `/goal` | aider | OpenHands | Copilot agent |
|---|:---:|:---:|:---:|:---:|:---:|
| Multi-task backlog from docs | ✅ | ❌ | ❌ | partial | partial *(Issues)* |
| Independent-process critic | ✅ | ❌ | ❌ | ❌ | ❌ |
| Per-task git rollback | ✅ | ❌ | partial | ❌ | n/a *(PR-based)* |
| Resume on rate-limit | ✅ | ❌ | n/a | n/a | n/a |
| Multi-vendor (Codex + Gemini) | ✅ | ❌ | ✅ | ✅ | ❌ |
| Subscription-only billing | ✅ | ✅ | ❌ | ❌ | ✅ |
| Zero-Docker install | ✅ | ✅ | ✅ | ❌ | n/a |
| Sandbox / isolation | ❌ | ✅ | ❌ | ✅ | ✅ |
| Web UI / dashboard | ❌ | ❌ | ❌ | ✅ | ✅ |
| Interactive conversation | ❌ | partial | ✅ | ✅ | partial |

**LoopDex's slice:** *unattended multi-task batches with hard review gates on top of subscription CLIs.* If you need sandboxing, GUI, or PR workflow, the right answer is one of the columns to the right.

---

## 📁 File structure

```
LoopDex/
├── loop.sh                              ← entry point
├── backlog_manager.py                   ← backlog parsing + atomic updates
├── progress_window.py                   ← progress.txt sliding window
├── backlog_guide.md                     ← backlog format spec
├── TASK_PLANNING_FAILURE_PATTERNS.md    ← failure pattern catalog
├── agents/
│   ├── setup_agent.md   setup_critic.md ← Setup Phase
│   ├── planner.md       plan_critic.md  ← Planning stage
│   └── implementer.md   impl_critic.md  ← Implementation stage
└── docs/
    ├── security.md      dogfood.md      backlog_mutation_policy.md
    └── design_invariants.md             legacy_run.md
```

The legacy `run.sh` document-driven workflow is retained for compatibility — see [`docs/legacy_run.md`](docs/legacy_run.md). New usage should prefer `init` + `run`.

---

## ⚠️ Legal & disclaimers

- **Third-party services.** LoopDex invokes external CLIs (OpenAI Codex, Google Gemini, optionally Anthropic Claude Code). Your docs, source, and prompts are transmitted under those providers' policies. Don't feed sensitive or regulated data unless your provider terms permit.
- **Terms of service.** You are responsible for ensuring looped, automated CLI invocation complies with each provider's ToS. The authors make no representation that any usage pattern is permitted, and accept no liability for suspensions or charges.
- **Trademarks.** "ChatGPT", "Codex", "GPT" — OpenAI. "Gemini", "Vertex AI", "Google Cloud" — Google LLC. "Claude", "Claude Code" — Anthropic. Use here is nominative; no endorsement implied.
- **Model names.** Default model IDs reflect IDs that worked at release. Provider availability shifts; if a default returns "model not found", pick a different ID via the wizard or env var.
- **Autonomous execution.** LoopDex runs AI-generated code without per-step approval. You choose the target directory and runtime environment.
- **Input content.** You retain ownership of your docs and code. By running LoopDex you confirm you have the right to share that content with your configured providers.

---

<div align="center">

### 📜 License

**MIT** — see [LICENSE](LICENSE). Provided "as is", without warranty of any kind.

<sub>If LoopDex saves you a few hours of unattended grinding, a ⭐ on the repo is the only currency it accepts.</sub>

</div>
