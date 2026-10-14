"""Separate mesh records from asynchronous Linux console messages."""
import json
import re

KERNEL_MESSAGE = re.compile(r"\[\s*\d+\.\d+\]")


def mesh_record(line):
    if not line.startswith("S32MESH "):
        return None
    payload = line[8:]
    try:
        record, end = json.JSONDecoder().raw_decode(payload)
    except json.JSONDecodeError:
        if "^C" in payload or KERNEL_MESSAGE.search(payload):
            return None  # A signal or printk interrupted an incomplete record.
        raise
    suffix = payload[end:].strip()
    if suffix and not suffix.startswith("^C") and not KERNEL_MESSAGE.match(suffix):
        raise ValueError("Unexpected text after mesh record")
    return record
