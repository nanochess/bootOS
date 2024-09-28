org 0x7e00

stack:  equ 0x7700
line:   equ 0x7780
sector: equ 0x7800
osbase: equ 0x7e00

entry_size:     equ 16
sector_size:    equ 512
max_entries:    equ sector_size/entry_size

start:
        mov ax, 0x0003
        int 0x10

        mov ax, 0x0600
        mov bh, 0x07
        mov cx, 0
        mov dx, 0
        int 0x10

        xor ax,ax
        mov ds,ax
        mov es,ax
        mov ss,ax
        mov sp,stack

        mov si,int_0x20
        mov di,0x0020*4
        mov cl,6
.load_vec:
        movsw
        stosw
        loop .load_vec

info_command:
        mov si,intro

print_then_restart:
        call output_string
        int int_restart

restart:
        cld
        push cs
        push cs
        push cs
        pop ds
        pop es
        pop ss
        mov sp,stack

        mov al,'>'
        call input_line

        cmp byte [si],0x00
        je restart

        mov di,commands

command_execution:
        cmp byte [si], 0
        je restart

        cmp byte [si], '/'
        je exec_from_disk

        mov cl, [di]
        inc di
        xor ch, ch
        push si
        rep cmpsb
        jne compare_command
        call word [di]
        jmp restart

compare_command:
        add di, cx
        scasw
        pop si
        jmp command_execution

exec_from_disk:
        inc si
        cmp byte [si], 0
        je file_not_found_error

        mov bx, si
        mov di, osbase
        int int_load_file

        jc file_not_found_error

        jmp bx

file_not_found_error:
        mov si, not_found_msg
        call print_multiline
        jmp restart

not_found_msg:
        db "Not found.", 13, 10, 0

rm_command:
os22:
        mov bx,si
        lodsb
        cmp al,0x20
        je os22
        int int_delete_file
        jc file_not_found_error
        ret

ls_command:
        call read_dir
        mov di,bx
entry_reading_loop:
        cmp byte [di],0
        je next_entry_check
        mov si,di
        call output_string
next_entry_check: call next_entry
        jne entry_reading_loop
        ret

filename_length:
        push si
        xor cx,cx
.loop:
        lodsb
        inc cx
        cmp al,0
        jne .loop

        pop si
        mov di,sector
        ret

load_file:
        push di
        push es
        call find_file
        mov ah,0x02
shared_file:
        pop es
        pop bx
        jc ret_cf
        call disk

ret_cf:
        mov bp,sp
        rcl byte [bp+4],1
        iret

save_file:
        push di
        push es
        push bx
        int int_delete_file
        pop bx
        call filename_length

.find:  es cmp byte [di],0
        je .empty
        call next_entry
        jne .find
        jmp shared_file

.empty: push di
        rep movsb
        call write_dir
        pop di
        call get_location
        mov ah,0x03
        jmp shared_file

delete_file:
        call find_file
        jc ret_cf
        mov cx,entry_size
        call write_zero_dir
        jmp ret_cf

find_file:
        push bx
        call read_dir
        pop si
        call filename_length
find_file_loop:
        push si
        push di
        push cx
        repe cmpsb
        pop cx
        pop di
        pop si
        je get_location
        call next_entry
        jne find_file_loop
        ret

next_entry:
        add di,byte entry_size
        cmp di,sector+sector_size
        stc
        ret

get_location:
        lea ax,[di-(sector-entry_size)]

        mov cl,4
        shl ax,cl
        add ax,3
        xchg ax,cx
        ret

ft_command:
        mov di,sector
        mov cx,sector_size
        call write_zero_dir
        mov bx,osbase
        dec cx
        jmp short disk

read_dir:
        push cs
        pop es
        mov ah,0x02
        jmp short disk_dir

write_zero_dir:
        mov al,0
        rep stosb

write_dir:
        mov ah,0x03
disk_dir:
        mov bx,sector
        mov cx,0x0004

disk:
        push ax
        push bx
        push cx
        push es
        mov al,0x01
        xor dx,dx
        int 0x13
        pop es
        pop cx
        pop bx
        pop ax
        jc disk
        ret

input_line:
        int int_output_char
        mov si, line
        mov di, si
        mov cx, 1

input_line_loop:
        xor ah, ah
        int 0x16

        cmp al, 0x08
        je handle_backspace

        cmp al, 0x0D
        je end_input

        cmp cx, 80
        jae input_line_loop

        stosb
        inc cx
        mov ah, 0x0E
        int 0x10
        jmp input_line_loop

handle_backspace:
        cmp cx, 1
        jle input_line_loop

        dec di
        dec cx
        mov ah, 0x0E
        mov al, 0x08
        int 0x10
        mov al, ' '
        int 0x10
        mov al, 0x08
        int 0x10
        jmp input_line_loop

end_input:
        mov al, 0
        stosb
        mov ah, 0x0E
        mov al, 0x0D
        int 0x10
        mov al, 0x0A
        int 0x10
        mov si, line
        ret

input_key:
        mov ah,0x00
        int 0x16

output_char:
        cmp al,0x0d
        jne output_character
        mov al,0x0a
        int int_output_char
        mov al,0x0d
output_character:
        mov ah,0x0e
        mov bx,0x0007
        int 0x10
        iret

output_string:
        lodsb
        int int_output_char
        cmp al,0x00
        jne output_string
        mov al,0x0d
        int int_output_char
        ret

print_multiline:
    lodsb
    cmp al, 0
    je .done
    mov ah, 0x0E
    int 0x10
    jmp print_multiline
.done:
    ret

hexedit_command:
        mov di,osbase
enter_command: push di
        mov al,'#'
        call input_line
        pop di
        cmp byte [si],0
        je filename_input
hex_input_loop: call xdigit
        jnc enter_command
        mov cl,4
        shl al,cl
        xchg ax,cx
        call xdigit
        or al,cl
        stosb
        jmp hex_input_loop
filename_input:
        mov al,'*'
        call input_line
        push si
        pop bx
        mov di,osbase
        int int_save_file
        ret
xdigit:
        lodsb
        cmp al,0x00
        je error_handling
        sub al,0x30
        jc xdigit
        cmp al,0x0a
        jc error_handling
        sub al,0x07
        and al,0x0f
        stc
error_handling:
        ret

intro:
        db "3secOS",0

error_message:
        db "ERR",0

help_message:
    db "Available commands:", 13, 10
    db "  ls - List files", 13, 10
    db "  ft - Format disk", 13, 10
    db "  rm - Remove file", 13, 10
    db "  hx - Hexadecimal editor", 13, 10
    db "  i  - Show this help", 13, 10, 0

help_command:
    mov si, help_message
    call print_multiline
    ret

commands:
        db 2,"ls"
        dw ls_command
        db 2,"ft"
        dw ft_command
        db 1,"h"
        dw hexedit_command
        db 2,"rm"
        dw rm_command
        db 1,"i"
        dw help_command
        db 0
        dw exec_from_disk

int_restart:            equ 0x20
int_input_key:          equ 0x21
int_output_char:        equ 0x22
int_load_file:          equ 0x23
int_save_file:          equ 0x24
int_delete_file:        equ 0x25

int_0x20:
        dw restart
        dw input_key
        dw output_char
        dw load_file
        dw save_file
        dw delete_file

        times 1024-($-$$) db 0x4f