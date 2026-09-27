#!/usr/bin/env python3
"""Build a NEW disposable floppy image with core, fast and demo; never overwrite."""
from pathlib import Path
import argparse
from image import create,put,read_regular,write_atomic

ROOT=Path(__file__).resolve().parents[1]

def make_demo():
    data=create(read_regular(ROOT/'build/core.img'),360)
    for name in ('fast','demo'):
        data=put(data,name,read_regular(ROOT/'build'/f'{name}.img'))
    return data

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,default=ROOT/'build/demo-disk.img')
    a=p.parse_args()
    try:
        write_atomic(a.output,make_demo())
        print(f'{a.output}: 360 KiB, files fast and demo; use only in an emulator')
    except (OSError,ValueError) as exc:
        p.exit(2,f'error: {exc}\n')
