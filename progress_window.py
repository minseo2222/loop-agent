import sys
import re
import io
import os
import tempfile

# Force UTF-8 output in Windows cp949 environments
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

MAX_VALUE_CHARS = 300
MAX_SUMMARY_CHARS = 1800
MAX_MARKDOWN_CHARS = 14000


def parse_sections(text):
    sections = re.split(r'(?m)(?==== Loop \d+:)', text)
    return [s for s in sections if s.strip().startswith('=== Loop')]


def parse_header(text):
    end = text.find('\n---\n')
    return text[:end + 5] if end >= 0 else ''


def read_text(filepath):
    if not filepath or not os.path.exists(filepath):
        return ''
    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        return f.read()


def clean_value(value, default='none', limit=MAX_VALUE_CHARS):
    value = re.sub(r'\s+', ' ', (value or '').strip())
    if not value:
        value = default
    if len(value) > limit:
        value = value[:limit - 3].rstrip() + '...'
    return value


def extract_field(text, label, default='none'):
    match = re.search(r'(?mi)^\s*-?\s*' + re.escape(label) + r':\s*(.+?)\s*$', text)
    return clean_value(match.group(1) if match else '', default=default)


def parse_current_task(text):
    return {
        'task_id': extract_field(text, 'Task ID'),
        'task_name': extract_field(text, 'Task Name'),
        'fail_count': extract_field(text, 'Fail count', '0'),
        'failure_summary': extract_field(text, 'Last failure summary'),
        'evidence_path': extract_field(text, 'Evidence path'),
    }


def first_match(patterns, text, default='none'):
    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE | re.MULTILINE)
        if match:
            return clean_value(match.group(1))
    return default


def derive_failure_context(task, recent_text):
    summary = task['failure_summary']
    combined = summary + '\n' + recent_text
    last_verdict = first_match([
        r'\bverdict=([A-Za-z_ -]+)',
        r'Impl Critic verdict:\s*([A-Za-z_ -]+)',
        r'Plan Critic verdict:\s*([A-Za-z_ -]+)',
        r'Verdict:\s*([A-Za-z_ -]+)',
        r'Final decision:\s*([A-Za-z_ -]+)',
    ], combined)
    last_stage = first_match([
        r'^([A-Za-z -]+) failure\b',
        r'\b(Plan Critic|Impl Critic|Shell Verify|Scope Check|No-change) verdict:',
        r'FAIL \((Plan Critic|Impl Critic|shell verify|scope check|no-change)[^)]*\)',
    ], combined)
    return last_verdict, last_stage


def summarize_section(section):
    keep = []
    interesting = re.compile(
        r'^(=== Loop |Time:|Task:|Plan Critic verdict:|Impl Critic verdict:|'
        r'Verify result:|Verify results:|Verify exit codes:|Final decision:|'
        r'Evidence:|Evidence directory:|Failure evidence:|Blocked reason:|Backlog fail result:|'
        r'Proposal evidence:|Mutation evidence:|Verdict source:|Current allowed Files:|'
        r'Original task:|Current Files:|Current Depends:|Current Verify:|Current Completion criteria:|'
        r'Suggested child task count:|Suggested child task|Child \d+ Files:|Child \d+ Depends:|'
        r'Child \d+ Verify:|Child \d+ Completion criteria:|'
        r'Requested additional files:|Fail count unchanged:|Semantic backlog fields unchanged:|'
        r'Recommended action:|'
        r'Rollback:|PASS commit:|PASS result:|Completed steps:|Result:|Reason:)',
        re.IGNORECASE,
    )
    for raw_line in section.splitlines():
        line = clean_value(raw_line, limit=220)
        if not line:
            continue
        if interesting.search(line):
            keep.append(line)
    if not keep:
        keep = [clean_value(section.splitlines()[0] if section.splitlines() else 'loop result')]
    summary = '\n'.join('- ' + line for line in keep)
    if len(summary) > MAX_SUMMARY_CHARS:
        summary = summary[:MAX_SUMMARY_CHARS - 3].rstrip() + '...'
    return summary


def markdown_content(progress_text, current_task_text, window_size):
    task = parse_current_task(current_task_text)
    sections = parse_sections(progress_text)[-window_size:]
    recent_text = '\n'.join(sections)
    last_verdict, last_stage = derive_failure_context(task, recent_text)
    fail_count = task['fail_count']
    try:
        failed_before = int(re.sub(r'\D.*$', '', fail_count)) > 0
    except ValueError:
        failed_before = False

    guidance = (
        'Use the failure summary and evidence path to avoid repeating the last failed approach. '
        'Stay inside the approved task file scope and keep verify output bounded.'
        if failed_before else
        'No prior failure is recorded for this task. Proceed from the source-of-truth task files.'
    )

    out = [
        '# Progress Window',
        '',
        'Bounded Markdown context for agents. Raw `.loop-agent/progress.txt` remains the durable log.',
        '',
        '## Current Task',
        '',
        f'- Task ID: {task["task_id"]}',
        f'- Task Name: {task["task_name"]}',
        f'- Fail count: {fail_count}',
        f'- Last verdict: {last_verdict}',
        f'- Last failed stage: {last_stage}',
        f'- Last failure summary: {task["failure_summary"]}',
        f'- Evidence path: {task["evidence_path"]}',
        f'- Next-attempt guidance: {guidance}',
        '',
        '## Hard Constraints',
        '',
        '- Treat this file as bounded context, not as source of truth.',
        '- Read source-of-truth files directly when the prompt requires it.',
        '- Do not modify `.loop-agent/` state files from agents.',
        '- Do not pull full diffs, full logs, or huge verify output into agent context.',
        '',
        f'## Recent Loop Summaries ({len(sections)} of latest {window_size})',
        '',
    ]
    if sections:
        for section in sections:
            out.append(summarize_section(section))
            out.append('')
    else:
        out.append('- none')
        out.append('')

    content = '\n'.join(out).rstrip() + '\n'
    if len(content) > MAX_MARKDOWN_CHARS:
        content = content[:MAX_MARKDOWN_CHARS - 80].rstrip() + '\n\n# Truncated\nProgress window was bounded.\n'
    return content


def write_atomic(filepath, content):
    d = os.path.dirname(filepath) or '.'
    fd, tmp = tempfile.mkstemp(dir=d, prefix='.pg_', suffix='.tmp')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', errors='replace') as f:
            f.write(content)
            f.flush()
            try:
                os.fsync(f.fileno())
            except OSError:
                pass
        os.replace(tmp, filepath)
    except BaseException:
        try:
            if os.path.exists(tmp):
                os.unlink(tmp)
        except OSError:
            pass
        raise


def cmd_window(filepath, window_size):
    """Legacy compatibility mode: write the most recent window_size sections to stdout."""
    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        text = f.read()
    for section in parse_sections(text)[-window_size:]:
        print(section.strip())
        print()


def cmd_truncate(filepath, keep_n):
    """Atomically trim the file to header + the most recent keep_n sections.

    No-op if the number of sections is already <= keep_n.
    Prints 'TRUNCATED: <removed>' to stdout if truncation occurred.
    """
    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        text = f.read()

    header = parse_header(text)
    sections = parse_sections(text)
    total = len(sections)
    if total <= keep_n:
        return  # no-op, no output

    keep = sections[-keep_n:]
    removed = total - keep_n

    out = [header.rstrip() + '\n']
    out.append(f'\n# (previous {removed} sections removed, keeping the most recent {keep_n})\n\n')
    out.append('\n'.join(s.rstrip() + '\n' for s in keep))
    content = ''.join(out)

    # atomic write
    d = os.path.dirname(filepath) or '.'
    fd, tmp = tempfile.mkstemp(dir=d, prefix='.pg_', suffix='.tmp')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', errors='replace') as f:
            f.write(content)
            f.flush()
            try:
                os.fsync(f.fileno())
            except OSError:
                pass
        os.replace(tmp, filepath)
    except BaseException:
        try:
            if os.path.exists(tmp):
                os.unlink(tmp)
        except OSError:
            pass
        raise

    print(f'TRUNCATED: {removed}')


def cmd_markdown(progress_file, current_task_file, output_file, window_size):
    progress_text = read_text(progress_file)
    current_task_text = read_text(current_task_file)
    write_atomic(output_file, markdown_content(progress_text, current_task_text, window_size))


if __name__ == '__main__':
    if len(sys.argv) >= 4 and sys.argv[1] == '--truncate':
        cmd_truncate(sys.argv[2], int(sys.argv[3]))
    elif len(sys.argv) >= 5 and sys.argv[1] == '--markdown':
        size = int(sys.argv[5]) if len(sys.argv) >= 6 else 5
        cmd_markdown(sys.argv[2], sys.argv[3], sys.argv[4], size)
    elif len(sys.argv) >= 3:
        # Legacy compatibility: progress_window.py <file> <window_size>
        cmd_window(sys.argv[1], int(sys.argv[2]))
    else:
        sys.stderr.write(
            'Usage:\n'
            '  progress_window.py <file> <window_size>\n'
            '  progress_window.py --truncate <file> <keep_n>\n'
            '  progress_window.py --markdown <progress_file> <current_task_file> <output_file> [window_size]\n'
        )
        sys.exit(1)
