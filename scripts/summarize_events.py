#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path


TASK_RE = re.compile(r"^\s*-\s+\[([ xX!])\]\s+(Task\s+[^:]+):\s*(.*)$")
LEGACY_TASK_RE = re.compile(r"^\s*##\s+(Task\s+[^:]+):\s*(.*)$")
HASH_RE = re.compile(r"\b[0-9a-f]{7,40}\b", re.IGNORECASE)


def read_events(path):
    events = []
    if not path.exists():
        return events
    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(event, dict):
                events.append(event)
    return events


def parse_backlog(path):
    tasks = []
    current = None
    if not path.exists():
        return tasks
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.rstrip()
        match = TASK_RE.match(line) or LEGACY_TASK_RE.match(line)
        if match:
            if current:
                tasks.append(current)
            if len(match.groups()) == 3:
                marker, task_id, name = match.groups()
            else:
                marker, task_id, name = "", match.group(1), match.group(2)
            current = {"id": task_id.strip(), "name": name.strip(), "marker": marker.strip().lower(), "lines": [], "meta": {}}
            continue
        if current is None:
            continue
        current["lines"].append(line)
        meta = re.match(r"^\s*-\s*([^:]+):\s*(.*)$", line)
        if meta:
            current["meta"][meta.group(1).strip().lower()] = meta.group(2).strip()
    if current:
        tasks.append(current)
    return tasks


def unique(values):
    seen = set()
    result = []
    for value in values:
        if value and value not in seen:
            seen.add(value)
            result.append(value)
    return result


def task_label(task_id, task_name):
    if task_id and task_name:
        return f"{task_id} - {task_name}"
    return task_id or task_name or "unknown task"


def event_type(event):
    return str(event.get("event") or event.get("type") or "")


def event_status(event):
    return str(event.get("status") or event.get("outcome") or event.get("verify_status") or "")


def summarize_event_file(path):
    summary = {
        "decisions": {"PASS": 0, "FAIL": 0, "BLOCKED": 0},
        "proposal_verdicts": {},
    }
    for event in read_events(Path(path)):
        kind = event_type(event)
        status = event_status(event).upper()
        if kind == "decision" and status in summary["decisions"]:
            summary["decisions"][status] += 1
        if kind == "proposal_verdict":
            verdict = str(event.get("verdict") or status).upper()
            if verdict:
                summary["proposal_verdicts"][verdict] = summary["proposal_verdicts"].get(verdict, 0) + 1
    return summary


def collect_completed(events, tasks):
    completed = []
    for task in tasks:
        status = task["meta"].get("status", "").upper()
        if task["marker"] == "x" or status in {"DONE", "PASS", "COMPLETE", "COMPLETED"}:
            completed.append(task_label(task["id"], task["name"]))
    for event in events:
        if event_status(event).upper() == "PASS" and event_type(event) in {"decision", "commit"}:
            completed.append(task_label(str(event.get("task_id", "")), str(event.get("task_name", ""))))
    return unique(completed)


def collect_commits(events, tasks):
    commits = []
    for event in events:
        commits.extend(HASH_RE.findall(str(event.get("commit_hash") or event.get("pass_commit_hash") or "")))
    for task in tasks:
        for key, value in task["meta"].items():
            if "commit" in key:
                commits.extend(HASH_RE.findall(value))
        for line in task["lines"]:
            if "commit" in line.lower():
                commits.extend(HASH_RE.findall(line))
    return unique(commits)


def collect_failures(events, tasks):
    failures = []
    for event in events:
        kind = event_type(event)
        status = event_status(event).upper()
        label = task_label(str(event.get("task_id", "")), str(event.get("task_name", "")))
        if kind == "verify_result" and status == "FAIL":
            failures.append(f"{label}: verify failed")
        elif kind == "rollback":
            reason = str(event.get("reason") or "rollback")
            failures.append(f"{label}: rollback - {reason}")
        elif kind == "decision" and status in {"FAIL", "ERROR"}:
            failures.append(f"{label}: {status} - {event.get('reason') or event.get('stage') or status}")
    for task in tasks:
        fail_count = task["meta"].get("fail count") or task["meta"].get("fail_count")
        failure = task["meta"].get("last failure") or task["meta"].get("failure") or task["meta"].get("failure evidence")
        if fail_count and fail_count != "0":
            detail = f"fail count {fail_count}"
            if failure:
                detail += f"; {failure}"
            failures.append(f"{task_label(task['id'], task['name'])}: {detail}")
    return unique(failures)


def collect_blocked(tasks):
    blocked = []
    for task in tasks:
        reason = task["meta"].get("blocked reason") or task["meta"].get("block reason") or task["meta"].get("blocked")
        if task["marker"] == "!" or task["meta"].get("status", "").upper() == "BLOCKED" or reason:
            blocked.append(f"{task_label(task['id'], task['name'])}: {reason or 'blocked'}")
    return unique(blocked)


def collect_policy_blocks(events):
    blocks = []
    for event in events:
        if event_type(event) != "blocked":
            continue
        block_type = str(event.get("block_type") or "BLOCKED").upper()
        if block_type == "FAIL":
            continue
        reason = event.get("reason") or "blocked"
        detail = f"{task_label(str(event.get('task_id', '')), str(event.get('task_name', '')))}: BLOCKED: {block_type} - {reason}; policy block"
        child_count = event.get("suggested_child_task_count")
        if block_type == "SPLIT_TASK" and child_count not in (None, ""):
            detail += f"; suggested child task count: {child_count}"
        requested_files = event.get("requested_files")
        if requested_files:
            detail += f"; requested files: {requested_files}"
        action = event.get("recommended_action")
        if not action:
            if block_type == "SCOPE_EXPAND":
                action = "Review the scope expansion proposal and manually update backlog.md Files if appropriate."
            elif block_type == "SPLIT_TASK":
                action = "Review the split proposal and manually replace the blocked task with child tasks if appropriate."
        if action:
            detail += f"; Action required: {action}; Recommended action: {action}"
        if event.get("fail_count_unchanged") is True:
            detail += "; Fail count unchanged; fail count unchanged"
        blocks.append(detail)
    return unique(blocks)


def collect_proposals(path):
    if not path.exists() or not path.is_dir():
        return []
    return sorted(str(item.relative_to(path.parent).as_posix()) for item in path.glob("*.md") if item.is_file())


def evidence_dir(value):
    value = str(value).replace("\\", "/").strip()
    for marker, prefix in ((".loop-agent/evidence/", ".loop-agent/evidence/"), ("evidence/", ".loop-agent/evidence/")):
        if marker in value:
            tail = value.split(marker, 1)[1]
            parts = [part for part in tail.split("/") if part]
            if parts:
                return f"{prefix}{parts[0]}/"
    return ""


def collect_evidence(events, tasks, project_root=None):
    refs = []
    for event in events:
        for key in ("evidence_rel", "evidence_dir", "verify_results_path", "verify_commands_path"):
            refs.append(evidence_dir(event.get(key, "")))
    for task in tasks:
        for value in task["meta"].values():
            refs.append(evidence_dir(value))
        for line in task["lines"]:
            refs.append(evidence_dir(line))
    refs = unique(refs)
    # Drop references to pruned (deleted) evidence dirs so the final report
    # only points at locations the user can actually inspect. PASS evidence is
    # pruned by default (LOOP_EVIDENCE_PRUNE_PASS=1); FAIL/BLOCKED dirs persist.
    if project_root is not None:
        refs = [r for r in refs if r and (project_root / r).exists()]
    return refs


def section(title, values):
    lines = [f"## {title}", ""]
    lines.extend(f"- {value}" for value in values) if values else lines.append("- none")
    lines.append("")
    return lines


def write_report(args):
    project = Path(args.project).resolve()
    state_dir = Path(args.state_dir).resolve() if args.state_dir else project / ".loop-agent"
    output = Path(args.output).resolve() if args.output else state_dir / "report.md"
    progress_window = state_dir / "progress_window.md"
    events = read_events(state_dir / "events.jsonl")
    tasks = parse_backlog(state_dir / "backlog.md")

    lines = ["# Loop Agent Final Report", ""]
    lines += section("Completed tasks", collect_completed(events, tasks))
    lines += section("Commit hashes", collect_commits(events, tasks))
    lines += section("Failed attempts", collect_failures(events, tasks))
    lines += section("Blocked policy outcomes", collect_policy_blocks(events))
    lines += section("Blocked tasks", collect_blocked(tasks))
    lines += section("Proposal files", collect_proposals(state_dir / "proposals"))
    lines += section("Evidence references", collect_evidence(events, tasks, project))
    lines += section("Latest progress window", [".loop-agent/progress_window.md"] if progress_window.exists() else [])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", default=".")
    parser.add_argument("--state-dir", default="")
    parser.add_argument("--output", default="")
    write_report(parser.parse_args())


if __name__ == "__main__":
    main()
