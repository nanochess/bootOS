"""API sequences and full shell execution, in addition to isolated routines."""
import random
import unittest
from minipc import PC
from support import ROOT, PAYLOAD, boot, install, command
import sys
sys.path.insert(0,str(ROOT/'tools'))
import image as fs


class SequenceTests(unittest.TestCase):
    def test_seeded_filesystem_sequences_with_and_without_cache(self):
        for accelerated in (False,True):
            pc=boot()
            if accelerated:
                install(pc)
            randomizer=random.Random(0xb005)
            expected={}
            for step in range(600):
                name=f'file{randomizer.randrange(40):02}'.encode()
                op=randomizer.choice(('load','save','save','delete'))
                with self.subTest(cache=accelerated,step=step,op=op,name=name):
                    if op=='save':
                        data=randomizer.randbytes(512)
                        rejected=name not in expected and len(expected)==32
                        carry,_=pc.invoke(0x24,name,data)
                        self.assertEqual(carry,rejected)
                        if not rejected:
                            expected[name]=data
                    elif op=='delete':
                        carry,_=pc.invoke(0x25,name)
                        self.assertEqual(carry,name not in expected)
                        expected.pop(name,None)
                    else:
                        carry,data=pc.invoke(0x23,name)
                        self.assertEqual(carry,name not in expected)
                        if name in expected:
                            self.assertEqual(data,expected[name])
            # Host-side parser independently checks the final physical layout.
            on_disk={name.encode():bytes(pc.disk[fs.offset(pc.disk,slot):fs.offset(pc.disk,slot)+512])
                     for slot,name in fs.entries(pc.disk)}
            self.assertEqual(on_disk,expected)

    def test_real_shell_loads_installer_then_executes_program_twice(self):
        data=fs.create((ROOT/'build/core.img').read_bytes(),360)
        for name in ('fast','demo'):
            data=fs.put(data,name,(ROOT/'build'/f'{name}.img').read_bytes())
        pc=PC(bytearray(data))
        self.assertEqual(pc.run(),'keyboard')
        command(pc,b'fast')
        self.assertEqual(pc.get(0x413,16),638)
        pc.io_log.clear()
        command(pc,b'demo')
        command(pc,b'demo')
        self.assertEqual(bytes(pc.screen).count(b'bootOS demo OK'),2)
        self.assertEqual(len(pc.io_log),2)


if __name__=='__main__':
    unittest.main()
