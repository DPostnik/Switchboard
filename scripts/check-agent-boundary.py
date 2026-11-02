#!/usr/bin/env python3
"""Check the independent contract and the extracted Codex command boundary."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
failures = []
for path in sorted((root / 'Sources/AgentContract').glob('*.swift')):
    source = path.read_text()
    for imported in re.findall(r'^\s*(?:@\w+\s+)?import\s+(\w+)', source, re.MULTILINE):
        if imported != 'Foundation':
            failures.append(f'{path.name}: forbidden dependency {imported}')
    if re.search(r'\b(?:JSONValue|CodexConnection|ClaudeJobRunner)\b', source):
        failures.append(f'{path.name}: native transport/payload leaked into contract')
    if re.search(r'"(?:thread|turn|account|item|model|mcpServer)/[^"\n]+"', source):
        failures.append(f'{path.name}: native RPC method leaked into contract')
package = (root / 'Package.swift').read_text()
if '.target(name: "AgentContract"),' not in package:
    failures.append('AgentContract must remain a target with no package dependencies')
# Commands, notifications and approval encoding belong to the adapter.
for folder in ['ContextCore', 'ContextDesk', 'ContextTranscript']:
    for path in sorted((root / 'Sources' / folder).glob('*.swift')):
        source = path.read_text()
        if re.search(r'\bCodexConnection\b|@_spi\s*\(\s*NativeProtocol', source):
            failures.append(f'{path}: native transport bypasses CodexClient')
        if folder in ['ContextDesk', 'ContextTranscript'] and re.search(r'\.request\s*\(', source):
            failures.append(f'{path}: raw RPC dispatch in application/UI')
        if folder in ['ContextDesk', 'ContextTranscript']:
            if re.search(r'\bJSONValue\b|"(?:thread|turn|account|item|model|mcpServer|serverRequest)/[^"\n]+"', source):
                failures.append(f'{path}: native payload/method in application/UI')
        if re.search(r'\bClaudeJobRunner\b', source) and path.name != 'AgentIntegrationFactory.swift':
            failures.append(f'{path}: native Claude runner outside adapter/composition root')
        if folder == 'ContextDesk':
            if re.search(r'\b(?:CodexClient|ArchiveSummaryRunner|BrowserConfiguration)\b|\.providerArguments\s*\(', source):
                failures.append(f'{path}: application bypasses AgentIntegration')
            if path.name != 'AgentIntegrationFactory.swift' and re.search(r'import\s+(?:CodexAdapter|ClaudeAdapter)', source):
                failures.append(f'{path}: adapter import outside the composition root')
        if folder == 'ContextCore':
            if re.search(r'\["(?:tokenUsage|inputTokens|cachedInputTokens|outputTokens|rateLimitsByLimitId|rateLimits|durationMs|turns)"\]', source):
                failures.append(f'{path}: native Codex decoder in shared core')
            if re.search(r'\bCodexDecoding\b', source):
                failures.append(f'{path}: native decoder bypasses adapter')
        if folder != 'ContextDesk' and re.search(r'import\s+(?:CodexAdapter|ClaudeAdapter)', source):
            failures.append(f'{path}: adapter dependency in shared core/transcript')
if '.target(name: "CodexAdapter", dependencies: ["AgentContract", "ContextCore"]),' not in package:
    failures.append('CodexAdapter must depend only on AgentContract and ContextCore')
if (root / 'Sources/ContextCore/CodexConnection.swift').exists():
    failures.append('Native transport must live in CodexAdapter')
if '.target(name: "ClaudeAdapter", dependencies: ["AgentContract", "ContextCore"]),' not in package:
    failures.append('ClaudeAdapter must depend only on AgentContract and ContextCore')
if (root / 'Sources/ContextCore/ClaudeJobRunner.swift').exists():
    failures.append('Native Claude runner must live in ClaudeAdapter')
if (root / 'Sources/ContextCore/ClaudeModels.swift').exists():
    failures.append('The Claude model catalog must live in ClaudeAdapter')

# Stage B (N agents): the application and transcript reach agents through the registry. Concrete connection and agent
# IDs, legacy job engines, Claude catalog types and "Claude or Codex" labels appear only in the composition root and
# presentation table. Comments and string literals are ignored, so paths such as ".claude/..." do not count.
agent_constant = re.compile(
    r'(?<![\w"])(?:AgentConnectionID|AgentID|JobEngine)?\.(?:originalCodex|appClaude|codex|claudeCode|claude)\b'
    r'|\bClaude(?:Model|Effort|Advisor|Runtime)\b')
# Read on the raw line: string literals are what it looks for.
agent_label = re.compile(r'"(?:Claude|Codex|Claude Code)"\s*:\s*"(?:Claude|Codex|Claude Code)"')
agent_allowlist = {'Sources/ContextDesk/AgentIntegrationFactory.swift'}


def code_only(source):
    """Source without comments and string literal contents (approximate, line structure kept)."""
    source = re.sub(r'"""[\s\S]*?"""', lambda m: '""' + '\n' * m.group(0).count('\n'), source)
    lines = []
    for line in source.split('\n'):
        line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
        lines.append(re.sub(r'//.*', '', line))
    return lines


remaining = {}
for folder in ['ContextDesk', 'ContextTranscript']:
    for path in sorted((root / 'Sources' / folder).glob('*.swift')):
        relative = str(path.relative_to(root))
        text = path.read_text()
        for number, (line, raw) in enumerate(zip(code_only(text), text.split('\n')), 1):
            for match in list(agent_constant.finditer(line)) + list(agent_label.finditer(raw)):
                if relative in agent_allowlist:
                    remaining[relative] = remaining.get(relative, 0) + 1
                else:
                    failures.append(f'{relative}:{number}: concrete agent "{match.group(0).strip()}" outside the registry; '
                                    'use AgentIntegrationFactory profiles, traits or descriptor capabilities')
if failures:
    sys.exit('\n'.join(failures))
allowed = ', '.join(f'{Path(name).name} {count}' for name, count in sorted(remaining.items())) or 'none'
print(f'AgentContract and Codex command/event boundaries passed (stages 3–4); concrete agent IDs only in the allowlist ({allowed}).')
