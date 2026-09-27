        ; Normal bootOS application for a real shell-to-program smoke test.
        ; BSD-2-Clause; see LICENSE. Loaded by INT 23h at 0000:7c00.
        cpu 8086
        org 0x7c00
start:
        cld
        mov si,message
.loop:
        lodsb
        test al,al
        je .done
        int 0x22
        jmp short .loop
.done:
        int 0x20
message:
        db "bootOS demo OK",13,0
        times 510-($-$$) db 0x4f
        db 0x55,0xaa
