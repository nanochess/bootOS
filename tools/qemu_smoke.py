#!/usr/bin/env python3
"""Independent full-PC smoke gate (requires QEMU; no timing claims).

Creates a disposable image, boots it, types fast/demo/demo via QMP, and checks
VGA text memory plus the BIOS memory reservation. Exit 77 = unavailable,
never PASS. This gate was NOT run against QEMU in the delivery environment.
Protocol reference: https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from demo_image import make_demo

ROOT=Path(__file__).resolve().parents[1]


class QMP:
    def __init__(self,path,process):
        self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
        self.sock.settimeout(3)
        deadline=time.monotonic()+10
        while True:
            try:
                self.sock.connect(str(path))
                break
            except (FileNotFoundError,ConnectionRefusedError):
                if process.poll() is not None:
                    raise RuntimeError('QEMU exited before opening QMP')
                if time.monotonic()>deadline:
                    raise TimeoutError('QMP connection timeout')
                time.sleep(.05)
        self.stream=self.sock.makefile('rwb')
        greeting=json.loads(self.stream.readline())
        if 'QMP' not in greeting:
            raise RuntimeError('Invalid QMP greeting')
        self.sequence=0
        self.call('qmp_capabilities')

    def call(self,command,arguments=None):
        self.sequence+=1
        request={'execute':command,'id':self.sequence}
        if arguments is not None:
            request['arguments']=arguments
        self.stream.write(json.dumps(request).encode()+b'\n')
        self.stream.flush()
        while True:
            line=self.stream.readline()
            if not line:
                raise RuntimeError('QMP disconnected')
            reply=json.loads(line)
            if reply.get('id')!=self.sequence:
                continue
            if 'error' in reply:
                raise RuntimeError(str(reply['error']))
            return reply.get('return')

    def close(self):
        self.stream.close()
        self.sock.close()


def run(qemu):
    with tempfile.TemporaryDirectory(prefix='bootos-qemu-') as directory:
        temp=Path(directory)
        image=temp/'disk.img'
        image.write_bytes(make_demo())
        with (temp/'qemu.log').open('w+b') as log:
            process=subprocess.Popen([qemu,'-machine','pc','-accel','tcg','-m','16M',
                '-display','none','-monitor','none','-serial','none',
                '-drive',f'file={image},format=raw,if=floppy,index=0',
                '-boot','a','-snapshot','-no-reboot',
                '-qmp',f'unix:{temp / "qmp.sock"},server=on,wait=off'],
                stdout=log,stderr=subprocess.STDOUT)
            qmp=None
            try:
                qmp=QMP(temp/'qmp.sock',process)
                def memory(address,size):
                    destination=temp/'memory.bin'
                    qmp.call('pmemsave',{'val':address,'size':size,'filename':str(destination)})
                    data=destination.read_bytes()
                    if len(data)!=size:
                        raise RuntimeError('Incomplete guest-memory dump')
                    return data
                def screen():
                    return memory(0xb8000,4000)[::2]
                def wait_until(predicate,label):
                    deadline=time.monotonic()+12
                    while not predicate():
                        if time.monotonic()>deadline:
                            raise TimeoutError(label)
                        if process.poll() is not None:
                            raise RuntimeError('QEMU exited unexpectedly')
                        time.sleep(.05)
                def command(text):
                    for key in list(text)+['ret']:
                        qmp.call('send-key',{'keys':[{'type':'qcode','data':key}], 'hold-time':30})
                        time.sleep(.07)
                wait_until(lambda:b'bootOS' in screen() and b'$' in screen(),'boot prompt')
                before=int.from_bytes(memory(0x413,2),'little')
                command('fast')
                wait_until(lambda:int.from_bytes(memory(0x413,2),'little')==before-2,'cache installation')
                command('demo')
                wait_until(lambda:screen().count(b'bootOS demo OK')==1,'first demo')
                command('demo')
                wait_until(lambda:screen().count(b'bootOS demo OK')==2,'second demo')
                return {'status':'PASS','qemu':qemu,'check':'BIOS boot + installer + two application executions',
                        'memory_kib_before':before,'memory_kib_after':before-2,
                        'limits':'Functional smoke only; no performance or hardware equivalence claim'}
            except Exception as exc:
                process.terminate()
                process.wait(timeout=5)
                log.seek(0)
                raise RuntimeError(f'{exc}; QEMU log: {log.read().decode(errors="replace")}') from exc
            finally:
                if qmp is not None:
                    qmp.close()
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--qemu',default='qemu-system-i386')
    p.add_argument('--output',type=Path,default=ROOT/'reports/qemu.json')
    args=p.parse_args()
    executable=shutil.which(args.qemu)
    if executable is None:
        report={'status':'NOT_RUN','reason':f'{args.qemu} not installed','exit_code':77}
        code=77
    else:
        try:
            report=run(executable)
            code=0
        except Exception as exc:
            report={'status':'FAIL','reason':str(exc)}
            code=1
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    return code

if __name__=='__main__':
    sys.exit(main())
