"""Deterministic fixtures using the documented upstream CHS layout."""
from pathlib import Path
from minipc import PC, CS, IF

ROOT = Path(__file__).resolve().parents[1]

def image(kind='core', entries=()):
    disk = bytearray(360 * 1024)
    disk[:512] = (ROOT / 'build' / (kind + '.img')).read_bytes()
    for slot, name, payload in entries:
        assert 0 <= slot < 32 and 1 <= len(name) <= 15 and len(payload) == 512
        pos = 512 + slot * 16
        disk[pos:pos+16] = name + bytes(16-len(name))
        pos = (slot+1) * 2 * 9 * 512
        disk[pos:pos+512] = payload
    return disk

def boot(kind='core', entries=(), alternate_cs=False):
    pc = PC(image(kind, entries))
    if alternate_cs:
        pc.seg[CS], pc.ip = 0x7c0, 0
    assert pc.run() == 'keyboard'
    return pc

def install(pc):
    pc.install_fast((ROOT / 'build' / 'fast.img').read_bytes())
    return pc

def command(pc, text):
    # Services used by tests return to a HLT trampoline. Enter shell explicitly.
    if pc.halted:
        pc.halted = False
        pc.interrupt(0x20)
        assert pc.run() == 'keyboard'
    pc.keys.extend(text + b'\r')
    assert pc.run() == 'keyboard'

PAYLOAD = bytes(range(256)) * 2
