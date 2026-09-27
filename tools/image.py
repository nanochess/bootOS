#!/usr/bin/env python3
"""Safe host-side bootOS image construction. Regular files only; no raw devices.

All modifying commands write a separate output image. Existing output files are
refused unless --force is explicit. Images use the unchanged upstream CHS layout.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import stat
import tempfile

GEOMETRIES = {180:(40,1,9),360:(40,2,9),720:(80,2,9),1200:(80,2,15),1440:(80,2,18)}


def read_regular(path: Path) -> bytes:
    fd=os.open(path,os.O_RDONLY|getattr(os,'O_NOFOLLOW',0)|getattr(os,'O_NONBLOCK',0))
    try:
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('Only regular files are accepted; never devices or pipes')
        if info.st_size > 2*1024*1024:
            raise ValueError('Input is larger than the supported floppy images')
        with os.fdopen(fd,'rb',closefd=False) as source:
            return source.read()
    finally:
        os.close(fd)


def geometry(data: bytes):
    if len(data)%1024 or len(data)//1024 not in GEOMETRIES:
        raise ValueError('Expected a 180, 360, 720, 1200 or 1440 KiB floppy image')
    return GEOMETRIES[len(data)//1024]


def validate_boot(data: bytes):
    if len(data)!=512 or data[-2:]!=b'\x55\xaa':
        raise ValueError('Boot/program sector must be exactly 512 bytes with 55 aa signature')


def name_bytes(name: str) -> bytes:
    try:
        value=name.encode('ascii')
    except UnicodeEncodeError as exc:
        raise ValueError('Names must be ASCII') from exc
    if not 1 <= len(value) <= 15 or any(c<33 or c>126 for c in value):
        raise ValueError('Names must contain 1..15 printable ASCII characters, without spaces')
    return value


def entries(data: bytes):
    geometry(data)
    validate_boot(data[:512])
    result=[]
    seen=set()
    for slot in range(32):
        entry=bytes(data[512+16*slot:528+16*slot])
        if entry[0]==0:
            continue
        zero=entry.find(b'\0')
        if zero<0:
            raise ValueError(f'Directory slot {slot} has no NUL terminator')
        name=entry[:zero]
        if any(c<32 or c>126 for c in name):
            raise ValueError(f'Directory slot {slot} is not a printable ASCII name')
        if name in seen:
            raise ValueError(f'Duplicate directory name at slot {slot}')
        seen.add(name)
        result.append((slot,name.decode('ascii')))
    return result


def offset(data: bytes,slot: int) -> int:
    if not 0 <= slot < 32:
        raise ValueError('Slot must be in 0..31')
    _,heads,spt=geometry(data)
    return (slot+1)*heads*spt*512


def create(boot: bytes,size: int) -> bytes:
    validate_boot(boot)
    if size not in GEOMETRIES:
        raise ValueError('Unsupported image size')
    image=bytearray(size*1024)
    image[:512]=boot
    return bytes(image)


def put(data: bytes,name: str,payload: bytes) -> bytes:
    encoded=name_bytes(name)
    if len(payload)>512:
        raise ValueError('Programs/files may occupy at most 512 bytes')
    listed=entries(data)
    occupied={i for i,n in listed}
    found=next((i for i,n in listed if n==name),None)
    if found is None:
        found=next((i for i in range(32) if i not in occupied),None)
    if found is None:
        raise ValueError('Directory is full (32 files)')
    result=bytearray(data)
    pos=512+16*found
    result[pos:pos+16]=encoded+bytes(16-len(encoded))
    pos=offset(data,found)
    result[pos:pos+512]=payload+bytes(512-len(payload))
    return bytes(result)


def upgrade(data: bytes,boot: bytes) -> bytes:
    entries(data)
    validate_boot(boot)
    return boot+data[512:]


def write_atomic(path: Path,data: bytes,force=False):
    # No implicit in-place writes, raw block devices, or followed symlinks.
    if path.is_symlink():
        raise ValueError('Output symlinks are not allowed')
    if path.exists() and not path.is_file():
        raise ValueError('Output must be a regular file')
    if path.exists() and not force:
        raise FileExistsError(f'Output already exists: {path}')
    fd,tmp=tempfile.mkstemp(prefix='.bootos-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if force:
            os.replace(tmp,path)
        else:
            # Atomic no-clobber publication, unlike exists()+replace().
            os.link(tmp,path)
            os.unlink(tmp)
        dirfd=os.open(path.parent,os.O_RDONLY|getattr(os,'O_DIRECTORY',0))
        try:
            os.fsync(dirfd)
        finally:
            os.close(dirfd)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    sub=p.add_subparsers(dest='command',required=True)
    c=sub.add_parser('create')
    c.add_argument('output',type=Path)
    c.add_argument('--boot',type=Path,required=True)
    c.add_argument('--size',type=int,choices=GEOMETRIES,default=360)
    for action in ('put','upgrade'):
        cmd=sub.add_parser(action)
        cmd.add_argument('image',type=Path)
        cmd.add_argument('--output',type=Path,required=True)
        if action=='put':
            cmd.add_argument('name')
            cmd.add_argument('program',type=Path)
        else:
            cmd.add_argument('--boot',type=Path,required=True)
    for action in ('check','ls'):
        cmd=sub.add_parser(action)
        cmd.add_argument('image',type=Path)
    for cmd in (c,sub.choices['put'],sub.choices['upgrade']):
        cmd.add_argument('--force',action='store_true',help='Explicitly replace a regular output image')
    a=p.parse_args()
    try:
        if a.command in ('check','ls'):
            data=read_regular(a.image)
            listed=entries(data)
            print(json.dumps({'bytes':len(data),'geometry':geometry(data),'files':listed},indent=2))
            return
        if getattr(a,'image',None) and a.image.resolve()==a.output.resolve():
            raise ValueError('Use a separate output path; in-place source modification is not supported')
        if a.command=='create':
            result=create(read_regular(a.boot),a.size)
        elif a.command=='put':
            result=put(read_regular(a.image),a.name,read_regular(a.program))
        else:
            result=upgrade(read_regular(a.image),read_regular(a.boot))
        write_atomic(a.output,result,a.force)
        print(f'Wrote {len(result)} bytes to {a.output}')
    except (OSError,ValueError) as exc:
        p.exit(2,f'error: {exc}\n')

if __name__=='__main__':
    main()
