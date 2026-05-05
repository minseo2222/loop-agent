import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BACKLOG_MANAGER = ROOT / 'backlog_manager.py'


def backlog_with(files_field):
    return textwrap.dedent(f"""\
        # Backlog

        ## Phase 1

        - [ ] Task 1.1: Sample task
          - Depends: none
          - Fail count: 0
          - Files: {files_field}
          - Completion criteria:
            - [ ] verify: `python -m unittest`
        """)


class AllowedFilesExtractTests(unittest.TestCase):
    def run_manager(self, content, *args):
        with tempfile.TemporaryDirectory() as tmp:
            backlog_file = Path(tmp) / 'backlog.md'
            backlog_file.write_text(content, encoding='utf-8')
            return subprocess.run(
                [sys.executable, str(BACKLOG_MANAGER), args[0], str(backlog_file), *args[1:]],
                cwd=str(ROOT),
                text=True,
                capture_output=True,
            )

    def files_output(self, content, task_id='Task 1.1'):
        result = self.run_manager(content, 'files', task_id)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.splitlines()

    def test_files_command_parses_comma_separated_files(self):
        content = backlog_with('src/a.py, tests/test_a.py')

        self.assertEqual(
            self.files_output(content),
            ['src/a.py', 'tests/test_a.py'],
        )

    def test_files_command_parses_newline_file_list(self):
        content = textwrap.dedent("""\
            # Backlog

            ## Phase 1

            - [ ] Task 1.1: Sample task
              - Depends: none
              - Fail count: 0
              - Files:
                - src/a.py
                - tests/test_a.py
              - Completion criteria:
                - [ ] verify: `python -m unittest`
            """)

        self.assertEqual(
            self.files_output(content),
            ['src/a.py', 'tests/test_a.py'],
        )

    def test_files_command_parses_backtick_wrapped_files(self):
        content = backlog_with('`src/a.py`, `tests/test_a.py`')

        self.assertEqual(
            self.files_output(content),
            ['src/a.py', 'tests/test_a.py'],
        )

    def test_files_command_deduplicates_and_excludes_empty_entries(self):
        content = backlog_with('src/a.py, , src/a.py, tests/test_a.py')

        self.assertEqual(
            self.files_output(content),
            ['src/a.py', 'tests/test_a.py'],
        )

    def test_files_command_fails_for_missing_task_or_files(self):
        missing_task = self.run_manager(backlog_with('src/a.py'), 'files', 'Task 9.9')
        self.assertNotEqual(missing_task.returncode, 0)
        self.assertIn('ERROR: task not found', missing_task.stdout)

        missing_files = self.run_manager(backlog_with(''), 'files', 'Task 1.1')
        self.assertNotEqual(missing_files.returncode, 0)
        self.assertIn('ERROR: Files not found', missing_files.stdout)

    def test_lint_rejects_invalid_paths(self):
        invalid_paths = [
            '../outside.py',
            'C:/temp/outside.py',
            '~/outside.py',
            'src/',
            '.loop-agent/proposals/task.md',
        ]

        for file_path in invalid_paths:
            with self.subTest(file_path=file_path):
                result = self.run_manager(backlog_with(file_path), 'lint')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('LINT FAILED', result.stdout)


if __name__ == '__main__':
    unittest.main()
