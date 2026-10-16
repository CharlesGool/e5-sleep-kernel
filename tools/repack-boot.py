#!/usr/bin/env python3
"""Repack an e5-linux boot image (the flash package's files/boot.img) with another kernel.

    repack-boot.py BASE.img Image.lk MODULES_DIR OUT.img

Only the kernel and the ramdisk's linux-modules/*.ko change: every module of the
base is replaced by the file of the same name in MODULES_DIR (all must exist);
init, busybox, the f2fs repair tools and etc/ stay byte for byte. The layout is
boot/build-boot-image.py's: header page, kernel, lz4-legacy newc ramdisk, the
base's vbmeta blob, zeros, its AVB footer with the new original size (AVB is not
enforced on this unlocked device). A JSON manifest is written next to OUT.
"""
import hashlib
import json
import struct
import sys
from pathlib import Path

import lz4.block

PAGE = 4096
PERSIST_LOG_OFFSET = 56 << 20
LEGACY_MAGIC = bytes.fromhex('02214c18')
BLOCK = 8 << 20


def lz4_legacy_decompress(b):
    assert b[:4] == LEGACY_MAGIC, 'not a legacy lz4 frame'
    out, i = bytearray(), 4
    while i + 4 <= len(b):
        n = struct.unpack_from('<I', b, i)[0]
        i += 4
        if n == 0x184C2102:
            continue
        if n == 0 or i + n > len(b):
            break
        out += lz4.block.decompress(b[i:i + n], uncompressed_size=BLOCK)
        i += n
    return bytes(out)


def lz4_legacy_compress(b):
    out = bytearray(LEGACY_MAGIC)
    for j in range(0, len(b), BLOCK):
        c = lz4.block.compress(b[j:j + BLOCK], mode='high_compression', compression=12, store_size=False)
        out += struct.pack('<I', len(c)) + c
    return bytes(out)


def cpio_parse(b):
    ents, i = [], 0
    while True:
        assert b[i:i + 6] == b'070701', 'not newc at %d' % i
        f = [int(b[i + 6 + 8 * k:i + 14 + 8 * k], 16) for k in range(13)]
        fsize, nsize = f[6], f[11]
        name = b[i + 110:i + 110 + nsize - 1].decode()
        j = (i + 110 + nsize + 3) & ~3
        data = b[j:j + fsize]
        i = (j + fsize + 3) & ~3
        if name == 'TRAILER!!!':
            return ents
        ents.append([name, f, data])


def cpio_build(ents):
    out = bytearray()

    def rec(name, f, data, ino):
        nb = name.encode() + b'\0'
        v = [ino, f[1], f[2], f[3], f[4], f[5], len(data), f[7], f[8], f[9], f[10], len(nb), 0]
        r = b'070701' + b''.join(b'%08X' % x for x in v) + nb
        r += b'\0' * (-len(r) % 4) + data
        return r + b'\0' * (-len(r) % 4)

    for ino, (name, f, data) in enumerate(ents, 1):
        out += rec(name, f, data, ino)
    out += rec('TRAILER!!!', [0] * 13, b'', 0)
    return bytes(out)


def main():
    base_p, kern_p, mods_p, out_p = map(Path, sys.argv[1:5])
    base = base_p.read_bytes()
    assert base[:8] == b'ANDROID!' and struct.unpack_from('<I', base, 40)[0] == 4, 'not a v4 boot image'
    ks, rs = struct.unpack_from('<II', base, 8)
    roff = PAGE + (ks + PAGE - 1) // PAGE * PAGE
    ents = cpio_parse(lz4_legacy_decompress(base[roff:roff + rs]))

    n = 0
    for e in ents:
        if e[0].startswith('linux-modules/') and e[0].endswith('.ko'):
            new = mods_p / Path(e[0]).name
            if not new.is_file():
                sys.exit('no %s in %s' % (new.name, mods_p))
            e[2] = new.read_bytes()
            n += 1
    cpio = cpio_build(ents)
    assert [x[0] for x in cpio_parse(cpio)] == [x[0] for x in ents], 'cpio round trip'
    ram = lz4_legacy_compress(cpio)
    assert lz4_legacy_decompress(ram) == cpio, 'lz4 round trip'

    kern = kern_p.read_bytes()
    hdr = bytearray(base[:PAGE])
    struct.pack_into('<I', hdr, 8, len(kern))
    struct.pack_into('<I', hdr, 12, len(ram))
    body = bytes(hdr) + kern + b'\0' * (-len(kern) % PAGE) + ram
    body += b'\0' * (-len(body) % PAGE)
    original_size = len(body)
    avb_off, avb_size = struct.unpack_from('>QQ', base, len(base) - 44)
    body += base[avb_off:avb_off + avb_size]
    if len(body) > PERSIST_LOG_OFFSET:
        sys.exit('image data (%d bytes) overlaps the persistent log area' % len(body))
    body += b'\0' * (len(base) - 64 - len(body))
    footer = bytearray(base[-64:])
    struct.pack_into('>QQQ', footer, 12, original_size, original_size, avb_size)
    image = body + bytes(footer)
    assert len(image) == len(base)
    out_p.write_bytes(image)
    man = {
        'image': out_p.name, 'base': base_p.name,
        'sha256': hashlib.sha256(image).hexdigest(),
        'sha256_head56m': hashlib.sha256(image[:PERSIST_LOG_OFFSET]).hexdigest(),
        'kernel_sha256': hashlib.sha256(kern).hexdigest(),
        'kernel_size': len(kern), 'ramdisk_size': len(ram), 'modules_replaced': n,
        'persist_log_offset': PERSIST_LOG_OFFSET,
    }
    out_p.with_suffix('.json').write_text(json.dumps(man, indent=2) + '\n')
    print(json.dumps(man, indent=2))


if __name__ == '__main__':
    main()
