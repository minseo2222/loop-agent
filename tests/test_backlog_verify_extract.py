import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


BACKLOG_MANAGER = Path(__file__).resolve().parents[1] / 'backlog_manager.py'


class BacklogVerifyExtractTests(unittest.TestCase):
    def run_verify(self, backlog_content, task_id='Task 1.1'):
        with tempfile.NamedTemporaryFile('w', encoding='utf-8', suffix='.md', delete=False) as f:
            f.write(backlog_content)
            backlog_path = f.name
        try:
            return subprocess.run(
                [sys.executable, str(BACKLOG_MANAGER), 'verify', backlog_path, task_id],
                capture_output=True,
                text=True,
            )
        finally:
            os.unlink(backlog_path)

    def backlog(self, criteria):
        return (
            '# Backlog\n\n'
            '- [ ] Task 1.1: Example task\n'
            '  - Files: `example.py`\n'
            '  - Depends: none\n'
            '  - Fail count: 0\n'
            '  - Completion criteria:\n'
            f'{criteria}'
        )

    def test_one_verify_command(self):
        result = self.run_verify(
            self.backlog('    - [ ] verify: `python -m unittest tests/test_example.py`\n')
        )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), 'python -m unittest tests/test_example.py')

    def test_multiple_verify_commands(self):
        result = self.run_verify(
            self.backlog(
                '    - [ ] verify: `python -m unittest tests/test_one.py`\n'
                '    - [ ] verify: `python -m unittest tests/test_two.py`\n'
            )
        )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                'python -m unittest tests/test_one.py',
                'python -m unittest tests/test_two.py',
            ],
        )

    def test_missing_verify_command_exits_nonzero(self):
        result = self.run_verify(self.backlog('    - [ ] command is documented elsewhere\n'))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ERROR: verify command not found', result.stdout)

    def test_backtick_wrapped_command_extraction(self):
        result = self.run_verify(
            self.backlog('    - [ ] verify: `python -m unittest tests/test_backticks.py`\n')
        )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), 'python -m unittest tests/test_backticks.py')

    def test_plain_verify_line_extraction(self):
        result = self.run_verify(
            self.backlog('    - [ ] verify: python -m unittest tests/test_plain.py\n')
        )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), 'python -m unittest tests/test_plain.py')


if __name__ == '__main__':
    unittest.main()
