import os
import subprocess
import sys
import tempfile
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKLOG_MANAGER = os.path.join(ROOT, 'backlog_manager.py')


VALID_TASK = """# Backlog

- [ ] Task 1.1: Valid task
  - Files: `app.py`
  - Depends: Task 1.0
  - Fail count: 0
  - Completion criteria:
    - [ ] Required fields are present.
    - [ ] verify: `python -m unittest`
"""


class BacklogLintRequiredFieldsTest(unittest.TestCase):
    def run_lint(self, content):
        with tempfile.NamedTemporaryFile('w', delete=False, encoding='utf-8') as f:
            f.write(content)
            path = f.name
        try:
            with open(path, 'r', encoding='utf-8') as f:
                before = f.read()
            result = subprocess.run(
                [sys.executable, BACKLOG_MANAGER, 'lint', path],
                cwd=ROOT,
                text=True,
                capture_output=True,
            )
            with open(path, 'r', encoding='utf-8') as f:
                after = f.read()
            self.assertEqual(before, after)
            return result
        finally:
            os.unlink(path)

    def test_missing_required_fields_fail_lint(self):
        cases = [
            ('Files', '  - Files: `app.py`\n', 'missing Files'),
            ('Depends', '  - Depends: Task 1.0\n', 'missing Depends'),
            ('Fail count', '  - Fail count: 0\n', 'missing Fail count'),
            ('verify command', '    - [ ] verify: `python -m unittest`\n', 'missing verify command'),
            (
                'completion criteria',
                '  - Completion criteria:\n    - [ ] Required fields are present.\n',
                'missing completion criteria',
            ),
        ]

        for name, text, message in cases:
            with self.subTest(name=name):
                result = self.run_lint(VALID_TASK.replace(text, ''))
                output = result.stdout + result.stderr
                self.assertNotEqual(0, result.returncode)
                self.assertIn(message, output)

    def test_valid_backlog_passes_lint(self):
        result = self.run_lint(VALID_TASK)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn('LINT OK', result.stdout)


if __name__ == '__main__':
    unittest.main()
