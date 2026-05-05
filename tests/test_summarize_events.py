import tempfile
import unittest
from pathlib import Path

from scripts.summarize_events import summarize_event_file


class SummarizeEventsTest(unittest.TestCase):
    def test_counts_decisions_and_proposal_verdicts(self):
        fixture = Path(__file__).parent / "fixtures" / "events_sample.jsonl"

        summary = summarize_event_file(fixture)

        self.assertEqual(1, summary["decisions"]["PASS"])
        self.assertEqual(1, summary["decisions"]["FAIL"])
        self.assertEqual(1, summary["decisions"]["BLOCKED"])
        self.assertEqual(2, summary["proposal_verdicts"]["PASS"])
        self.assertEqual(1, summary["proposal_verdicts"]["FAIL"])

    def test_malformed_jsonl_is_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "events.jsonl"
            path.write_text(
                '{"event":"decision","status":"PASS"}\n'
                "not json\n"
                '{"event":"proposal_verdict","verdict":"FAIL"}\n',
                encoding="utf-8",
            )

            summary = summarize_event_file(path)

        self.assertEqual(1, summary["decisions"]["PASS"])
        self.assertEqual(0, summary["decisions"]["FAIL"])
        self.assertEqual(0, summary["decisions"]["BLOCKED"])
        self.assertEqual(1, summary["proposal_verdicts"]["FAIL"])

    def test_missing_event_file_returns_zero_counts(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "missing.jsonl"

            summary = summarize_event_file(path)

        self.assertEqual({"PASS": 0, "FAIL": 0, "BLOCKED": 0}, summary["decisions"])
        self.assertEqual({}, summary["proposal_verdicts"])


if __name__ == "__main__":
    unittest.main()
