# E2E Tests

E2E tests use dependency-free bash helpers and fake CLI test doubles. The fake CLI tests are local deterministic checks; they should not call real AI services or require real Codex or Gemini.

Run the happy-path E2E test:

```bash
bash tests/e2e_pass_fake_cli.sh
```

Run the CI-equivalent local checks:

```bash
bash -n loop.sh run.sh && python -m py_compile backlog_manager.py progress_window.py && bash tests/e2e_pass_fake_cli.sh && bash tests/e2e_rate_limit_fake_cli.sh
```

Fake CLI behavior is for deterministic testing only, not production use.

Current helper self-tests:

```bash
bash tests/lib/assert.sh --self-test
bash tests/lib/project_factory.sh --self-test
```

Expected verify command:

```bash
bash tests/lib/assert.sh --self-test && bash tests/lib/project_factory.sh --self-test
```
