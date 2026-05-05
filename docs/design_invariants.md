# Design Invariants

## Autonomous Run Mode

Explicit `run` mode is unattended. After a backlog has been generated and approved, run mode never asks for human input while executing tasks.

## Backlog Immutability Contract

In run mode, backlog task scope is immutable. Agents may read the selected task and use its declared scope, but they must not change what the task means.

Agents cannot modify backlog semantics. They must not add, remove, reorder, split, merge, rename, expand, narrow, or reinterpret tasks in `.loop-agent/backlog.md`. If a task cannot be completed within its declared scope, the implementation summary must report the missing files or blocker instead of changing the backlog.

Out-of-scope changes can never be committed. A passing task is limited to the files and behavior allowed by the selected backlog task and its approved plan.

## Semantic Fields

Semantic fields define what work the task means and what counts as done. They include the task ID, name, size, file scope, description, completion criteria, verify commands, and dependencies.

Changing a semantic field changes the task contract. Those changes are prohibited during run mode.

## Lifecycle Fields

Lifecycle fields record execution state for an existing task. They include status, fail count, blocked reason, progress markers, reports, and other loop-managed bookkeeping.

Lifecycle fields are owned by the loop runtime, not by agents. Agents report outcomes through their required outputs; the runtime applies lifecycle updates after review.

## Proposal Files

Proposal files are review-only reports, not executable backlog mutations. They describe a requested change for a human or later approved process to review.

Standardized proposal files must include title, task ID, task name, verdict, requested change, reason, evidence path, and the sentence `No backlog semantic change was applied.`

Generating a proposal file never applies backlog semantic changes.

## Deterministic Decision Rules

Final task decisions are deterministic runtime decisions, not agent-only decisions. Proposal-only verdicts such as `SCOPE_EXPAND` and `SPLIT_TASK` generate review-only proposal files and block completion without mutating backlog semantics.

A task can PASS only when the Impl Critic returns critic PASS, backlog shell verify commands pass with recorded shell evidence, scope and state-file gates pass, and the commit succeeds when commit-on-pass is enabled. critic PASS is required, but it is not enough by itself.

Failure paths roll back implementation changes as appropriate, preserve evidence, and leave lifecycle updates to the runtime. Preventing false PASS results takes priority over maximizing completion rate.
