#!/usr/bin/env python3
"""Finish the boot-openwrt-only companion package for the e5-sleep1 kernel.

    make-bootopenwrt-pkg.py PKG_DIR ORIG_FLASHER_DIR NEW_BOOT_JSON

PKG_DIR already holds the copied files and files/boot.img (the new image). This
writes files/boot.json (the original with the new image's hashes and sizes),
marks files/VERSION, makes flash.py refuse everything but --boot-openwrt, and
writes SHA256SUMS over the package's files.
"""
import hashlib
import json
import os
import sys

pkg, orig, newj = sys.argv[1:4]
bj = json.load(open(os.path.join(orig, 'files', 'boot.json')))
new = json.load(open(newj))
img = open(os.path.join(pkg, 'files', 'boot.img'), 'rb').read()
bj.update({'image': 'boot-e5-sleep1.img', 'sha256': hashlib.sha256(img).hexdigest(),
           'sha256_head56m': new['sha256_head56m'], 'kernel_sha256': new['kernel_sha256'],
           'kernel_size': new['kernel_size'], 'ramdisk_size': new['ramdisk_size']})
assert bj['sha256_head56m'] == hashlib.sha256(img[:56 << 20]).hexdigest()
open(os.path.join(pkg, 'files', 'boot.json'), 'w', newline='\n').write(json.dumps(bj, indent=2) + '\n')

vp = os.path.join(pkg, 'files', 'VERSION')
v = open(vp, encoding='utf-8').read().strip()
if 'boot-openwrt only' not in v:
    v = v.replace('kernel 6.18.54-e5-mobile4', 'kernel 6.18.54-e5-sleep1') + ' [boot-openwrt only]'
open(vp, 'w', encoding='utf-8', newline='\n').write(v + '\n')

fp = os.path.join(pkg, 'flash.py')
s = open(fp, encoding='utf-8').read()
old = '    check_package()\n    if a.update:'
guard = ('    check_package()\n'
         "    # e5-sleep1: only the deep-sleep kernel's boot image is here (its modules are in the device's\n"
         '    # root already) and no root image, so this package can only bring an installed system back\n'
         '    if not a.boot_openwrt:\n'
         "        die('this package is only for --boot-openwrt (the e5-sleep1 kernel); "
         "use the full package to install or update')\n"
         '    if a.update:')
if 'e5-sleep1:' not in s:
    assert old in s
    s = s.replace(old, guard, 1)
    open(fp, 'w', encoding='utf-8', newline='\n').write(s)

names = []
for root, _, files in os.walk(pkg):
    for f in files:
        rel = '/'.join(os.path.relpath(os.path.join(root, f), pkg).split(os.sep))
        if rel != 'SHA256SUMS':
            names.append(rel)
with open(os.path.join(pkg, 'SHA256SUMS'), 'w', newline='\n') as o:
    for rel in sorted(names):
        o.write(hashlib.sha256(open(os.path.join(pkg, *rel.split('/')), 'rb').read()).hexdigest() + '  ' + rel + '\n')
print(open(os.path.join(pkg, 'SHA256SUMS')).read())
print(json.dumps({k: bj[k] for k in ('sha256_head56m', 'kernel_size', 'ramdisk_size')}, indent=1))
