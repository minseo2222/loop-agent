# loop-agent

Drop your planning docs into a project folder, set the number of iterations, and loop-agent autonomously builds the full backlog, then runs a plan → implement → review cycle to write your code.

Supported CLIs: **OpenAI Codex** (default), **Google Gemini**

---

## ⚠️ Safety notice — read before running

loop-agent runs AI agents **autonomously** and **executes code they generate without human approval at each step**. By design it ships with permissive defaults so the loop can run unattended:

- The bundled `.claude/settings.json` sets `"defaultMode": "bypassPermissions"`.
- The default Gemini flags include `--yolo`, which bypasses the CLI's sandbox/approval prompts.
- The loop calls `git commit` and `git rollback` on the target project automatically.

Because of this, you should:

1. **Run only against a dedicated project directory** under version control. Never point it at your home directory, system folders, or a repo with uncommitted work you cannot afford to lose.
2. **Prefer an isolated environment** (a fresh VM, container, or throwaway workspace) — at minimum a dedicated user account.
3. **Review `.claude/settings.json` and `LOOP_GEMINI_FLAGS`** and tighten them if you do not want bypass-permission behavior.
4. **Treat planning docs as untrusted input** if they came from outside your team — prompt-injected docs can steer the agent.

The authors provide this software **as-is, with no warranty**. You are responsible for what the agent does on your machine.

---

## How it works

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

Each stage runs as an **independent process** — no context from the previous stage carries over, which ensures review independence.

PASS → marks the backlog task complete and prints progress  
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

loop-agent does not call the Gemini API directly — it runs the `gemini` CLI command.

Authentication method determines quota and cost:

- Google account OAuth login: uses Gemini CLI / Code Assist account quota
- `GEMINI_API_KEY`: uses Google AI Studio / Gemini API key, may apply free tier limits or charges
- Vertex AI: billed under your Google Cloud / Vertex AI project

Avoid unexpected charges by verifying which authentication method is active.

### Install loop-agent

```bash
unzip loop-agent.zip -d ~/loop-agent
cd ~/loop-agent
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

---

## Backlog generation

The backlog is the single source of truth for what loop-agent builds. There are four files involved:

| File | Role |
|------|------|
| [`backlog_guide.md`](backlog_guide.md) | Human-readable spec: backlog format, task sizing rules, quality checklist. Read this to understand or manually edit a backlog. |
| [`agents/setup_agent.md`](agents/setup_agent.md) | Prompt that drives the Setup Agent. Reads your planning docs and generates `.loop-agent/backlog.md` automatically. |
| [`agents/setup_critic.md`](agents/setup_critic.md) | Prompt that drives the Setup Critic. Validates the generated backlog and requests a retry if quality checks fail. |
| [`TASK_PLANNING_FAILURE_PATTERNS.md`](TASK_PLANNING_FAILURE_PATTERNS.md) | Living document of recurring failure patterns — task scope too broad, missing verify commands, keyword-only validation, BLOCKED mishandling, and more. Both Setup Agent and Setup Critic reference this when generating and validating backlogs. |

### Generating manually with Claude Code

If you prefer to generate the backlog yourself instead of running the Setup Phase:

1. Open your project folder in Claude Code
2. Copy the contents of [`backlog_guide.md`](backlog_guide.md) into the conversation
3. Claude will analyze your planning docs and write `.loop-agent/backlog.md`
4. Review and edit as needed, then run `./loop.sh N .` to start looping

### Run

```bash
./loop.sh <iterations> <project-folder> [cli]
```

`cli` is optional, defaults to `codex`. Options: `codex` | `gemini`.

```bash
# Default (codex)
./loop.sh 5 /Users/yourname/myproject
./loop.sh 5 .

# Explicit CLI
./loop.sh 5 /myproject codex
./loop.sh 5 /myproject gemini

# Windows (Git Bash)
./loop.sh 5 "/c/Users/yourname/myproject" gemini
```

---

## Environment variables

### Common

| Variable | Default | Purpose |
|----------|---------|---------|
| `COMMIT_ON_PASS` | `1` | Auto-commit on PASS. Set to `0` to accumulate in working tree |
| `PROGRESS_SIZE_THRESHOLD` | `524288` (512KB) | Trim progress.txt when it exceeds this size |
| `PROGRESS_KEEP_ENTRIES` | `50` | Number of recent sections to keep after trim |

### Codex only

| Variable | Default | Purpose |
|----------|---------|---------|
| `CODEX_MODEL` | `gpt-5.5` | Codex model to use |

```bash
CODEX_MODEL=gpt-5.4 ./loop.sh 5 . codex
```

### Gemini only

| Variable | Default | Purpose |
|----------|---------|---------|
| `LOOP_GEMINI_MODEL` | `gemini-3.1-pro-preview` | Model ID |
| `LOOP_GEMINI_FLAGS` | `--yolo` | Flags to bypass sandbox/approval |
| `LOOP_GEMINI_MODEL_FLAG` | `--model` | Flag used to specify the model |
| `LOOP_GEMINI_USE_PROMPT_ARG` | `0` | Set to `1` to pass prompt via `-p` instead of stdin |

```bash
# Different model
LOOP_GEMINI_MODEL=gemini-2.5-pro ./loop.sh 5 . gemini

# For versions that don't support stdin
LOOP_GEMINI_USE_PROMPT_ARG=1 ./loop.sh 5 . gemini
```

---

## Safety mechanisms

### Rate limit handling

When a ChatGPT or Gemini rate limit is detected:
- If in Implementer or Impl Critic stage, auto git rollback
- Failure count is not incremented
- Exits safely with code 2
- Resume with the same command after the limit resets

### State file protection

If an agent modifies state files under `.loop-agent/` (backlog, progress, etc.), they are automatically restored. Legitimate agent outputs (plan.md, impl_summary.md, etc.) are not affected.

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

---

## Output files

```
myproject/
  .loop-agent/
    backlog.md          ← full task list + completion status
    progress.txt        ← per-loop execution log (auto-trimmed)
    report.md           ← cumulative report
    codex.log           ← agent stderr log (for debugging)
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
./loop.sh 5 ./myproject codex   # hits rate limit → exit 2
# (wait)
./loop.sh 5 ./myproject codex   # resumes where it left off
```

---

## File structure

```
loop-agent/
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

## Legal & disclaimers

- **Third-party services.** loop-agent invokes external CLIs (OpenAI Codex, Google Gemini, and optionally Anthropic Claude Code). Your planning documents, source code, and prompts are transmitted to those providers under their own privacy and usage policies. Do not feed sensitive personal data, regulated information, or third-party confidential material unless your use of those providers permits it.
- **Terms of Service.** You are responsible for ensuring that your use of loop-agent — including automated, looped invocation of paid CLIs — complies with the Terms of Service of OpenAI, Google, Anthropic, and any other upstream provider. The authors of loop-agent do not represent that any particular usage pattern is permitted by those providers, and accept no liability for account suspensions, billing, or other consequences arising from such use.
- **Trademarks.** "ChatGPT", "Codex", "GPT" are trademarks of OpenAI. "Gemini", "Vertex AI", "Google Cloud", "Google AI Studio" are trademarks of Google LLC. "Claude", "Claude Code" are trademarks of Anthropic, PBC. "Windows", "Microsoft Store" are trademarks of Microsoft Corporation. All other product names mentioned are property of their respective owners. Use here is nominative and does not imply endorsement or affiliation.
- **Model names.** Default model identifiers in this repository (e.g. `gpt-5.5`, `gemini-3.1-pro-preview`) are examples and may not match the model IDs your account currently has access to. Override them via the documented environment variables.
- **Autonomous execution.** As stated in the Safety notice above, loop-agent runs AI agents that generate and execute code without per-step human approval. The user is solely responsible for selecting an appropriate target directory and runtime environment.
- **Input content.** You retain ownership of any planning documents and source code you provide. By running loop-agent you confirm you have the right to share that content with the upstream LLM providers you have configured.

---

## License

MIT — see [LICENSE](LICENSE).

The software is provided "as is", without warranty of any kind, express or implied. See LICENSE for full terms.
