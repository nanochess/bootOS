# Makefile contributed by jtsiomb

src = os.asm

.PHONY: all
all: os.img os-disk.img

os.img: $(src)
	nasm -f bin -l os.lst -o $@ $(src)

# BIOS floppy images need a standard disk geometry for bootOS's filesystem.
os-disk.img: os.img
	dd if=/dev/zero of=$@ bs=512 count=720
	dd if=os.img of=$@ conv=notrunc

.PHONY: clean
clean:
	$(RM) os.img os-disk.img

.PHONY: run runqemu
run: runqemu

runqemu: os-disk.img
	qemu-system-x86_64 -drive file=os-disk.img,format=raw,if=floppy
