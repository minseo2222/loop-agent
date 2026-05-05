# Dogfooding loop-agent

Use this guide when you want loop-agent to upgrade this repository with its own backlog loop.

## Start from a safe branch

Do not run loop-agent against a dirty `main` branch. Start from a clean git tree, then create and switch to a dedicated branch:

```bash
git status --short
git checkout main
git pull
git checkout -b loop/dogfood-run
```

If `git status --short` prints anything before the run, commit or stash that work first. Rollback is git-based, so a clean preflight makes each task boundary clear.

You can also require the branch prefix before explicit `run` starts:

```bash
LOOP_REQUIRE_BRANCH_PREFIX=loop/ ./loop.sh run --project . --iterations 1 --cli codex
```

## Put the backlog in the loop state directory

The approved backlog for this repository must be at:

```text
.loop-agent/backlog.md
```

Review that backlog before running. It should contain focused tasks, exact file scopes, and verify commands for each task.

## Run fake CLI tests first

Before using a real agent CLI, run the deterministic fake CLI checks:

```bash
bash tests/e2e_pass_fake_cli.sh
bash tests/e2e_rate_limit_fake_cli.sh
```

These tests check the loop mechanics without spending Codex or Gemini quota.

## Start with small iteration counts

Begin with one iteration and inspect the result before increasing the run length:

```bash
./loop.sh run --project . --iterations 1 --cli codex
```

If that pass looks correct, increase gradually:

```bash
./loop.sh run --project . --iterations 3 --cli codex
./loop.sh run --project . --iterations 5 --cli codex
```

## Inspect evidence and reports

After each dogfood run, inspect the printed summary, git diff, and loop-owned evidence under `.loop-agent/`. Pay attention to verify output, critic verdicts, blocked tasks, and any scope expansion requests before raising the iteration count.
