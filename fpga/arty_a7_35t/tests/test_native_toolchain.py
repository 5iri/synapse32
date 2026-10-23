#!/usr/bin/env python3
"""Run a native RV32IMA Linux C toolchain under user QEMU without binfmt.

The compiler driver and its helpers remain target executables. Temporary host
shell wrappers selected by GCC -B add QEMU to helper execve calls. The wrappers
are a host-test adapter and are never installed in the FPGA package.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time

CPU = 'rv32,c=false,f=false,d=false,zfa=false'
MARCH = 'rv32ima_zicsr_zifencei'
ALLOWED_EXTENSIONS = {'i', 'm', 'a', 'zicsr', 'zifencei', 'zmmul', 'zaamo', 'zalrsc'}


def executable(path):
    path = Path(path).resolve()
    if not path.is_file() or not os.access(path, os.X_OK):
        raise RuntimeError(f'Not an executable: {path}')
    return path


def discover(prefix, name, explicit=None):
    if explicit:
        return executable(explicit)
    if name == 'gcc':
        choices = [prefix / 'bin/gcc', prefix / 'bin/riscv32-linux-musl-gcc']
    else:
        choices = [prefix / 'bin' / name, prefix / 'riscv32-linux-musl/bin' / name]
        choices += sorted(prefix.glob(f'libexec/gcc/*/*/{name}'))
        choices += sorted(prefix.glob(f'lib/gcc/*/*/{name}'))
    for path in choices:
        if path.is_file() and os.access(path, os.X_OK):
            return path.resolve()
    raise RuntimeError(f'Cannot find native {name} under {prefix}; specify --{name}')


def elf_isa(path, readelf):
    data = path.read_bytes()
    if data[:6] != b'\x7fELF\x01\x01':
        raise RuntimeError(f'{path}: expected little-endian ELF32')
    machine = struct.unpack_from('<H', data, 18)[0]
    flags = struct.unpack_from('<I', data, 36)[0]
    if machine != 243 or flags & 15:
        raise RuntimeError(f'{path}: expected full-register RISC-V, no RVC, soft-float ABI; machine={machine}, flags=0x{flags:x}')
    checked = subprocess.run([readelf, '-A', str(path)], check=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, timeout=10)
    architectures = re.findall(r'Tag_RISCV_arch:\s*"?([^"\s]+)', checked.stdout)
    for architecture in architectures:
        if not architecture.startswith('rv32'):
            raise RuntimeError(f'{path}: unsupported architecture {architecture}')
        extensions = [re.sub(r'[0-9].*', '', token)
                      for token in architecture[4:].split('_')]
        if not set(extensions) <= ALLOWED_EXTENSIONS or 'i' not in extensions:
            raise RuntimeError(f'{path}: unsupported extensions in {architecture}')
    return {'path': str(path), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
            'elf_flags': flags, 'architecture_attributes': architectures,
            'attribute_note': 'No architecture attribute section' if not architectures else ''}


class Runner:
    def __init__(self, directory, timeout):
        self.directory, self.timeout = directory, timeout
        self.records = []

    def run(self, argv, env):
        start = time.monotonic()

        def disable_core():
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

        process = subprocess.Popen(argv, cwd=self.directory, env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True, preexec_fn=disable_core)
        output = b''
        try:
            output, _ = process.communicate(timeout=self.timeout)
        except BaseException:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    output, _ = process.communicate(timeout=1)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    output, _ = process.communicate(timeout=1)
            raise
        finally:
            self.records.append({'argv': list(map(str, argv)), 'exit_code': process.poll(),
                                 'seconds': time.monotonic() - start,
                                 'output': output.decode(errors='replace')})
        if process.returncode:
            raise RuntimeError(f'Command failed ({process.returncode}): {shlex.join(map(str, argv))}\n{output.decode(errors="replace")}')
        return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qemu', required=True, type=Path)
    parser.add_argument('--prefix', required=True, type=Path,
                        help='Installed toolchain prefix containing bin/gcc and libexec/gcc')
    parser.add_argument('--sysroot', type=Path, help='Target libc root (default: auto-detect below prefix)')
    for name in ('gcc', 'cc1', 'as', 'ld', 'collect2'):
        parser.add_argument('--' + name, type=Path)
    parser.add_argument('--readelf', default=shutil.which('readelf') or shutil.which('llvm-readelf'))
    parser.add_argument('--timeout', type=float, default=60, help='Deadline per compiler/program command')
    parser.add_argument('--transcript', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if not 0 < args.timeout <= 300:
        parser.error('--timeout must be in (0,300] seconds')
    report = {'passed': False, 'qemu_cpu': CPU, 'march': MARCH, 'abi': 'ilp32',
              'scope': 'Real native compiler/helper executions under host user QEMU; no FPGA memory-capacity or performance claim.',
              'native_tools': {}, 'cases': []}
    runner = None
    try:
        prefix, qemu = args.prefix.resolve(), executable(args.qemu)
        if not args.readelf:
            raise RuntimeError('readelf or llvm-readelf is required for ISA checks')
        tools = {name: discover(prefix, name, getattr(args, name))
                 for name in ('gcc', 'cc1', 'as', 'ld')}
        try:
            tools['collect2'] = discover(prefix, 'collect2', args.collect2)
        except RuntimeError:
            if args.collect2:
                raise
        for name, path in tools.items():
            report['native_tools'][name] = elf_isa(path, args.readelf)
        sysroot_candidates = [prefix, prefix / 'riscv32-linux-musl', prefix / 'sysroot', prefix.parent / 'sysroot']
        sysroot = args.sysroot.resolve() if args.sysroot else next(
            (p for p in sysroot_candidates if (p / 'include/stdio.h').is_file()
             and (p / 'lib/libc.a').is_file()), None)
        if sysroot is None or not (sysroot / 'include/stdio.h').is_file():
            raise RuntimeError('Target musl headers/library root missing; specify --sysroot')
        report['sysroot'] = str(sysroot)
        with tempfile.TemporaryDirectory(prefix='synapse32-native-cc-') as temporary:
            work = Path(temporary)
            adapters = work / 'helpers'
            adapters.mkdir()
            for name, path in tools.items():
                if name == 'gcc':
                    continue
                command = ' '.join(shlex.quote(str(v)) for v in [qemu, '-cpu', CPU, path])
                wrapper = adapters / name
                wrapper.write_text(f'#!/bin/sh\nexec {command} "$@"\n')
                wrapper.chmod(0o755)
            env = {**os.environ, 'LC_ALL': 'C', 'TMPDIR': str(work),
                   'COMPILER_PATH': str(adapters), 'QEMU_CPU': CPU}
            # Prevent unrelated host toolchain variables leaking into target GCC.
            for name in ('GCC_EXEC_PREFIX', 'CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH',
                         'LIBRARY_PATH', 'LD_PRELOAD', 'QEMU_LD_PREFIX'):
                env.pop(name, None)
            runner = Runner(work, args.timeout)
            gcc = [str(qemu), '-cpu', CPU, str(tools['gcc']), '-B' + str(adapters) + '/',
                   '--sysroot=' + str(sysroot), '-march=' + MARCH, '-mabi=ilp32',
                   '-static', '-O2', '-fno-lto', '-fno-use-linker-plugin']
            runner.run([str(qemu), '-cpu', CPU, str(tools['gcc']), '-dumpmachine'], env)
            cases = [
                ('hello', {'hello.c': '#include <stdio.h>\nint main(void){puts("hello from Synapse32 native C");return 0;}\n'},
                 ['hello.c'], b'hello from Synapse32 native C\n'),
                ('two-units', {'helper.c': 'int transform(int x){return 7*x+3;}\n',
                               'main.c': '#include <stdio.h>\nextern int transform(int);int main(void){printf("two=%d\\n",transform(42));return 0;}\n'},
                 ['helper.c', 'main.c'], b'two=297\n'),
                ('arithmetic', {'arithmetic.c': '#include <stdio.h>\n#include <math.h>\nvolatile unsigned long long n=1234567890123ULL,d=97ULL;\nvolatile double a=9.0,b=2.0,x=2.25;\nint main(void){printf("u64=%llu/%llu fp=%.3f sqrt=%.3f\\n",n/d,n%d,a/b,sqrt(x));return 0;}\n'},
                 ['arithmetic.c', '-lm'], f'u64={1234567890123//97}/{1234567890123%97} fp=4.500 sqrt=1.500\n'.encode()),
            ]
            for name, sources, arguments, expected in cases:
                for filename, content in sources.items():
                    (work / filename).write_text(content)
                output = work / name
                runner.run(gcc + arguments + ['-o', str(output)], env)
                attributes = elf_isa(output, args.readelf)
                actual = runner.run([str(qemu), '-cpu', CPU, str(output)], env)
                if actual != expected:
                    raise RuntimeError(f'{name}: output {actual!r}, expected {expected!r}')
                report['cases'].append({'name': name, 'passed': True,
                                        'output': actual.decode(), 'elf': attributes})
                print(f'PASS: native C {name}, exact output; ELF32 RV32IMA/ILP32', flush=True)
            report['passed'] = True
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        report['error'] = str(error)
        print(f'FAIL: {error}', file=sys.stderr)
    finally:
        report['commands'] = runner.records if runner else []
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2) + '\n')
        if args.transcript:
            args.transcript.parent.mkdir(parents=True, exist_ok=True)
            with args.transcript.open('w') as log:
                for record in report['commands']:
                    log.write('$ ' + shlex.join(record['argv']) + '\n')
                    log.write(record['output'])
                    log.write(f'\nexit={record["exit_code"]} elapsed={record["seconds"]:.3f}s\n')
                if report.get('error'):
                    log.write('FAIL: ' + report['error'] + '\n')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
