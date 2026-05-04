# Task Planning Failure Patterns

This document records common causes of repeated failures when building and running tasks with loop-agent.
The goal is to reduce Plan Critic and Impl Critic failures on future tasks, and to prevent completed-looking states that are not actually complete.

## Scope

This document is not project-specific implementation guidance. It is an operational reference that loop-agent applies when creating and validating backlogs for any new project.

Applies to:

- Creating `.loop-agent/backlog.md` for the first time during setup phase
- Manually splitting or reopening existing backlog tasks
- Repeated Plan Critic / Impl Critic failures
- Reconciling state mirrors such as docs, trackers, roadmaps, and contracts
- Verifying completion that looks done without a PASS

Does not apply to:

- Project-specific product requirements
- High-level design directions explicitly requested by the user
- Per-project technical decisions such as test or build tool choices

---

## Core Principles

- A task must be a small unit that can be verified in a single loop iteration.
- `Likely files` / plan `File:` fields should list exact file paths, not broad directories.
- Completion criteria and the verify command must cover the same scope.
- Documentation audit tasks must check for contradictions between documents, not just keyword presence.
- `.loop-agent/*` are state files. Implementation and verification evidence should be recorded in non-state project docs.
- `BLOCKED` or `[!]` tasks are not complete. They can fall out of the open task count — split them into explicit follow-up tasks.
- "Internal core capability", "public CLI/Studio surface", and "what the docs promise" are different layers. Tasks and docs must not mix them.

---

## Task Type Classification

Classify each task as exactly one of the types below before writing it. A task that spans multiple types has a high failure probability.

### 1. Implementation task

Purpose: change actual source, runtime, or test code.

Good criteria:
- 1–3 core files
- Directly runnable test or build command
- Documentation mirror updates go in a separate task

### 2. Test realignment task

Purpose: fix stale test expectations when the runtime is correct but tests haven't caught up.

Good criteria:
- Focused on test files
- Runtime changes only allowed when tests prove a runtime contract violation
- Criteria confirm existing behavior is not broadened

### 3. Documentation reconciliation task

Purpose: resolve contradictions between contract, policy, roadmap, benchmark, and README files.

Good criteria:
- No source changes
- Completion criteria explicitly state "no contradictions"
- Checks for conflicting language, not just keyword presence

### 4. Mirror / status refresh task

Purpose: bring non-state mirrors (tracker, roadmap, next backlog) up to date.

Good criteria:
- No source, runtime, or test changes
- Verifies `current through`, `pending`, `blocked`, and `next safe work` language together
- Direct `.loop-agent/*` edits are treated as manual backlog maintenance, kept separate

### 5. Audit / evidence task

Purpose: confirm that completed markers are backed by real source, test, or doc evidence.

Good criteria:
- If evidence exists, record as "confirmed"
- If evidence is missing, do not implement — create an explicit follow-up task
- Audit findings and implementation repair must not be in the same task

### 6. Final gate task

Purpose: re-run the full gate after preceding repair, audit, and mirror tasks are done.

Good criteria:
- Source changes are the exception, not the rule
- Build, test, and audit command results are recorded truthfully
- On failure, split into separate tasks instead of fixing everything in one

---

## Verification Levels

Every task must have at least one verification level. Higher-risk tasks should combine multiple levels.

### Level 1: Existence check

```bash
rg -n "expected-symbol|expected-doc-term" path/to/file.ts path/to/doc.md
```

Use for: confirming a file, export, doc anchor, or specific term exists.

Limitation: does not guarantee semantic consistency — "supported" and "unsupported" can coexist and still pass.

### Level 2: Focused behavioral check

```bash
pnpm --filter package exec vitest run path/to/test.ts -t "specific case"
```

Use for: verifying a narrow behavior or regression.

Note: confirm that the command covers all core behaviors claimed by the task.

### Level 3: Package or module gate

```bash
pnpm --filter package test
pnpm --filter package typecheck
```

Use for: verifying the integrated state of one package.

Note: if too slow or broad, move to a final gate task.

### Level 4: Full project gate

```bash
pnpm build && pnpm --filter core test && pnpm --filter cli test
```

Use for: phase completion, release readiness, closing a false-positive audit.

Note: on failure, split the causes into separate tasks rather than fixing everything at once.

### Level 5: Semantic consistency check

Use for: confirming that docs, contracts, policies, and roadmaps all describe the same state.

Good criteria examples:

```text
No document describes this route as both implemented and future-only.
Public CLI/Studio support remains unsupported unless a validated command exists.
Tracker, roadmap, and next backlog agree on next safe work.
```

Note: a single `rg` may not be enough. Search for contradictory terms together and write explicit judgment criteria into the completion conditions.

---

## Recurring Failure Patterns

### 1. Audit task scope too broad

Symptoms:
- Plan Critic rejects with "scope too broad" or "not executable in one iteration"
- Implementer tries to reconcile multiple phases, docs, and packages at once; Impl Critic catches omissions

Prevention:
- Scope phase audits to 1–3 phases at a time
- Never mix "source evidence", "doc reconciliation", and "mirror refresh" in one task
- If more than 3–5 core file groups are needed, split before writing the backlog

Good form:
```text
Task A: Reconcile contract docs only
Task B: Refresh tracker/backlog mirrors only
Task C: Re-run final audit gate only
```

Bad form:
```text
Revalidate Phase 7-9 and update all docs and split any remaining work
```

### 2. Directory instead of exact file path

Symptoms:
- Plan Critic rejects broad directory entries in the `File:` field
- "Plan looks right but file paths aren't specific enough" failures repeat

Prevention:
- List the actual files to read and change in `Likely files`
- Wildcards and directories are last-resort fallbacks for supplementary searching only
- Files called out by a previous critic must appear in both `Likely files` and the validation command of the next task

Check:
```text
Good: src/pipeline/runner.ts
Bad:  src/pipeline/
```

### 3. Verify command covers less than the task scope

Symptoms:
- The plan says it audits a specific file but that file is absent from the `verify:` command
- Impl Critic fails with "the search command passes but doesn't validate the required files"

Prevention:
- Every core file added to `Likely files` must also appear in the validation command
- Don't rely on the implementation summary alone — make the verify command cover the same file set
- An `rg` command is only existence evidence; if doc consistency is required, add "no contradictions" to the criteria explicitly

### 4. Keyword search mistaken for semantic validation

Symptoms:
- `rg -n "supported|unsupported|approved"` passes but documents contradict each other
- One doc says "implemented", another says "future bridge" or "not opened"

Prevention:
- Add "no contradictions between documents" directly to the completion criteria
- Separate internal core capability from public CLI/Studio surface in writing
- "Approved core bridge exists" and "public command is supported" are different claims

Example wording:
```text
Core approval-gated bridge is implemented, but public CLI/Studio command surface remains
unopened unless a validated command exists.
```

### 5. State file vs. non-state artifact boundary confusion

Symptoms:
- Implementer tries to directly update `.loop-agent/backlog.md`, or leaves no evidence in any non-state doc
- After rollback, `.loop-agent/` is preserved, so state and actual work diverge

Prevention:
- Treat `.loop-agent/*` as state files managed by the loop system
- Leave implementation and verification evidence in non-state mirrors such as `next_phase_backlog.md`, `PROJECT_TRACKER.md`, or roadmap/contract docs
- When a human must manually add tasks to the backlog, handle it as separate manual backlog maintenance

### 6. Looks complete after Impl Critic FAIL

Symptoms:
- After Impl Critic FAIL and rollback, the backlog appears complete or exhausted
- `[!] Task ...` BLOCKED falls out of open task counts, showing output like `84/84 Tasks (100%)`

Prevention:
- Never trust `100%` without a PASS
- Confirm the last verdict in progress/report is PASS
- Leave `[!]` BLOCKED tasks as-is and reopen the root cause as an explicit `[ ]` split task
- The split task description must include why it was split and the exact cause from the critic

Verification sequence:
```bash
git status --short -- . ':(exclude).loop-agent/**' ':(exclude)loop-agent/**'
grep -E '^\- \[ \] Task|^\- \[!\] Task' .loop-agent/backlog.md
tail -120 .loop-agent/progress.txt
```

### 7. Retrying BLOCKED without splitting

Symptoms:
- The same task failed 5 times and is BLOCKED, but the same command keeps running
- Planner reproduces the same broad task; critic fails it for the same reason

Prevention:
- After 3+ failures with the same critic reason, split the original task
- Split task descriptions mirror the critic message closely
- First split: "resolve doc contradictions"; second: "mirror refresh"; third: "final gate"

### 8. State mirrors disagree with each other

Symptoms:
- Tracker says "current through Task X" but the next backlog lists a different next task
- Roadmap shows pending while backlog shows completed

Prevention:
- Tasks that update state mirrors must be separate from source modification tasks
- Mirror refresh task validation commands must search all mirror files together
- Check `current through`, `pending`, `blocked`, and `next safe work` language in the same pass

### 9. Public surface and internal capability mixed

Symptoms:
- The core has an approved bridge but there is no public CLI command, or it is unsupported
- Docs don't distinguish the two, so "implemented" and "not opened" look like a contradiction

Prevention:
- Make the layer explicit in documentation:

```text
Internal core capability: implemented approval-gated bridge.
Public CLI/Studio surface: still unsupported unless a validated command/page exists.
Unapproved/mixed-source route: still blocked.
```

### 10. Completion criteria `[x]` mistaken for task completion

Symptoms:
- The task header is `[x]` but criteria items are a mix of `[x]` and `[ ]`
- Reader confuses "some criteria are checked" with "task is done"

Prevention:
- Task completion requires the task header `[x]` AND a PASS verdict in progress/report/commit
- Criteria `[x]` marks only partial condition status
- Write criteria as statements verifiable without the loop modifying them directly

---

## Task Writing Checklist

Check every item before adding a task to the backlog:

- [ ] Can this task be completed in one loop iteration?
- [ ] Does it map clearly to one task type: implementation, test realignment, documentation reconciliation, mirror refresh, audit/evidence, or final gate?
- [ ] Are `Likely files` exact file paths?
- [ ] Does the validation command include the core files from `Likely files`?
- [ ] Are files called out by a previous critic not missing?
- [ ] Does the task avoid mixing source, test, doc, and mirror work excessively?
- [ ] Does the task avoid using `.loop-agent/*` as implementation output?
- [ ] Is it impossible to judge completion from `[x]` or `100%` alone without a PASS?
- [ ] Are public CLI/Studio surface and internal core capability distinguished?
- [ ] Do status words like "future", "not implemented", "blocked", "supported" agree across documents?
- [ ] Is there a clear basis for how to split the task on failure?

---

## Setup Phase Validation Rules

When setup phase generates a backlog for a new project:

Setup Agent must:
- Read all planning docs and existing code before converting requirements to tasks
- Split Large tasks into Small/Medium immediately — no Large tasks in the backlog
- Keep task types separate: implementation, test realignment, doc reconciliation, mirror refresh, and final gate are distinct tasks
- Use exact file paths in `Files:` fields; for files that don't exist yet, write the exact path to be created
- Ensure each task's `verify:` command validates the same scope as its completion criteria
- Only mark work as done in `Completed Tasks` after reading actual source, test, or doc evidence

Setup Critic must FAIL when:
- Any task uses a broad directory-only file scope
- A `verify:` command does not validate the core files or behavior the task claims
- A documentation or audit task only checks keyword existence without checking semantic contradictions
- Internal capability and public surface are treated as the same thing
- Mirror/status refresh and source implementation are in the same task
- Already-completed tasks are marked done without real code evidence
- Dependencies are missing or circular

---

## Backlog State Validation Rules

Do not judge completion from loop output alone. Verify all of the following:

Acceptable as complete when:
- Task header is `[x]`, AND
- Last progress/report verdict is PASS, AND
- A PASS commit (or "nothing to commit on PASS") is recorded, AND
- Source/doc changes after rollback are intact and as intended, AND
- The next task is selected correctly

Not acceptable as complete when:
- `100%` is shown without any PASS
- `[!]` BLOCKED tasks exist
- Backlog appears exhausted after an Impl Critic FAIL + rollback
- Only `.loop-agent/backlog.md` changed with no non-state evidence
- Last progress verdict is FAIL, SPLIT_TASK, SCOPE_EXPAND, or SUSPENDED

---

## Critic Feedback Incorporation Rules

When a Plan Critic or Impl Critic provides a failure reason, the next task must reflect it structurally.

Must incorporate:
- Exact file paths called out
- Missing validation command scope
- Stale or contradictory wording
- Out-of-scope files
- Split or scope expand suggestions

Must not do:
- Retry the same broad task with a different name
- Add abstract instructions like "do it better this time"
- Add a file to `Likely files` but omit it from the validation command

Good follow-up task description:
```text
Fix the stale bridge-status wording called out by Impl Critic:
`contract.md` still describes write-next as future-only while `runner.ts` exposes an approved bridge.
Distinguish implemented internal core capability from unopened public CLI/Studio surface.
```

Bad follow-up task description:
```text
Fix docs and rerun audit.
```

---

## Recommended Split Structure

When a documentation or audit task is stuck, split in this order:

1. **Evidence task** — confirm whether real evidence exists in source, tests, or docs. If not, create a missing follow-up instead of implementing.
2. **Reconciliation task** — fix only conflicting contract, policy, benchmark, or lifecycle language. Separate public surface from internal capability.
3. **Mirror task** — update only tracker, next backlog, and roadmap files. Align `current through`, `pending`, `blocked`, and `next safe work`.
4. **Final gate task** — re-run the full validation or audit query after the above tasks complete. If new contradictions appear, split into another explicit follow-up.

---

## Post-Failure Decision Rules

- **Plan Critic FAIL**: the plan is wrong before implementation. Fix file scope, validation scope, or unimplemented scope — don't retry the same task unchanged.
- **Impl Critic FAIL**: the implementation didn't satisfy the criteria. After rollback, treat source/doc changes as gone and reflect the critic's "Next Planner guidance" in a new task.
- **SUSPENDED**: usage limit or external interruption. Confirm rollback, then retry the same task.
- **BLOCKED**: do not keep running the same task. `[!]` tasks are not complete and may fall out of open task counts. Always add small `[ ]` split tasks.

---

## Document Evolution Rules

This is a living document, not a fixed ruleset. It accumulates failure patterns discovered during loop-agent operation.

Add a new pattern when:
- The same Plan Critic failure reason appears 2+ times
- The same Impl Critic failure reason appears 2+ times
- State and actual work diverge after a rollback
- `100%` or a completed marker doesn't match actual PASS state
- An unsafe backlog is generated during setup phase for a new project

Format for new patterns:
```markdown
### N. Short pattern name

Symptoms:
- What kept failing repeatedly?

Cause:
- Was it task design, validation, state handling, or doc contradictions?

Prevention:
- What specific rule goes into the next backlog or task?

Verification:
- What command or review criterion prevents recurrence?
```

Update an existing rule when:
- It is too project-specific to apply to new projects
- It is too abstract for Setup Agent or Planner to apply to actual tasks
- Critics cannot use it as a basis for FAIL

Quality bar for this document:
- Examples go in the appendix; rules in the body stay project-neutral
- Rules must make clear exactly which files, verifications, or states to check
- Every sentence must be directly applicable during setup phase of a new project
- `agents/setup_agent.md` and `agents/setup_critic.md` should reference the core rules here

---

## Appendix: Concrete Rules from Past Cases

- **Task 10.17.6**: Phase 4–6 audit scope was initially too narrow, then failed again because file paths were broad directories. Fix was exact file paths and an expanded validation command.
- **Task 10.17.7** (Plan stage): Missing original phase files were called out repeatedly. Fix was including the relevant source, contract, and roadmap files in both scope and validation command.
- **Task 10.17.7** (Impl stage): Bridge status doc contradictions were called out repeatedly. Fix was separating "core approved bridge implemented" from "public CLI/Studio surface unopened".
- **BLOCKED → false 100%**: After BLOCKED, output showed `84/84 Tasks (100%)` but the project was not actually complete. `[!]` tasks had fallen out of open task counts — reopen as split tasks.
