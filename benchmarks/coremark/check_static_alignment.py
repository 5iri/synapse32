#!/usr/bin/env python3
"""Check the linked RV32 CoreMark buffer before stripping its symbol table."""
import argparse
import hashlib
import json
import struct
from pathlib import Path


def check(path):
    data = path.read_bytes()
    if data[:6] != b"\x7fELF\x01\x01":
        raise ValueError("expected a little-endian ELF32 executable")
    header = struct.unpack_from("<16sHHIIIIIHHHHHH", data)
    if header[1] != 2 or header[2] != 243:
        raise ValueError("expected a linked RISC-V ET_EXEC executable")
    sections = [struct.unpack_from("<IIIIIIIIII", data, header[6] + n * header[11])
                for n in range(header[12])]
    for section in sections:
        if section[1] != 2:  # SHT_SYMTAB
            continue
        names = sections[section[6]]
        strings = data[names[4]:names[4] + names[5]]
        for offset in range(section[4], section[4] + section[5], section[9]):
            name, address, size, _, _, _ = struct.unpack_from("<IIIBBH", data, offset)
            if strings[name:].split(b"\0", 1)[0] != b"static_memblk":
                continue
            if not address or address % 4:
                raise ValueError(f"static_memblk at 0x{address:08x} is not 4-byte aligned")
            return {"symbol": "static_memblk", "address": f"0x{address:08x}",
                    "size_bytes": size, "required_alignment_bytes": 4,
                    "elf_sha256": hashlib.sha256(data).hexdigest()}
    raise ValueError("static_memblk symbol missing; check an unstripped MEM_STATIC ELF")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("elf", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        result = check(args.elf)
    except (ValueError, IndexError, struct.error) as error:
        parser.exit(1, f"CoreMark alignment check failed: {error}\n")
    encoded = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(encoded)
    else:
        print(encoded, end="")


if __name__ == "__main__":
    main()
