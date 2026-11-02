#!/usr/bin/env python3 -I
"""Write a condensed protocol index for one agent CLI version into Tests/Fixtures/compat/.

Run by hand when a new engine version is verified; never at runtime, in tests or nightly.

  python3 -I scripts/compat-snapshot.py codex [--binary PATH]
      Runs the installed binary's `--version` and `app-server generate-json-schema --experimental`
      (CODEX_HOME is a fresh temporary directory, so ~/.codex is never read or written) and writes
      codex-<version>.json: client requests (params/response types), server requests, notifications,
      thread item types and, for every type reachable from them, its properties with referenced types.

  python3 -I scripts/compat-snapshot.py claude --version 2.1.292
      Finds the @anthropic-ai/claude-agent-sdk release whose `claudeCodeVersion` matches, downloads it with
      `npm pack --ignore-scripts` into a fresh temporary directory, reads only `package/sdk.d.ts` from the
      tarball in memory (nothing is extracted or executed) and writes claude-<version>.json: the frame types,
      system and result subtypes and control request subtypes of `StdoutMessage`.

The Swift test CompatibilitySnapshotTests checks the adapters' declared protocol surface against these files.
"""
import argparse
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'Tests/Fixtures/compat'


def write(name, index):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / name
    # One type per line keeps diffs between versions readable.
    lines = ['{']
    keys = list(index)
    for i, key in enumerate(keys):
        value = index[key]
        comma = ',' if i < len(keys) - 1 else ''
        if isinstance(value, dict) and value and all(isinstance(v, (dict, list, str)) for v in value.values()) and key in ('clientRequests', 'serverRequests', 'notifications', 'itemTypes', 'types'):
            lines.append(f'  {json.dumps(key)}: {{')
            inner = sorted(value)
            for j, k in enumerate(inner):
                c = ',' if j < len(inner) - 1 else ''
                lines.append(f'    {json.dumps(k)}: {json.dumps(value[k], sort_keys=True, separators=(",", ":"))}{c}')
            lines.append('  }' + comma)
        else:
            lines.append(f'  {json.dumps(key)}: {json.dumps(value, sort_keys=True)}{comma}')
    lines.append('}')
    path.write_text('\n'.join(lines) + '\n')
    print(f'wrote {path.relative_to(ROOT)} ({path.stat().st_size} bytes)')


# --- Codex ---------------------------------------------------------------------------------------

def codex_binary(explicit):
    if explicit:
        return explicit
    home = Path.home()
    candidates = [f'{d}/{app}/Contents/Resources/{rel}' for d in ['/Applications', str(home / 'Applications')]
                  for app in ['ChatGPT.app', 'Codex.app'] for rel in ['codex-cli/CodexCLI.app/Contents/MacOS/codex', 'codex']]
    candidates += ['/opt/homebrew/bin/codex', '/usr/local/bin/codex']
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    sys.exit('Codex binary not found; pass --binary PATH')


def refs(schema):
    """Referenced definition names anywhere inside one property schema (not following the references)."""
    found = set()
    if isinstance(schema, dict):
        ref = schema.get('$ref')
        if isinstance(ref, str):
            found.add(ref.rsplit('/', 1)[-1])
        for key, value in schema.items():
            if key != '$ref':
                found |= refs(value)
    elif isinstance(schema, list):
        for value in schema:
            found |= refs(value)
    return found


def properties(schema):
    """Property name -> referenced types, merged over union variants; '|' lists aliased types, '+' marks an open object."""
    props, aliases, open_object = {}, set(), False
    def visit(node):
        nonlocal open_object
        if not isinstance(node, dict):
            return
        if node.get('additionalProperties') is True:
            open_object = True
        for name, value in (node.get('properties') or {}).items():
            props.setdefault(name, set()).update(refs(value))
        for key in ('oneOf', 'anyOf', 'allOf'):
            for variant in node.get(key) or []:
                if isinstance(variant, dict) and '$ref' in variant:
                    aliases.add(variant['$ref'].rsplit('/', 1)[-1])
                else:
                    visit(variant)
        if '$ref' in node:
            aliases.add(node['$ref'].rsplit('/', 1)[-1])
        for key in ('items', 'additionalProperties'):
            if isinstance(node.get(key), dict):
                aliases.update(refs(node[key]))
    visit(schema)
    result = {name: sorted(values) for name, values in sorted(props.items())}
    if aliases:
        result['|'] = sorted(aliases)
    if open_object:
        result['+'] = []
    return result


def codex(args):
    binary = codex_binary(args.binary)
    version_text = subprocess.run([binary, '--version'], capture_output=True, text=True, timeout=30, check=True).stdout.strip()
    match = re.fullmatch(r'codex-cli (\S+)', version_text)
    if not match:
        sys.exit(f'unexpected --version output: {version_text!r}')
    version = match[1]
    with tempfile.TemporaryDirectory(prefix='codex-schema-') as temp:
        home, out = Path(temp) / 'home', Path(temp) / 'out'
        home.mkdir(); out.mkdir()
        env = {k: v for k, v in os.environ.items() if k in ('PATH', 'HOME', 'USER', 'LANG', 'TMPDIR')}
        env['CODEX_HOME'] = str(home)
        subprocess.run([binary, 'app-server', 'generate-json-schema', '--experimental', '--out', str(out)],
                       env=env, cwd=temp, capture_output=True, timeout=120, check=True)
        definitions = {}
        for name in ['codex_app_server_protocol.v2.schemas.json', 'codex_app_server_protocol.schemas.json',
                     'ServerNotification.json', 'ServerRequest.json', 'ClientRequest.json']:
            for key, value in json.loads((out / name).read_text()).get('definitions', {}).items():
                definitions.setdefault(key, value)
        def variants(name):
            for variant in json.loads((out / name).read_text())['oneOf']:
                method = variant['properties']['method']['enum'][0]
                params = refs(variant['properties'].get('params', {}))
                yield method, (sorted(params)[0] if params else None)
        client = {}
        for method, params in variants('ClientRequest.json'):
            entry = {'params': params}
            response = params[:-len('Params')] + 'Response' if params and params.endswith('Params') else None
            if response in definitions:
                entry['response'] = response
            client[method] = entry
        server = {method: {'params': params} for method, params in variants('ServerRequest.json')}
        notifications = {method: params for method, params in variants('ServerNotification.json')}
        items = {}
        for variant in definitions['ThreadItem']['oneOf']:
            kind = variant['properties']['type']['enum'][0]
            items[kind] = properties(variant)
    roots = {v for e in client.values() for v in e.values() if v} | {e['params'] for e in server.values() if e['params']}
    roots |= {v for v in notifications.values() if v} | {r for p in items.values() for v in p.values() for r in v}
    types, queue = {}, sorted(roots)
    while queue:
        name = queue.pop()
        if name in types or name not in definitions:
            continue
        types[name] = properties(definitions[name])
        queue.extend(r for v in types[name].values() for r in v if r not in types)
    write(f'codex-{version}.json', {
        'agent': 'codex', 'version': version,
        'source': 'codex app-server generate-json-schema --experimental',
        'clientRequests': client, 'serverRequests': server, 'notifications': notifications,
        'itemTypes': items, 'types': types,
    })


# --- Claude --------------------------------------------------------------------------------------

def npm(*args, cwd):
    # Run outside the repository so no project .npmrc or package.json is consulted.
    return subprocess.run(['npm', *args], capture_output=True, text=True, timeout=120, check=True, cwd=cwd).stdout


def claude(args):
    package = '@anthropic-ai/claude-agent-sdk'
    major, minor, patch = args.version.split('.')
    # SDK 0.<minor+2>.<patch> has tracked Claude Code 2.<minor>.<patch>; the field below is the proof.
    sdk = args.sdk or f'0.{int(minor) + 2}.{patch}'
    with tempfile.TemporaryDirectory(prefix='claude-sdk-') as temp:
        reported = npm('view', f'{package}@{sdk}', 'claudeCodeVersion', cwd=temp).strip()
        if reported != args.version:
            sys.exit(f'{package}@{sdk} reports claudeCodeVersion {reported!r}, not {args.version}; pass --sdk')
        npm('pack', f'{package}@{sdk}', '--ignore-scripts', '--pack-destination', temp, cwd=temp)
        tarball = next(Path(temp).glob('*.tgz'))
        with tarfile.open(tarball) as archive:
            member = archive.getmember('package/sdk.d.ts')
            source = archive.extractfile(member).read().decode()
    def declaration(name):
        match = re.search(r'declare type ' + re.escape(name) + r' = (\{.*?\n\}|[^;{]+);', source, re.S)
        if not match:
            sys.exit(f'type {name} not found in sdk.d.ts')
        return match[1]
    def literals(body, field):
        line = re.search(r'^\s{4}' + field + r': ([^;\n]+);', body, re.M)
        return re.findall(r"'([a-z_]+)'", line[1]) if line else []
    def members(union):
        return [n.strip().split('.')[-1] for n in union.split('|') if n.strip()]
    frames, system, results, seen = set(), set(), set(), set()
    def visit(name):
        if name in seen:
            return
        seen.add(name)
        body = declaration(name)
        if not body.startswith('{'):
            for member in members(body):
                visit(member)
            return
        kinds = literals(body, 'type')
        frames.update(kinds)
        if 'system' in kinds:
            system.update(literals(body, 'subtype'))
        if 'result' in kinds:
            results.update(literals(body, 'subtype'))
    for member in members(re.search(r'declare type StdoutMessage = ([^;]+);', source)[1]):
        visit(member)
    inner = re.search(r'declare type SDKControlRequestInner = ([^;]+);', source)[1]
    controls = sorted({s for m in members(inner) for s in literals(declaration(m), 'subtype')})
    write(f'claude-{args.version}.json', {
        'agent': 'claude-code', 'version': args.version,
        'source': f'{package}@{sdk} sdk.d.ts (claudeCodeVersion {args.version}): StdoutMessage, SDKControlRequestInner',
        'frameTypes': sorted(frames), 'systemSubtypes': sorted(system), 'resultSubtypes': sorted(results),
        'controlRequestSubtypes': controls,
    })


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='agent', required=True)
    c = sub.add_parser('codex'); c.add_argument('--binary')
    k = sub.add_parser('claude'); k.add_argument('--version', required=True); k.add_argument('--sdk')
    args = parser.parse_args()
    codex(args) if args.agent == 'codex' else claude(args)


if __name__ == '__main__':
    main()
