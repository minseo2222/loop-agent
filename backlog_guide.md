# backlog_guide.md — Backlog Generation Instructions

> This file is read by Claude Code when opening a **target project** alongside LoopDex.
> It instructs Claude to analyze planning documents and generate `.loop-agent/backlog.md`,
> which LoopDex uses to drive its autonomous plan → implement → review loop.

---

You are a senior software architect conducting a full project analysis.
Read ALL planning documents and existing code, then create a complete `backlog.md` that maps out every task needed to finish the project.

---

## Step 1: Read all planning documents

Read EVERY file that contains requirements, specs, features, backlog, roadmap, phases, or implementation goals.
Do NOT stop at one file. Read all of them.

Look for: `SPEC.md`, `REQUIREMENTS.md`, `DESIGN.md`, `README.md` (if it has requirements),
`docs/`, backlog, roadmap, brief, plan, phase, milestone, spec, contract, policy, matrix

## Step 2: Read existing code

Check what is already implemented by reading the actual source files.
Do NOT trust filenames alone — read the contents.

## Step 3: Gap analysis

Compare planning documents against existing code and identify:
- Fully implemented
- Partially implemented
- Not implemented at all

Show this analysis before writing the backlog. Do not skip this step.

## Step 4: Write backlog.md

Save the result to `.loop-agent/backlog.md`. Create the folder if it doesn't exist:

```bash
mkdir -p .loop-agent
```

---

## Task sizing rules

- **Small**: 1 file, < 50 lines, clear scope
- **Medium**: 1–3 files, moderate complexity
- **Large**: **not allowed** — must be split into Small/Medium tasks before writing
- Split oversized work while authoring the backlog. In run mode, `SPLIT_TASK` is only a proposal/block signal after discovery; it requires human backlog maintenance before retry and does not insert child tasks automatically.

---

## Backlog quality rules

- Each task must have a valid task ID in the format `Task Phase.Number`.
- Each task must include `Size`, `Files`, `Description`, `Completion criteria`, `Depends`, `Fail count`, and a `verify:` command.
- `Size` must be `Small` or `Medium`.
- `Files:` must be non-empty and use paths relative to the project root.
- Prefer exact file paths over broad directories in every task's `Files:` field.
- If a task would touch more than 3–5 core files, split it before writing the backlog.
- Keep source/code work, documentation updates, and final validation as separate tasks when they involve different file groups.
- Every task's `verify:` command must cover the same core files or behavior claimed by its completion criteria.
- For audit/documentation tasks, include criteria that check for contradictory status language, not only keyword presence.
- Do not create tasks that require writing `.loop-agent/*` as implementation evidence — use non-state project docs instead.
- Task IDs follow the format `Task Phase.Number` (e.g. Task 1.1, Task 1.2, Task 2.1).

---

## Backlog format

```markdown
# Backlog

## Project Overview
(2–3 sentences: what this project builds in total)

## Already Implemented
(brief summary of what already exists in the code)

## Phase 1: (phase name)

- [ ] Task 1.1: (task name)
  - Size: Small/Medium
  - Files: (non-empty exact file path relative to project root)
  - Description: (what needs to be done)
  - Completion criteria:
    - [ ] (verifiable condition)
    - [ ] Verify with `verify: (shell command)`
  - Depends: None
  - Fail count: 0

- [ ] Task 1.2: (task name)
  - Size: Small/Medium
  - Files: (non-empty exact file path relative to project root)
  - Description: (what needs to be done)
  - Completion criteria:
    - [ ] (verifiable condition)
    - [ ] Verify with `verify: (shell command)`
  - Depends: Task 1.1
  - Fail count: 0

## Phase 2: (phase name)
(Phase 2 starts after Phase 1 is complete)

- [ ] Task 2.1: ...

## Completed Tasks
(tasks already done based on existing code)
- [x] Task 0.1: (description)
```

## Backlog maintenance

During compaction, completed task bodies move to `backlog_archive.md`. Active `backlog.md` retains pending `[ ]` and blocked `[!]` tasks, and should not retain empty repeated `## Tasks` headings or other empty task headings after completed tasks are archived.

---

## Self-validation (required before saving)

Check each item before writing the file:

1. **Is every requirement from the planning docs covered by a task?**
   If anything is intentionally deferred, list it in a `## Deferred` section with a reason.

2. **Are there any Large tasks?**
   If yes, split them and rewrite before saving.

3. **Does every task use a valid task ID and `Small` or `Medium` size?**
   If not, fix the ID or split the task.

4. **Does every task have non-empty relative `Files`, `Description`, `Completion criteria`, `Depends`, and `Fail count` fields?**
   If not, add the missing field before saving.

5. **Does every task have a Verify check with a `verify:` command?**
   If not, add one.

6. **Are dependency IDs correct and free of cycles?**
   If not, fix them.

7. **Does the backlog pass lint?**
   Run `python backlog_manager.py lint .loop-agent/backlog.md` and fix any reported errors before using the backlog.

---

After saving, print:

```
backlog.md created: .loop-agent/backlog.md
Total tasks: N
Phases: M
```
