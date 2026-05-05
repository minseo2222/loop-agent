"""
backlog_manager.py
Parse backlog.md, update task status, and calculate progress.
Usage:
  python backlog_manager.py status <backlog_file>
  python backlog_manager.py next <backlog_file>
  python backlog_manager.py complete <backlog_file> <task_id>
  python backlog_manager.py block <backlog_file> <task_id> <reason> <verdict> <evidence_path>
  python backlog_manager.py split <backlog_file> <task_id> <child_specs_json_file> <reason> <verdict> <evidence_path>
  python backlog_manager.py insert-dependency <backlog_file> <task_id> <dependency_specs_json_file> <reason> <verdict> <evidence_path>
  python backlog_manager.py compact <backlog_file> <archive_file>
  python backlog_manager.py fail <backlog_file> <task_id> [max_attempts] [summary] [evidence_path]
  python backlog_manager.py progress <backlog_file>
  python backlog_manager.py lint <backlog_file>
  python backlog_manager.py semantic-snapshot <backlog_file>
  python backlog_manager.py files <backlog_file> <task_id>
  python backlog_manager.py verify <backlog_file> <task_id>
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

def _extract_task_field_blocks(section, field_name):
    blocks = []
    lines = section.splitlines()
    field_pattern = re.compile(r'^(\s*)-\s+' + re.escape(field_name) + r':\s*(.*)$', re.IGNORECASE)
    for i, line in enumerate(lines):
        match = field_pattern.match(line)
        if not match:
            continue

        indent = len(match.group(1))
        block = [match.group(2).strip()]
        for next_line in lines[i + 1:]:
            if not next_line.strip():
                continue
            next_indent = len(next_line) - len(next_line.lstrip(' '))
            if next_indent <= indent:
                break
            block.append(next_line.strip())
        blocks.append(block)
    return blocks

def _ordered_unique_strings(values):
    result = []
    seen = set()
    for value in values:
        if value and value not in seen:
            result.append(value)
            seen.add(value)
    return result

def _extract_task_file_entries(section):
    files = []
    for block in _extract_task_field_blocks(section, 'Files'):
        for entry in block:
            backtick_values = re.findall(r'`([^`]+)`', entry)
            if backtick_values:
                files.extend(value.strip() for value in backtick_values if value.strip())
                continue
            item = re.sub(r'^-\s*', '', entry).strip()
            if not item:
                continue
            files.extend(part.strip() for part in item.split(',') if part.strip())
    return files

def extract_task_files(section):
    files = []
    for file_path in _extract_task_file_entries(section):
        if not file_path:
            continue
        files.append(file_path)
    return _ordered_unique_strings(files)

def _validate_task_file_paths(task_id, files):
    errors = []
    seen = set()
    allowed_loop_agent_files = {
        '.loop-agent/backlog.md',
        '.loop-agent/current_task.md',
        '.loop-agent/progress.txt',
    }

    for file_path in files:
        normalized = file_path.replace('\\', '/')
        duplicate_key = normalized.lower()

        if duplicate_key in seen:
            errors.append(f'{task_id}: duplicate file entry {file_path}')
        else:
            seen.add(duplicate_key)

        if not file_path:
            errors.append(f'{task_id}: empty file entry')
            continue
        if file_path == '~' or file_path.startswith(('~/', '~\\')):
            errors.append(f'{task_id}: home path not allowed {file_path}')
        if os.path.isabs(file_path) or normalized.startswith('/') or re.match(r'^[A-Za-z]:[\\/]', file_path):
            errors.append(f'{task_id}: absolute path not allowed {file_path}')
        if '..' in normalized.split('/'):
            errors.append(f'{task_id}: parent traversal not allowed {file_path}')
        if normalized.endswith('/') or normalized in ('.', ''):
            errors.append(f'{task_id}: directory-only file entry {file_path}')
        if normalized.startswith('.loop-agent/') and normalized not in allowed_loop_agent_files:
            errors.append(f'{task_id}: .loop-agent file not allowed {file_path}')

    return errors

def extract_task_depends(section):
    deps = []
    for block in _extract_task_field_blocks(section, 'Depends'):
        dep_text = ' '.join(part for part in block if part).strip()
        if dep_text.lower() in ('none', ''):
            continue
        deps.extend(re.findall(r'Task [\d.]+', dep_text))
    return _ordered_unique_strings(deps)

def extract_task_fail_count(section):
    fail_count = 0
    for block in _extract_task_field_blocks(section, 'Fail count'):
        if not block:
            continue
        match = re.match(r'(\d+)', block[0])
        if match:
            fail_count = int(match.group(1))
    return fail_count

def extract_task_verify_commands(section):
    commands = []
    for line in section.splitlines():
        match = re.search(r'verify:\s*(.*)$', line, re.IGNORECASE)
        if not match:
            continue
        value = match.group(1).strip()
        backtick_values = re.findall(r'`([^`]+)`', value)
        if backtick_values:
            commands.extend(command.strip() for command in backtick_values)
        elif value:
            commands.append(value)
    return _ordered_unique_strings(commands)

def extract_task_completion_criteria(section):
    criteria = []
    for block in _extract_task_field_blocks(section, 'Completion criteria'):
        for entry in block:
            item = re.sub(r'^-\s*', '', entry).strip()
            item = re.sub(r'^\[[ xX]\]\s*', '', item).strip()
            if item:
                criteria.append(item)
    return criteria

def extract_task_description(section):
    description = []
    for block in _extract_task_field_blocks(section, 'Description'):
        description.extend(part for part in block if part)
    return description

def semantic_snapshot(content):
    snapshot = {}
    for task in parse_tasks(content):
        sec_start, sec_end = find_task_section(content, task['id'])
        if sec_start is None:
            section = ''
        else:
            section = content[sec_start:sec_end]
        snapshot[task['id']] = {
            'title': task['name'],
            'files': extract_task_files(section),
            'depends': extract_task_depends(section),
            'verify': extract_task_verify_commands(section),
            'description': extract_task_description(section),
            'completion_criteria': extract_task_completion_criteria(section),
        }
    return snapshot

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
    next_task = get_next_task_with_index(tasks, completed_ids)
    result = {
        'total': total,
        'done': done,
        'blocked': blocked,
        'pending': pending,
        'complete': pending == 0 and blocked == 0,
        'next_task': (
            {'id': next_task['id'], 'name': next_task['name']}
            if next_task else None
        )
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

def cmd_block(backlog_file, task_id, reason, verdict, evidence_path):
    content = read_file(backlog_file)
    sec_start, sec_end = find_task_section(content, task_id)
    if sec_start is None:
        print('ERROR: task section not found')
        sys.exit(1)

    section = content[sec_start:sec_end]
    section = re.sub(
        r'(- \[)[ x!](\] ' + re.escape(task_id) + r':[^\n]*\n)',
        r'\1!\2',
        section,
        count=1
    )
    section = re.sub(r'  - Blocked reason:[^\n]*\n', '', section)
    section = re.sub(r'  - Last verdict:[^\n]*\n', '', section)
    section = re.sub(r'  - Evidence path:[^\n]*\n', '', section)

    metadata = (
        f'  - Blocked reason: {reason}\n'
        f'  - Last verdict: {verdict}\n'
        f'  - Evidence path: {evidence_path}\n'
    )
    if '  - Fail count:' in section:
        section = re.sub(
            r'(  - Fail count:[^\n]*\n)',
            lambda m: m.group(1) + metadata,
            section,
            count=1
        )
    elif '  - Depends:' in section:
        section = re.sub(
            r'(  - Depends:[^\n]*\n)',
            lambda m: m.group(1) + metadata,
            section,
            count=1
        )
    else:
        section = re.sub(
            r'(- \[[ x!]\] ' + re.escape(task_id) + r':[^\n]*\n)',
            lambda m: m.group(1) + metadata,
            section,
            count=1
        )

    write_file(backlog_file, content[:sec_start] + section + content[sec_end:])
    print('OK')

def _render_child_task(child, depends):
    files = child.get('files') or []
    verify = child.get('verify') or []
    criteria = child.get('completion_criteria') or []

    lines = [
        f'- [ ] {child["id"]}: {child["name"]}',
        '  - Files: ' + ', '.join(f'`{file_path}`' for file_path in files),
        '  - Depends: ' + (', '.join(depends) if depends else 'none'),
        '  - Fail count: 0',
    ]
    for command in verify:
        lines.append(f'  - Verify: `{command}`')
    lines.append('  - Completion criteria:')
    for criterion in criteria:
        lines.append(f'    - [ ] {criterion}')
    return '\n'.join(lines) + '\n'

def _validate_split_children(parent_id, children):
    errors = []
    if not isinstance(children, list):
        return ['child specs must be a list']
    if not children:
        return ['at least one child task is required']
    if len(children) > 2:
        errors.append('more than two child tasks requested')

    expected_ids = [f'{parent_id}.{i}' for i in range(1, len(children) + 1)]
    seen_ids = set()
    for index, child in enumerate(children):
        if not isinstance(child, dict):
            errors.append(f'child {index + 1}: spec must be an object')
            continue
        child_id = _single_line(child.get('id'))
        name = _single_line(child.get('name'))
        files = child.get('files')
        verify = child.get('verify')
        criteria = child.get('completion_criteria')

        if child_id != expected_ids[index]:
            errors.append(f'child {index + 1}: expected id {expected_ids[index]}')
        if child_id in seen_ids:
            errors.append(f'child {index + 1}: duplicate id {child_id}')
        seen_ids.add(child_id)
        if not re.match(r'^Task \d+(?:\.\d+)+$', child_id):
            errors.append(f'child {index + 1}: invalid task id {child_id}')
        if not name:
            errors.append(f'child {index + 1}: missing name')
        if not isinstance(files, list) or not files:
            errors.append(f'child {index + 1}: missing Files')
        else:
            clean_files = [_single_line(value) for value in files]
            if any(not value for value in clean_files):
                errors.append(f'child {index + 1}: empty file path')
            errors.extend(_validate_task_file_paths(child_id, clean_files))
            child['files'] = clean_files
        if not isinstance(verify, list) or not verify:
            errors.append(f'child {index + 1}: missing Verify')
        else:
            clean_verify = [_single_line(value) for value in verify]
            if any(not value for value in clean_verify):
                errors.append(f'child {index + 1}: empty verify command')
            child['verify'] = clean_verify
        if not isinstance(criteria, list) or not criteria:
            errors.append(f'child {index + 1}: missing completion criteria')
        else:
            clean_criteria = [_single_line(value) for value in criteria]
            if any(not value for value in clean_criteria):
                errors.append(f'child {index + 1}: empty completion criterion')
            child['completion_criteria'] = clean_criteria
        child['id'] = child_id
        child['name'] = name

    return errors

def _validate_dependency_specs(current_id, dependencies, existing_ids):
    errors = []
    if not isinstance(dependencies, list):
        return ['dependency specs must be a list']
    if not dependencies:
        return ['at least one dependency task is required']
    if len(dependencies) > 2:
        errors.append('more than two dependency tasks requested')

    seen_ids = set()
    for index, dependency in enumerate(dependencies):
        if not isinstance(dependency, dict):
            errors.append(f'dependency {index + 1}: spec must be an object')
            continue

        dependency_id = _single_line(dependency.get('id'))
        name = _single_line(dependency.get('name'))
        files = dependency.get('files')
        verify = dependency.get('verify')
        criteria = dependency.get('completion_criteria')

        if dependency_id in seen_ids:
            errors.append(f'dependency {index + 1}: duplicate id {dependency_id}')
        seen_ids.add(dependency_id)
        if dependency_id in existing_ids:
            errors.append(f'{dependency_id}: task already exists')
        if dependency_id == current_id:
            errors.append(f'dependency {index + 1}: id matches current task')
        if not re.match(r'^Task \d+(?:\.\d+)+$', dependency_id):
            errors.append(f'dependency {index + 1}: invalid task id {dependency_id}')
        if not name:
            errors.append(f'dependency {index + 1}: missing name')
        if not isinstance(files, list) or not files:
            errors.append(f'dependency {index + 1}: missing Files')
        else:
            clean_files = [_single_line(value) for value in files]
            if any(not value for value in clean_files):
                errors.append(f'dependency {index + 1}: empty file path')
            errors.extend(_validate_task_file_paths(dependency_id, clean_files))
            dependency['files'] = clean_files
        if not isinstance(verify, list) or not verify:
            errors.append(f'dependency {index + 1}: missing Verify')
        else:
            clean_verify = [_single_line(value) for value in verify]
            if any(not value for value in clean_verify):
                errors.append(f'dependency {index + 1}: empty verify command')
            dependency['verify'] = clean_verify
        if not isinstance(criteria, list) or not criteria:
            errors.append(f'dependency {index + 1}: missing completion criteria')
        else:
            clean_criteria = [_single_line(value) for value in criteria]
            if any(not value for value in clean_criteria):
                errors.append(f'dependency {index + 1}: empty completion criterion')
            dependency['completion_criteria'] = clean_criteria

        dependency['id'] = dependency_id
        dependency['name'] = name

    return errors

def _update_current_depends(section, current_id, final_dependency_id):
    depends_match = re.search(r'(?m)^(  - Depends:\s*)([^\n]*)$', section)
    if depends_match:
        dep_text = depends_match.group(2).strip()
        deps = []
        if dep_text.lower() not in ('none', ''):
            deps = [part.strip() for part in dep_text.split(',') if part.strip()]
        if final_dependency_id not in deps:
            deps.append(final_dependency_id)
        replacement = depends_match.group(1) + (', '.join(deps) if deps else 'none')
        return section[:depends_match.start()] + replacement + section[depends_match.end():]

    files_match = re.search(r'(?m)^  - Files:[^\n]*\n', section)
    depends_line = f'  - Depends: {final_dependency_id}\n'
    if files_match:
        return section[:files_match.end()] + depends_line + section[files_match.end():]
    header_match = re.search(r'^- \[[ x!]\] ' + re.escape(current_id) + r':[^\n]*\n', section)
    if header_match:
        return section[:header_match.end()] + depends_line + section[header_match.end():]
    return section

def cmd_insert_dependency(backlog_file, task_id, dependency_specs_json_file, reason, verdict, evidence_path):
    content = read_file(backlog_file)
    sec_start, sec_end = find_task_section(content, task_id)
    if sec_start is None:
        print('ERROR: task section not found')
        sys.exit(1)

    try:
        dependencies = json.loads(read_file(dependency_specs_json_file))
    except (OSError, json.JSONDecodeError) as exc:
        print(f'ERROR: invalid dependency specs: {exc}')
        sys.exit(1)

    tasks = parse_tasks(content)
    existing_ids = {task['id'] for task in tasks}
    errors = _validate_dependency_specs(task_id, dependencies, existing_ids)
    if errors:
        print('ERROR: invalid dependency insertion')
        for error in errors:
            print(f'- {error}')
        sys.exit(1)

    current_section = content[sec_start:sec_end]
    current_deps = extract_task_depends(current_section)
    dependency_sections = []
    previous_dependency_id = None
    for index, dependency in enumerate(dependencies):
        depends = current_deps if index == 0 else [previous_dependency_id]
        dependency_sections.append(_render_child_task(dependency, depends))
        previous_dependency_id = dependency['id']

    current_section = _update_current_depends(current_section, task_id, dependencies[-1]['id'])
    inserted = '\n'.join(section.rstrip() for section in dependency_sections) + '\n\n' + current_section
    new_content = content[:sec_start] + inserted + content[sec_end:]
    write_file(backlog_file, new_content)
    print('INSERTED: ' + ', '.join(dependency['id'] for dependency in dependencies))

def _replace_depends_parent_with_child(content, parent_id, final_child_id):
    def replace_line(match):
        prefix = match.group(1)
        dep_text = match.group(2).strip()
        if dep_text.lower() in ('none', ''):
            return match.group(0)
        deps = []
        changed = False
        for dep in [part.strip() for part in dep_text.split(',')]:
            if dep == parent_id:
                dep = final_child_id
                changed = True
            if dep and dep not in deps:
                deps.append(dep)
        if not changed:
            return match.group(0)
        return prefix + (', '.join(deps) if deps else 'none')

    return re.sub(r'(?m)^(  - Depends:\s*)([^\n]+)$', replace_line, content)

def _mark_parent_replaced(section, parent_id, reason, verdict, evidence_path, replaced_by):
    section = re.sub(
        r'(- \[)[ x!](\] ' + re.escape(parent_id) + r':[^\n]*\n)',
        r'\1!\2',
        section,
        count=1
    )
    for field in ('Blocked reason', 'Last verdict', 'Evidence path', 'Replaced by'):
        section = re.sub(r'  - ' + re.escape(field) + r':[^\n]*\n', '', section)

    metadata = (
        f'  - Blocked reason: {reason}\n'
        f'  - Last verdict: {verdict}\n'
        f'  - Evidence path: {evidence_path}\n'
        f'  - Replaced by: {", ".join(replaced_by)}\n'
    )
    if '  - Fail count:' in section:
        return re.sub(
            r'(  - Fail count:[^\n]*\n)',
            lambda m: m.group(1) + metadata,
            section,
            count=1
        )
    if '  - Depends:' in section:
        return re.sub(
            r'(  - Depends:[^\n]*\n)',
            lambda m: m.group(1) + metadata,
            section,
            count=1
        )
    return re.sub(
        r'(- \[[ x!]\] ' + re.escape(parent_id) + r':[^\n]*\n)',
        lambda m: m.group(1) + metadata,
        section,
        count=1
    )

def cmd_split(backlog_file, task_id, child_specs_json_file, reason, verdict, evidence_path):
    content = read_file(backlog_file)
    sec_start, sec_end = find_task_section(content, task_id)
    if sec_start is None:
        print('ERROR: task section not found')
        sys.exit(1)

    try:
        children = json.loads(read_file(child_specs_json_file))
    except (OSError, json.JSONDecodeError) as exc:
        print(f'ERROR: invalid child specs: {exc}')
        sys.exit(1)

    tasks = parse_tasks(content)
    existing_ids = {task['id'] for task in tasks}
    errors = _validate_split_children(task_id, children)
    for child in children if isinstance(children, list) else []:
        child_id = child.get('id') if isinstance(child, dict) else ''
        if child_id in existing_ids:
            errors.append(f'{child_id}: task already exists')
    if errors:
        print('ERROR: invalid split')
        for error in errors:
            print(f'- {error}')
        sys.exit(1)

    parent_section = content[sec_start:sec_end]
    parent_deps = extract_task_depends(parent_section)
    child_sections = []
    previous_child_id = None
    for index, child in enumerate(children):
        depends = parent_deps if index == 0 else [previous_child_id]
        child_sections.append(_render_child_task(child, depends))
        previous_child_id = child['id']

    replaced_by = [child['id'] for child in children]
    parent_section = _mark_parent_replaced(
        parent_section,
        task_id,
        reason,
        verdict,
        evidence_path,
        replaced_by
    )
    inserted = parent_section.rstrip() + '\n\n' + '\n'.join(section.rstrip() for section in child_sections) + '\n'
    new_content = content[:sec_start] + inserted + content[sec_end:]
    new_content = _replace_depends_parent_with_child(new_content, task_id, children[-1]['id'])
    write_file(backlog_file, new_content)
    print('SPLIT: ' + ', '.join(replaced_by))

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

LAST_FAILURE_SUMMARY_LIMIT = 300

def _single_line(value):
    return re.sub(r'\s+', ' ', str(value or '')).strip()

def _last_failure_summary(summary, evidence_path):
    summary = _single_line(summary)
    evidence_path = _single_line(evidence_path)
    if evidence_path and evidence_path not in summary:
        suffix = f' Evidence: {evidence_path}'
        if summary:
            summary = summary + suffix
        else:
            summary = f'Evidence: {evidence_path}'
    if len(summary) <= LAST_FAILURE_SUMMARY_LIMIT:
        return summary
    if evidence_path:
        suffix = f' Evidence: {evidence_path}'
        if len(suffix) < LAST_FAILURE_SUMMARY_LIMIT:
            prefix_limit = LAST_FAILURE_SUMMARY_LIMIT - len(suffix) - 3
            if prefix_limit > 0:
                return summary[:prefix_limit].rstrip() + '...' + suffix
    return summary[:LAST_FAILURE_SUMMARY_LIMIT - 3].rstrip() + '...'

def cmd_fail(backlog_file, task_id, max_attempts=5, summary='', evidence_path=''):
    max_attempts = str(max_attempts)
    if not re.match(r'^[1-9][0-9]*$', max_attempts):
        print(f'ERROR: max_attempts must be a positive integer: {max_attempts}')
        sys.exit(1)
    max_attempts = int(max_attempts)

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

    # Remove all existing failure lifecycle metadata, then insert current values.
    section_clean = re.sub(r'  - Fail count:\s*\d+\n', '', section)
    section_clean = re.sub(r'  - Last failure summary:[^\n]*\n', '', section_clean)
    section_clean = re.sub(r'  - Evidence path:[^\n]*\n', '', section_clean)

    failure_metadata = '  - Fail count: ' + str(new_fail) + '\n'
    last_summary = _last_failure_summary(summary, evidence_path)
    evidence_path = _single_line(evidence_path)
    if last_summary:
        failure_metadata += f'  - Last failure summary: {last_summary}\n'
    if evidence_path:
        failure_metadata += f'  - Evidence path: {evidence_path}\n'

    # Insert fail count after the 'Depends:' line, or after the task header if absent
    if '  - Depends:' in section_clean:
        section_new = re.sub(
            r'(  - Depends:[^\n]*\n)',
            lambda m: m.group(1) + failure_metadata,
            section_clean,
            count=1
        )
    else:
        # Insert after the first task line
        section_new = re.sub(
            r'(- \[[ x!]\] ' + re.escape(task_id) + r':[^\n]*\n)',
            lambda m: m.group(1) + failure_metadata,
            section_clean,
            count=1
        )

    new_content = content[:sec_start] + section_new + content[sec_end:]

    # Block the task after the configured number of failures.
    if new_fail >= max_attempts:
        block_pattern = r'(- \[) \] (' + re.escape(task_id) + r':)'
        new_content = re.sub(block_pattern, r'\1!] \2', new_content)
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

def _has_integer_fail_count(section):
    for block in _extract_task_field_blocks(section, 'Fail count'):
        if block and re.match(r'^\d+$', block[0]):
            return True
    return False

def _has_task_field(section, field_name):
    return bool(_extract_task_field_blocks(section, field_name))

def _task_id_parts(task_id):
    match = re.match(r'^Task (\d+(?:\.\d+)*)$', task_id)
    if not match:
        return None
    return [int(part) for part in match.group(1).split('.')]

def _is_prior_task_id(dep_id, task_id):
    dep_parts = _task_id_parts(dep_id)
    task_parts = _task_id_parts(task_id)
    return dep_parts is not None and task_parts is not None and len(dep_parts) <= 2 and dep_parts < task_parts

def _validate_task_dependencies(tasks, completed_ids=None):
    errors = []
    task_ids = {task['id'] for task in tasks}
    task_ids.update(completed_ids or [])
    deps_by_task = {}

    for task in tasks:
        deps = task['deps']
        deps_by_task[task['id']] = deps
        for dep in deps:
            if dep == task['id']:
                errors.append(f'{task["id"]}: self dependency')
            elif dep not in task_ids and not _is_prior_task_id(dep, task['id']):
                errors.append(f'{task["id"]}: unknown dependency {dep}')

    visiting = set()
    visited = set()

    def visit(task_id, path):
        if task_id in visiting:
            cycle = path[path.index(task_id):] + [task_id]
            errors.append('dependency cycle: ' + ' -> '.join(cycle))
            return
        if task_id in visited:
            return

        visiting.add(task_id)
        for dep in deps_by_task.get(task_id, []):
            if dep in task_ids and dep != task_id:
                visit(dep, path + [dep])
        visiting.remove(task_id)
        visited.add(task_id)

    for task in tasks:
        visit(task['id'], [task['id']])

    return errors

def cmd_lint(backlog_file):
    content = read_file(backlog_file)
    tasks = parse_tasks(content)
    completed_ids = extract_completed_ids(content)
    errors = []

    for task in tasks:
        sec_start, sec_end = find_task_section(content, task['id'])
        if sec_start is None:
            errors.append(f'{task["id"]}: task section not found')
            continue

        section = content[sec_start:sec_end]
        task_files = _extract_task_file_entries(section)
        if not extract_task_files(section):
            errors.append(f'{task["id"]}: missing Files')
        errors.extend(_validate_task_file_paths(task['id'], task_files))
        if not _has_task_field(section, 'Depends'):
            errors.append(f'{task["id"]}: missing Depends')
        if not _has_integer_fail_count(section):
            errors.append(f'{task["id"]}: missing Fail count')
        if not extract_task_verify_commands(section):
            errors.append(f'{task["id"]}: missing verify command')
        if not extract_task_completion_criteria(section):
            errors.append(f'{task["id"]}: missing completion criteria')

    errors.extend(_validate_task_dependencies(tasks, completed_ids))

    if errors:
        print('LINT FAILED')
        for error in errors:
            print(f'- {error}')
        sys.exit(1)

    print(f'LINT OK: {len(tasks)} tasks checked')

def cmd_semantic_snapshot(backlog_file):
    content = read_file(backlog_file)
    print(json.dumps(semantic_snapshot(content), sort_keys=True, separators=(',', ':')))

def cmd_files(backlog_file, task_id):
    content = read_file(backlog_file)
    sec_start, sec_end = find_task_section(content, task_id)
    if sec_start is None:
        print('ERROR: task not found')
        sys.exit(1)

    files = extract_task_files(content[sec_start:sec_end])
    if not files:
        print('ERROR: Files not found')
        sys.exit(1)

    errors = _validate_task_file_paths(task_id, files)
    if errors:
        print('ERROR: invalid Files')
        for error in errors:
            print(f'- {error}')
        sys.exit(1)

    for file_path in files:
        print(file_path)

def cmd_verify(backlog_file, task_id):
    content = read_file(backlog_file)
    sec_start, sec_end = find_task_section(content, task_id)
    if sec_start is None:
        print('ERROR: task not found')
        sys.exit(1)

    commands = extract_task_verify_commands(content[sec_start:sec_end])
    if not commands:
        print('ERROR: verify command not found')
        sys.exit(1)

    for command in commands:
        print(command)

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
    elif cmd == 'block' and len(sys.argv) >= 7:
        cmd_block(backlog_file, sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
    elif cmd == 'split' and len(sys.argv) >= 8:
        cmd_split(backlog_file, sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7])
    elif cmd == 'insert-dependency' and len(sys.argv) >= 8:
        cmd_insert_dependency(backlog_file, sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7])
    elif cmd == 'compact' and len(sys.argv) >= 4:
        cmd_compact(backlog_file, sys.argv[3])
    elif cmd == 'fail' and len(sys.argv) >= 4:
        max_attempts = sys.argv[4] if len(sys.argv) >= 5 else 5
        summary = sys.argv[5] if len(sys.argv) >= 6 else ''
        evidence_path = sys.argv[6] if len(sys.argv) >= 7 else ''
        cmd_fail(backlog_file, sys.argv[3], max_attempts, summary, evidence_path)
    elif cmd == 'expand' and len(sys.argv) >= 5:
        cmd_expand(backlog_file, sys.argv[3], sys.argv[4])
    elif cmd == 'progress':
        cmd_progress(backlog_file)
    elif cmd == 'lint':
        cmd_lint(backlog_file)
    elif cmd == 'semantic-snapshot':
        cmd_semantic_snapshot(backlog_file)
    elif cmd == 'files' and len(sys.argv) >= 4:
        cmd_files(backlog_file, sys.argv[3])
    elif cmd == 'verify' and len(sys.argv) >= 4:
        cmd_verify(backlog_file, sys.argv[3])
    else:
        print(f'Unknown command: {cmd}')
        sys.exit(1)
