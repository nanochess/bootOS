import sys
import tempfile
import unittest
from pathlib import Path
from support import ROOT, PAYLOAD
sys.path.insert(0,str(ROOT/'tools'))
import image as fs


class ImageTests(unittest.TestCase):
    def setUp(self):
        self.boot=(ROOT/'build/core.img').read_bytes()

    def test_every_geometry_and_last_slot(self):
        for size in fs.GEOMETRIES:
            data=fs.create(self.boot,size)
            for i in range(32):
                data=fs.put(data,f'f{i}',bytes([i])*512)
            self.assertEqual(len(data),size*1024)
            self.assertEqual(len(fs.entries(data)),32)
            off=fs.offset(data,31)
            self.assertEqual(data[off:off+512],bytes([31])*512)
            with self.assertRaises(ValueError):
                fs.put(data,'extra',b'no')

    def test_short_file_padding_and_overwrite(self):
        data=fs.put(fs.create(self.boot,360),'hello',b'hello')
        off=fs.offset(data,0)
        self.assertEqual(data[off:off+512],b'hello'+bytes(507))
        updated=fs.put(data,'hello',PAYLOAD)
        self.assertEqual(updated[512:1024],data[512:1024])
        self.assertEqual(updated[off:off+512],PAYLOAD)

    def test_upgrade_preserves_every_nonboot_byte(self):
        old=(ROOT/'build/baseline.img').read_bytes()
        data=fs.put(fs.create(old,360),'keep',PAYLOAD)
        updated=fs.upgrade(data,self.boot)
        self.assertEqual(updated[512:],data[512:])
        self.assertEqual(updated[:512],self.boot)

    def test_invalid_inputs(self):
        data=fs.create(self.boot,360)
        for name in ('','a'*16,'white space','x\0y','é'):
            with self.subTest(name=name),self.assertRaises(ValueError):
                fs.put(data,name,b'a')
        with self.assertRaises(ValueError):
            fs.put(data,'hello',bytes(513))
        with self.assertRaises(ValueError):
            fs.create(bytes(512),360)
        with self.assertRaises(ValueError):
            fs.entries(bytes(100))

    def test_directory_corruption_rejected(self):
        data=bytearray(fs.create(self.boot,360))
        data[512:528]=b'a'*16
        with self.assertRaises(ValueError):
            fs.entries(data)

    def test_atomic_publication_no_clobber_and_explicit_replace(self):
        with tempfile.TemporaryDirectory() as d:
            target=Path(d)/'disk.img'
            fs.write_atomic(target,b'original')
            with self.assertRaises(FileExistsError):
                fs.write_atomic(target,b'replacement')
            self.assertEqual(target.read_bytes(),b'original')
            fs.write_atomic(target,b'replacement',force=True)
            self.assertEqual(target.read_bytes(),b'replacement')
            self.assertFalse(list(Path(d).glob('.bootos-*')))

    def test_reject_symlinks_and_devices(self):
        with tempfile.TemporaryDirectory() as d:
            actual=Path(d)/'file'
            actual.write_bytes(b'data')
            link=Path(d)/'link'
            link.symlink_to(actual)
            with self.assertRaises(OSError):
                fs.read_regular(link)
            with self.assertRaises(ValueError):
                fs.write_atomic(link,b'bad',force=True)
            self.assertEqual(actual.read_bytes(),b'data')
        with self.assertRaises(ValueError):
            fs.read_regular(Path('/dev/null'))

    def test_utility_images_execute_with_kernel(self):
        from minipc import PC
        for size,(cyl,heads,spt) in fs.GEOMETRIES.items():
            disk=fs.put(fs.create(self.boot,size),'hello',PAYLOAD)
            pc=PC(bytearray(disk),heads=heads,spt=spt)
            self.assertEqual(pc.run(),'keyboard')
            self.assertEqual(pc.invoke(0x23,b'hello'),(False,PAYLOAD))

if __name__=='__main__':
    unittest.main()
