#!/usr/bin/env python3
"""Read-only, aggregate-only verification activity baseline from the capability ledger.

Counts ledger observations, not executions, UI prompts, or successful tasks. A command
may produce several decisions. No commands, chat IDs, paths, or transcript text leave
the collector. Run with fixed --since/--until Warsaw timestamps for comparison.
"""
import argparse
import collections
import datetime as dt
import json
from pathlib import Path
import re
import shlex
import sqlite3
from zoneinfo import ZoneInfo

WARSAW = ZoneInfo('Europe/Warsaw')
DATA = Path.home() / 'Library/Application Support/Switchboard'


def timestamp(value):
    parsed = dt.datetime.fromisoformat(value)
    return parsed.replace(tzinfo=WARSAW) if parsed.tzinfo is None else parsed


def categories(command):
    """Conservative command-text categories; shell tokens are never evaluated.

    Unwrap shell -c/-lc only. Stop before heredoc bodies, which contain data/code
    rather than outer shell commands. Filters/arguments can still mention a
    category, so these remain observations rather than verified launches.
    """
    for _ in range(4):
        try:
            words = shlex.split(command)
        except ValueError:
            break
        if len(words) == 3 and Path(words[0]).name in ('sh', 'bash', 'zsh') and words[1] in ('-c', '-lc'):
            command = words[2]
        else:
            break
    command = command.split('<<', 1)[0]
    matches = []
    patterns = {
        'load': r'\bsysctl\s+-n\s+vm\.loadavg\s+hw\.ncpu\b',
        'process': r'\b(?:ps\s+-(?:a[xo]*|e[flo]*)\b|pgrep\s)',
        'build': r'(?:^|[\s/])(?:build-app|build-prompter|build-mobile)\.sh\b',
        'test': r'(?:^|[\s/])test\.sh\b|\bswift\s+test\b|\bxcodebuild\s+test\b|\b(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?test\b|\bpytest\b',
        'restart': r'(?:^|[\s/])request-app-restart\.sh\b',
    }
    for name, pattern in patterns.items():
        if re.search(pattern, command):
            matches.append(name)
    return matches


def read_only(path):
    connection = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)
    connection.execute('PRAGMA query_only=ON')
    return connection


def collect(args):
    if args.until <= args.since:
        raise ValueError('--until must be after --since')
    db = read_only(args.database)
    try:
        columns = {r[1] for r in db.execute('PRAGMA table_info(decisions)')}
        required = {'date', 'chat', 'turn', 'project', 'agent', 'tool', 'capability', 'target', 'decision', 'audit'}
        if not required <= columns:
            raise ValueError('ledger schema changed; update the collector')
        rows = db.execute('SELECT chat,turn,project,agent,tool,capability,target,decision,audit FROM decisions '
                          'WHERE date >= ? AND date < ?', (args.since.timestamp(), args.until.timestamp())).fetchall()
    finally:
        db.close()
    metadata = read_only(args.metadata)
    try:
        value = metadata.execute("SELECT value FROM state WHERE key='app'").fetchone()
        projects = {p['id']: p['name'] for p in json.loads(value[0]).get('projects', [])} if value else {}
    finally:
        metadata.close()
    groups = {}
    for chat, turn, project, agent, tool, capability, target, decision, audit in rows:
        if capability != 'shell' or tool not in ('Bash', 'commandExecution'):
            continue
        for category in categories(target or ''):
            key = (projects.get(project, '(unknown project)'), agent, category)
            g = groups.setdefault(key, {'decisions': collections.Counter(), 'chats': set(), 'turns': set(), 'fingerprints': set()})
            g['decisions'][decision + (' (audit)' if audit else '')] += 1
            if chat:
                g['chats'].add(chat)
            if chat and turn:
                g['turns'].add((chat, turn))
                g['fingerprints'].add((chat, turn, target))
    return {
        'version': 1,
        'sinceWarsaw': args.since.astimezone(WARSAW).isoformat(),
        'untilWarsawExclusive': args.until.astimezone(WARSAW).isoformat(),
        'ledgerRecords': len(rows),
        'allDecisions': dict(sorted(collections.Counter(r[7] + (' (audit)' if r[8] else '') for r in rows).items())),
        'limitations': [
            'Categories are command-text heuristics and can overlap; they do not prove a launch.',
            'used means observed under engine rules, not exit-zero or successful verification.',
            'asked/hookAsked are decision records, not verified rendered prompts or interruptions.',
            'Fingerprints collapse identical command text within a turn and can collapse genuine retries.',
            'Turn counts measure coverage only; completed tasks and launch IDs are absent from this ledger.',
            'Records without a turn remain in decision totals but not turn/fingerprint counts.',
        ],
        'groups': [dict(project=k[0], agent=k[1], operation=k[2],
                        records=sum(g['decisions'].values()), decisions=dict(sorted(g['decisions'].items())),
                        chats=len(g['chats']), turns=len(g['turns']), commandFingerprints=len(g['fingerprints']))
                   for k, g in sorted(groups.items())],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--since', type=timestamp, required=True, help='Warsaw ISO timestamp unless offset supplied')
    parser.add_argument('--until', type=timestamp, required=True, help='exclusive Warsaw ISO timestamp unless offset supplied')
    parser.add_argument('--database', type=Path, default=DATA / 'capability-ledger.sqlite')
    parser.add_argument('--metadata', type=Path, default=DATA / 'metadata.sqlite')
    args = parser.parse_args()
    try:
        print(json.dumps(collect(args), ensure_ascii=False, indent=2))
    except (sqlite3.Error, ValueError) as error:
        parser.exit(1, f'verification-baseline: {error}\n')


if __name__ == '__main__':
    main()
