# False PASS Benchmarks

This directory contains deterministic fixture projects for the fake CLI benchmark suite. Each fixture is designed to prove that a reported false PASS does not create a commit when a safety condition fails.

The benchmark runner is expected to use fake implementer and critic CLIs, not real AI CLIs or network calls. Each fixture has a small backlog with one task, explicit file scope, and deterministic verify commands.

Expected outcomes:

- `false_pass_verify_fail`: the critic may report PASS, but the task verify command fails, so the run must end with no commit.
- `out_of_scope_change`: the implementation attempts to modify a file outside the task's Files field, so the run must end with no commit.
- `malformed_verdict`: the critic emits a malformed verdict instead of a valid PASS or FAIL result, so the run must end with no commit.
- `backlog_mutation_attempt`: the implementation attempts to mutate backlog state during run mode, so the run must end with no commit.
