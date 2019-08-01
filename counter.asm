        ;
        ; Shows how to use bootOS services
        ;
        ; by Oscar Toledo G.
        ; http://nanochess.org/
        ;
        ; Creation date: Jul/31/2019.
        ;

        org 0x7c00

        ;
        ; These segment values and addresses are for
        ; testing the correct bootOS behavior.
        ;
name_segment:    equ 0x1000
name_address:    equ 0x0100

data_segment:    equ 0x1100
data_address:    equ 0x0200

start:
        mov ax,name_segment
        mov es,ax

        mov si,name
        mov di,name_address
        mov bx,di
        mov cx,9
        rep movsb

        push es
        pop ds                  ; ds:bx ready pointing to filename

        mov ax,data_segment
        mov es,ax
        mov di,data_address     ; es:di ready pointing to data

        push bx
        push ds
        push di
        push es
        int 0x23                ; Load file.
        pop ds
        pop di
        push di
        push ds
        mov al,'*'              ; Exists.
        jnc .1
        mov al,'?'              ; Doesn't exist.
        mov word [di],0x0000    ; Setup counter to zero.
.1:
        int 0x22                ; Output character.

        mov ax,[di]             ; Read data.

        inc al                  ; Increase right digit.
        cmp al,10               ; Is it 10?
        jne .2                  ; No, jump.
        mov al,0                ; Reset to zero.

        inc ah                  ; Increase left digit.
        cmp ah,10               ; Is it 10?
        jne .2                  ; No, jump.
        mov ah,0                ; Reset to zero.

.2:     mov [di],ax             ; Save data.

        push ax
        mov al,ah
        add al,'0'              ; Convert to ASCII.
        int 0x22                ; Output character.
        pop ax

        add al,'0'              ; Convert to ASCII.
        int 0x22                ; Output character.

        mov al,0x0d             ; Go to next row on screen.
        int 0x22                ; Output character.

        pop es
        pop di
        pop ds
        pop bx
        int 0x24                ; Save file.

        int 0x20                ; Return to bootOS.

name:   db "data.bin",0         ; Filename.

