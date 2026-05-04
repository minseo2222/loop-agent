import sys
import re
import io
import os
import tempfile

# Force UTF-8 output in Windows cp949 environments
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')


def parse_sections(text):
    sections = re.split(r'(?m)(?==== Loop \d+:)', text)
    return [s for s in sections if s.strip().startswith('=== Loop')]


def parse_header(text):
    end = text.find('\n---\n')
    return text[:end + 5] if end >= 0 else ''


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


if __name__ == '__main__':
    if len(sys.argv) >= 4 and sys.argv[1] == '--truncate':
        cmd_truncate(sys.argv[2], int(sys.argv[3]))
    elif len(sys.argv) >= 3:
        # Legacy compatibility: progress_window.py <file> <window_size>
        cmd_window(sys.argv[1], int(sys.argv[2]))
    else:
        sys.stderr.write(
            'Usage:\n'
            '  progress_window.py <file> <window_size>\n'
            '  progress_window.py --truncate <file> <keep_n>\n'
        )
        sys.exit(1)
