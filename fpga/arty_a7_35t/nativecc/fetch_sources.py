#!/usr/bin/env python3
"""Fetch pinned compiler sources in resumable, bounded HTTP ranges."""
import argparse
import hashlib
import json
from pathlib import Path
import time
import urllib.error
import urllib.request


def digest(path):
    checksum = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(block)
    return checksum.hexdigest()


def fetch(destination, name, spec):
    final = destination / name
    if final.exists():
        if final.stat().st_size != spec['bytes'] or digest(final) != spec['sha256']:
            raise RuntimeError(f'Cached source differs from its pin: {final}')
        return
    partial = destination / (name + '.part')
    mirrors = [spec['url']] if 'url' in spec else [
        base + spec['path'] for base in (
            'https://ftp.gnu.org/gnu/', 'https://mirrors.kernel.org/gnu/',
            'https://ftpmirror.gnu.org/')]
    errors = 0
    while not partial.exists() or partial.stat().st_size < spec['bytes']:
        start = partial.stat().st_size if partial.exists() else 0
        stop = min(start + 8 * 1024 * 1024, spec['bytes'])
        url = mirrors[errors % len(mirrors)]
        request = urllib.request.Request(url, headers={
            'Range': f'bytes={start}-{stop - 1}', 'User-Agent': 'Synapse32-nativecc/1'})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                content_range = response.headers.get('Content-Range', '')
                if response.status == 206:
                    if not content_range.startswith(f'bytes {start}-'):
                        raise RuntimeError(f'Unexpected Content-Range: {content_range}')
                elif start:
                    raise RuntimeError('Server did not honor the resume offset')
                with partial.open('ab') as output:
                    remaining = stop - start
                    deadline = time.monotonic() + 120
                    while remaining:
                        if time.monotonic() > deadline:
                            raise TimeoutError('Source range exceeded 120 seconds')
                        block = response.read(min(65536, remaining))
                        if not block:
                            raise RuntimeError('Source range ended early')
                        output.write(block)
                        remaining -= len(block)
            print(f'{name}: {stop}/{spec["bytes"]} bytes', flush=True)
        except (OSError, RuntimeError, urllib.error.URLError) as error:
            errors += 1
            if errors >= 12:
                raise RuntimeError(f'{name}: download retries exhausted: {error}') from error
            print(f'{name}: retry {errors}: {error}', flush=True)
    if partial.stat().st_size != spec['bytes'] or digest(partial) != spec['sha256']:
        raise RuntimeError(f'Downloaded source differs from its SHA256 pin: {partial}')
    partial.replace(final)
    print(f'Verified {name}: {spec["sha256"]}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=True)
    pins = json.loads(Path(__file__).with_name('sources.json').read_text())
    for name, spec in pins['sources'].items():
        fetch(args.destination, name, spec)


if __name__ == '__main__':
    main()
