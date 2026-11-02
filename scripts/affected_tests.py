"""Select Swift test files likely affected by uncommitted (or since-BASE) changes.

Heuristic, not a proof: the nightly full run is the safety net. A changed test
file is always selected. For a changed source file, the declarations touched
by each diff hunk (the nearest enclosing func/property/type) are looked up by
name in the test sources. Build-graph changes select the full suite.
"""
from pathlib import Path
import re
import subprocess

TESTS = Path('Tests/ContextCoreTests')
# Any of these changing can affect every target; run everything.
GLOBAL = ('Package.swift', 'Package.resolved', 'scripts/swift-task.py', 'scripts/affected_tests.py', 'Sources/CSQLite/')
DECL = re.compile(
    r'^(?P<indent>\s*)(?:@\w+(?:\([^)]*\))?\s+)*'
    r'(?:(?:public|internal|private|fileprivate|package|open|final|static|class|nonisolated|override|mutating|convenience|required|indirect|lazy|weak|unowned)(?:\([^)]*\))?\s+)*'
    r'(?P<kind>struct|class|enum|actor|protocol|extension|func|var|let|init|typealias)\b\s*(?P<name>[A-Za-z_]\w*)?')
# Tests that read data or follow code by path rather than by declaration name: an adapter change, a new
# protocol snapshot or a snapshot script change re-checks the declared protocol surface (cheap, no processes).
PATH_TESTS = {
    'Sources/CodexAdapter/': ['CompatibilitySnapshotTests'],
    'Sources/ClaudeAdapter/': ['CompatibilitySnapshotTests'],
    'Tests/Fixtures/compat/': ['CompatibilitySnapshotTests'],
    'scripts/compat-snapshot.py': ['CompatibilitySnapshotTests'],
}
COMMON = {'body', 'init', 'main', 'description', 'hash', 'encode', 'decode', 'value', 'state', 'title', 'text', 'name', 'path', 'items', 'error', 'result', 'update', 'start', 'stop', 'reset', 'load', 'save', 'Self'}


def git(*args):
    return subprocess.run(['git', *args], capture_output=True, text=True, check=True).stdout


def changed_files(base):
    names = set(git('diff', '--name-only', base, '--').split())
    names |= set(git('ls-files', '--others', '--exclude-standard').split())
    return sorted(names)


def changed_lines(base, path):
    """New-file line numbers touched by the diff; deletions map to their position."""
    lines = set()
    for match in re.finditer(r'^@@ -\S+ \+(\d+)(?:,(\d+))? @@', git('diff', '-U0', base, '--', path), re.M):
        start, count = int(match[1]), int(match[2] or 1)
        lines.update(range(start, start + max(count, 1)))
    return lines


def declarations(lines):
    """(line index, indent, kind, name) for member-level declarations."""
    found = []
    for index, line in enumerate(lines):
        match = DECL.match(line)
        if not match:
            continue
        indent = len(match['indent'].expandtabs(4))
        # Locals inside function bodies are not API that tests reference.
        if match['kind'] in ('var', 'let') and indent > 4:
            continue
        found.append((index, indent, match['kind'], match['name']))
    return found


def touched_names(path, numbers):
    lines = Path(path).read_text(errors='replace').splitlines()
    decls = declarations(lines)
    if numbers is None:  # new file: everything it declares
        return {name for _, _, kind, name in decls if name and kind != 'extension'}
    names = set()
    for number in numbers:
        before = [d for d in decls if d[0] <= number - 1]
        if not before:
            continue
        _, indent, kind, name = before[-1]
        if kind in ('init', 'extension') or not name:
            # Use the enclosing type for initializers and extension-level edits.
            outer = [d for d in before if d[1] < indent and d[2] in ('struct', 'class', 'enum', 'actor', 'protocol', 'extension') and d[3]]
            name = outer[-1][3] if outer else None
        if name:
            names.add(name)
    return names


def select(base='HEAD'):
    """Return (test file stems, reason). Stems None means run the full suite."""
    files = changed_files(base)
    if not files:
        return [], f'no changes relative to {base}'
    if any(f == g or (g.endswith('/') and f.startswith(g)) for f in files for g in GLOBAL):
        return None, 'build configuration changed'
    test_files = sorted(TESTS.glob('*.swift'))
    selected = {Path(f).stem for f in files if f.startswith(str(TESTS) + '/') and f.endswith('.swift') and Path(f).exists()}
    names = set()
    tracked = set(git('ls-files').split())
    for f in files:
        for prefix, stems in PATH_TESTS.items():
            if f == prefix or (prefix.endswith('/') and f.startswith(prefix)):
                selected.update(stem for stem in stems if (TESTS / (stem + '.swift')).exists())
        if not Path(f).is_file():
            continue
        if f.startswith('Sources/') and f.endswith('.swift'):
            names |= touched_names(f, changed_lines(base, f) if f in tracked else None)
            stem = Path(f).stem + 'Tests'
            if (TESTS / (stem + '.swift')).exists():
                selected.add(stem)
        elif not f.startswith(str(TESTS) + '/'):
            # Resources (skills, browser runtime, plugins) are referenced by file name.
            names.add(Path(f).name)
    names = {n for n in names if len(n) >= 4 and n not in COMMON}
    sources = {test.stem: test.read_text(errors='replace') for test in test_files}
    for name in names:
        if name[0].islower() and '.' not in name:
            # Members are referenced as `.name` or called as `name(`.
            pattern = re.compile(r'\.' + re.escape(name) + r'(?!\w)|(?<![\w.])' + re.escape(name) + r'\(')
        else:
            pattern = re.compile(r'(?<!\w)' + re.escape(name) + r'(?!\w)')
        hits = {stem for stem, text in sources.items() if pattern.search(text)}
        # A lowercase member found in most files is a generic word, not a dependency.
        if name[0].islower() and len(hits) * 10 > len(test_files) * 4:
            continue
        selected |= hits
    if len(selected) * 10 >= len(test_files) * 7:
        return None, f'{len(selected)}/{len(test_files)} test files affected'
    return sorted(selected), f'{len(selected)}/{len(test_files)} test files affected'


if __name__ == '__main__':
    import sys
    stems, reason = select(sys.argv[1] if len(sys.argv) > 1 else 'HEAD')
    print(reason)
    print('\n'.join(stems) if stems is not None else '(full suite)')
