#!/usr/bin/env python3
"""Translate the small NASM subset used by os.asm and assemble with GNU binutils.

This is a fallback/audit builder, NOT a general NASM implementation. It rejects
unknown directives. GNU as .arch i8086 prevents post-8086 instructions. Normal
upstream builds can continue to use NASM. Output is linked at the relocation
address 0x7a00, not the BIOS loading address 0x7c00.
"""
from __future__ import annotations
import argparse
import ast
import json
from pathlib import Path
import re
import subprocess

REGS = set('ax bx cx dx si di bp sp al bl cl dl ah bh ch dh es cs ss ds'.split())

def translate(text: str) -> str:
    out = ['.intel_syntax noprefix', '.code16', '.arch i8086', '.text', '.global start']
    scope = ''
    for number, raw in enumerate(text.splitlines(), 1):
        s = raw.split(';', 1)[0].strip()
        if not s:
            continue
        # NASM local labels are scoped to the preceding nonlocal label.
        m = re.match(r'^([\w.]+):\s*(.*)$', s)
        if m:
            label, s = m.groups()
            if label.startswith('.'):
                label = scope + '__' + label[1:]
            else:
                scope = label
            if s.startswith('equ '):
                out.append(f'.set {label}, {s[4:]}')
                continue
            out.append(label + ':')
        if not s:
            continue
        s = re.sub(r'(?<![\w])\.([a-zA-Z_]\w*)', lambda m: scope+'__'+m[1], s)
        s = re.sub(r"'(.)'", lambda m: str(ord(m[1])), s)
        if s == 'cpu 8086' or s.startswith('org '):
            continue
        if s.startswith('times '):
            if s != 'times 510-($-$$) db 0x4f':
                raise ValueError(f'Unsupported times directive at line {number}')
            out += ['payload_end:', '.org 510, 0x4f']
            continue
        if s.startswith(('db ', 'dw ')):
            op = '.byte' if s.startswith('db ') else '.word'
            vals = re.findall(r'"[^"\\]*"|[^,]+', s[3:])
            for v in vals:
                v = v.strip()
                if v.startswith('"'):
                    if op != '.byte':
                        raise ValueError('Only db strings supported')
                    value = ast.literal_eval(v)
                    out.append('.byte ' + ','.join(str(b) for b in value.encode('ascii')))
                else:
                    out.append(f'{op} {v}')
            continue
        if s.startswith(('%', 'section', 'bits', 'align', 'incbin')):
            raise ValueError(f'Unsupported directive at line {number}: {s}')
        s = re.sub(r'\b(byte|word)\s+(?=\[)', r'\1 ptr ', s)
        s = re.sub(r',\s*byte\s+(?!ptr)', ',', s)
        if s.startswith('es '):
            s = s[3:].replace('[', 'es:[', 1)
        # NASM permits [es:x]; GNU Intel syntax uses es:[x].
        s = re.sub(r'\[(cs|ds|es|ss):([^]]+)\]', r'\1:[\2]', s)
        s = s.replace(' short ', ' ')
        s = s.replace('call far ', 'lcall ').replace('jmp far ', 'ljmp ')
        if s.startswith('int '):
            s = 'int offset ' + s[4:]
        if s.startswith(('mov ', 'cmp ', 'add ', 'sub ', 'and ', 'or ', 'xor ')):
            lhs, rhs = s.split(',', 1)
            rhs = rhs.strip()
            if '[' not in rhs and rhs not in REGS:
                s = lhs + ', offset ' + rhs
        out.append('    ' + s)
    return '\n'.join(out) + '\n'

def build(source: Path, output: Path, origin: int = 0x7a00) -> dict[str, int]:
    output.parent.mkdir(parents=True, exist_ok=True)
    gas = output.with_suffix('.S')
    obj = output.with_suffix('.o')
    elf = output.with_suffix('.elf')
    gas.write_text(translate(source.read_text()), encoding='ascii')
    subprocess.run(['as', '--32', '-o', str(obj), str(gas)], check=True)
    subprocess.run(['ld', '-m', 'elf_i386', '-Ttext', hex(origin), '-e', 'start', '-o', str(elf), str(obj)], check=True)
    subprocess.run(['objcopy', '-O', 'binary', '-j', '.text', str(elf), str(output)], check=True)
    symbols = {}
    for line in subprocess.check_output(['nm', '-n', str(elf)], text=True).splitlines():
        fields = line.split()
        if len(fields) == 3:
            symbols[fields[2]] = int(fields[0], 16)
    output.with_suffix('.symbols.json').write_text(json.dumps(symbols, indent=2)+'\n')
    data = output.read_bytes()
    if len(data) != 512 or data[-2:] != b'\x55\xaa':
        raise ValueError('Expected exactly 512 bytes and BIOS signature 55 aa')
    print(f'{output}: {len(data)} bytes, payload {symbols["payload_end"]-origin}, signature 55aa')
    return symbols

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--origin', type=lambda s: int(s, 0), default=0x7a00)
    args = parser.parse_args()
    build(args.source, args.output, args.origin)
