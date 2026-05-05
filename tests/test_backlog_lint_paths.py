import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BACKLOG_MANAGER = ROOT / 'backlog_manager.py'


def backlog_with_files(files_line):
    return f"""# Backlog

- [ ] Task 1.1: Example task
  - Files: {files_line}
  - Depends: none
  - Fail count: 0
  - Completion criteria:
    - [ ] Example criterion.
    - [ ] verify: `python -m unittest`
"""


class BacklogLintPathTests(unittest.TestCase):
    def run_lint(self, files_line):
        with tempfile.NamedTemporaryFile('w', encoding='utf-8', suffix='.md', delete=False) as f:
            f.write(backlog_with_files(files_line))
            path = f.name

        try:
            return subprocess.run(
                [sys.executable, str(BACKLOG_MANAGER), 'lint', path],
                cwd=str(ROOT),
                text=True,
                capture_output=True,
            )
        finally:
            Path(path).unlink(missing_ok=True)

    def assert_lint_fails(self, files_line, expected_text):
        result = self.run_lint(files_line)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(expected_text, result.stdout + result.stderr)

    def test_absolute_paths_fail(self):
        self.assert_lint_fails('C:/tmp/example.py', 'absolute path not allowed')

    def test_parent_traversal_fails(self):
        self.assert_lint_fails('../example.py', 'parent traversal not allowed')

    def test_home_paths_fail(self):
        self.assert_lint_fails('~/example.py', 'home path not allowed')

    def test_empty_entries_fail(self):
        self.assert_lint_fails('src/example.py, ', 'empty file entry')

    def test_duplicate_entries_fail_consistently(self):
        self.assert_lint_fails('src/example.py, src/example.py', 'duplicate file entry')

    def test_relative_project_paths_pass_without_existing(self):
        result = self.run_lint('src/does_not_need_to_exist.py')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_loop_agent_implementation_scope_fails(self):
        self.assert_lint_fails('.loop-agent/plan.md', '.loop-agent file not allowed')

    def test_loop_agent_lifecycle_file_passes(self):
        result = self.run_lint('.loop-agent/backlog.md')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_directory_only_entries_fail(self):
        self.assert_lint_fails('src/', 'directory-only file entry')


if __name__ == '__main__':
    unittest.main()
