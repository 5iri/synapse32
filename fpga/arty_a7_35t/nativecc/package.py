#!/usr/bin/env python3
"""Create the small native C toolchain tree and Linux initramfs fragment."""
import argparse
from pathlib import Path
import shutil
import subprocess
import json
import hashlib
import os
import sys
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build-dir', type=Path, required=True)
parser.add_argument('--output', type=Path, help='New bundle directory (default: BUILD_DIR/bundle)')
parser.add_argument('--qemu', type=Path, help='RV32 QEMU for dumping the native specs')
args = parser.parse_args()
root = args.build_dir.resolve()
here = Path(__file__).resolve().parent
source = root / 'native-stage/opt/nativecc'
bundle_root = args.output.resolve() if args.output else root / 'bundle'
bundle = bundle_root / 'opt/nativecc'
target = 'riscv32-linux-musl'
version = '12.4.0'
if bundle_root.exists():
    manifest_path = root / 'bundle-manifest.json'
    if args.output or not manifest_path.is_file() or not (root / 'initramfs.list').is_file():
        parser.error(f'Package output already exists: {bundle_root}; choose a fresh output directory')
    previous = json.loads(manifest_path.read_text())
    expected = previous['files']
    actual = {str(path.relative_to(bundle_root)) for path in bundle_root.rglob('*')
              if path.is_file() and not path.is_symlink()}
    if actual != set(expected):
        parser.error('Cached bundle file list changed; choose a fresh NATIVECC_OUT')
    for name, entry in expected.items():
        path = bundle_root / name
        if path.stat().st_size != entry['bytes'] or hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
            parser.error(f'Cached bundle differs: {path}; choose a fresh NATIVECC_OUT')
    for name in ['bin/gcc', 'bin/as', 'bin/ld', f'libexec/gcc/{target}/{version}/cc1',
                 f'libexec/gcc/{target}/{version}/collect2']:
        if (bundle / name).read_bytes() != (source / name).read_bytes():
            parser.error('Rebuilt tools differ from cached bundle; choose a fresh NATIVECC_OUT')
    for name, link in [('bin/cc', 'gcc'), (f'{target}/bin/as', '../../bin/as'),
                       (f'{target}/bin/ld', '../../bin/ld')]:
        path = bundle / name
        if not path.is_symlink() or os.readlink(path) != link:
            parser.error(f'Cached bundle symlink differs: {path}')
    print('Verified existing native C bundle:', previous['regular_file_bytes'], 'bytes')
    sys.exit(0)
(bundle / 'bin').mkdir(parents=True)
for name in ['gcc', 'as', 'ld']:
    shutil.copy2(source / 'bin' / name, bundle / 'bin' / name)
(bundle / 'bin/cc').symlink_to('gcc')
helpers = Path('libexec/gcc') / target / version
(bundle / helpers).mkdir(parents=True)
for name in ['cc1', 'collect2']:
    shutil.copy2(source / helpers / name, bundle / helpers / name)
libs = Path('lib/gcc') / target / version
(bundle / libs).mkdir(parents=True)
for name in ['include', 'include-fixed']:
    shutil.copytree(source / libs / name, bundle / libs / name, symlinks=True)
for pattern in ['libgcc*.a', 'crt*.o']:
    for path in (source / libs).glob(pattern):
        shutil.copy2(path, bundle / libs / path.name)
shutil.copytree(root / 'cross' / target / 'include', bundle / 'include', symlinks=True, ignore=shutil.ignore_patterns('c++'))
for path in (source / 'lib').iterdir():
    if path.is_file() and (path.name in {'libc.a', 'libm.a', 'libpthread.a', 'libcrypt.a', 'libdl.a', 'libresolv.a', 'librt.a', 'libutil.a', 'libxnet.a'} or path.name.endswith('.o')):
        shutil.copy2(path, bundle / 'lib' / path.name)
for name in ['as', 'ld']:
    path = bundle / target / 'bin' / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.symlink_to('../../bin/' + name)
script_source = source / target / 'lib/ldscripts'
script_dest = bundle / target / 'lib/ldscripts'
script_dest.mkdir(parents=True)
for path in script_source.glob('elf32lriscv*'):
    shutil.copy2(path, script_dest / path.name)
strip = root / 'cross/bin' / (target + '-strip')
for path in list((bundle / 'lib').glob('*.a')) + list((bundle / libs).glob('*.a')):
    subprocess.run([str(strip), '--strip-debug', str(path)], check=True)
qemu = args.qemu or root.parent / 'qemu-profile/usr/bin/qemu-riscv32-static'
if not qemu.is_file():
    parser.error('Specify --qemu with an executable qemu-riscv32 (static or dynamic)')
with (bundle / libs / 'specs').open('w') as output:
    subprocess.run([str(qemu), '-cpu', 'rv32,c=false,f=false,d=false,zfa=false', str(source / 'bin/gcc'), '-dumpspecs'], stdout=output, check=True)
licenses = bundle / 'share/licenses/nativecc'
for component in ['gcc-12.4.0', 'binutils-2.44', 'musl-1.2.5', 'gmp-6.3.0', 'mpfr-4.2.2', 'mpc-1.3.1']:
    directory = root / 'musl-cross-make' / component
    for path in directory.iterdir():
        if path.is_file() and (path.name.startswith('COPYING') or path.name.startswith('LICENSE') or path.name == 'COPYRIGHT'):
            destination = licenses / component / path.name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)
for name in ['sources.json', 'build.sh', 'fetch_sources.py', 'package.py']:
    shutil.copy2(here / name, licenses / name)
shutil.copy2(root / 'musl-cross-make/config.mak', licenses / 'cross-config.mak')
records = []
for path in sorted(bundle_root.rglob('*')):
    relative = '/' + str(path.relative_to(bundle_root))
    if path.is_symlink():
        records.append('slink %s %s 0777 0 0' % (relative, os.readlink(path)))
    elif path.is_dir():
        records.append('dir %s 0755 0 0' % relative)
    else:
        mode = '0755' if path.stat().st_mode & 0o111 else '0644'
        records.append('file %s %s %s 0 0' % (relative, path, mode))
for name in ['gcc', 'cc', 'as', 'ld']:
    records.append('slink /bin/%s ../opt/nativecc/bin/%s 0777 0 0' % (name, name))
fragment = root / ('initramfs.list' if not args.output else bundle_root.name + '-initramfs.list')
fragment.write_text('\n'.join(records) + '\n')
files = {str(path.relative_to(bundle_root)): {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'bytes': path.stat().st_size} for path in bundle_root.rglob('*') if path.is_file() and not path.is_symlink()}
report = {'prefix': '/opt/nativecc', 'gcc_version': version, 'target': target, 'architecture': 'rv32ima_zicsr_zifencei', 'abi': 'ilp32', 'default_link': 'static', 'regular_file_bytes': sum(value['bytes'] for value in files.values()), 'files': files}
manifest = root / ('bundle-manifest.json' if not args.output else bundle_root.name + '-manifest.json')
manifest.write_text(json.dumps(report, indent=2) + '\n')
print('Bundle regular bytes:', report['regular_file_bytes'])
