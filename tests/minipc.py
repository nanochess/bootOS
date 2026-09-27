"""Small, fail-closed 8086 subset runner for bootOS regression tests.

Executes the assembled machine code, not a Python rewrite of the filesystem.
BIOS disk/video/keyboard/memory services are deterministic test doubles. This
is NOT a cycle-accurate emulator, full PC, or independent hardware validation.
Unsupported opcodes raise rather than silently pass. Counts are guest opcode
and string-iteration counts; neither count is a clock-cycle measurement.
"""
from __future__ import annotations
from collections import Counter, deque
from dataclasses import dataclass, field

CF, PF, AF, ZF, SF, TF, IF, DF, OF = 1, 4, 16, 64, 128, 256, 512, 1024, 2048
AX, CX, DX, BX, SP, BP, SI, DI = range(8)
ES, CS, SS, DS = range(4)

class BudgetExceeded(RuntimeError):
    pass
class WaitingForKey(Exception):
    pass

@dataclass
class PC:
    disk: bytearray
    heads: int = 2
    spt: int = 9
    mem: bytearray = field(default_factory=lambda: bytearray(1 << 20))
    r: list[int] = field(default_factory=lambda: [0]*8)
    seg: list[int] = field(default_factory=lambda: [0]*4)
    ip: int = 0x7c00
    flags: int = IF | 2
    keys: deque = field(default_factory=deque)
    screen: bytearray = field(default_factory=bytearray)
    counts: Counter = field(default_factory=Counter)
    io_log: list = field(default_factory=list)
    writes: list = field(default_factory=list)
    trace_writes: bool = False
    fail_io: bool = False
    halted: bool = False

    def __post_init__(self):
        self.mem[0x7c00:0x7e00] = self.disk[:512]
        self.put(0x413, 640, 16)
        for v in (0x10, 0x12, 0x13, 0x16):
            self.put(v*4, v*16, 16)
            self.put(v*4+2, 0xf000, 16)

    def addr(self, seg: int, off: int) -> int:
        return ((seg << 4) + (off & 0xffff)) & 0xfffff

    def get(self, a: int, w: int) -> int:
        self.counts['data_reads'] += 1
        if w == 8:
            return self.mem[a & 0xfffff]
        return self.mem[a & 0xfffff] | (self.mem[(a+1) & 0xfffff] << 8)

    def put(self, a: int, v: int, w: int) -> None:
        if self.trace_writes:
            self.writes.append((a & 0xfffff, w//8))
        self.mem[a & 0xfffff] = v & 255
        if w == 16:
            self.mem[(a+1) & 0xfffff] = (v >> 8) & 255

    def reg(self, i: int, w: int) -> int:
        return self.r[i] if w == 16 else ((self.r[i & 3] >> (8 if i & 4 else 0)) & 255)

    def setreg(self, i: int, v: int, w: int) -> None:
        if w == 16:
            self.r[i] = v & 65535
        else:
            shift = 8 if i & 4 else 0
            k = i & 3
            self.r[k] = (self.r[k] & ~(255 << shift)) | ((v & 255) << shift)

    def f(self, flag: int, yes: bool) -> None:
        self.flags = (self.flags | flag) if yes else (self.flags & ~flag)

    def szp(self, v: int, w: int) -> None:
        v &= (1 << w)-1
        self.f(ZF, v == 0)
        self.f(SF, bool(v & (1 << (w-1))))
        self.f(PF, (v & 255).bit_count() % 2 == 0)

    def alu(self, op: int, a: int, b: int, w: int) -> int:
        mask, sign = (1 << w)-1, 1 << (w-1)
        carry = int(bool(self.flags & CF)) if op in (2, 3) else 0
        if op in (0, 2):
            raw = a+b+carry
            self.f(CF, raw > mask)
            self.f(OF, bool((~(a^b) & (a^raw)) & sign))
            self.f(AF, bool((a^b^raw) & 16))
        elif op in (3, 5, 7):
            raw = a-b-carry
            self.f(CF, raw < 0)
            self.f(OF, bool(((a^b) & (a^raw)) & sign))
            self.f(AF, bool((a^b^raw) & 16))
        else:
            raw = {1: lambda: a|b, 4: lambda: a&b, 6: lambda: a^b}[op]()
            self.f(CF, False)
            self.f(OF, False)
        self.szp(raw, w)
        return raw & mask

    def byte(self) -> int:
        v = self.mem[self.addr(self.seg[CS], self.ip)]
        self.ip = (self.ip+1) & 65535
        return v

    def word(self) -> int:
        a = self.byte()
        return a | (self.byte() << 8)

    @staticmethod
    def signed(v: int, w: int) -> int:
        return v - (1 << w) if v & (1 << (w-1)) else v

    def push(self, v: int) -> None:
        self.r[SP] = (self.r[SP]-2) & 65535
        self.put(self.addr(self.seg[SS], self.r[SP]), v, 16)

    def pop(self) -> int:
        v = self.get(self.addr(self.seg[SS], self.r[SP]), 16)
        self.r[SP] = (self.r[SP]+2) & 65535
        return v

    def modrm(self, w: int, override: int | None):
        m = self.byte()
        mod, reg, rm = m >> 6, (m >> 3) & 7, m & 7
        if mod == 3:
            return reg, ('r', rm, w, 0)
        if mod == 0 and rm == 6:
            off, default = self.word(), DS
        else:
            pairs = ((BX,SI),(BX,DI),(BP,SI),(BP,DI),(SI,),(DI,),(BP,),(BX,))
            regs = pairs[rm]
            off = sum(self.r[x] for x in regs)
            default = SS if BP in regs else DS
            if mod == 1:
                off += self.signed(self.byte(),8)
            elif mod == 2:
                off += self.signed(self.word(),16)
        off &= 65535
        seg = self.seg[default if override is None else override]
        return reg, ('m', self.addr(seg, off), w, off)

    def readop(self, operand) -> int:
        return self.reg(operand[1],operand[2]) if operand[0]=='r' else self.get(operand[1],operand[2])

    def writeop(self, operand, value: int) -> None:
        if operand[0]=='r':
            self.setreg(operand[1],value,operand[2])
        else:
            self.put(operand[1],value,operand[2])

    def condition(self, n: int) -> bool:
        c,z,s,o,p = [bool(self.flags & f) for f in (CF,ZF,SF,OF,PF)]
        return (o,not o,c,not c,z,not z,c or z,not(c or z),s,not s,p,not p,s!=o,s==o,z or s!=o,not z and s==o)[n]

    def interrupt(self, n: int) -> None:
        self.counts[f'int_{n:02x}'] += 1
        self.push(self.flags)
        self.push(self.seg[CS])
        self.push(self.ip)
        self.flags &= ~(IF|TF)
        self.ip = self.get(n*4,16)
        self.seg[CS] = self.get(n*4+2,16)

    def bios(self, n: int) -> None:
        self.counts[f'bios_{n:02x}'] += 1
        cf = bool(self.flags & CF)
        if n == 0x10:
            if self.reg(4,8) != 0x0e:
                raise NotImplementedError('Only BIOS teletype is implemented')
            self.screen.append(self.reg(0,8))
        elif n == 0x12:
            self.r[AX] = self.get(0x413,16)
        elif n == 0x16:
            if not self.keys:
                raise WaitingForKey
            self.r[AX] = self.keys.popleft()
        elif n == 0x13:
            operation = self.reg(4,8)
            if operation not in (2,3):
                raise NotImplementedError(f'BIOS disk function {operation:02x}')
            ch,cl = self.reg(5,8),self.reg(1,8)
            cylinder = ch | ((cl & 0xc0) << 2)
            sector, head, drive = cl & 63, self.reg(6,8), self.reg(2,8)
            count = self.reg(0,8)
            offset = ((cylinder*self.heads+head)*self.spt+sector-1)*512
            cf = self.fail_io or drive != 0 or head >= self.heads or not 1 <= sector <= self.spt or count != 1 or offset+512 > len(self.disk)
            address = self.addr(self.seg[ES],self.r[BX])
            self.io_log.append({'op':operation,'cylinder':cylinder,'sector':sector,'head':head,'drive':drive,'error':cf})
            if not cf:
                if operation == 2:
                    self.mem[address:address+512] = self.disk[offset:offset+512]
                    self.counts['sector_reads'] += 1
                else:
                    self.disk[offset:offset+512] = self.mem[address:address+512]
                    self.counts['sector_writes'] += 1
            self.setreg(4,1 if cf else 0,8)
        else:
            raise NotImplementedError(f'BIOS interrupt {n:02x}')
        self.ip = self.pop()
        self.seg[CS] = self.pop()
        self.flags = self.pop() | 2
        if n == 0x13:
            self.f(CF, cf)

    def step(self) -> None:
        if self.seg[CS] == 0xf000 and self.ip in (0x100,0x120,0x130,0x160):
            self.bios(self.ip//16)
            return
        pc = self.addr(self.seg[CS],self.ip)
        override, rep = None, None
        op = self.byte()
        while op in (0x26,0x2e,0x36,0x3e,0xf2,0xf3):
            if op in (0xf2,0xf3):
                rep = op
            else:
                override = {0x26:ES,0x2e:CS,0x36:SS,0x3e:DS}[op]
            op = self.byte()
        self.counts['opcodes'] += 1
        if 0xb0 <= op <= 0xbf:
            w = 8 if op < 0xb8 else 16
            self.setreg(op & 7,self.byte() if w==8 else self.word(),w)
        elif 0x50 <= op <= 0x57:
            self.push(self.r[op & 7])
        elif 0x58 <= op <= 0x5f:
            self.r[op & 7] = self.pop()
        elif op in (0x06,0x0e,0x16,0x1e):
            self.push(self.seg[(op >> 3)&3])
        elif op in (0x07,0x17,0x1f):
            self.seg[(op >> 3)&3] = self.pop()
        elif 0x40 <= op <= 0x4f:
            cf = self.flags & CF
            i = op & 7
            self.r[i] = self.alu(0 if op < 0x48 else 5,self.r[i],1,16)
            self.f(CF,bool(cf))
        elif 0x90 <= op <= 0x97:
            i = op & 7
            self.r[AX],self.r[i] = self.r[i],self.r[AX]
        elif op in (0x88,0x89,0x8a,0x8b,0x8c,0x8d,0x8e,0x86,0x87):
            w = 16 if op & 1 or op in (0x8c,0x8e) else 8
            reg, operand = self.modrm(w,override)
            if op == 0x8d:
                self.r[reg] = operand[3]
            elif op == 0x8c:
                self.writeop(operand,self.seg[reg])
            elif op == 0x8e:
                self.seg[reg] = self.readop(operand)
            elif op in (0x86,0x87):
                value = self.readop(operand)
                self.writeop(operand,self.reg(reg,w))
                self.setreg(reg,value,w)
            elif op & 2:
                self.setreg(reg,self.readop(operand),w)
            else:
                self.writeop(operand,self.reg(reg,w))
        elif op in (0xc6,0xc7):
            w = 8 if op == 0xc6 else 16
            reg, operand = self.modrm(w,override)
            if reg:
                raise NotImplementedError('C6/C7 extension')
            self.writeop(operand,self.byte() if w==8 else self.word())
        elif 0xa0 <= op <= 0xa3:
            w = 16 if op & 1 else 8
            a = self.addr(self.seg[DS if override is None else override],self.word())
            if op & 2:
                self.put(a,self.reg(AX,w),w)
            else:
                self.setreg(AX,self.get(a,w),w)
        elif op <= 0x3d and (op & 7) <= 5:
            kind, w = op >> 3,16 if op & 1 else 8
            if (op & 7) in (4,5):
                value = self.alu(kind,self.reg(AX,w),self.byte() if w==8 else self.word(),w)
                if kind != 7:
                    self.setreg(AX,value,w)
            else:
                reg, operand = self.modrm(w,override)
                a,b = (self.reg(reg,w),self.readop(operand)) if op & 2 else (self.readop(operand),self.reg(reg,w))
                value = self.alu(kind,a,b,w)
                if kind != 7:
                    if op & 2:
                        self.setreg(reg,value,w)
                    else:
                        self.writeop(operand,value)
        elif op in (0x80,0x81,0x83):
            w = 8 if op == 0x80 else 16
            kind, operand = self.modrm(w,override)
            imm = self.word() if op == 0x81 else self.byte()
            if op == 0x83:
                imm = self.signed(imm,8) & 65535
            v = self.alu(kind,self.readop(operand),imm,w)
            if kind != 7:
                self.writeop(operand,v)
        elif op in (0x84,0x85,0xa8,0xa9):
            w = 16 if op & 1 else 8
            if op in (0xa8,0xa9):
                a,b = self.reg(AX,w), self.word() if w==16 else self.byte()
            else:
                reg, operand = self.modrm(w,override)
                a,b = self.reg(reg,w),self.readop(operand)
            self.alu(4,a,b,w)
        elif op in (0xd0,0xd1,0xd2,0xd3):
            w = 16 if op & 1 else 8
            kind, operand = self.modrm(w,override)
            count = self.reg(1,8) if op & 2 else 1
            v,mask = self.readop(operand),(1<<w)-1
            for _ in range(count):
                carry = int(bool(self.flags & CF))
                if kind in (0,2,4):
                    out = (v >> (w-1)) & 1
                    low = out if kind==0 else carry if kind==2 else 0
                    v = ((v << 1) | low) & mask
                elif kind in (1,3,5,7):
                    out = v & 1
                    high = out if kind==1 else carry if kind==3 else (v >> (w-1)) if kind==7 else 0
                    v = (v >> 1) | (high << (w-1))
                else:
                    raise NotImplementedError('Shift extension')
                self.f(CF,bool(out))
            if count:
                self.writeop(operand,v)
                if kind >= 4:
                    self.szp(v,w)
                # All code under test ignores OF for multi-bit shifts.
                if count == 1:
                    self.f(OF, bool(((v >> (w-1)) ^ int(bool(self.flags&CF))) & 1) if kind in (0,2,4) else bool(((v >> (w-1)) ^ (v >> (w-2)))&1))
        elif 0x70 <= op <= 0x7f:
            delta = self.signed(self.byte(),8)
            if self.condition(op & 15):
                self.ip = (self.ip+delta) & 65535
        elif op in (0xe0,0xe1,0xe2,0xe3):
            delta = self.signed(self.byte(),8)
            if op == 0xe3:
                take = self.r[CX] == 0
            else:
                self.r[CX] = (self.r[CX]-1) & 65535
                take = self.r[CX] != 0 and (op==0xe2 or bool(self.flags&ZF)==(op==0xe1))
            if take:
                self.ip = (self.ip+delta) & 65535
        elif op in (0xe8,0xe9,0xeb):
            delta = self.signed(self.byte(),8) if op==0xeb else self.signed(self.word(),16)
            if op == 0xe8:
                self.push(self.ip)
            self.ip = (self.ip+delta) & 65535
        elif op == 0xff:
            kind, operand = self.modrm(16,override)
            v = self.readop(operand)
            if kind in (2,4):
                if kind == 2:
                    self.push(self.ip)
                self.ip = v
            elif kind in (3,5):
                if operand[0] != 'm':
                    raise ValueError('Far pointer must be in memory')
                seg = self.get(operand[1]+2,16)
                if kind == 3:
                    self.push(self.seg[CS])
                    self.push(self.ip)
                self.ip,self.seg[CS] = v,seg
            elif kind == 6:
                self.push(v)
            else:
                raise NotImplementedError(f'FF /{kind}')
        elif op == 0xcd:
            self.interrupt(self.byte())
        elif op == 0xcf:
            self.ip = self.pop()
            self.seg[CS] = self.pop()
            self.flags = self.pop() | 2
        elif op == 0xc3:
            self.ip = self.pop()
        elif op in (0x9c,0x9d):
            if op == 0x9c:
                self.push(self.flags)
            else:
                self.flags = self.pop() | 2
        elif op in (0xf8,0xf9,0xfa,0xfb,0xfc,0xfd):
            flag = CF if op < 0xfa else IF if op < 0xfc else DF
            self.f(flag,bool(op & 1))
        elif op == 0xf4:
            self.halted = True
        elif op in (0xa4,0xa5,0xa6,0xa7,0xaa,0xab,0xac,0xad,0xae,0xaf):
            w, step = (16,2) if op & 1 else (8,1)
            if self.flags & DF:
                step = -step
            count = self.r[CX] if rep else 1
            for _ in range(count):
                self.counts['string_iterations'] += 1
                source = self.addr(self.seg[DS if override is None else override],self.r[SI])
                dest = self.addr(self.seg[ES],self.r[DI])
                if op in (0xa4,0xa5):
                    self.put(dest,self.get(source,w),w)
                elif op in (0xa6,0xa7):
                    self.alu(7,self.get(source,w),self.get(dest,w),w)
                elif op in (0xaa,0xab):
                    self.put(dest,self.reg(AX,w),w)
                elif op in (0xac,0xad):
                    self.setreg(AX,self.get(source,w),w)
                else:
                    self.alu(7,self.reg(AX,w),self.get(dest,w),w)
                if op in (0xa4,0xa5,0xa6,0xa7,0xac,0xad):
                    self.r[SI] = (self.r[SI]+step) & 65535
                if op in (0xa4,0xa5,0xa6,0xa7,0xaa,0xab,0xae,0xaf):
                    self.r[DI] = (self.r[DI]+step) & 65535
                if rep:
                    self.r[CX] = (self.r[CX]-1) & 65535
                    if op in (0xa6,0xa7,0xae,0xaf) and bool(self.flags&ZF) != (rep==0xf3):
                        break
        else:
            raise NotImplementedError(f'Opcode {op:02x} at {pc:05x}')

    def run(self, budget: int = 200_000) -> str:
        for _ in range(budget):
            if self.halted:
                return 'halt'
            try:
                self.step()
            except WaitingForKey:
                return 'keyboard'
        raise BudgetExceeded(f'At {self.seg[CS]:04x}:{self.ip:04x}')

    def invoke(self, vector: int, name: bytes, data: bytes | None = None,
               ds: int = 0x100, es: int = 0x200, flags: int = IF | 2,
               budget: int = 200_000) -> tuple[bool, bytes]:
        """Invoke a real installed bootOS interrupt, return CF and 512 data bytes."""
        self.seg[DS],self.seg[ES] = ds,es
        self.seg[SS],self.r[SP] = 0,0x7600
        self.r[BX],self.r[DI] = 0x100,0x300
        naddr,daddr = self.addr(ds,0x100),self.addr(es,0x300)
        self.mem[naddr:naddr+len(name)+1] = name+b'\0'
        if data is not None:
            if len(data) != 512:
                raise ValueError('Payload must contain 512 bytes')
            self.mem[daddr:daddr+512] = data
        self.mem[0x600] = 0xf4
        self.seg[CS],self.ip,self.flags,self.halted = 0,0x600,flags,False
        self.interrupt(vector)
        if self.run(budget) != 'halt':
            raise AssertionError('Service unexpectedly returned to the shell')
        return bool(self.flags&CF),bytes(self.mem[daddr:daddr+512])

    def install_fast(self, fast: bytes) -> None:
        self.mem[0x7c00:0x7e00] = fast
        self.seg[CS],self.ip,self.halted = 0,0x7c00,False
        self.keys.clear()
        if self.run() != 'keyboard':
            raise AssertionError('Accelerator did not return to the shell')
