# /// script
# requires-python = ">=3.10"
# dependencies = ["capstone"]
# ///
"""Disassemble one or more address ranges of the ONU's /bin/cli (MIPS32 BE, uClibc PIC).

Resolves gp-relative GOT slots to imported symbol names, and lui/addiu pairs to
strings / known functions, so jalr-via-GOT calls read as real calls.
"""
import struct
import sys

import capstone

PATH = sys.argv[1]
RANGES = [(int(a, 16), int(b, 16)) for a, b in zip(sys.argv[2::2], sys.argv[3::2])]

raw = open(PATH, 'rb').read()
LOADS = [(0x0, 0x400000, 0x198c4), (0x198c4, 0x4298c4, 0x28b0)]


def va2off(v):
    for foff, va, size in LOADS:
        if va <= v < va + size:
            return foff + (v - va)
    return None


def off2va(o):
    for foff, va, size in LOADS:
        if foff <= o < foff + size:
            return va + (o - foff)
    return None


PRINTABLE = set(range(0x20, 0x7F))


def cstr(va):
    o = va2off(va)
    if o is None:
        return None
    end = raw.find(b'\0', o)
    if end < 0 or not 1 <= end - o <= 200:
        return None
    b = raw[o:end]
    return b.decode() if all(c in PRINTABLE for c in b) else None


# --- dynamic symbols, in index order (needed for GOT slot names)
def dynsym_names():
    nchain = struct.unpack_from('>I', raw, va2off(0x4002DC) + 4)[0]
    sf, tf = va2off(0x400A14), va2off(0x401A84)
    out = []
    for i in range(nchain):
        name = struct.unpack_from('>I', raw, sf + i * 16)[0]
        if not name:
            out.append(f'sym{i}')
            continue
        end = raw.index(b'\0', tf + name)
        out.append(raw[tf + name:end].decode('latin1'))
    return out


DYN = dynsym_names()
FUNCS = {}
for i, n in enumerate(DYN):
    pass

# defined function symbol -> address, from the dynamic table
def defined_funcs():
    nchain = len(DYN)
    sf = va2off(0x400A14)
    out = {}
    for i in range(nchain):
        name, value, size, info, other, shndx = struct.unpack_from('>IIIBBH', raw, sf + i * 16)
        if shndx != 0 and (info & 0xF) == 2 and DYN[i] and not DYN[i].startswith('sym'):
            out[value] = DYN[i]
    return out


FUNCS = defined_funcs()

GOT = 0x42BD70
LOCAL_GOTNO = 0x6C
GOTSYM = 0x72
GP = GOT + 0x7FF0


def got_call(off):
    addr = (GP + off) & 0xFFFFFFFF
    if not (GOT <= addr < GP):
        return None
    idx = (addr - GOT) // 4
    if idx < LOCAL_GOTNO:
        return None
    si = GOTSYM + idx - LOCAL_GOTNO
    return DYN[si] if si < len(DYN) else None


def got_local(off):
    addr = (GP + off) & 0xFFFFFFFF
    if not (GOT <= addr < GP):
        return None
    idx = (addr - GOT) // 4
    if idx >= LOCAL_GOTNO:
        return None
    o = va2off(addr)
    val = struct.unpack_from('>I', raw, o)[0] if o is not None else 0
    return val, idx


def annot(addr):
    s = cstr(addr)
    if s:
        return f'; "{s}"'
    n = FUNCS.get(addr)
    if n:
        return f'; <{n}>'
    o = va2off(addr)
    if o is None:
        return ''
    cand = [(va, n) for va, n in FUNCS.items() if va <= addr < va + 0x800]
    if cand:
        va, n = max(cand)
        return f'; <{n}+{addr - va:#x}>'
    return ''


md = capstone.Cs(capstone.CS_ARCH_MIPS, capstone.CS_MODE_MIPS32 + capstone.CS_MODE_BIG_ENDIAN)
md.detail = False
md.skipdata = True

for start, end in RANGES:
    print(f'===== {start:#x} .. {end:#x}')
    hi = {}
    code = b''.join(raw[va2off(a):va2off(a) + 4] for a in range(start, end, 4))
    pc = start
    for insn in md.disasm(code, start):
        note = ''
        mn, ops = insn.mnemonic, insn.op_str
        parts = [p.strip().lstrip('$') for p in ops.split(',')]
        rt = parts[0].rstrip('$ ') if parts else ''
        # lui tracking, keyed by register name
        if mn == 'lui' and len(parts) == 2:
            hi[parts[0]] = int(parts[1], 16)
        elif mn in ('addiu', 'ori') and len(parts) == 3 and parts[1] in hi:
            base = hi[parts[1]] << 16
            imm = int(parts[2], 0)
            note = annot((base + imm) & 0xFFFFFFFF)
        elif mn in ('lw', 'lb', 'lbu', 'lh', 'sw', 'sb', 'sh') and len(parts) == 2:
            off_str, reg = parts[1].replace(')', '').split('(')
            if reg.strip().lstrip('$') == 'gp' and mn == 'lw' and off_str.strip():
                name = got_call(int(off_str, 0))
                if name:
                    note = f'; {name}'
                else:
                    loc = got_local(int(off_str, 0))
                    if loc:
                        note = f'; GOT[{loc[1]}] = {loc[0]:#x} {annot(loc[0])}'
            elif reg.strip().lstrip('$') in hi and off_str.strip():
                base = hi[reg.strip().lstrip('$')] << 16
                note = annot((base + int(off_str, 0)) & 0xFFFFFFFF)
        elif mn in ('jal', 'j') and len(parts) == 1:
            try:
                note = annot(int(parts[0], 16))
            except ValueError:
                pass
        print(f'{insn.address:#010x}  {insn.bytes.hex():8s}  {mn:8s} {ops:38s}{note}')
        pc = insn.address
