#!/usr/bin/env python3
"""Prefer SwiftPM; support the locally broken CLT installation without changing it."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / '.build/local-build'
LOG = OUT / 'test-last.log'
# Lines worth showing in compact test output; everything goes to LOG.
SHOWN = re.compile(r'error:|fatal error|✘|Test run with|Expectation failed|recorded an issue|Fatal|Crash|signal [0-9]|exited with')
SHOWN_LIMIT = 60
FAILED_TEST = re.compile(r'✘ Test (\w+)\(.*\) (?:with \d+ test cases? )?failed after')
RETRY_LIMIT = 8


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def run_logged(args, verbose, log):
    """Run a test-task command, keeping the full output in LOG and printing a compact view."""
    args = [str(x) for x in args]
    log.write('$ ' + ' '.join(args) + '\n')
    log.flush()
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace')
    shown = 0
    failed = set()
    for line in process.stdout:
        log.write(line)
        if match := FAILED_TEST.search(line):
            failed.add(match[1])
        if verbose:
            print(line, end='', flush=True)
        elif SHOWN.search(line):
            shown += 1
            if shown <= SHOWN_LIMIT:
                print(re.sub(r'\x1b\[[0-9;]*m', '', line).rstrip()[:400], flush=True)
            elif shown == SHOWN_LIMIT + 1:
                print(f'... more failures in {LOG.relative_to(ROOT)}', flush=True)
    log.flush()
    if process.wait() != 0:
        error = subprocess.CalledProcessError(process.returncode, args)
        error.failed_tests = failed
        raise error


def run_tests(execute, command, filters, serial=False):
    """Run tests once; retry only the failed test functions once, serially, and say so.

    Some process-based fixtures have fixed deadlines that a fully parallel run can
    exceed. A serial pass separates that from a real regression without
    rerunning the whole suite.
    """
    flags = [x for value in filters for x in ('--filter', value)] + (['--no-parallel'] if serial else [])
    # Tests that build a default DeskModel would otherwise create files in the user's real data folder.
    # Opt-in live tests that need the real Codex home can set SWITCHBOARD_DATA_ROOT themselves.
    if 'SWITCHBOARD_DATA_ROOT' not in os.environ:
        os.environ['SWITCHBOARD_DATA_ROOT'] = tempfile.mkdtemp(prefix='switchboard-test-data-')
    try:
        execute(command + flags)
        return
    except subprocess.CalledProcessError as error:
        failed = sorted(getattr(error, 'failed_tests', ()))
        if serial or not failed or len(failed) > RETRY_LIMIT:
            raise
    print(f'Retrying {len(failed)} failed test(s) once, serially: {", ".join(failed)}', flush=True)
    retry = ['--filter', r'\.(?:' + '|'.join(failed) + r')\(', '--no-parallel']
    execute(command + retry)
    print(f'FLAKY (failed in parallel, passed serially): {", ".join(failed)}. '
          'Not a regression in the tested code; do not rerun the suite. Report it.', flush=True)


def capture(args):
    return run(args, capture_output=True, text=True).stdout.strip()


def sources(folder):
    return sorted((ROOT / folder).rglob('*.swift'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('task', choices=['build', 'test'])
    parser.add_argument('--direct', action='store_true', help='Explicitly exercise the direct compiler fallback')
    parser.add_argument('--filter', action='append', default=[], help='Swift Testing filter regex (repeatable); a test file name such as QueueTests selects that file')
    parser.add_argument('--changed', action='store_true', help='Run only test files affected by changes relative to --base (heuristic)')
    parser.add_argument('--base', default='HEAD', help='Git revision for --changed (default: HEAD, i.e. uncommitted changes)')
    parser.add_argument('--verbose', action='store_true', help='Stream full test output instead of failures and the summary')
    args = parser.parse_args()
    os.chdir(ROOT)
    OUT.mkdir(parents=True, exist_ok=True)
    filters = list(args.filter)
    if args.changed:
        from affected_tests import select
        stems, reason = select(args.base)
        if stems == []:
            print(f'NO TESTS RUN: {reason}. Use --base REV for committed changes or omit --changed for the full suite.')
            return
        if stems is None:
            print(f'Selection: full suite ({reason}).', flush=True)
        else:
            print(f'Selection: {reason}: {", ".join(stems)}', flush=True)
            filters.append(r'(?:^|[/.])(?:' + '|'.join(stems) + r')\.swift:')
    if args.task == 'test':
        log = LOG.open('w')
        verbose = args.verbose
        execute = lambda command: run_logged(command, verbose, log)
    else:
        execute = run
    compiler = capture(['xcrun', '--find', 'swiftc'])
    swift = capture(['xcrun', '--find', 'swift'])
    developer = Path(capture(['xcode-select', '-p']))
    version = capture([compiler, '--version'])
    target = platform.machine() + '-apple-macosx14.0'
    candidates = [Path(os.environ.get('SWITCHBOARD_SDK', capture(['xcrun', '--show-sdk-path'])))]
    if 'SWITCHBOARD_SDK' not in os.environ:
        sdk_dirs = [developer / 'SDKs', developer / 'Platforms/MacOSX.platform/Developer/SDKs']
        installed = [p for folder in sdk_dirs for p in folder.glob('MacOSX[0-9]*.sdk')]
        candidates += sorted(installed, key=lambda p: tuple(map(int, re.findall(r'\d+', p.name))), reverse=True)
    seen = set()
    sdk = None
    with tempfile.TemporaryDirectory(prefix='sdk-probe-', dir=OUT) as tmp:
        probe = Path(tmp) / 'Probe.swift'
        probe.write_text('import Foundation\nimport SwiftUI\nimport AppKit\n'
                         'struct SDKProbe: View {\n'
                         '  @State private var value = false\n'
                         '  var body: some View { Text(value ? "yes" : "no") }\n'
                         '}\n')
        for candidate in candidates:
            candidate = candidate.resolve()
            if candidate in seen:
                continue
            seen.add(candidate)
            result = subprocess.run([compiler, '-sdk', str(candidate), '-target', target, '-typecheck', str(probe)], capture_output=True, text=True)
            if result.returncode == 0:
                sdk = candidate
                break
            print(f'SDK incompatible: {candidate}', file=sys.stderr)
            (OUT / 'sdk-probe-error.log').write_text(result.stderr)
    if sdk is None:
        raise RuntimeError('No compatible SDK. See .build/local-build/sdk-probe-error.log. Install a matching Xcode/Command Line Tools release or set SWITCHBOARD_SDK.')
    if args.task == 'build' or args.verbose:
        print(f'Compiler: {version}\nSDK: {sdk}', flush=True)
    if args.task == 'test':
        log.write(f'Compiler: {version}\nSDK: {sdk}\n')
    health = subprocess.run([swift, 'package', '--version'], capture_output=True, text=True)
    direct = args.direct or health.returncode != 0
    if health.returncode != 0:
        (OUT / 'swiftpm-error.log').write_text(health.stdout + health.stderr)
        print('SwiftPM cannot start; using direct compilation. Diagnostic: .build/local-build/swiftpm-error.log', flush=True)
    # Full Xcode keeps testing frameworks in the macOS platform; CLT uses
    # Library/Developer. Keep framework and runtime paths from the same layout.
    testing_layouts = [
        (developer / 'Platforms/MacOSX.platform/Developer/Library/Frameworks',
         developer / 'Platforms/MacOSX.platform/Developer/usr/lib'),
        (developer / 'Library/Developer/Frameworks',
         developer / 'Library/Developer/usr/lib'),
    ]
    frameworks, testing_libraries = next(
        (layout for layout in testing_layouts if (layout[0] / 'Testing.framework').is_dir()),
        testing_layouts[0],
    )
    has_testing_framework = (frameworks / 'Testing.framework').is_dir()
    test_flags = []
    if has_testing_framework:
        test_flags = ['-F', str(frameworks), '-Xlinker', '-rpath', '-Xlinker', str(frameworks), '-Xlinker', '-rpath', '-Xlinker', str(testing_libraries)]
    macros = Path(compiler).parent.parent / 'lib/swift/host/plugins/testing'
    if macros.is_dir():
        test_flags += ['-plugin-path', str(macros)]
    if args.task == 'test':
        with tempfile.TemporaryDirectory(prefix='testing-probe-', dir=OUT) as tmp:
            probe = Path(tmp) / 'TestingProbe.swift'
            probe.write_text('import Testing\n@Test func toolchainProbe() { #expect(true) }\n')
            result = subprocess.run([compiler, '-sdk', str(sdk), '-target', target, '-typecheck'] + test_flags + [str(probe)], capture_output=True, text=True)
            if result.returncode != 0:
                (OUT / 'testing-probe-error.log').write_text(result.stdout + result.stderr)
                raise RuntimeError('Swift Testing framework/macros are incompatible with this toolchain. Tests did not run. Install a matching Command Line Tools or Xcode release; see guides/building.md and .build/local-build/testing-probe-error.log.')
    if not direct:
        # A source/build/test failure must fail, never trigger a fallback or reuse an old binary.
        if args.task == 'build':
            command = [swift, 'build', '--sdk', sdk, '-c', 'release', '--product', 'ContextDesk', '--force-resolved-versions']
            run(command)
            bin_path = capture([swift, 'build', '--sdk', sdk, '-c', 'release', '--show-bin-path'])
            shutil.copy2(Path(bin_path) / 'ContextDesk', OUT / 'ContextDesk')
        else:
            command = [swift, 'test', '--sdk', sdk, '--disable-xctest', '--force-resolved-versions']
            if macros.is_dir():
                command += ['-Xswiftc', '-plugin-path', '-Xswiftc', macros]
            if has_testing_framework:
                command += ['-Xswiftc', '-F', '-Xswiftc', frameworks, '-Xlinker', '-F', '-Xlinker', frameworks, '-Xlinker', '-rpath', '-Xlinker', frameworks, '-Xlinker', '-rpath', '-Xlinker', testing_libraries]
            run_tests(execute, command, filters)
    else:
        resolved = json.loads((ROOT / 'Package.resolved').read_text())
        pins = resolved['pins']
        if len(pins) != 1 or pins[0]['identity'] != 'tomldecoder' or pins[0]['state']['version'] != '0.4.5':
            raise RuntimeError('Dependency graph changed. Update the direct build recipe or repair SwiftPM.')
        dependency = ROOT / '.build/checkouts/TOMLDecoder'
        if not dependency.is_dir():
            raise RuntimeError('Pinned TOMLDecoder checkout missing. Restore SwiftPM and run swift package resolve first.')
        if capture(['git', '-C', dependency, 'rev-parse', 'HEAD']) != pins[0]['state']['revision'] or capture(['git', '-C', dependency, 'status', '--porcelain']):
            raise RuntimeError('TOMLDecoder checkout must be clean and match Package.resolved.')
        # Rebuild all modules in an empty directory so compiler/SDK changes cannot reuse stale objects.
        with tempfile.TemporaryDirectory(prefix='compile-', dir=OUT) as tmp:
            work = Path(tmp)
            base = [compiler, '-sdk', sdk, '-swift-version', '6', '-target', target, '-parse-as-library', '-I', work, '-I', ROOT / 'Sources/CSQLite', '-L', work]
            base += ['-Onone', '-enable-testing'] if args.task == 'test' else ['-O']
            modules = [('AgentContract', 'Sources/AgentContract'), ('FringeProtocol', 'Sources/FringeProtocol'), ('TOMLDecoder', '.build/checkouts/TOMLDecoder/Sources/TOMLDecoder'), ('ContextCore', 'Sources/ContextCore'), ('CodexAdapter', 'Sources/CodexAdapter'), ('ClaudeAdapter', 'Sources/ClaudeAdapter'), ('ContextTranscript', 'Sources/ContextTranscript')]
            if args.task == 'test':
                # The app does not link ACPAdapter yet; only the tests use it.
                modules += [('ACPAdapter', 'Sources/ACPAdapter'), ('ContextDesk', 'Sources/ContextDesk')]
            for name, folder in modules:
                if args.task == 'build' or args.verbose:
                    print(f'Compiling {name}', flush=True)
                flags = ['-Xfrontend', '-entry-point-function-name', '-Xfrontend', 'ContextDesk_main'] if name == 'ContextDesk' else []
                execute(base + flags + ['-emit-library', '-static', '-emit-module', '-module-name', name, '-emit-module-path', work / (name + '.swiftmodule'), '-o', work / ('lib' + name + '.a')] + sources(folder))
            libraries = ['-lClaudeAdapter', '-lCodexAdapter', '-lContextTranscript', '-lContextCore', '-lTOMLDecoder', '-lAgentContract', '-lFringeProtocol']
            if args.task == 'build':
                run(base + ['-module-name', 'ContextDesk'] + sources('Sources/ContextDesk') + libraries + ['-o', work / 'ContextDesk'])
                shutil.copy2(work / 'ContextDesk', OUT / 'ContextDesk')
            else:
                runner = work / 'Runner.swift'
                # New Testing releases also expose a CInt-returning overload. Keep
                # the process-exiting entry point, including its failing exit status.
                runner.write_text('import Testing\n@main struct Runner { static func main() async { let _: Never = await Testing.__swiftPMEntryPoint() } }\n')
                execute(base + test_flags + ['-module-name', 'ContextCoreTests'] + sources('Tests/ContextCoreTests') + [runner, '-lContextDesk', '-lACPAdapter'] + libraries + ['-o', work / 'Tests'])
                run_tests(execute, [work / 'Tests'], filters)
    if args.task == 'build':
        digest = hashlib.sha256()
        browser_resources = [ROOT / 'BrowserRuntime' / name for name in
                             ('server.py', 'broker.py', 'transport.py', 'chrome_host.py', 'profiles.py', 'cdp.py', 'page_input.py', 'install.py', 'cards.js', 'page_read.js', 'page_tree.js', 'runtime.lock.json', 'README.md')]
        for path in sorted([ROOT / 'Package.swift', ROOT / 'Package.resolved'] + list((ROOT / 'Sources').rglob('*')) + list((ROOT / 'Skills').rglob('*')) + browser_resources):
            if path.is_file():
                digest.update(str(path.relative_to(ROOT)).encode() + b'\0' + path.read_bytes())
        (OUT / 'build-info.json').write_text(json.dumps({'builtAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'compiler': version, 'sdk': str(sdk), 'backend': 'swiftc' if direct else 'SwiftPM', 'sourceSHA256': digest.hexdigest()}, indent=2) + '\n')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        if LOG.exists() and sys.argv[1:2] == ['test']:
            sys.exit(f'FAILED (exit {error.returncode}). Full log: {LOG.relative_to(ROOT)} — read it instead of rerunning.')
        sys.exit(str(error))
    except RuntimeError as error:
        sys.exit(str(error))
