# Security Notes

Loop-agent runs AI agents and backlog verify commands with the user's shell permissions. It is not a sandbox, a complete shell parser, a secret scanner, or a guarantee that a command is safe. Unattended mode can be dangerous because planning docs, agent output, and verify commands can affect what runs on the user's machine.

## Threat Model

Planning documents, backlog entries, and task descriptions are untrusted input. A prompt injection in those files can try to steer Planner, Implementer, or Critic behavior, request out-of-scope edits, hide unsafe instructions, or ask the agent to ignore project rules. Review planning docs and generated backlog tasks before running unattended work.

Backlog verify commands are also part of the threat model. Dangerous verify commands can delete files, read or print secrets, modify system settings, contact network services, install software, or run hidden shell behavior. LoopDex checks extracted verify commands with a basic denylist before Planner or Implementer runs, but passing that check does not mean a command is safe.

The denylist blocks these command forms when detected:

- standalone `sudo`
- `rm -rf /`
- detectable `curl ... | sh`
- detectable `wget ... | sh`

Verify commands still run through the shell when they pass this check. Shell execution remains dangerous: commands can delete files, leak data, run network downloads, or hide behavior in forms this denylist does not understand. Users must review backlog verify commands before approving or running a project.

## Clean Tree and Branches

Explicit `run` mode expects a clean tree before agent calls begin. Commit or stash user work first so per-task rollback has a clear git snapshot.

Run unattended work on a dedicated branch. LoopDex does not switch branches for you; optionally set `LOOP_REQUIRE_BRANCH_PREFIX` to make explicit `run` fail unless the current branch starts with the configured prefix.

## Risk Mode Boundaries

`LOOP_RISK_MODE=unattended` preserves LoopDex's built-in bypass flags for Codex and Gemini so the loop can run without per-step approval prompts.

`LOOP_RISK_MODE=safe` avoids those built-in bypass flags where the wrapped CLI supports that. Safe mode is still not a sandbox: agent commands, shell verify commands, and provider CLIs run with user permissions.

## Secret Path Guard

After Implementer runs, LoopDex blocks changes to a small set of obvious secret-like paths before verify or PASS commit. Blocked examples include `.env`, `.env.local`, `cert.pem`, `.ssh/id_rsa`, `.ssh/id_ed25519`, `id_rsa`, `id_ed25519`, and paths containing `private_key`.

When this guard matches, LoopDex writes evidence under `.loop-agent/evidence/loop-N/secret_paths.txt`, records the task failure, rolls back implementation changes, and skips the PASS commit.

This guard is path-based only. It is not full secret scanning, does not inspect file contents for credentials, does not catch every secret file name, and does not make LoopDex a sandbox. A command can still read or expose secret files even if no secret-like path is modified.

## Rollback Limits

Rollback is per task and git-based. It can restore the project working tree to the pre-task snapshot for normal implementation, verify, critic, scope, state-file, and rate-limit failures.

Rollback does not protect files outside the project, external services, credentials already exposed to a command, system settings, destructive shell actions that already affected the machine, or work already committed by earlier passed tasks. Shell evidence and loop-owned reports under `.loop-agent/` may be preserved for debugging.

## Safety Failure Reporting

Safety failures are recorded in raw `.loop-agent/progress.txt`. When `.loop-agent/progress_window.md` exists, it may summarize recent safety and progress context for agents, but it is a bounded context window and not the system source of truth.
