#!/usr/bin/env python3
"""Build a fixed-size boot ROM image with the installed RISC-V toolchain."""
import pathlib
import subprocess

here = pathlib.Path(__file__).resolve().parent
out = here / "build"
out.mkdir(exist_ok=True)
subprocess.run([
    "riscv64-unknown-elf-gcc", "-march=rv32ima_zicsr_zifencei", "-mabi=ilp32",
    "-nostdlib", "-nostartfiles", "-Wl,-Ttext=0x80000000", "-Wl,--no-relax",
    "-o", str(out / "smoke.elf"), str(here / "smoke.S")
], check=True)
subprocess.run(["riscv64-unknown-elf-objcopy", "-O", "binary",
                str(out / "smoke.elf"), str(out / "smoke.bin")], check=True)
raw = (out / "smoke.bin").read_bytes()
if len(raw) > 1024 or len(raw) % 4:
    raise ValueError("Boot image must fit 256 aligned words")
words = [int.from_bytes(raw[i:i+4], "little") for i in range(0, len(raw), 4)]
words += [0x00000013] * (256-len(words))
(here / "boot.hex").write_text("".join(f"{word:08x}\n" for word in words))
print(f"Boot image: {len(raw)} bytes, padded to 1024 bytes")
