import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BACKLOG_MANAGER = ROOT / 'backlog_manager.py'


def task_block(task_id, name, depends):
    return f"""- [ ] {task_id}: {name}
  - Files: `{task_id.lower().replace(' ', '_')}.py`
  - Depends: {depends}
  - Fail count: 0
  - Completion criteria:
    - [ ] Done
    - [ ] verify: `python -c "print('ok')"`
"""


def backlog(*tasks):
    return '# Backlog\n\n## Phase 1\n\n' + '\n'.join(tasks)


class BacklogLintDependencyTests(unittest.TestCase):
    def run_lint(self, content):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / 'backlog.md'
            path.write_text(content, encoding='utf-8')
            return subprocess.run(
                [sys.executable, str(BACKLOG_MANAGER), 'lint', str(path)],
                cwd=ROOT,
                text=True,
                capture_output=True,
            )

    def assert_lint_fails(self, content, text):
        result = self.run_lint(content)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(text, result.stdout + result.stderr)

    def assert_lint_passes(self, content):
        result = self.run_lint(content)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('LINT OK', result.stdout)

    def test_unknown_dependency_fails(self):
        self.assert_lint_fails(
            backlog(task_block('Task 1.1', 'Alpha', 'Task 9.9')),
            'unknown dependency Task 9.9',
        )

    def test_self_dependency_fails(self):
        self.assert_lint_fails(
            backlog(task_block('Task 1.1', 'Alpha', 'Task 1.1')),
            'self dependency',
        )

    def test_simple_dependency_cycle_fails(self):
        self.assert_lint_fails(
            backlog(
                task_block('Task 1.1', 'Alpha', 'Task 1.2'),
                task_block('Task 1.2', 'Beta', 'Task 1.1'),
            ),
            'dependency cycle',
        )

    def test_multi_task_dependency_cycle_fails(self):
        self.assert_lint_fails(
            backlog(
                task_block('Task 1.1', 'Alpha', 'Task 1.2'),
                task_block('Task 1.2', 'Beta', 'Task 1.3'),
                task_block('Task 1.3', 'Gamma', 'Task 1.1'),
            ),
            'dependency cycle',
        )

    def test_depends_none_passes(self):
        self.assert_lint_passes(
            backlog(task_block('Task 1.1', 'Alpha', 'none'))
        )

    def test_multiple_valid_dependencies_pass(self):
        self.assert_lint_passes(
            backlog(
                task_block('Task 1.1', 'Alpha', 'none'),
                task_block('Task 1.2', 'Beta', 'none'),
                task_block('Task 1.3', 'Gamma', 'Task 1.1, Task 1.2'),
            )
        )


if __name__ == '__main__':
    unittest.main()
