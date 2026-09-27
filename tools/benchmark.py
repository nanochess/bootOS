#!/usr/bin/env python3
"""Count actual guest BIOS I/O in a deterministic 8086 subset test runner.

These are operation counts, NOT milliseconds, CPU cycles, tokens, or a global
speedup. No QEMU/hardware timing has been performed by this script.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
from support import PAYLOAD, boot, install


def measure(kind, workload, n):
    pc=boot('baseline' if kind=='upstream' else 'core',
            [(0,b'alpha',PAYLOAD),(1,b'beta',b'B'*512)])
    if kind=='core+fast':
        install(pc)
    pc.counts.clear()
    pc.io_log.clear()
    for i in range(n):
        if workload=='overwrite_same_file':
            carry,_=pc.invoke(0x24,b'alpha',bytes([i%256])*512)
            assert not carry
        elif workload=='missing_name':
            assert pc.invoke(0x23,b'absent')[0]
        else:
            second=workload=='alternating_two_files' and i%2==1
            name,expected=(b'beta',b'B'*512) if second else (b'alpha',PAYLOAD)
            carry,result=pc.invoke(0x23,name)
            assert not carry and result==expected
    counts=dict(sorted(pc.counts.items()))
    return {
        'variant':kind,'workload':workload,'operations':n,
        'bios_disk_calls':len(pc.io_log),
        'directory_writes':sum(e['op']==3 and e['cylinder']==0 and e['sector']==2 for e in pc.io_log),
        'counts':counts,
        # REP is decoded once in opcodes; iterations must be reported separately.
        'guest_work_units':counts.get('opcodes',0)+counts.get('string_iterations',0),
        'guest_work_units_definition':'decoded opcodes + string iterations; NOT cycles',
        'byte_result_checks':'passed',
    }


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--iterations',type=int,default=100)
    p.add_argument('--output',type=Path,default=ROOT/'reports/benchmark.json')
    args=p.parse_args()
    if not 1 <= args.iterations <= 10000:
        p.error('--iterations must be between 1 and 10000')
    rows=[measure(kind,workload,args.iterations)
          for workload in ('repeat_same_file','overwrite_same_file','alternating_two_files','missing_name')
          for kind in ('upstream','core','core+fast')]
    document={
        'baseline_commit':'e54fffe4243bb77e487798801a3bc4c3e60cb01e',
        'date':'2026-09-27',
        'method':'actual assembled machine code on project-local 8086 subset runner; deterministic BIOS doubles',
        'limits':['Not cycle-accurate','Not an independent full-PC emulator',
                  'No QEMU boot test run here','No physical floppy or latency measurement',
                  'Cache installation and boot costs excluded; first cold load INCLUDED',
                  'Cache reserves 2 KiB; single-file cache is explicitly opt-in'],
        'host':{'python':platform.python_version(), 'platform':platform.platform(),
                'assembler':subprocess.check_output(['as','--version'],text=True).splitlines()[0]},
        'binary_sha256':{k:hashlib.sha256((ROOT/'build'/f'{k}.img').read_bytes()).hexdigest()
                         for k in ('baseline','core','fast')},
        'results':rows,
    }
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(document,indent=2)+'\n')
    print('workload                 variant     diskIO  dirWrites  opcodes  REP/str iterations')
    for r in rows:
        c=r['counts']
        print(f"{r['workload']:24} {r['variant']:11} {r['bios_disk_calls']:6} {r['directory_writes']:10} {c.get('opcodes',0):8} {c.get('string_iterations',0):18}")
    print(f'Raw report: {args.output}')

if __name__=='__main__':
    main()
