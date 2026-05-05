# Backlog Mutation Policy

## Default Behavior

Automatic backlog mutation is disabled by default. Run mode keeps semantic backlog changes proposal-only unless a future task explicitly enables a guarded mutation path.

Agents may report that backlog scope, task order, or dependencies need review. They must not apply those changes automatically under the default policy.

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

When `LOOP_ALLOW_AUTO_SCOPE_EXPAND=1` is set, loop-agent may append valid requested files to only the active task `Files` list. The guarded path must enforce these limits:

- Maximum added files: 3 files per scope expansion.
- Path lint: no absolute paths, no parent traversal, no `.loop-agent/` paths, and no secret-like paths such as `.env`, private key files, or paths containing `private_key`.
- Backlog lint: the full backlog must pass backlog lint after mutation; lint failure blocks acceptance and rolls back the mutation.
- Event logging: attempted, accepted, rejected, and blocked outcomes must be recorded with task ID, mutation type, reason, affected paths, and evidence location.

## Experimental Task Split Flag

Automatic task splitting is disabled by default. A `SPLIT_TASK` verdict writes a split proposal and does not update the backlog unless `LOOP_ALLOW_AUTO_TASK_SPLIT=1` is set.

When `LOOP_ALLOW_AUTO_TASK_SPLIT=1` is set, loop-agent may replace only the active task with reviewed child task specs from the Impl Critic `## Split task` section. The guarded path must enforce these limits:

- Maximum child tasks: 2 child tasks per split.
- Child task IDs: child IDs must extend the parent ID in order, such as `Task 12.6.1` and `Task 12.6.2`.
- Backlog lint: the full backlog must pass backlog lint after mutation; lint failure blocks acceptance and rolls back the mutation.
- Parent replacement: the original parent task is marked blocked/replaced with the reason, verdict, evidence path, and replaced-by metadata.
- Dependencies: the first child inherits the parent dependencies, later children depend on the previous child, and downstream dependencies that pointed at the parent are updated to the final child.
- Event logging: attempted, accepted, rejected, and blocked outcomes must be recorded with task ID, mutation type, reason, affected paths, and evidence location.

## Experimental Dependency Insertion Flag

Automatic dependency insertion is disabled by default. A `DEPENDENCY_INSERT` verdict writes a proposal, blocks the active task for review, and does not insert backlog tasks unless `LOOP_ALLOW_AUTO_DEPENDENCY_INSERT=1` is set.

When `LOOP_ALLOW_AUTO_DEPENDENCY_INSERT=1` is set, loop-agent may insert reviewed dependency task specs before only the active task. The guarded path must enforce these limits:

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
