import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class BenchmarkReportTest(unittest.TestCase):
    def test_reports_false_pass_metrics_from_results_jsonl(self):
        records = [
            {
                "scenario": "clean pass",
                "exit_code": 0,
                "committed": True,
                "false_pass": False,
            },
            {
                "scenario": "false pass",
                "exit_code": 0,
                "committed": True,
                "false_pass": True,
            },
            {
                "scenario": "failure",
                "exit_code": 1,
                "committed": False,
                "false_pass": False,
            },
        ]

        with tempfile.TemporaryDirectory() as tmpdir:
            result_path = Path(tmpdir) / "results.jsonl"
            with result_path.open("w", encoding="utf-8") as handle:
                for record in records:
                    handle.write(json.dumps(record) + "\n")

            script_path = Path(__file__).resolve().parents[1] / "scripts" / "benchmark_report.py"
            result = subprocess.run(
                [sys.executable, str(script_path), str(result_path)],
                check=True,
                capture_output=True,
                text=True,
            )

        self.assertIn("Total scenarios: 3", result.stdout)
        self.assertIn("Committed scenarios: 2", result.stdout)
        self.assertIn("False PASS count: 1", result.stdout)
        self.assertIn("False PASS rate: 33.33%", result.stdout)


if __name__ == "__main__":
    unittest.main()
