#!/usr/bin/env python3
"""Stage the pinned vendor-signed helper. No agent setup or global installation."""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / 'NonoRuntime/runtime.lock.json').read_text())

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def verify(binary):
    if digest(binary) != LOCK['binary_sha256']:
        raise ValueError('nono binary checksum mismatch')
    arch = subprocess.check_output(['/usr/bin/lipo', '-archs', str(binary)], text=True).strip()
    if arch != 'arm64':
        raise ValueError('nono architecture mismatch: ' + arch)
    requirement = 'anchor apple generic and identifier "' + LOCK['identifier'] + '" and certificate leaf[subject.OU] = "' + LOCK['team_identifier'] + '"'
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R=' + requirement, str(binary)], check=True)

CACHE = ROOT / '.build/nono-cache' / pathlib.Path(LOCK['url']).name


def download(target):
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_suffix('.part')
    try:
        with urllib.request.urlopen(LOCK['url'], timeout=60) as response, partial.open('wb') as output:
            shutil.copyfileobj(response, output)
    except OSError:
        # Some sandboxes route only curl through their proxy.
        subprocess.run(['/usr/bin/curl', '-fsSL', '--retry', '2', LOCK['url'], '-o', str(partial)], check=True)
    partial.rename(target)


def prepare(destination, archive=None, resources=None):
    """Binary into `destination` (a code folder such as Contents/Helpers); lock and license into `resources`
    (a non-code folder such as Contents/Resources/NonoRuntime; defaults to `destination`)."""
    destination = pathlib.Path(destination)
    resources = pathlib.Path(resources) if resources else destination
    destination.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='nono-package-') as temporary:
        temp = pathlib.Path(temporary)
        source = pathlib.Path(archive) if archive else CACHE
        if archive is None and (not source.exists() or digest(source) != LOCK['archive_sha256']):
            download(source)
        if digest(source) != LOCK['archive_sha256']:
            raise ValueError('nono archive checksum mismatch')
        with tarfile.open(source) as bundle:
            member = bundle.getmember('nono')
            if not member.isfile():
                raise ValueError('nono archive member must be a regular file')
            binary = temp / 'nono'
            with bundle.extractfile(member) as stream, binary.open('wb') as output:
                shutil.copyfileobj(stream, output)
        binary.chmod(0o755)
        verify(binary)
        shutil.copy2(binary, destination / 'nono')
        for name in ['LICENSE', 'runtime.lock.json']:
            shutil.copy2(ROOT / 'NonoRuntime' / name, resources / name)
        verify(destination / 'nono')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination')
    parser.add_argument('--archive', help='Use this archive instead of the .build/nono-cache copy; identical checks still apply')
    parser.add_argument('--resources', help='Folder for the lock and license (keep non-code files out of Contents/Helpers)')
    args = parser.parse_args()
    prepare(args.destination, args.archive, args.resources)
