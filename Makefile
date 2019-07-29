# Makefile contributed by jtsiomb

src = os.asm

.PHONY: all
all: os.img

os.img: $(src)
	nasm -f bin -l os.lst -o $@ $(src)

.PHONY: clean
clean:
	$(RM) os.img

.PHONY: runqemu
runqemu: os.img
	qemu-system-i386 -fda os.img
