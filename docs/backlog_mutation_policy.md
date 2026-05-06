# Backlog Mutation Policy

## Default Behavior

Automatic backlog mutation is disabled by default. Run mode keeps semantic backlog changes proposal-only unless a future task explicitly enables a guarded mutation path.

Agents may report that backlog scope, task order, or dependencies need review. They must not apply those changes automatically under the default policy.

Human review is required to unblock any proposal-only mutation. If the proposal is accepted, a human edits the backlog deliberately, such as updating `Files`, dependencies, task text, or child tasks, then reruns LoopDex. If the proposal is rejected, a human either revises the original task so it fits the approved scope or leaves the task blocked; the runtime must not infer rejection by mutating backlog semantics automatically.

## SCOPE_EXPAND Default Policy

By default, `SCOPE_EXPAND` blocks the active task and creates a proposal for human review. It does not mutate semantic fields, including `Files`, `Depends`, verify commands, completion criteria, description, or task ordering.

`SCOPE_EXPAND` is not counted as an implementation failure. The task `Fail count` is not incremented when the loop blocks for a scope-expansion proposal.

Example progress entry:

```text
Task 12.3 blocked with SCOPE_EXPAND
Blocked status: [!] blocked for human review.
Blocked reason: implementation needs src/new_file.ts, which is outside the approved Files scope.
Evidence/proposal: .loop-agent/evidence/loop-9/scope_expand_proposal.md
Human action required: accept by editing the backlog Files or dependencies, or reject by revising/leaving the task blocked before retry.
Fail count: unchanged at 2.
```

To unblock, a human reviews the proposal, intentionally edits the backlog scope or dependencies if the change is accepted, and reruns LoopDex. If the proposal is rejected, the human should revise the task or leave it blocked instead of relying on automatic mutation.

## SPLIT_TASK Default Policy

By default, `SPLIT_TASK` blocks the active task and creates a split proposal for human review. It happens when the active task is too broad for the current loop boundary or discovery shows that ordered child tasks are needed before implementation can continue.

`SPLIT_TASK` is not counted as an implementation failure. The task `Fail count` is not incremented when the loop blocks for a split proposal.

Normal run mode does not insert child tasks, replace the parent task, rewrite dependencies, or otherwise change backlog structure. To unblock, a human reviews the proposal, intentionally edits the backlog if the split is accepted, and reruns LoopDex. If the split is rejected, the human should revise the original task so it is implementable within the approved boundary or leave it blocked; the loop does not automatically restore, rewrite, or retry it as an ordinary failure.

Example split proposal:

```text
Task 8.4 blocked with SPLIT_TASK
Blocked status: [!] blocked for human review.
Blocked reason: current task requires separate model and UI changes.
Evidence/proposal: .loop-agent/evidence/loop-11/split_task_proposal.md
Human action required: accept by replacing the backlog task with reviewed child tasks, or reject by revising/leaving the task blocked before retry.
Fail count: unchanged at 1.

Proposed child tasks:
- Task 8.4.1: Add export job model
  Files: src/export_jobs.ts
  Depends: Task 8.3
- Task 8.4.2: Add export job controls
  Files: src/export_controls.ts
  Depends: Task 8.4.1
```

## Benchmark Coverage

Automatic mutation must not be enabled until benchmark coverage exists for accepted, rejected, and blocked mutation outcomes. The benchmark must include proposal-only behavior, scope gate behavior, event logging, and rollback-safe failure paths.

The benchmark result must be recorded as evidence before any mutation path is accepted.

## Allowed Mutation Types

Only these mutation types are eligible for future automatic handling:

- Scope expansion: adding narrowly required files to an existing task scope.
- Task splitting: replacing an oversized task with smaller ordered tasks.
- Dependency insertion: adding an explicit dependency needed to preserve execution order.

No other semantic backlog mutation is allowed without a new policy update.

## Experimental Scope Expansion Flag

Automatic backlog mutation remains disabled by default. A `SCOPE_EXPAND` verdict writes a proposal and does not update task `Files` unless `LOOP_ALLOW_AUTO_SCOPE_EXPAND=1` is set.

When `LOOP_ALLOW_AUTO_SCOPE_EXPAND=1` is set, LoopDex may append valid requested files to only the active task `Files` list. The guarded path must enforce these limits:

- Maximum added files: 3 files per scope expansion.
- Path lint: no absolute paths, no parent traversal, no `.loop-agent/` paths, and no secret-like paths such as `.env`, private key files, or paths containing `private_key`.
- Backlog lint: the full backlog must pass backlog lint after mutation; lint failure blocks acceptance and rolls back the mutation.
- Event logging: attempted, accepted, rejected, and blocked outcomes must be recorded with task ID, mutation type, reason, affected paths, and evidence location.

## Experimental Task Split Flag

Automatic task splitting is disabled by default. A `SPLIT_TASK` verdict writes a split proposal and does not update the backlog unless `LOOP_ALLOW_AUTO_TASK_SPLIT=1` is set.

When `LOOP_ALLOW_AUTO_TASK_SPLIT=1` is set, LoopDex may replace only the active task with reviewed child task specs from the Impl Critic `## Split task` section. The guarded path must enforce these limits:

- Maximum child tasks: 2 child tasks per split.
- Child task IDs: child IDs must extend the parent ID in order, such as `Task 12.6.1` and `Task 12.6.2`.
- Backlog lint: the full backlog must pass backlog lint after mutation; lint failure blocks acceptance and rolls back the mutation.
- Parent replacement: the original parent task is marked blocked/replaced with the reason, verdict, evidence path, and replaced-by metadata.
- Dependencies: the first child inherits the parent dependencies, later children depend on the previous child, and downstream dependencies that pointed at the parent are updated to the final child.
- Event logging: attempted, accepted, rejected, and blocked outcomes must be recorded with task ID, mutation type, reason, affected paths, and evidence location.

## Experimental Dependency Insertion Flag

Automatic dependency insertion is disabled by default. A `DEPENDENCY_INSERT` verdict writes a proposal, blocks the active task for review, and does not insert backlog tasks unless `LOOP_ALLOW_AUTO_DEPENDENCY_INSERT=1` is set.

When `LOOP_ALLOW_AUTO_DEPENDENCY_INSERT=1` is set, LoopDex may insert reviewed dependency task specs before only the active task. The guarded path must enforce these limits:

- Maximum inserted tasks: 2 dependency tasks per insertion.
- Inserted task fields: each inserted task must have a unique valid task ID, non-empty name, valid `Files`, valid `Verify`, and non-empty completion criteria.
- Dependency update: the active task `Depends` field is updated only after policy validation succeeds; existing dependencies must not be dropped, and the final inserted task is appended.
- Backlog lint: the full backlog must pass backlog lint after mutation; lint failure blocks acceptance and rolls back the mutation.
- Event logging: attempted, accepted, rejected, and blocked outcomes must be recorded with task ID, mutation type, reason, affected paths, and evidence location.

## Hard Limits

Any future mutation path must enforce these limits:

- Maximum added files: 3 files per task mutation.
- Maximum inserted tasks: 2 tasks per original task.
- Path restrictions: added files must stay inside the project, must not target `.loop-agent/`, and must not include secret-like paths such as `.env`, private key files, or paths containing `private_key`.
- Lint requirements: the full backlog must pass backlog lint after the proposed mutation is built and before it can be accepted.

If any limit is exceeded, the mutation must be blocked and reported for human review.

## Required Evidence

Each attempted mutation must retain evidence containing:

- Proposal text describing the requested mutation and reason.
- Shell verify output from the relevant verify command.
- Changed files from git evidence.
- Backlog lint result.
- Benchmark result for the mutation behavior being exercised.

Missing evidence blocks acceptance.

## Event Logging

The event log must record each mutation attempt with enough information for status and reports to explain the outcome.

Required event outcomes are:

- attempted: a mutation was considered.
- accepted: a mutation passed policy, benchmark, lint, and evidence gates.
- rejected: a mutation was validly considered but not accepted.
- blocked: a mutation could not proceed because it violated policy, limits, lint, scope, or evidence requirements.

Each event must include the task ID, mutation type, outcome, reason, affected paths, and evidence location.

## Non-goals

This policy does not enable automatic backlog mutation.

This policy does not allow agents to edit `.loop-agent/` state files.

This policy does not relax run-mode immutability, verify gates, rollback boundaries, or scope gates.
