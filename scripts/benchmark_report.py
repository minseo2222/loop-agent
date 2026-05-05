#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def load_records(path):
    records = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{line_number}: invalid JSON: {exc}") from exc

            if not isinstance(record, dict):
                raise SystemExit(f"{path}:{line_number}: record must be an object")
            if not isinstance(record.get("scenario"), str):
                raise SystemExit(f"{path}:{line_number}: scenario must be a string")
            if not isinstance(record.get("exit_code"), int):
                raise SystemExit(f"{path}:{line_number}: exit_code must be an integer")
            if not isinstance(record.get("committed"), bool):
                raise SystemExit(f"{path}:{line_number}: committed must be a boolean")
            if not isinstance(record.get("false_pass"), bool):
                raise SystemExit(f"{path}:{line_number}: false_pass must be a boolean")

            records.append(record)
    return records


def main(argv):
    if len(argv) != 2:
        raise SystemExit("usage: benchmark_report.py RESULTS.jsonl")

    result_path = Path(argv[1])
    records = load_records(result_path)
    total = len(records)
    exit_failures = sum(1 for record in records if record["exit_code"] != 0)
    committed = sum(1 for record in records if record["committed"])
    false_passes = sum(1 for record in records if record["false_pass"])
    false_pass_rate = (false_passes / total * 100) if total else 0.0

    print("Benchmark summary")
    print(f"Total scenarios: {total}")
    print(f"Exit-code failures: {exit_failures}")
    print(f"Committed scenarios: {committed}")
    print(f"False PASS count: {false_passes}")
    print(f"False PASS rate: {false_pass_rate:.2f}%")
    print(f"Results file: {result_path}")


if __name__ == "__main__":
    main(sys.argv)
