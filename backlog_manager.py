"""
backlog_manager.py
Parse backlog.md, update task status, and calculate progress.
Usage:
  python backlog_manager.py status <backlog_file>
  python backlog_manager.py next <backlog_file>
  python backlog_manager.py complete <backlog_file> <task_id>
  python backlog_manager.py compact <backlog_file> <archive_file>
  python backlog_manager.py fail <backlog_file> <task_id>
  python backlog_manager.py progress <backlog_file>
"""
import sys
import re
import io
import json
import os
import tempfile

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

def read_file(path):
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        return f.read()

def write_file(path, content):
    """Atomic write.

    Write fully to a temp file → flush to disk via fsync → atomically replace with os.replace.
    On interrupt/crash/disk-full:
      - The original file is not corrupted (only the temp file remains if rename hasn't happened)
      - The temp file is created in the same directory with a '.' prefix
        → cleanup_orphaned_backups does not remove it on next run,
          but .loop-agent/ is gitignored so it only causes noise.
    """
    target_dir = os.path.dirname(path) or '.'
    fd, tmp_path = tempfile.mkstemp(
        dir=target_dir, prefix='.bm_', suffix='.tmp'
    )
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', errors='replace') as f:
            f.write(content)
            f.flush()
            try:
                os.fsync(f.fileno())
            except OSError:
                # fsync not supported on some filesystems — data is in the OS buffer
                pass
        os.replace(tmp_path, path)  # atomic on both POSIX and Windows (same volume)
    except BaseException:
        # Clean up temp file on failure (including KeyboardInterrupt)
        try:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)
        except OSError:
            pass
        raise

def find_task_section(content, task_id):
    """Return the start position of a task and the start of the next task (or end of file)."""
    pattern = re.compile(
        r'^- \[([ x!])\] ' + re.escape(task_id) + r':[^\n]*\n',
        re.MULTILINE
    )
    m = pattern.search(content)
    if not m:
        return None, None

    start = m.start()

    # Find the start of the next task (- [ ] Task, ## Phase, or end of file)
    next_task = re.search(
        r'\n- \[[ x!]\] Task |\n## ',
        content[m.end():]
    )
    if next_task:
        end = m.end() + next_task.start() + 1  # include the \n
    else:
        end = len(content)

    return start, end

def parse_tasks(content):
    """Parse tasks from backlog.md."""
    tasks = []
    pattern = re.compile(
        r'^- \[([ x!])\] (Task [\d.]+:[^\n]*)',
        re.MULTILINE
    )
    for m in pattern.finditer(content):
        status_char = m.group(1)
        task_line = m.group(2)
        task_id_match = re.match(r'(Task [\d.]+):(.*)', task_line)
        if not task_id_match:
            continue
        task_id = task_id_match.group(1).strip()
        task_name = task_id_match.group(2).strip()

        if status_char == 'x':
            status = 'done'
        elif status_char == '!':
            status = 'blocked'
        else:
            status = 'pending'

        # Parse only within the task section bounds
        sec_start, sec_end = find_task_section(content, task_id)
        if sec_start is None:
            section = content[m.start():m.start()+600]
        else:
            section = content[sec_start:sec_end]

        # Parse fail count — use the last value in the section (last wins on duplicates)
        fail_matches = list(re.finditer(r'Fail count:\s*(\d+)', section))
        fail_count = int(fail_matches[-1].group(1)) if fail_matches else 0

        # Parse dependencies
        dep_match = re.search(r'Depends:\s*([^\n]+)', section)
        deps = []
        if dep_match:
            dep_str = dep_match.group(1).strip()
            if dep_str.lower() not in ('none', ''):
                raw_deps = [d.strip() for d in dep_str.split(',')]
                for d in raw_deps:
                    # Only recognize "Task X.Y" format as a dependency
                    # Text like "Phase N complete" is ignored (phase order is guaranteed by backlog order)
                    if re.match(r'Task [\d.]+$', d):
                        deps.append(d)
                    # Unrecognized dependencies are silently ignored (prevents deps_not_met)

        tasks.append({
            'id': task_id,
            'name': task_name,
            'status': status,
            'fail_count': fail_count,
            'deps': deps,
            'pos': m.start()
        })
    return tasks

def get_done_ids(tasks):
    return {t['id'] for t in tasks if t['status'] == 'done'}

def get_next_task(tasks):
    """Return the first pending task whose dependencies are satisfied."""
    done_ids = get_done_ids(tasks)
    for t in tasks:
        if t['status'] != 'pending':
            continue
        deps_met = all(dep in done_ids for dep in t['deps'])
        if deps_met:
            return t
    return None

COMPLETED_INDEX_HEADING = '## Completed Task IDs'

def extract_completed_ids(content):
    pattern = re.compile(
        r'^' + re.escape(COMPLETED_INDEX_HEADING) + r'\s*\n(?P<body>.*?)(?=^## |\Z)',
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(content)
    if not match:
        return []

    ids = []
    seen = set()
    for line in match.group('body').splitlines():
        id_match = re.match(r'\s*-\s*(Task [\d.]+)\s*$', line)
        if id_match:
            task_id = id_match.group(1)
            if task_id not in seen:
                ids.append(task_id)
                seen.add(task_id)
    return ids

def replace_completed_index(content, completed_ids):
    if completed_ids:
        body = '\n'.join(f'- {task_id}' for task_id in completed_ids)
    else:
        body = '- none'
    block = f'{COMPLETED_INDEX_HEADING}\n\n{body}\n\n'

    pattern = re.compile(
        r'^' + re.escape(COMPLETED_INDEX_HEADING) + r'\s*\n.*?(?=^## |\Z)',
        re.MULTILINE | re.DOTALL,
    )
    if pattern.search(content):
        return pattern.sub(block, content, count=1)

    first_heading = re.match(r'(# .*\n+)', content)
    if first_heading:
        return content[:first_heading.end()] + block + content[first_heading.end():]
    return block + content

def ordered_unique(values):
    result = []
    seen = set()
    for value in values:
        if value and value not in seen:
            result.append(value)
            seen.add(value)
    return result

def get_done_ids_with_index(tasks, completed_ids):
    done_ids = get_done_ids(tasks)
    done_ids.update(completed_ids)
    return done_ids

def get_next_task_with_index(tasks, completed_ids):
    done_ids = get_done_ids_with_index(tasks, completed_ids)
    for t in tasks:
        if t['status'] != 'pending':
            continue
        deps_met = all(dep in done_ids for dep in t['deps'])
        if deps_met:
            return t
    return None

def cmd_status(backlog_file):
    content = read_file(backlog_file)
    tasks = parse_tasks(content)
    completed_ids = extract_completed_ids(content)
    done_ids = get_done_ids_with_index(tasks, completed_ids)
    total = len([t for t in tasks if t['status'] != 'done']) + len(done_ids)
    done = len(done_ids)
    blocked = sum(1 for t in tasks if t['status'] == 'blocked')
    pending = sum(1 for t in tasks if t['status'] == 'pending')
    result = {
        'total': total,
        'done': done,
        'blocked': blocked,
        'pending': pending,
        'complete': pending == 0 and blocked == 0
    }
    print(json.dumps(result))

def cmd_next(backlog_file):
    content = read_file(backlog_file)
    tasks = parse_tasks(content)
    completed_ids = extract_completed_ids(content)
    next_task = get_next_task_with_index(tasks, completed_ids)
    if next_task:
        print(json.dumps({'id': next_task['id'], 'name': next_task['name']}))
    else:
        pending = [t for t in tasks if t['status'] == 'pending']
        blocked = [t for t in tasks if t['status'] == 'blocked']
        if not pending and not blocked:
            print(json.dumps({'id': None, 'reason': 'all_done'}))
        elif not pending and blocked:
            print(json.dumps({'id': None, 'reason': 'all_blocked'}))
        else:
            print(json.dumps({'id': None, 'reason': 'deps_not_met'}))

def cmd_complete(backlog_file, task_id):
    content = read_file(backlog_file)
    pattern = r'(- \[) \] (' + re.escape(task_id) + r':)'
    new_content = re.sub(pattern, r'\1x] \2', content)
    if new_content == content:
        print('ERROR: task not found or already done')
        sys.exit(1)
    write_file(backlog_file, new_content)
    print('OK')

def cmd_compact(backlog_file, archive_file):
    content = read_file(backlog_file)
    tasks = parse_tasks(content)
    completed_index_ids = extract_completed_ids(content)
    archive_content = read_file(archive_file) if os.path.exists(archive_file) else ''
    archived_task_ids = [t['id'] for t in parse_tasks(archive_content)]

    done_tasks = [t for t in tasks if t['status'] == 'done']
    if not done_tasks:
        merged_ids = ordered_unique(completed_index_ids + archived_task_ids)
        new_content = replace_completed_index(content, merged_ids)
        if new_content != content:
            write_file(backlog_file, new_content)
        print('NO_CHANGE: no completed task sections to archive')
        return

    remove_ranges = []
    archived_sections = []
    archived_ids = set(archived_task_ids)
    done_ids = []

    for task in done_tasks:
        sec_start, sec_end = find_task_section(content, task['id'])
        if sec_start is None:
            continue
        section = content[sec_start:sec_end].rstrip() + '\n'
        remove_ranges.append((sec_start, sec_end))
        done_ids.append(task['id'])
        if task['id'] not in archived_ids:
            archived_sections.append(section)
            archived_ids.add(task['id'])

    compacted_parts = []
    cursor = 0
    for sec_start, sec_end in sorted(remove_ranges):
        compacted_parts.append(content[cursor:sec_start])
        cursor = sec_end
    compacted_parts.append(content[cursor:])
    compacted_content = ''.join(compacted_parts)

    merged_ids = ordered_unique(completed_index_ids + done_ids + archived_task_ids)
    compacted_content = replace_completed_index(compacted_content, merged_ids)
    compacted_content = re.sub(r'\n{4,}', '\n\n\n', compacted_content).rstrip() + '\n'
    write_file(backlog_file, compacted_content)

    if archived_sections:
        if archive_content:
            archive_out = archive_content.rstrip() + '\n\n'
        else:
            archive_out = '# Backlog Archive\n\n'
        archive_out += '\n'.join(section.rstrip() for section in archived_sections)
        archive_out = archive_out.rstrip() + '\n'
        write_file(archive_file, archive_out)

    print(f'COMPACTED: archived {len(done_ids)} completed task sections')

def cmd_fail(backlog_file, task_id):
    content = read_file(backlog_file)
    tasks = parse_tasks(content)
    task = next((t for t in tasks if t['id'] == task_id), None)
    if not task:
        print('ERROR: task not found')
        sys.exit(1)

    new_fail = task['fail_count'] + 1

    # Find the task section bounds
    sec_start, sec_end = find_task_section(content, task_id)
    if sec_start is None:
        print('ERROR: task section not found')
        sys.exit(1)

    section = content[sec_start:sec_end]

    # Remove all existing 'Fail count:' lines, then insert one with the correct value
    section_clean = re.sub(r'  - Fail count:\s*\d+\n', '', section)

    # Insert fail count after the 'Depends:' line, or after the task header if absent
    if '  - Depends:' in section_clean:
        section_new = re.sub(
            r'(  - Depends:[^\n]*\n)',
            r'\1  - Fail count: ' + str(new_fail) + '\n',
            section_clean,
            count=1
        )
    else:
        # Insert after the first task line
        section_new = re.sub(
            r'(- \[[ x!]\] ' + re.escape(task_id) + r':[^\n]*\n)',
            r'\1  - Fail count: ' + str(new_fail) + '\n',
            section_clean,
            count=1
        )

    new_content = content[:sec_start] + section_new + content[sec_end:]

    # Block the task after 5 or more failures
    if new_fail >= 5:
        block_pattern = r'(- \[) \] (' + re.escape(task_id) + r':)'
        new_content = re.sub(block_pattern, r'\1!\] \2', new_content)
        print('BLOCKED')
    else:
        print(f'FAIL_COUNT:{new_fail}')

    write_file(backlog_file, new_content)

def cmd_expand(backlog_file, task_id, new_files_str):
    """Add new files to a task's file scope."""
    content = read_file(backlog_file)

    sec_start, sec_end = find_task_section(content, task_id)
    if sec_start is None:
        print('ERROR: task section not found')
        sys.exit(1)

    section = content[sec_start:sec_end]

    # Find the existing Files: line
    file_match = re.search('(  - Files: )([^\n]+)', section)
    if not file_match:
        print('ERROR: Files: field not found in task')
        sys.exit(1)

    existing = file_match.group(2).strip()
    # Skip files already in scope
    new_files = [f.strip() for f in new_files_str.split(',')]
    to_add = []
    for f in new_files:
        # Strip backticks and extract file path only (remove reason text)
        # e.g. "`path/to/file.ts — reason text`" → "path/to/file.ts"
        f_clean = f.strip('`').strip()
        # Remove text after " — " or ": " (reason description)
        f_clean = re.split(r'\s+[—–-]{1,2}\s+|\s*:\s*(?!.*\.ts|.*\.js)', f_clean)[0].strip()
        f_clean = f_clean.strip('`').strip()
        if f_clean and f_clean not in existing:
            to_add.append(f'`{f_clean}`')

    if not to_add:
        print('NO_CHANGE: all files already in scope')
        return

    new_files_line = existing.rstrip(', ') + ', ' + ', '.join(to_add)
    section_new = section[:file_match.start(2)] + new_files_line + section[file_match.end(2):]
    new_content = content[:sec_start] + section_new + content[sec_end:]
    write_file(backlog_file, new_content)
    print(f'EXPANDED: added {", ".join(to_add)}')

def cmd_progress(backlog_file):
    content = read_file(backlog_file)
    tasks = parse_tasks(content)
    completed_ids = extract_completed_ids(content)
    done_ids = get_done_ids_with_index(tasks, completed_ids)
    total = len([t for t in tasks if t['status'] != 'done']) + len(done_ids)
    done = len(done_ids)
    blocked = [t for t in tasks if t['status'] == 'blocked']
    pending = [t for t in tasks if t['status'] == 'pending']

    if total == 0:
        print('Progress: 0/0 Tasks')
        return

    pct = int(done / total * 100)
    bar_filled = int(done / total * 20)
    bar = '█' * bar_filled + '░' * (20 - bar_filled)

    print(f'Progress: {bar} {done}/{total} Tasks ({pct}%)')
    if blocked:
        blocked_ids = ', '.join(t['id'] for t in blocked)
        print(f'BLOCKED: {blocked_ids}')
    if pending:
        next_task = get_next_task_with_index(tasks, completed_ids)
        if next_task:
            print(f'Next task: {next_task["id"]} {next_task["name"]}')

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]
    backlog_file = sys.argv[2]

    if cmd == 'status':
        cmd_status(backlog_file)
    elif cmd == 'next':
        cmd_next(backlog_file)
    elif cmd == 'complete' and len(sys.argv) >= 4:
        cmd_complete(backlog_file, sys.argv[3])
    elif cmd == 'compact' and len(sys.argv) >= 4:
        cmd_compact(backlog_file, sys.argv[3])
    elif cmd == 'fail' and len(sys.argv) >= 4:
        cmd_fail(backlog_file, sys.argv[3])
    elif cmd == 'expand' and len(sys.argv) >= 5:
        cmd_expand(backlog_file, sys.argv[3], sys.argv[4])
    elif cmd == 'progress':
        cmd_progress(backlog_file)
    else:
        print(f'Unknown command: {cmd}')
        sys.exit(1)
