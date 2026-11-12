#!/usr/bin/env python3
"""Group Switchboard access requests that needed the user or were refused. Read-only; no judgement."""
import argparse
import collections
import contextlib
import datetime
import json
import os
from pathlib import Path
import re
import shlex
import sqlite3
import sys
import zoneinfo

ROOT = Path.home() / 'Library/Application Support/Switchboard'
REPOSITORY = Path(__file__).resolve().parents[4]
PRESETS_SOURCE = REPOSITORY / 'Sources/ContextCore/AccessPresets.swift'
RECORD_SOURCE = REPOSITORY / 'Sources/AgentContract/AgentRuntimeEvents.swift'
COLUMNS = {'id', 'date', 'chat', 'run', 'project', 'role', 'agent', 'tool', 'capability', 'target', 'decision', 'turn', 'audit'}
SKIPPED = ('used', 'allowed')
PATH_CAPABILITIES = {'read', 'writeInProject', 'writeOutside'}
WRITE_CAPABILITIES = {'writeInProject', 'writeOutside'}
FILE_TOOLS = {'Read', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit', 'Grep', 'Glob'}
LOCAL = zoneinfo.ZoneInfo('Europe/Warsaw')
HOME = str(Path.home())
TEMP_ROOTS = ('/tmp', '/private/tmp', '/var/folders', '/private/var/folders')
ID_COMPONENT = re.compile(r'^([0-9A-Fa-f-]{32,36}|agent-[0-9a-f]{8,}|[0-9a-f]{16,}|tmp\.[A-Za-z0-9]+)$')


def fail(message):
    sys.exit('access_requests: ' + message)


def connect(file):
    if not file.exists():
        fail(f'{file} not found')
    connection = sqlite3.connect(file.resolve().as_uri() + '?mode=ro', uri=True)
    connection.execute('PRAGMA query_only=ON')
    return connection


def swift_cases(source, enum):
    """Raw values of a Swift `enum <name>: String` in the app's source, or None when the source is not here."""
    if not source.exists():
        return None
    body = re.search(r'enum ' + enum + r': String[^{]*\{(.*?)\n    \}', source.read_text(), re.S)
    if not body:
        fail(f'enum {enum} not found in {source}; update this script with the app change')
    return set(re.findall(r'\b([a-z][A-Za-z]*)\b', ' '.join(re.findall(r'case ([^\n]+)', body.group(1)))))


def presets():
    """Access sets from the app's catalog: id -> read, write, unsandboxed."""
    if not PRESETS_SOURCE.exists():
        return None
    text = PRESETS_SOURCE.read_text()
    result = {}
    for block in re.findall(r'AccessPreset\(id: "([^"]+)"(.*?)(?=AccessPreset\(id:|\n    \])', text, re.S):
        fields = {name: re.findall(r'"([^"]+)"', value) for name, value in re.findall(r'\b(read|write|unsandboxed): \[(.*?)\]', block[1], re.S)}
        result[block[0]] = {key: [expand(path) for path in fields.get(key, [])] if key != 'unsandboxed' else fields.get(key, [])
                            for key in ('read', 'write', 'unsandboxed')}
    base = re.search(r'baseUnsandboxed = \[(.*?)\]', text)
    if not result or not base:
        fail(f'access sets not found in {PRESETS_SOURCE}; update this script with the app change')
    result['_base'] = {'read': [], 'write': [], 'unsandboxed': re.findall(r'"([^"]+)"', base.group(1))}
    return result


def expand(path):
    return HOME + path[1:] if path.startswith('~/') else path


def tilde(path):
    return '~' + path[len(HOME):] if path == HOME or path.startswith(HOME + '/') else path


def app_state(file):
    with contextlib.closing(connect(file)) as connection:
        row = connection.execute("SELECT value FROM state WHERE key='app'").fetchone()
    if not row:
        fail(f'no app state in {file}')
    state = json.loads(row[0])
    return {p['id']: p for p in state.get('projects', [])}, {c['id']: c for c in state.get('chats', [])}


def folder(path, project_path):
    """The folder a rule would name: the file's folder, cut before ID-like components (chat, worktree, temp IDs)."""
    path = os.path.normpath(path)
    for root in TEMP_ROOTS:
        if path == root or path.startswith(root + '/'):
            # Temporary folders are new each time; only the root can become a rule (`/tmp` is `/private/tmp`).
            return root if root.startswith('/private/') else '/private' + root
    parts = path.split('/')
    for index, part in enumerate(parts[1:], 1):
        if ID_COMPONENT.match(part):
            return '/'.join(parts[:index]) or '/'
    last = parts[-1]
    if '.' in last.lstrip('.') or os.path.isfile(path):
        path = os.path.dirname(path)
    if project_path and (path == project_path or path.startswith(project_path + '/')):
        # Inside the project only the top folder matters for a rule.
        rest = path[len(project_path) + 1:].split('/')
        return project_path + ('/' + rest[0] if rest[0] else '')
    return path


SEPARATORS = re.compile(r'\s*(?:&&|\|\||;|\|)\s*')


HEAD = re.compile(r'^[\w./~$+-]+( [A-Za-z][\w.:/-]*)?$')


def heads(command):
    """(head, segment) per command segment: first word plus subcommand, without `cd`, `set`, env prefixes and heredoc bodies.
    The segment keeps its flags so coverage can be checked against trusted command prefixes."""
    result = []
    for segment in SEPARATORS.split(command.split('<<')[0].replace('\n', ' ; ')):
        try:
            words = shlex.split(segment)
        except ValueError:
            words = segment.split()
        while words and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', words[0]):
            words = words[1:]
        if not words or words[0] in ('cd', 'echo', 'true', 'set', 'export', 'exit', '{', '}', 'then', 'do', 'done', 'fi'):
            continue
        rest = [w for w in words[1:] if not w.startswith('-')]
        head = words[0] + (' ' + rest[0] if rest and len(rest[0]) <= 60 else '')
        if not HEAD.match(head):
            head = words[0]
        if HEAD.match(head):
            result.append((head, ' '.join(words)))
    return result or [(command.split()[0] if command.split() else '', command)]


def coverage(capability, tool, key, project, catalog):
    """What in the current settings already opens this target, if anything."""
    if not project or capability not in PATH_CAPABILITIES | {'shell'}:
        return None
    roots = [(project['path'], True, 'project')] + [(r['path'], r['writable'], 'folder ' + tilde(r['path'])) for r in project.get('extraRoots') or []]
    sets = [] if catalog is None else ['_base'] + [p for p in project.get('accessPresets') or [] if p in catalog]
    if capability == 'shell':
        commands = [(c, 'command ' + c) for c in project.get('sandboxCommands') or []]
        commands += [(c, 'set ' + s if s != '_base' else 'base') for s in sets for c in catalog[s]['unsandboxed']]
        for prefix, source in commands:
            if key == prefix or key.startswith(prefix + ' '):
                return source
        return None
    write = capability in WRITE_CAPABILITIES
    if tool not in FILE_TOOLS:
        # Access sets open paths only inside the command sandbox, not for the file tools.
        roots += [(path, True, 'set ' + s) for s in sets for path in catalog[s]['write']]
        roots += [(path, False, 'set ' + s) for s in sets for path in catalog[s]['read']]
    for path, writable, source in roots:
        if (key == path or key.startswith(path.rstrip('/') + '/')) and (writable or not write):
            return source
    return None


def collect(args):
    projects, chats = app_state(args.metadata)
    catalog = presets()
    capabilities = swift_cases(RECORD_SOURCE, 'Capability')
    decisions = swift_cases(RECORD_SOURCE, 'Decision')
    with contextlib.closing(connect(args.database)) as connection:
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if 'decisions' not in tables:
            fail(f'table decisions not found in {args.database}; the ledger schema changed, update this script')
        found = {row[1] for row in connection.execute('PRAGMA table_info(decisions)')}
        if not COLUMNS <= found:
            fail(f'decisions lacks columns {sorted(COLUMNS - found)}; the ledger schema changed, update this script')
        since = args.since or datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=args.days)
        # Nullable additions let this version read old and migrated databases.
        audit_select = ', '.join(name if name in found else 'NULL AS ' + name
                                 for name in ('request_id', 'source', 'stage', 'outcome', 'rule_id', 'reason'))
        connection.row_factory = sqlite3.Row
        rows = [dict(row) for row in connection.execute(
            'SELECT id, date, chat, run, turn, project, role, agent, tool, capability, target, decision, audit, '
            + audit_select + ' FROM decisions WHERE date >= ? ORDER BY date, id', (since.timestamp(),))]
    selected = None
    if args.project:
        matches = [p for p in projects.values() if args.project in (p['id'], p['name'], p['path'], tilde(p['path']))]
        if len(matches) != 1:
            fail(f'project {args.project!r} not found; known: {", ".join(sorted(p["name"] for p in projects.values()))}')
        selected = matches[0]['id']
    unknown = collections.Counter()
    groups = {}
    records = 0
    for row, events, interrupted, old in request_lifecycles(rows):
        date, chat, project_id, role, agent, tool, capability, target, decision, audit = (
            row[name] for name in ('date', 'chat', 'project', 'role', 'agent', 'tool', 'capability', 'target', 'decision', 'audit'))
        if selected and project_id != selected:
            continue
        if capabilities is not None and capability not in capabilities:
            unknown['capability ' + capability] += 1
        if decisions is not None and decision not in decisions:
            unknown['decision ' + decision] += 1
        project = projects.get(project_id)
        target = (target or '').strip()
        if capability in PATH_CAPABILITIES and target.startswith('/'):
            key, chained, check = folder(target, project and project['path']), [], os.path.normpath(target)
        elif capability == 'shell' and target:
            found_heads = heads(target)
            key, chained = found_heads[0][0], [head for head, _ in found_heads[1:]]
            check = found_heads[0][1]
        else:
            key, chained, check = (tool if capability.startswith('connector') or not target else target[:80]), [], None
        group = groups.setdefault((project_id, capability, key), {
            'project': project['name'] if project else (project_id or '(none)'),
            'capability': capability, 'target': tilde(key), 'tools': collections.Counter(),
            'decisions': collections.Counter(), 'roles': collections.Counter(), 'chats': {}, 'chained': collections.Counter(),
            'count': 0, 'records': 0, 'interruptions': 0, 'legacy': 0, 'stages': collections.Counter(),
            'sources': collections.Counter(), 'outcomes': collections.Counter(), 'rules': collections.Counter(),
            'reasons': collections.Counter(), 'last': 0, 'covered': collections.Counter()})
        if check and (source := coverage(capability, tool, check, project, catalog)):
            group['covered'][source] += 1
        group['count'] += 1
        group['records'] += len(events)
        records += len(events)
        group['interruptions'] += int(interrupted)
        group['legacy'] += int(old)
        group['last'] = max(group['last'], date)
        group['tools'][tool] += 1
        for event in events:
            group['decisions'][event['decision'] + (' (audit)' if event['audit'] else '')] += 1
            for key, field in [('stages', 'stage'), ('sources', 'source'), ('outcomes', 'outcome'), ('rules', 'rule_id'),
                               ('reasons', 'reason')]:
                if event[field]:
                    group[key][event[field]] += 1
        group['roles'][role] += 1
        group['chained'].update(chained)
        if chat:
            example = group['chats'].setdefault(chat, {'count': 0, 'target': ' ⏎ '.join(target.split('\n'))[:160], 'date': date})
            example['count'] += 1
    result = []
    for (project_id, _, _), group in groups.items():
        chats_by_use = sorted(group['chats'].items(), key=lambda item: (-item[1]['count'], -item[1]['date']))
        result.append({
            'project': group['project'], 'capability': group['capability'], 'target': group['target'],
            'requests': group['count'], 'chats': len(group['chats']), 'last': local(group['last']),
            'records': group['records'], 'interruptions': group['interruptions'], 'legacyRequests': group['legacy'],
            'stages': dict(group['stages']), 'sources': dict(group['sources']),
            'outcomes': dict(group['outcomes']), 'rules': dict(group['rules']),
            # Why the app asked, allowed or denied (ledger column `reason`, absent before 2026-11-12).
            'reasons': dict(group['reasons'].most_common()),
            'decisions': dict(group['decisions'].most_common()), 'tools': dict(group['tools'].most_common(3)),
            'roles': dict(group['roles'].most_common()),
            **({'chained': [h for h, _ in group['chained'].most_common(4)]} if group['chained'] else {}),
            **({'alreadyOpenBy': ', '.join(f'{source} ({count} req)' for source, count in group['covered'].most_common())}
               if group['covered'] else {}),
            'examples': [{'chat': 'switchboard-chat:' + chat, 'title': (chats.get(chat) or {}).get('title', '')[:60],
                          'target': tilde(info['target'])} for chat, info in chats_by_use[:args.examples]]})
    totals = collections.Counter()
    for group in result:
        totals[group['project']] += group['requests']
    one_off, kept = collections.defaultdict(list), []
    for group in result:
        if group['chats'] <= 1 and group['requests'] <= args.one_off and not group.get('alreadyOpenBy'):
            one_off[group['project']].append(group)
        else:
            kept.append(group)
    result = sorted(kept, key=lambda g: (-totals[g['project']], g['project'], -g['chats'], -g['requests']))
    one_off = {project: {'groups': len(items), 'requests': sum(g['requests'] for g in items),
                         'records': sum(g['records'] for g in items), 'interruptions': sum(g['interruptions'] for g in items),
                         'legacyRequests': sum(g['legacyRequests'] for g in items),
                         'targets': [f"{g['capability']} {g['target'][:70]}" for g in sorted(items, key=lambda g: -g['requests'])[:6]]}
               for project, items in one_off.items()}
    settings = {p['name']: {'path': tilde(p['path']), 'sets': p.get('accessPresets') or [],
                            'folders': [tilde(r['path']) + (' (write)' if r['writable'] else '') for r in p.get('extraRoots') or []],
                            'commands': p.get('sandboxCommands') or [],
                            # Named Keychain items: each one's secret is readable by the project's agents. Names only;
                            # the app state never holds a secret value.
                            **({'keychainItems': [keychain_label(item) for item in p['keychainItems']]} if p.get('keychainItems') else {}),
                            **({'sandbox': False} if p.get('commandSandbox') is False else {})}
                for p in projects.values() if not selected or p['id'] == selected}
    return {'version': 2, 'since': local(since.timestamp()), 'requests': sum(totals.values()), 'records': records,
            'interruptions': sum(g['interruptions'] for g in kept) + sum(g['interruptions'] for g in one_off.values()),
            'legacyRequests': sum(g['legacyRequests'] for g in kept) + sum(g['legacyRequests'] for g in one_off.values()),
            'groups': result, 'oneOff': one_off, 'settings': settings,
            **({'unknownValues': dict(unknown)} if unknown else {}),
            **({'warning': 'app sources not found: access-set coverage and value checks skipped'} if catalog is None else {})}


def keychain_label(item):
    """`service` or `service (account)`, as the app shows it (`KeychainItemRule.label`)."""
    service = str(item.get('service', ''))
    return service + (f" ({item['account']})" if item.get('account') else '')


def local(timestamp):
    return datetime.datetime.fromtimestamp(timestamp, LOCAL).strftime('%Y-%m-%d %H:%M')


def request_lifecycles(rows):
    """One entry per unique request; execution records never imply a request or a user interruption."""
    lifecycles = collections.defaultdict(list)
    legacy = []
    for row in rows:
        if row['request_id'] and row['stage']:
            # Native item IDs need session and turn scope; local interaction UUIDs are globally unique.
            identity = (row['chat'], row['agent'], row['turn'], row['request_id'])
            lifecycles[identity].append(row)
        elif row['decision'] not in SKIPPED:
            legacy.append([row])
    for events in list(lifecycles.values()) + legacy:
        requested = [row for row in events if row['stage'] == 'requested']
        presented = [row for row in events if row['stage'] == 'presented']
        old = all(not row['stage'] for row in events)
        if not old and not requested and not presented:
            continue  # A completion or response outside the window is not a new request.
        evidence = requested or presented or events
        representative = next((row for row in evidence if row['tool'] != 'interaction'), evidence[0])
        if not presented and all(row['decision'] in SKIPPED for row in events):
            continue
        yield representative, events, bool(presented), old


def markdown(report):
    lines = [f"# Access requests since {report['since']} Warsaw",
             f"{report['requests']} unique requests, {report['interruptions']} verified presented interruptions, "
             f"{report['records']} request lifecycle records; {report['legacyRequests']} legacy requests lack presentation evidence. "
             f"{len(report['groups'])} repeated groups below, "
             f"one-off groups (1 chat, few requests) folded per project.", '']
    if 'unknownValues' in report:
        lines += [f"Unknown values (update the skill): {report['unknownValues']}", '']
    if 'warning' in report:
        lines += ['Warning: ' + report['warning'], '']
    project = None
    projects = list(dict.fromkeys([g['project'] for g in report['groups']] + sorted(report['oneOff'])))
    rows = [g for name in projects for g in report['groups'] if g['project'] == name]

    def fold(name):
        info = report['oneOff'].get(name)
        if info:
            lines.append(f"- one-off: {info['groups']} groups, {info['requests']} req: " + '; '.join(f'`{t}`' for t in info['targets']))
    for group in rows + [None]:
        if group is None or group['project'] != project:
            if project is not None:
                fold(project)
            if group is None:
                break
            project = group['project']
            settings = report['settings'].get(project)
            lines += ['', f'## {project}']
            if settings:
                lines.append(f"Now: sets {', '.join(settings['sets']) or '-'}; folders {'; '.join(settings['folders']) or '-'}; "
                             f"commands {'; '.join(settings['commands']) or '-'}"
                             + (f"; KEYCHAIN ITEMS {'; '.join(settings['keychainItems'])}" if settings.get('keychainItems') else '')
                             + ('; sandbox off' if settings.get('sandbox') is False else ''))
        decisions = ', '.join(f'{k} {v}' for k, v in group['decisions'].items())
        lines.append(f"- **{group['capability']}** `{group['target']}`: {group['requests']} req, {group['interruptions']} interruptions, "
                     f"{group['records']} records, {group['chats']} chats, last {group['last']}; "
                     f"{decisions}; tools {', '.join(group['tools'])}"
                     + (f"; sources {', '.join(group['sources'])}" if group['sources'] else '')
                     + (f"; outcomes {group['outcomes']}" if group['outcomes'] else '')
                     + (f"; rules {', '.join(group['rules'])}" if group['rules'] else '')
                     + (f"; reasons {', '.join(f'{k} {v}' for k, v in group['reasons'].items())}" if group['reasons'] else '')
                     + (f"; chained {', '.join(group['chained'])}" if group.get('chained') else '')
                     + (f"; ALREADY OPEN BY {group['alreadyOpenBy']}" if group.get('alreadyOpenBy') else ''))
        for example in group['examples']:
            lines.append(f"  - {example['chat']} «{example['title']}»: `{example['target'][:120]}`")
    # Every granted Keychain item, also in projects without requests in the window: each is a standing secret grant.
    granted = {name: s['keychainItems'] for name, s in report['settings'].items() if s.get('keychainItems')}
    if granted:
        lines += ['', "## Keychain items (each one's secret is readable by the project's agents)"]
        lines += [f"- {name}: " + '; '.join(f'`{label}`' for label in items) for name, items in sorted(granted.items())]
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description='Group Switchboard access requests (read-only)')
    parser.add_argument('--days', type=int, default=14)
    parser.add_argument('--since', type=lambda value: datetime.datetime.fromisoformat(value).replace(tzinfo=LOCAL),
                        help='Warsaw time YYYY-MM-DD[THH:MM]; overrides --days (e.g. the previous review or a settings change)')
    parser.add_argument('--project', help='project name, path or ID')
    parser.add_argument('--format', choices=('md', 'json'), default='md')
    parser.add_argument('--examples', type=int, default=3)
    parser.add_argument('--one-off', type=int, default=2, help='fold groups with one chat and at most this many requests')
    parser.add_argument('--database', type=Path, default=ROOT / 'capability-ledger.sqlite')
    parser.add_argument('--metadata', type=Path, default=ROOT / 'metadata.sqlite')
    args = parser.parse_args()
    try:
        report = collect(args)
    except sqlite3.Error as error:
        fail(f'could not read the ledger: {error}')
    print(json.dumps(report, ensure_ascii=False) if args.format == 'json' else markdown(report))


if __name__ == '__main__':
    main()
