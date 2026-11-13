"""The narrowed mediated git and gh policy for the nono probes: a copy of `ExternalSandboxPlanner.gitCommand` and
`ghCommand` (Sources/ContextCore/ExternalSandbox.swift) compiled the way `ExternalSandboxPlan.policyDocument` compiles it.
Keep both in step; `ExternalSandboxTests` checks the Swift side, the probes check this copy under the real helper."""
import os
import subprocess

GIT = '/opt/homebrew/bin/git'
PLAIN_ENV = ['PATH', 'HOME', 'USER', 'LOGNAME', 'LANG', 'LC_*', 'TERM', 'TMPDIR', 'SSL_CERT_FILE']
GIT_LOCAL_ENV = PLAIN_ENV + ['GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL',
                             'GIT_COMMITTER_DATE', 'GIT_INDEX_FILE', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_EDITOR', 'GIT_SEQUENCE_EDITOR',
                             'GIT_MERGE_AUTOEDIT', 'GIT_OPTIONAL_LOCKS']
KEYCHAIN_SUBCOMMANDS = ['push', 'fetch', 'ls-remote']
KEYCHAIN_PREPEND = ['--no-pager', '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false', '-c', 'core.askPass=',
                    '-c', 'core.alternateRefsCommand=exit 0', '-c', 'credential.helper=', '-c', 'credential.helper=osxkeychain',
                    '-c', 'gpg.format=openpgp', '-c', 'gpg.program=gpg']
GH_SUBCOMMANDS = ['pr', 'issue', 'repo', 'api', 'run', 'workflow', 'release', 'search', 'label', 'status', 'cache',
                  'help', '--help', '-h', 'version', '--version']


def git_trees():
    exec_path = subprocess.check_output([GIT, '--exec-path'], text=True).strip()
    return sorted({'/bin', exec_path, os.path.realpath(exec_path)})


def _rules(trees, files=()):
    out = []
    for tree in trees:
        out += ['(allow process-exec* (subpath "%s"))' % tree, '(allow file-read* (subpath "%s"))' % tree,
                '(allow file-map-executable (subpath "%s"))' % tree]
    for file in files:
        out += ['(allow process-exec* (literal "%s"))' % file, '(allow file-read* (literal "%s"))' % file,
                '(allow file-map-executable (literal "%s"))' % file]
    return out


def _sandbox(fs, keychain, network, env, set_vars, trees=(), files=(), prepend=()):
    sandbox = dict(fs)
    sandbox['network'] = {'allow_all': network}
    sandbox['environment'] = {'allow_vars': env, 'set_vars': set_vars}
    if keychain:
        sandbox['keychain_access'] = 'read'
    if prepend:
        sandbox['argv_prepend'] = list(prepend)
    rules = _rules(trees, files)
    if rules:
        sandbox['unsafe_macos_seatbelt_rules'] = rules
    return sandbox


def git_policy(fs, home, roots):
    """`fs`: the `fs_*` lists of the session union; `home`: forced HOME; `roots`: accepted `-C` paths (canonical)."""
    trees = git_trees()
    leads = [[]] + [['-C', str(root)] for root in roots]
    local = _sandbox(fs, False, False, GIT_LOCAL_ENV, {'GIT_TERMINAL_PROMPT': '0', 'GIT_ALLOW_PROTOCOL': 'file', 'HOME': str(home)},
                     trees, ['/usr/bin/false', '/usr/bin/true'])
    clone = _sandbox(fs, False, True, GIT_LOCAL_ENV, {'GIT_TERMINAL_PROMPT': '0', 'GIT_ALLOW_PROTOCOL': 'https:file', 'HOME': str(home)},
                     trees, ['/usr/bin/false', '/usr/bin/true'])
    keychain = _sandbox(fs, True, True, PLAIN_ENV, {'GIT_TERMINAL_PROMPT': '0', 'GIT_ALLOW_PROTOCOL': 'https', 'HOME': str(home),
                                                    'GIT_EDITOR': ':', 'GIT_SEQUENCE_EDITOR': ':'}, trees, prepend=KEYCHAIN_PREPEND)
    deny = [{'argv': {'prefix': lead + ['pull']}, 'reason': 'git pull: run git fetch, then git merge --ff-only or git rebase'} for lead in leads]
    deny += [{'argv': {'prefix': lead + ['credential']}, 'reason': 'git credential is not available under the boundary'} for lead in leads]
    intercept = [{'match': {'argv': {'prefix': lead + [sub]}}, 'action': {'type': 'passthrough'}, 'sandbox': keychain}
                 for lead in leads for sub in KEYCHAIN_SUBCOMMANDS]
    intercept += [{'match': {'argv': {'prefix': lead + ['clone']}}, 'action': {'type': 'passthrough'}, 'sandbox': clone} for lead in leads]
    return {'executable': GIT, 'from': {'session': {'sandbox': local, 'invocation_policy': {'default': 'allow', 'deny': deny}}},
            'intercept': intercept}


def gh_policy(fs, home, executable):
    sandbox = _sandbox(fs, True, True, PLAIN_ENV, {'HOME': str(home), 'GH_PROMPT_DISABLED': '1', 'GH_NO_UPDATE_NOTIFIER': '1',
                                                   'GH_PAGER': 'cat', 'GIT_TERMINAL_PROMPT': '0'})
    refused = [('prefix', ['auth', 'token']), ('contains', ['--show-token']), ('prefix', ['auth', 'git-credential']), ('prefix', ['extension']),
               ('prefix', ['extensions']), ('prefix', ['ext']), ('prefix', ['alias']), ('prefix', ['config', 'set'])]
    allow = [{'argv': {'prefix': [name]}} for name in GH_SUBCOMMANDS]
    allow += [{'argv': {'exact': argv}} for argv in (['auth', 'status'], ['auth', 'status', '--active'], ['auth', 'status', '--hostname', 'github.com'])]
    return {'executable': executable, 'from': {'session': {'sandbox': sandbox, 'invocation_policy': {
        'default': 'deny', 'deny': [{'argv': {kind: argv}, 'reason': 'not available under the boundary'} for kind, argv in refused], 'allow': allow}}}}
