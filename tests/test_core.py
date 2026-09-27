import hashlib
import unittest
from minipc import PC, CF, DF, IF, CS, DS, ES, BX, DI, AX, CX, DX, SP, BudgetExceeded
from support import ROOT, PAYLOAD, boot, image, install, command


def git_blob(data):
    return hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()


class ProvenanceTests(unittest.TestCase):
    def test_exact_upstream_source(self):
        self.assertEqual(git_blob((ROOT/'tests/fixtures/upstream-os.asm').read_bytes()),
                         '7365e404118f5a8bcf245447dfe0df5fffa69963')

    def test_exact_upstream_binary(self):
        self.assertEqual(git_blob((ROOT/'build/baseline.img').read_bytes()),
                         'e48996807e07a128e7861587aebf86d6f2063fa7')

    def test_all_boot_sectors(self):
        for kind in ('baseline', 'core', 'fast'):
            with self.subTest(kind=kind):
                data = (ROOT/'build'/f'{kind}.img').read_bytes()
                self.assertEqual(len(data),512)
                self.assertEqual(data[-2:],b'\x55\xaa')


class CoreTests(unittest.TestCase):
    def test_boot_entry_points_and_relocation(self):
        for kind in ('baseline', 'core'):
            for alt in (False, True):
                with self.subTest(kind=kind, alternate_cs=alt):
                    pc = boot(kind, alternate_cs=alt)
                    data = (ROOT/'build'/f'{kind}.img').read_bytes()
                    self.assertEqual(bytes(pc.mem[0x7a00:0x7c00]),data)
                    for vector in range(0x20,0x26):
                        self.assertEqual(pc.get(vector*4+2,16),0)
                        self.assertTrue(0x7a00 <= pc.get(vector*4,16) < 0x7c00)

    def test_all_32_slots(self):
        entries = [(i,f'f{i:02}'.encode(),bytes([i])*512) for i in range(32)]
        for kind in ('baseline','core'):
            pc = boot(kind,entries)
            for i,name,payload in entries:
                with self.subTest(kind=kind,slot=i):
                    carry,result=pc.invoke(0x23,name)
                    self.assertFalse(carry)
                    self.assertEqual(result,payload)

    def test_create_read_delete_missing(self):
        for kind in ('baseline','core'):
            pc=boot(kind)
            self.assertTrue(pc.invoke(0x23,b'missing')[0])
            before=len(pc.io_log)
            self.assertFalse(pc.invoke(0x24,b'hello',PAYLOAD)[0])
            self.assertEqual(len(pc.io_log)-before,3)
            self.assertEqual(pc.invoke(0x23,b'hello'),(False,PAYLOAD))
            self.assertFalse(pc.invoke(0x25,b'hello')[0])
            self.assertTrue(pc.invoke(0x23,b'hello')[0])
            self.assertTrue(pc.invoke(0x25,b'hello')[0])

    def test_overwrite_eliminates_metadata_writes(self):
        for kind,expected_io,expected_metadata in [('baseline',4,2),('core',2,0)]:
            pc=boot(kind,[(0,b'hello',PAYLOAD)])
            pc.io_log.clear()
            self.assertFalse(pc.invoke(0x24,b'hello',b'Z'*512)[0])
            self.assertEqual(len(pc.io_log),expected_io)
            self.assertEqual(sum(e['op']==3 and e['cylinder']==0 for e in pc.io_log),expected_metadata)
            self.assertEqual(pc.invoke(0x23,b'hello'),(False,b'Z'*512))

    def test_overwrite_preserves_slot_even_with_earlier_holes(self):
        pc=boot('core',[(4,b'hello',PAYLOAD)])
        directory=bytes(pc.disk[512:1024])
        self.assertFalse(pc.invoke(0x24,b'hello',b'Q'*512)[0])
        self.assertEqual(bytes(pc.disk[512:1024]),directory)
        self.assertEqual(pc.io_log[-1]['cylinder'],5)
        self.assertEqual(pc.invoke(0x23,b'hello'),(False,b'Q'*512))

    def test_full_directory_rejects_create_but_allows_overwrite(self):
        entries=[(i,f'f{i}'.encode(),PAYLOAD) for i in range(32)]
        pc=boot('core',entries)
        original=bytes(pc.disk)
        self.assertTrue(pc.invoke(0x24,b'new',b'N'*512)[0])
        self.assertEqual(bytes(pc.disk),original)
        self.assertFalse(pc.invoke(0x24,b'f31',b'N'*512)[0])
        self.assertEqual(pc.invoke(0x23,b'f31'),(False,b'N'*512))

    def test_valid_name_boundaries(self):
        for length in (1,15):
            with self.subTest(length=length):
                pc=boot()
                name=b'a'*length
                self.assertFalse(pc.invoke(0x24,name,PAYLOAD)[0])
                self.assertEqual(pc.invoke(0x23,name),(False,PAYLOAD))
                self.assertFalse(pc.invoke(0x25,name)[0])

    def test_overlong_names_do_not_modify_disk(self):
        for length in (16,17,31,127,255):
            for vector in (0x23,0x24,0x25):
                with self.subTest(length=length,vector=vector):
                    pc=boot('core',[(0,b'keep',PAYLOAD)])
                    original=bytes(pc.disk)
                    self.assertTrue(pc.invoke(vector,b'a'*length,PAYLOAD)[0])
                    self.assertEqual(bytes(pc.disk),original)

    def test_nonzero_segments_and_caller_direction_flag(self):
        pc=boot()
        for vector in (0x24,0x23,0x25):
            carry,data=pc.invoke(vector,b'segmented',PAYLOAD,ds=0x150,es=0x400,flags=IF|DF|2)
            self.assertFalse(carry)
            self.assertTrue(pc.flags & DF)
            if vector==0x23:
                self.assertEqual(data,PAYLOAD)

    def test_shell_version_directory_and_format(self):
        pc=boot('core',[(0,b'hello',PAYLOAD)])
        command(pc,b'ver')
        command(pc,b'dir')
        self.assertIn(b'hello',pc.screen)
        command(pc,b'format')
        self.assertEqual(pc.disk[512:1024],bytes(512))
        self.assertEqual(pc.disk[:512],(ROOT/'build/core.img').read_bytes())


class AcceleratorTests(unittest.TestCase):
    def test_cold_and_warm_load_on_both_kernels(self):
        for kind in ('baseline','core'):
            pc=install(boot(kind,[(0,b'hello',PAYLOAD)]))
            pc.io_log.clear()
            for call in range(5):
                self.assertEqual(pc.invoke(0x23,b'hello'),(False,PAYLOAD))
                self.assertEqual(pc.r[BX],0x300)
                self.assertEqual(len(pc.io_log),2)

    def test_memory_reservation_and_repeat_install(self):
        pc=boot()
        old=pc.get(0x413,16)
        install(pc)
        segment=pc.get(0x23*4+2,16)
        self.assertEqual(pc.get(0x413,16),old-2)
        self.assertEqual(segment,(old-2)*64)
        install(pc)
        self.assertEqual(pc.get(0x413,16),old-2)
        self.assertEqual(pc.get(0x23*4+2,16),segment)

    def test_low_memory_refusal(self):
        pc=boot()
        vector=bytes(pc.mem[0x8c:0x90])
        pc.put(0x413,63,16)
        install(pc)
        self.assertEqual(bytes(pc.mem[0x8c:0x90]),vector)
        self.assertEqual(pc.get(0x413,16),63)

    def test_save_invalidates_and_delivers_new_data(self):
        pc=install(boot('core',[(0,b'hello',PAYLOAD)]))
        self.assertEqual(pc.invoke(0x23,b'hello'),(False,PAYLOAD))
        self.assertFalse(pc.invoke(0x24,b'hello',b'N'*512)[0])
        pc.io_log.clear()
        self.assertEqual(pc.invoke(0x23,b'hello'),(False,b'N'*512))
        self.assertEqual(len(pc.io_log),2)
        self.assertEqual(pc.invoke(0x23,b'hello'),(False,b'N'*512))
        self.assertEqual(len(pc.io_log),2)

    def test_delete_invalidates(self):
        pc=install(boot('core',[(0,b'hello',PAYLOAD)]))
        self.assertFalse(pc.invoke(0x23,b'hello')[0])
        self.assertFalse(pc.invoke(0x25,b'hello')[0])
        self.assertTrue(pc.invoke(0x23,b'hello')[0])

    def test_format_invalidates(self):
        pc=install(boot('core',[(0,b'hello',PAYLOAD)]))
        self.assertFalse(pc.invoke(0x23,b'hello')[0])
        command(pc,b'format')
        self.assertTrue(pc.invoke(0x23,b'hello')[0])

    def test_raw_bios_write_invalidates(self):
        pc=install(boot('core',[(0,b'hello',PAYLOAD)]))
        self.assertFalse(pc.invoke(0x23,b'hello')[0])
        pc.mem[0x5000:0x5200]=b'R'*512
        pc.r[AX],pc.r[BX],pc.r[CX],pc.r[DX]=0x0301,0x5000,0x0101,0
        pc.seg[ES],pc.seg[CS],pc.ip=0,0,0x600
        pc.seg[2],pc.r[SP]=0,0x7600
        pc.halted=False
        pc.interrupt(0x13)
        self.assertEqual(pc.run(),'halt')
        pc.io_log.clear()
        self.assertEqual(pc.invoke(0x23,b'hello'),(False,b'R'*512))
        self.assertEqual(len(pc.io_log),2)

    def test_missing_names_not_cached(self):
        pc=install(boot())
        pc.io_log.clear()
        for i in range(4):
            self.assertTrue(pc.invoke(0x23,b'no')[0])
        self.assertEqual(len(pc.io_log),4)

    def test_alternating_files_no_io_improvement(self):
        pc=install(boot('core',[(0,b'a',PAYLOAD),(1,b'b',b'B'*512)]))
        pc.io_log.clear()
        for i in range(10):
            name,data=(b'a',PAYLOAD) if i%2==0 else (b'b',b'B'*512)
            self.assertEqual(pc.invoke(0x23,name),(False,data))
        self.assertEqual(len(pc.io_log),20)

    def test_direction_flag_and_nonzero_segments(self):
        pc=install(boot('core',[(0,b'hello',PAYLOAD)]))
        for flags in (IF|DF|2,IF|DF|CF|2,IF|0x8d4|2):
            carry,data=pc.invoke(0x23,b'hello',ds=0x170,es=0x500,flags=flags)
            self.assertFalse(carry)
            self.assertEqual(data,PAYLOAD)
            self.assertEqual(pc.flags & ~CF, flags & ~CF)
            self.assertEqual((pc.seg[DS],pc.seg[ES]),(0x170,0x500))

    def test_reinstall_flushes_swapped_media(self):
        pc=install(boot('core',[(0,b'hello',PAYLOAD)]))
        self.assertFalse(pc.invoke(0x23,b'hello')[0])
        # An external media change with no BIOS call must be explicitly flushed.
        pc.disk[18*512:19*512]=b'S'*512
        self.assertEqual(pc.invoke(0x23,b'hello'),(False,PAYLOAD))
        install(pc)
        self.assertEqual(pc.invoke(0x23,b'hello'),(False,b'S'*512))


class KnownLimitTests(unittest.TestCase):
    """Passing here confirms a limitation remains, NOT that it was corrected."""
    def test_infinite_retry_remains_bounded_by_test_harness(self):
        pc=boot()
        pc.fail_io=True
        with self.assertRaises(BudgetExceeded):
            pc.invoke(0x23,b'a',budget=5000)
        self.assertGreater(len(pc.io_log),100)

    def test_empty_filename_remains_accepted(self):
        pc=boot()
        self.assertFalse(pc.invoke(0x24,b'',PAYLOAD)[0])
        self.assertEqual(bytes(pc.disk[512:528]),bytes(16))

    def test_upstream_overlong_name_corrupts_next_directory_slot(self):
        pc=boot('baseline')
        self.assertFalse(pc.invoke(0x24,b'a'*17,PAYLOAD)[0])
        self.assertEqual(pc.disk[528],ord('a'))

    def test_shell_input_still_has_no_upper_bound(self):
        pc=boot()
        pc.trace_writes=True
        pc.keys.extend(b'a'*129+b'\r')
        pc.run()
        self.assertTrue(any(0x7800 <= addr < 0x7810 for addr,width in pc.writes))

    def test_backspace_still_underflows_line_buffer(self):
        pc=boot()
        pc.trace_writes=True
        pc.keys.extend(b'\x08X\r')
        pc.run()
        self.assertTrue(any(addr==0x777f for addr,width in pc.writes))


class RunnerSelfTests(unittest.TestCase):
    def execute(self,code):
        pc=PC(bytearray(360*1024))
        code = bytes.fromhex(code) if isinstance(code,str) else code
        pc.mem[0x600:0x600+len(code)]=code
        pc.ip=0x600
        pc.r[SP]=0x7600
        pc.run()
        return pc

    def test_add_carry(self):
        pc=self.execute('b0ff 0401 f4')
        self.assertEqual(pc.reg(0,8),0)
        self.assertTrue(pc.flags & CF)
        self.assertTrue(pc.flags & 64)

    def test_subtract_borrow(self):
        pc=self.execute('b000 2c01 f4')
        self.assertEqual(pc.reg(0,8),255)
        self.assertTrue(pc.flags&CF)

    def test_interrupt_and_iret(self):
        pc=PC(bytearray(360*1024))
        pc.mem[0x600:0x603]=bytes.fromhex('cd30f4')
        pc.mem[0x700:0x704]=bytes.fromhex('b83412cf')
        pc.put(0x30*4,0x700,16)
        pc.put(0x30*4+2,0,16)
        pc.ip,pc.r[SP],pc.flags=0x600,0x7600,IF|DF|CF|2
        self.assertEqual(pc.run(),'halt')
        self.assertEqual(pc.r[AX],0x1234)
        self.assertEqual(pc.flags,IF|DF|CF|2)
        self.assertEqual(pc.r[SP],0x7600)

    def test_unknown_opcode_fails_closed(self):
        pc=PC(bytearray(360*1024))
        pc.mem[0x600]=0x0f
        pc.ip=0x600
        with self.assertRaises(NotImplementedError):
            pc.step()


if __name__=='__main__':
    unittest.main()
