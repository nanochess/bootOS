        ; Optional bootOS read-through accelerator. BSD-2-Clause; see LICENSE.
        ; Load as a normal bootOS file at 0000:7c00 and run "fast".
        ; Reserves 2 KiB at the top of BIOS-reported conventional memory.
        ; One 512-byte file is cached. Any BIOS INT 13h operation invalidates it.
        ; Run "fast" again to flush before using swapped removable media.
        ; Programs must respect BIOS memory size and must not overwrite vectors.
        cpu 8086
        org 0
boot:   equ 0x7c00
sector_size: equ 512
cache_name: equ 512
cache_valid: equ 528
cache_data: equ 544
start:
        cld
        xor ax,ax
        mov ds,ax
        mov bx,[0x23*4]
        mov ax,[0x23*4+2]
        mov es,ax
        cmp bx,load_hook
        jne install
        cmp word [es:magic],0xb05c
        jne install
        mov byte [es:cache_valid],0
        int 0x20
install:
        int 0x12
        cmp ax,64              ; Keep the kernel/stack well below the reservation
        jb refuse
        sub ax,2
        cli
        mov [0x413],ax         ; Cooperating programs see the reduced RAM limit
        mov cl,6
        shl ax,cl              ; KiB to segment paragraphs
        mov es,ax
        xor di,di
        mov si,boot
        mov cx,sector_size/2
        rep movsw
        mov si,0x23*4
        mov di,old_load
        movsw
        movsw
        mov si,0x13*4
        mov di,old_disk
        movsw
        movsw
        mov byte [es:cache_valid],0
        mov word [0x23*4],load_hook
        mov [0x23*4+2],ax
        mov word [0x13*4],disk_hook
        mov [0x13*4+2],ax
        sti
refuse:
        int 0x20

        ; This catches core format/delete/save and applications using BIOS I/O.
        ; It does not detect physical media exchange without an intervening I/O.
disk_hook:
        mov byte [cs:cache_valid],0
        jmp far [cs:old_disk]

load_hook:
        cld
        cmp byte [cs:cache_valid],1
        jne miss
        mov si,bx
        push es
        push di
        push cs
        pop es
        mov di,cache_name
        mov cx,16
.compare:
        lodsb
        scasb
        jne .different
        test al,al
        je hit
        loop .compare
.different:
        pop di
        pop es
        jmp short miss
hit:
        pop di
        pop es
        mov bx,di              ; Kernel's exec_from_disk relies on this result
        push ds
        push cs
        pop ds
        mov si,cache_data
        mov cx,sector_size/2
        rep movsw
        pop ds
        clc
        jmp short return_cf
miss:
        push bx
        push ds
        push es
        push di
        pushf
        call far [cs:old_load]  ; Original service returns through IRET
        pop di
        pop es
        pop ds
        pop bx
        jc failed
        push ds
        push es
        push di
        mov si,bx
        push cs
        pop es
        mov di,cache_name
        mov cx,16
.copy_name:
        lodsb
        stosb
        test al,al
        je fill
        loop .copy_name
        ; Do not cache unterminated names, even on an unpatched kernel.
        pop bx
        pop es
        pop ds
        mov byte [cs:cache_valid],0
        clc
        jmp short return_cf
fill:
        pop si                 ; Original caller's destination offset
        pop ds                 ; Original caller's destination segment
        mov bx,si
        mov di,cache_data
        mov cx,sector_size/2
        rep movsw
        mov byte [es:cache_valid],1
        push ds
        pop es
        pop ds
        clc
        jmp short return_cf
failed:
        mov bx,di
return_cf:
        mov bp,sp
        rcr byte [bp+4],1       ; Preserve all caller flags except CF
        rol byte [bp+4],1
        iret
old_load:
        dw 0,0
old_disk:
        dw 0,0
magic:
        dw 0xb05c
        times 510-($-$$) db 0x4f
        db 0x55,0xaa
