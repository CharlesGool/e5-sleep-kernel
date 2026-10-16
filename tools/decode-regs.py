#!/usr/bin/env python3
"""Name a regmap debugfs dump with the vendor register header.

decode-regs.py <regs.h> <PREFIX> <dump> [dump2]   (PREFIX e.g. REG_PMU_APB_)
With two dumps, prints only registers that differ.
"""
import re, sys

def names(hdr, prefix):
    out = {}
    for m in re.finditer(r'#define\s+(%s\w+)\s+(0x[0-9A-Fa-f]+)' % prefix, open(hdr).read()):
        out.setdefault(int(m.group(2), 16), m.group(1)[len(prefix):])
    return out

def dump(path):
    out = {}
    for line in open(path):
        m = re.match(r'\s*([0-9a-fA-F]+):\s*([0-9a-fA-FX]+)', line)
        if m and 'X' not in m.group(2):
            out[int(m.group(1), 16)] = int(m.group(2), 16)
    return out

n = names(sys.argv[1], sys.argv[2])
a = dump(sys.argv[3])
b = dump(sys.argv[4]) if len(sys.argv) > 4 else None
for off in sorted(n):
    if off not in a:
        continue
    if b is None:
        print('%04x %-48s %08x' % (off, n[off], a[off]))
    elif off in b and a[off] != b[off]:
        print('%04x %-48s %08x %08x  x=%08x' % (off, n[off], a[off], b[off], a[off] ^ b[off]))
