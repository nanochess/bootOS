all:
	nasm os.asm -f bin -o os.bin
	nasm boot.asm -f bin -o boot.bin

	dd if=/dev/zero of=zeros.img count=719 bs=512

	cat boot.bin os.bin zeros.img > bootable.img

clean:
	rm -f os.bin boot.bin zeros.img

clear:
	rm -f bootable.img os.bin boot.bin zeros.img

run:
	qemu-system-i386 -fda os.img

.PHONY: all clean clear run

