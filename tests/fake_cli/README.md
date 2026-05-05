# Fake CLI executables

This directory contains deterministic fake `codex` and `gemini` executables for shell tests. They read stdin when input is piped and choose output from `LOOP_FAKE_SCENARIO`.

Supported commands:

- `tests/fake_cli/codex --version`
- `tests/fake_cli/codex -v`
- `tests/fake_cli/codex --self-test`
- `tests/fake_cli/gemini --version`
- `tests/fake_cli/gemini -v`
- `tests/fake_cli/gemini --self-test`

Supported `LOOP_FAKE_SCENARIO` values:

- `pass` prints a passing implementation summary.
- `fail` prints a failing implementation summary.
- `rate_limit` writes rate-limit text to stderr and exits nonzero.
- `malformed` prints output that is not a valid summary.

Run both self-tests with:

```sh
tests/fake_cli/codex --self-test && tests/fake_cli/gemini --self-test
```
