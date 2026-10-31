#!/usr/bin/env python3
"""Rotate CHANGELOG.md for a release: the Unreleased section becomes the new version.

    python3 scripts/changelog.py rotate 1.1.0            # rewrite CHANGELOG.md in place
    python3 scripts/changelog.py rotate 1.1.0 --print    # show the result, write nothing
    python3 scripts/changelog.py unreleased              # print the Unreleased body (exit 1 when empty)

Keep a Changelog layout: `## [Unreleased]`, then `## [X.Y.Z] - YYYY-MM-DD` sections, and link
references at the end (`[Unreleased]: …compare/vPREV...HEAD`, `[X.Y.Z]: …`).
"""
import argparse
import datetime
import re
import sys
from pathlib import Path

REPOSITORY = 'https://github.com/DPostnik/Switchboard'
VERSION = re.compile(r'^\d+\.\d+\.\d+$')
SECTION = re.compile(r'^## \[([^\]]+)\](?: - (\d{4}-\d{2}-\d{2}))?\s*$', re.MULTILINE)
LINK = re.compile(r'^\[([^\]]+)\]: \S+\s*$', re.MULTILINE)


class ChangelogError(Exception):
    pass


def split(text):
    """Return (preamble, [(name, date, body)], links) where links is the trailing reference block."""
    lines = text.splitlines()
    end = len(lines)
    while end > 0 and (not lines[end - 1].strip() or LINK.match(lines[end - 1])):
        end -= 1
    body, links = '\n'.join(lines[:end]) + '\n', '\n'.join(lines[end:])
    sections = list(SECTION.finditer(body))
    if not sections:
        raise ChangelogError('no "## [Unreleased]" section')
    preamble = body[:sections[0].start()]
    parsed = []
    for index, match in enumerate(sections):
        end = sections[index + 1].start() if index + 1 < len(sections) else len(body)
        parsed.append((match.group(1), match.group(2), body[match.end():end].strip('\n')))
    return preamble, parsed, links


def unreleased(text):
    _, sections, _ = split(text)
    name, _, body = sections[0]
    if name != 'Unreleased':
        raise ChangelogError('the first section must be "## [Unreleased]"')
    return body.strip()


def rotate(text, version, today=None):
    if not VERSION.match(version):
        raise ChangelogError(f'not a semantic version: {version}')
    preamble, sections, links = split(text)
    name, _, body = sections[0]
    if name != 'Unreleased':
        raise ChangelogError('the first section must be "## [Unreleased]"')
    if not body.strip():
        raise ChangelogError('nothing under "## [Unreleased]"; add the changes before releasing')
    if any(section[0] == version for section in sections):
        raise ChangelogError(f'section [{version}] already exists')
    previous = sections[1][0] if len(sections) > 1 else None
    date = (today or datetime.date.today()).isoformat()
    out = [preamble.rstrip('\n'), '', '## [Unreleased]', '', f'## [{version}] - {date}', '', body.strip('\n'), '']
    for other, other_date, other_body in sections[1:]:
        header = f'## [{other}]' + (f' - {other_date}' if other_date else '')
        out += [header, '', other_body.strip('\n'), '']
    refs = {match.group(1): match.group(0).strip() for match in LINK.finditer(links)}
    refs['Unreleased'] = f'[Unreleased]: {REPOSITORY}/compare/v{version}...HEAD'
    refs[version] = (f'[{version}]: {REPOSITORY}/compare/v{previous}...v{version}' if previous
                     else f'[{version}]: {REPOSITORY}/releases/tag/v{version}')
    ordered = ['Unreleased', version] + [section[0] for section in sections[1:]]
    out += [refs[key] for key in ordered if key in refs]
    return '\n'.join(out).rstrip('\n') + '\n'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('command', choices=['rotate', 'unreleased'])
    parser.add_argument('version', nargs='?')
    parser.add_argument('--path', default=str(Path(__file__).resolve().parent.parent / 'CHANGELOG.md'))
    parser.add_argument('--print', action='store_true', help='print the rotated changelog instead of writing it')
    args = parser.parse_args(argv)
    path = Path(args.path)
    text = path.read_text()
    try:
        if args.command == 'unreleased':
            body = unreleased(text)
            print(body)
            return 0 if body else 1
        if not args.version:
            parser.error('rotate needs a version')
        result = rotate(text, args.version)
    except ChangelogError as error:
        print(f'changelog: {error}', file=sys.stderr)
        return 1
    if args.print:
        sys.stdout.write(result)
    else:
        path.write_text(result)
    return 0


if __name__ == '__main__':
    sys.exit(main())
