# Legacy run.sh

## Status

`run.sh` is deprecated. Use `./loop.sh init` and `./loop.sh run` for new work.

The script is retained for existing document-driven workflows that still call `run.sh [options] <doc-path>`.

## Usage

```bash
./run.sh [options] <doc-path>
```

Options:

- `-n, --loops <N>` sets the number of iterations. The default is `3`.
- `-t, --tool <tool>` selects `claude` or `codex`. The default is `codex`.
- `-h, --help` prints usage.

Examples:

```bash
./run.sh -n 5 -t codex docs/feature.md
./run.sh -n 3 -t claude docs/feature.md
```

## Old behavior

The legacy flow reads a single document path, renders prompt templates, and runs Planner, Plan Critic, Implementer, and Impl Critic stages in sequence for a fixed number of loops.

It does not use the current `loop.sh init` backlog setup flow or the explicit `loop.sh run` task lifecycle.

## Generated files

Legacy runs write runtime data under these compatibility surfaces:

- `state/` for session files, per-loop plans, critiques, and implementation output.
- `logs/` for session logs and reports.
- `prompts/` for the templates used by the legacy prompt renderer.

## Prompt compatibility

The `prompts/` templates are legacy compatibility surfaces for `run.sh`. They are kept so existing users and tests that depend on the old document-driven flow can continue to run.

New workflow development should use `loop.sh init` and `loop.sh run`.

## Limitations

`run.sh` is not the supported main entrypoint. It does not represent the current backlog-driven workflow, state handling, or supported quickstart path.

## Migration

For new or migrated projects:

1. Put the target work in a project directory.
2. Run `./loop.sh init --project <project> --cli codex`.
3. Review and approve the generated backlog.
4. Run `./loop.sh run --project <project> --iterations 5 --cli codex`.

Existing users may still need `run.sh` while maintaining scripts or documents built around the older `run.sh [options] <doc-path>` interface.
