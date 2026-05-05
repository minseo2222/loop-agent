import unittest

from backlog_manager import (
    extract_task_completion_criteria,
    extract_task_depends,
    extract_task_fail_count,
    extract_task_files,
    extract_task_verify_commands,
)


VALID_SECTION = """- [ ] Task 3.1: Add task section field extraction helpers
  - Depends: Task 2.5, Task 2.6
  - Fail count: 2
  - Files:
    - `backlog_manager.py`
    - `tests/test_backlog_fields.py`
  - Completion criteria:
    - [ ] Helper can extract `Files`.
    - [ ] Helper can extract `Depends`.
    - [ ] verify: `python -m unittest tests/test_backlog_fields.py`
"""


class TestBacklogFieldExtraction(unittest.TestCase):
    def test_valid_section_extracts_fields(self):
        self.assertEqual(
            extract_task_files(VALID_SECTION),
            ['backlog_manager.py', 'tests/test_backlog_fields.py'],
        )
        self.assertEqual(extract_task_depends(VALID_SECTION), ['Task 2.5', 'Task 2.6'])
        self.assertEqual(extract_task_fail_count(VALID_SECTION), 2)
        self.assertEqual(
            extract_task_verify_commands(VALID_SECTION),
            ['python -m unittest tests/test_backlog_fields.py'],
        )
        self.assertEqual(
            extract_task_completion_criteria(VALID_SECTION),
            [
                'Helper can extract `Files`.',
                'Helper can extract `Depends`.',
                'verify: `python -m unittest tests/test_backlog_fields.py`',
            ],
        )

    def test_inline_file_entries_and_depends_none(self):
        section = """- [ ] Task 3.2: Example
  - Depends: none
  - Files: `one.py`, `two.py`
  - Fail count: 0
"""
        self.assertEqual(extract_task_files(section), ['one.py', 'two.py'])
        self.assertEqual(extract_task_depends(section), [])
        self.assertEqual(extract_task_fail_count(section), 0)

    def test_plain_comma_file_entries(self):
        section = """- [ ] Task 3.3: Example
  - Files: one.py, two.py
"""
        self.assertEqual(extract_task_files(section), ['one.py', 'two.py'])

    def test_missing_fields_return_defaults(self):
        section = '- [ ] Task 3.4: Example\n'
        self.assertEqual(extract_task_files(section), [])
        self.assertEqual(extract_task_depends(section), [])
        self.assertEqual(extract_task_fail_count(section), 0)
        self.assertEqual(extract_task_verify_commands(section), [])
        self.assertEqual(extract_task_completion_criteria(section), [])

    def test_empty_and_malformed_fields_return_defaults(self):
        section = """- [ ] Task 3.5: Example
  - Depends:
  - Fail count: many
  - Files:
  - Completion criteria:
"""
        self.assertEqual(extract_task_files(section), [])
        self.assertEqual(extract_task_depends(section), [])
        self.assertEqual(extract_task_fail_count(section), 0)
        self.assertEqual(extract_task_verify_commands(section), [])
        self.assertEqual(extract_task_completion_criteria(section), [])


if __name__ == '__main__':
    unittest.main()
