#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 set-dns 用的 512 字形 Linux 控制台字体（PSF2 / 16x16 中文）。

背景：为什么是这个形状
----------------------
* 内核 vt 控制台不接受超过 512 个字形。目标机实测（7.2.9-x64v3-xanmod1）：
    256 -> rc=0     512 -> rc=0     768 -> rc=71 (ioctl KDFONTOP EINVAL)
  所以 512 是硬上限，完整中文字体（两万多字形）永远塞不进去。
* 索引 32 必须是空白。早期版本把 ASCII 从索引 0 开始紧凑排，'@' 落到了
  索引 32；内核报 "font position 32 is nonblank" 并把整个控制台画错位。
  所以：0..31 空白，32..126 放 ASCII 且索引 == 码点。
* PSF2 的 Unicode 表必须给**每个**索引一项。早期版本只给占用的槽写表，
  内核回 "get_uni_entry: short unicode table"，setfont 退出 65(EX_DATAERR)。
  所以：每个索引都写「码点 UTF-8 + 0xFF」，空槽只写一个 0xFF。

512 个槽的分配优先级：
    1. ASCII 0x20..0x7E（95 个，固定在自身码点）
    2. 菜单屏上真正会打印出来的每一个非 ASCII 字符
    3. 剩下按出现频率从高到低补汉字，直到表满
"""
import argparse
import json
import re
import struct
import sys
from collections import Counter

CSZ, W, H = 32, 16, 16          # 16x16 像素 = 32 字节/字形
MAX_GLYPH = 512                 # 内核硬上限
BLANK = bytes(CSZ)
PSF2_MAGIC = b'\x72\xb5\x4a\x86'

MENU_LINE = re.compile(r'^\s*\d+\)\s')
MENU_PROMPT = re.compile(r'输入 1/|请选择 DNS 模式|（0 = 退出）|q = 取消|按回车键返回菜单')
PICK_MODE = re.compile(r'^pick_mode\(\)\s*\{.*?^\}', re.S | re.M)


def load_unifont(path):
    """unifont.hex: 每行 'HEXCODEPOINT:HEXBITMAP'。"""
    g = {}
    with open(path, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            line = line.strip()
            if not line or ':' not in line:
                continue
            cp, bm = line.split(':', 1)
            try:
                g[int(cp, 16)] = bm
            except ValueError:
                continue
    return g


def to_cell(bm):
    """返回正好 CSZ 字节的字形位图；宽度不可用时返回 None。"""
    try:
        b = bytes.fromhex(bm)
    except ValueError:
        return None
    if len(b) == CSZ:                   # 已经是 16x16
        return b
    if len(b) == 16:                    # 8x16 -> 放到 16x16 的左半边
        return b''.join(bytes((b[i], 0)) for i in range(16))
    if len(b) == 64:                    # 16x32 -> 隔行取样压到 16 行
        return b''.join(b[i * 2:i * 2 + 2] for i in range(16))
    return None


def menu_chars(text):
    """脚本里"用户盯着看的那几屏"用到的非 ASCII 字符。

    只用三个精确来源，不要用「菜单/内核/系统更新」这类关键词去扫全文 ——
    那样会把脚本里所有提到这些词的注释和错误消息都吞进来（实测 562 个字符，
    512 槽根本装不下，还会把真正要显示的菜单字挤掉）。
    """
    chars = set()
    m = PICK_MODE.search(text)
    if m:
        chars |= {c for c in m.group(0) if ord(c) > 0x7F}
    for line in text.splitlines():
        if MENU_LINE.match(line) or MENU_PROMPT.search(line):
            chars |= {c for c in line if ord(c) > 0x7F}
    return chars


def build(text, unifont, limit=MAX_GLYPH):
    slots, cells, used = {}, {}, set()
    cursor = 128

    def alloc():
        nonlocal cursor
        while cursor < limit:
            i = cursor
            cursor += 1
            if i not in slots:
                return i
        return None

    def place(cp, idx=None):
        if cp in used or cp > 0xFFFF:
            return False
        bm = unifont.get(cp)
        if bm is None:
            return False
        cell = to_cell(bm)
        if cell is None:
            return False
        if idx is None:
            idx = alloc()
            if idx is None:
                return False
        elif idx >= limit or idx in slots:
            return False
        slots[idx] = cp
        cells[idx] = cell
        used.add(cp)
        return True

    missing_ascii = [cp for cp in range(0x20, 0x7F) if not place(cp, cp)]

    menu = menu_chars(text)
    menu_special = sorted(c for c in menu if not 0x4E00 <= ord(c) <= 0x9FFF)
    menu_cjk = sorted(c for c in menu if 0x4E00 <= ord(c) <= 0x9FFF)
    missing_menu = [c for c in menu_special + menu_cjk if not place(ord(c))]

    freq = Counter(c for c in text if 0x4E00 <= ord(c) <= 0x9FFF)
    filled = 0
    for c, _ in freq.most_common():
        if cursor >= limit:
            break
        if place(ord(c)):
            filled += 1

    # 覆盖率：控制台上真正能显示出来的汉字出现次数占比
    total_occ = sum(freq.values())
    shown = sum(n for c, n in freq.items() if ord(c) in used)
    covered = shown / total_occ if total_occ else 1.0

    body, table = bytearray(), bytearray()
    for i in range(limit):
        if i in slots:
            body += cells[i]
            table += chr(slots[i]).encode('utf-8') + b'\xff'
        else:
            body += BLANK
            table += b'\xff'

    header = struct.pack('<4sIIIIIII', PSF2_MAGIC, 0, 32, 1, limit, CSZ, H, W)
    report = {
        'glyphs': limit,
        'used': len(slots),
        'ascii': sum(1 for i in slots if i < 128),
        'menu_total': len(menu),
        'menu_placed': len(menu) - len(missing_menu),
        'freq_filled': filled,
        'coverage': round(covered, 4),
        'cjk_total': len(freq),
        'cjk_shown': sum(1 for c in freq if ord(c) in used),
        'index32_blank': slots.get(32) in (None, 0x20),
        'bytes': 32 + limit * CSZ + len(table),
        'missing_ascii': ['U+%04X' % cp for cp in missing_ascii],
        'missing_menu': ['U+%04X %s' % (ord(c), c) for c in missing_menu],
    }
    return header + bytes(body) + bytes(table), report


def check(psf_path, text):
    d = open(psf_path, 'rb').read()
    magic, ver, hdr, flags, ng, csz, h, w = struct.unpack('<4sIIIIIII', d[:32])
    if magic != PSF2_MAGIC:
        raise SystemExit('%s: 不是 PSF2 字体' % psf_path)
    table = d[32 + ng * csz:]
    have = set()
    for entry in table.split(b'\xff'):
        have |= set(entry.decode('utf-8', 'ignore'))
    menu = menu_chars(text)
    return ng, sorted(c for c in menu if c not in have)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src', help='set-dns.sh')
    ap.add_argument('out', nargs='?', help='输出 .psf（--check 时是要检查的字体）')
    ap.add_argument('--unifont', default='/usr/share/unifont/unifont.hex')
    ap.add_argument('--limit', type=int, default=MAX_GLYPH)
    ap.add_argument('--check', action='store_true',
                    help='只检查 out 是否覆盖了 src 的菜单字符')
    ap.add_argument('--json', help='把报告写到这个文件')
    a = ap.parse_args()

    text = open(a.src, encoding='utf-8', errors='replace').read()

    if a.check:
        if not a.out:
            raise SystemExit('--check 需要给出要检查的字体')
        ng, miss = check(a.out, text)
        print('  %s: %d 字形，菜单缺字 %d 个' % (a.out, ng, len(miss)))
        for c in miss[:30]:
            print('    缺: U+%04X %s' % (ord(c), c))
        return 1 if miss else 0

    unifont = load_unifont(a.unifont)
    if not unifont:
        raise SystemExit('unifont 表 %s 不存在或为空' % a.unifont)

    blob, rep = build(text, unifont, a.limit)
    if a.out:
        with open(a.out, 'wb') as fh:
            fh.write(blob)
    if a.json:
        with open(a.json, 'w', encoding='utf-8') as fh:
            json.dump(rep, fh, ensure_ascii=False, indent=2)

    print('  unifont 字形 %d' % len(unifont))
    print('  槽位 %d，已用 %d（ASCII %d + 其它 %d）'
          % (rep['glyphs'], rep['used'], rep['ascii'], rep['used'] - rep['ascii']))
    print('  菜单字符 %d，已覆盖 %d，缺 %d'
          % (rep['menu_total'], rep['menu_placed'], len(rep['missing_menu'])))
    print('  汉字覆盖 %d/%d，占出现次数 %.1f%%'
          % (rep['cjk_shown'], rep['cjk_total'], rep['coverage'] * 100))
    print('  频率补字 %d，索引 32 空白 %s，共 %d 字节'
          % (rep['freq_filled'], rep['index32_blank'], rep['bytes']))
    for s in rep['missing_ascii'] + rep['missing_menu']:
        print('  缺: %s' % s)
    return 0 if not (rep['missing_ascii'] or rep['missing_menu']) else 1


if __name__ == '__main__':
    sys.exit(main())
