import unittest

from backlog_manager import semantic_snapshot


BASE_BACKLOG = """# Backlog

## Phase 1

- [ ] Task 1.1: Build parser
  - Files: `parser.py`, `tests/test_parser.py`
  - Depends: none
  - Fail count: 0
  - Last verdict: PASS
  - Evidence path: .loop-agent/evidence/task-1.1.txt
  - Description:
    Read source text.
    Return parsed records.
  - Completion criteria:
    - [ ] Parser returns records.
    - [ ] verify: `python -m unittest tests/test_parser.py`

- [x] Task 1.2: Use parser
  - Files:
    - `runner.py`
  - Depends: Task 1.1
  - Fail count: 2
  - Last verdict: FAIL
  - Evidence path: .loop-agent/evidence/task-1.2.txt
  - Description: Call parser from runner.
  - Completion criteria:
    - [x] Runner calls parser.
    - [ ] verify: `python -m unittest tests/test_runner.py`
"""


class SemanticSnapshotTests(unittest.TestCase):
    def test_snapshot_includes_protected_semantic_fields(self):
        snapshot = semantic_snapshot(BASE_BACKLOG)

        self.assertEqual(
            snapshot["Task 1.1"],
            {
                "title": "Build parser",
                "files": ["parser.py", "tests/test_parser.py"],
                "depends": [],
                "verify": ["python -m unittest tests/test_parser.py"],
                "description": ["Read source text.", "Return parsed records."],
                "completion_criteria": [
                    "Parser returns records.",
                    "verify: `python -m unittest tests/test_parser.py`",
                ],
            },
        )
        self.assertEqual(snapshot["Task 1.2"]["depends"], ["Task 1.1"])
        self.assertEqual(snapshot["Task 1.2"]["files"], ["runner.py"])

    def test_lifecycle_changes_do_not_change_snapshot(self):
        changed = (
            BASE_BACKLOG
            .replace("- [ ] Task 1.1:", "- [x] Task 1.1:")
            .replace("Fail count: 0", "Fail count: 4")
            .replace("Last verdict: PASS", "Last verdict: FAIL")
            .replace(
                ".loop-agent/evidence/task-1.1.txt",
                ".loop-agent/evidence/changed.txt",
            )
        )

        self.assertEqual(semantic_snapshot(BASE_BACKLOG), semantic_snapshot(changed))

    def test_semantic_changes_change_snapshot(self):
        changed = BASE_BACKLOG.replace("Parser returns records.", "Parser returns rows.")

        self.assertNotEqual(semantic_snapshot(BASE_BACKLOG), semantic_snapshot(changed))

    def test_helper_does_not_modify_input_content(self):
        content = BASE_BACKLOG

        semantic_snapshot(content)

        self.assertEqual(content, BASE_BACKLOG)


if __name__ == "__main__":
    unittest.main()
