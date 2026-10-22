#!/usr/bin/env python3
"""Fetch verified upstream sources and build a static Linux workload executable."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
BOARD = HERE.parent
ZLIB_FILES = ('adler32 compress crc32 deflate infback inffast inflate inftrees trees uncompr zutil').split()
SQLITE_FLAGS = ['-DSQLITE_THREADSAFE=0', '-DSQLITE_OMIT_LOAD_EXTENSION',
                '-DSQLITE_DEFAULT_MEMSTATUS=0', '-DSQLITE_TEMP_STORE=3',
                '-DSQLITE_DEFAULT_CACHE_SIZE=-256', '-DSQLITE_DQS=0',
                '-DSQLITE_OMIT_DEPRECATED', '-DSQLITE_LIKE_DOESNT_MATCH_BLOBS']


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def obtain(source, cache):
    archive = cache / source['archive']
    if not archive.exists():
        fd, temporary_name = tempfile.mkstemp(prefix=archive.name + '.', suffix='.partial', dir=cache)
        os.close(fd)
        temporary = Path(temporary_name)
        print(f"Downloading {source['url']}", flush=True)
        try:
            with urllib.request.urlopen(source['url'], timeout=120) as response, temporary.open('wb') as output:
                shutil.copyfileobj(response, output)
            if sha256(temporary) != source['sha256']:
                raise RuntimeError(f"Source checksum mismatch: {source['archive']}")
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    if sha256(archive) != source['sha256']:
        raise RuntimeError(f"Source checksum mismatch: {archive}; remove the damaged cache file")
    if 'sha3_256' in source and hashlib.sha3_256(archive.read_bytes()).hexdigest() != source['sha3_256']:
        raise RuntimeError(f"Source SHA3 mismatch: {archive}")
    return archive


def unpack(archive, root, expected):
    # Only extract regular files/directories inside the recorded source root.
    # No symlinks, devices, absolute paths or parent traversal are accepted.
    if archive.suffix == '.zip':
        with zipfile.ZipFile(archive) as package:
            members = package.infolist()
            for member in members:
                parts = Path(member.filename).parts
                if not parts or parts[0] != expected or '..' in parts or Path(member.filename).is_absolute():
                    raise RuntimeError('Unsafe archive member')
                if (member.external_attr >> 16) & 0o170000 == 0o120000:
                    raise RuntimeError('Archive links are not accepted')
            package.extractall(root)
    else:
        with tarfile.open(archive) as package:
            members = package.getmembers()
            for member in members:
                parts = Path(member.name).parts
                if (not parts or parts[0] != expected or '..' in parts or Path(member.name).is_absolute()
                        or not (member.isfile() or member.isdir())):
                    raise RuntimeError('Unsafe archive member')
            package.extractall(root, members=members, filter='data')
    return root / expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native', action='store_true', help='host correctness build, never an FPGA measurement')
    parser.add_argument('--cc', help='compiler executable; defaults to the existing RV32 wrapper or cc with --native')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--cache', type=Path, default=BOARD / 'build/workload-sources')
    args = parser.parse_args()
    output = (args.output or BOARD / ('build/workloads-native' if args.native else 'build/workloads')).resolve()
    cache = args.cache.resolve()
    compiler = args.cc or ('cc' if args.native else os.environ.get('WORKLOAD_CC', str(BOARD / 'build/llvm-toolchain/riscv32-linux-gnu-gcc')))
    sources = json.loads((HERE / 'sources.json').read_text())
    cache.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    flags = ['-O2', '-std=c11', '-fno-pie', '-fno-pic', '-ffunction-sections', '-fdata-sections', '-D_FILE_OFFSET_BITS=64']
    if not args.native:
        flags += ['-march=rv32ima_zicsr_zifencei', '-mabi=ilp32', '-msmall-data-limit=0']
    link_flags = ['-static', '-no-pie', '-Wl,--gc-sections', '-Wl,--build-id=none', '-s']
    version = subprocess.check_output([compiler, '--version'], text=True)
    configuration = {'schema': 1, 'target': 'native-correctness' if args.native else 'riscv32-linux-ilp32',
                     'sources': sources, 'harness_sha256': sha256(HERE / 'workloads.c'),
                     'compiler': compiler, 'compiler_version': version,
                     'compiler_flags': flags, 'sqlite_flags': SQLITE_FLAGS, 'linker_flags': link_flags}
    build_id = hashlib.sha256(json.dumps(configuration, sort_keys=True).encode()).hexdigest()[:16]
    configuration['build_id'] = build_id
    archives = {name: obtain(source, cache) for name, source in sources.items()}
    with tempfile.TemporaryDirectory(prefix='workloads-', dir=output) as temporary:
        root = Path(temporary)
        extracted = {name: unpack(archives[name], root, source['directory']) for name, source in sources.items()}
        includes = ['-I' + str(extracted['zlib']), '-I' + str(extracted['sqlite'])]
        objects = []
        inputs = [(extracted['zlib'] / (name + '.c'), []) for name in ZLIB_FILES]
        inputs += [(extracted['sqlite'] / 'sqlite3.c', SQLITE_FLAGS),
                   (HERE / 'workloads.c', ['-Wall', '-Wextra', '-Werror', f'-DS32_BUILD_ID="{build_id}"'])]
        for source, extra in inputs:
            obj = root / (source.stem + '.o')
            command = [compiler, *flags, *includes, *extra, '-c', str(source), '-o', str(obj)]
            print(f'Compiling {source.name}', flush=True)
            subprocess.run(command, check=True)
            objects.append(str(obj))
        binary = output / 'workloads'
        subprocess.run([compiler, *flags, *objects, *link_flags, '-lm', '-o', str(binary)], check=True)
        shutil.copyfile(extracted['zlib'] / 'LICENSE', output / 'zlib-LICENSE.txt')
        sqlite_header = (extracted['sqlite'] / 'sqlite3.h').read_text()
        # Preserve the complete upstream public-domain dedication/header.
        (output / 'sqlite-PUBLIC-DOMAIN.txt').write_text(sqlite_header[:sqlite_header.index('*/') + 2] + '\n')
    configuration['binary_sha256'] = sha256(binary)
    configuration['binary_bytes'] = binary.stat().st_size
    (output / 'manifest.json').write_text(json.dumps(configuration, indent=2) + '\n')
    if not args.native:
        (output / 'initramfs.list').write_text(
            f'file /bin/workloads {binary} 0755 0 0\n'
            f'file /etc/workloads.json {output}/manifest.json 0644 0 0\n'
            f'file /etc/workloads-zlib-LICENSE.txt {output}/zlib-LICENSE.txt 0644 0 0\n'
            f'file /etc/workloads-sqlite-PUBLIC-DOMAIN.txt {output}/sqlite-PUBLIC-DOMAIN.txt 0644 0 0\n')
    print(json.dumps({key: configuration[key] for key in ('build_id', 'target', 'binary_bytes', 'binary_sha256')}), flush=True)


if __name__ == '__main__':
    main()
