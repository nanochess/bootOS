	; by Ish.
	; Public domain from https://ish.works/bootsector/bootsector.html

bits 16 ; tell NASM this is 16 bit code
org 0x7c00 ; tell NASM that our code will be loaded at offset 0x7c00

%define CURRENT_LEVEL 0x1000
%define CURRENT_LEVEL_4 0x1004
%define SCREEN_DS 0xb800

boot:
    ; clear screen (re-set text mode)
    xor ah, ah
    mov al, 0x03  ; text mode 80x25 16 colours
    int 0x10

    ; disable cursor
    mov ah, 0x01
    mov ch, 0x3f
    int 0x10

    ; set up stack
    mov ax, 0x9000
    mov ss, ax
    mov sp, 0x400

    ; set current level to test level by copying
    mov si, test_level

    ; get width and height and multiply by each other
    mov ax, [si]
    mul ah

    ; set multiplied width and height + 4 as counter
    mov cx, ax
    ;add cx, 4

    mov di, CURRENT_LEVEL ; next address to copy to
    xor ax, ax
    mov es, ax

    ; copy map size and player position ("uncompressed")
    lodsw
    stosw
    lodsw
    stosw

.copy_level_loop:
    ; load "compressed" byte: e.g. 0x28 or 0x44 into AL
    lodsb

    mov ah, al     ; AX = 0x2828
    and ax, 0x0FF0 ; AX = 0x0820 (little endian: 20 08)
    shr al, 4      ; AX = 0x0802 (little endian: 02 08)

    ; save "uncompressed" word: e.g. 02 08 or 04 04 from AX
    stosw

    loop .copy_level_loop

    call draw_current_level

.mainloop:
    ; read key
    xor ax, ax
    int 0x16

    cmp ah, 0x01 ; esc
    je boot

    cmp ah, 0x50 ; down arrow
    je  .try_move_down

    cmp ah, 0x48 ; up arrow
    je  .try_move_up

    cmp ah, 0x4b ; left arrow
    je  .try_move_left

    cmp ah, 0x4d ; right arrow
    je  .try_move_right

.redraw:
    call draw_current_level

.check_win:

    ; get width and height
    mov ax, [CURRENT_LEVEL] ; al = width; ah = height
    mul ah
    mov cx, ax ; cx = size of map

    xor bx, bx ; bx = number of bricks-NOT-on-a-spot

    mov si, CURRENT_LEVEL_4
.check_win_loop:
    lodsb
    cmp al, 2
    jne .not_a_brick
    inc bx
.not_a_brick:
    loop .check_win_loop

    ; so, did we win? is the number of spotless bricks == 0??
    cmp bx, 0
    je win
    jmp .mainloop


.try_move_down:
    mov al, byte [CURRENT_LEVEL] ; (width of current level) to the right = 1 down
    call try_move
    jmp .redraw

.try_move_up:
    mov al, byte [CURRENT_LEVEL]
    neg al ; (width of current level) to the left = 1 up
    call try_move
    jmp .redraw

.try_move_left:
    mov al, -1 ; one to the left
    call try_move
    jmp .redraw

.try_move_right:
    mov al, 1 ; one to the right
    call try_move
    jmp .redraw

win:
    ; print a nice win message to the middle of the screen
    mov si, str_you_win

    ; destination position on screen
    mov ax, SCREEN_DS
    mov es, ax
    mov di, (80 * 12 + 40 - 6) * 2

    mov ah, 0x0F
.loop:
    lodsb

    cmp al, 0
    je wait_for_esc

    stosw
    jmp .loop

wait_for_esc:
    ; read key
    xor ax, ax
    int 0x16

    cmp ah, 0x01 ; esc
    je boot
    jmp wait_for_esc
; halt:
;     cli ; clear interrupt flag
;     hlt ; halt execution


;; functions:

draw_current_level:
    ; get width and height
    mov cx, [CURRENT_LEVEL] ; cl = width; ch = height
    push cx ; put it in the stack for later reuse

    ; print in the middle and not in the corner
    mov di, 2000; middle of screen

    ; offset by half of width
    mov bl, cl
    and bx, 0x00FE
    sub di, bx

    ; offset by half of height
    mov cl, ch
    and cx, 0x00FE
    mov ax, 80
    mul cx
    sub di, ax


    mov si, CURRENT_LEVEL_4 ; source byte

    ; screen memory in text mode
    mov ax, SCREEN_DS
    mov es, ax

.loop:
    mov bl, [si]
    xor bh, bh
    add bx, bx
    add bx, display_chars
    mov dx, [bx]
    mov [es:di], dx

    inc si
    add di, 2
    pop cx ; get counters
    dec cl ; subtract 1 from X axis counter
    jz  .nextrow
    push cx
    jmp .loop

.nextrow:
    dec ch ; subtract 1 from Y axis counter
    jz  .finished
    mov cl, [CURRENT_LEVEL]
    push cx

    ; jump to next row down
    xor ch, ch
    neg cx
    add cx, 80
    add cx, cx
    add di, cx

    jmp .loop

.finished:
    ret

try_move:
    ; try to move the player
    ; al = offset of how much to move by
    pusha

    ; extend al into ax (signed)
    test al, al ; check if negative
    js .negative_al
    xor ah, ah
    jmp .after_al
.negative_al:
    mov ah, 0xFF
.after_al:
    push ax

    ; calculate total level size
    mov ax, [CURRENT_LEVEL]
    mul ah

    ; calculate requested destination position
    pop bx
    push bx
    mov dx, [CURRENT_LEVEL + 2]
    add bx, dx

    ; check if in bounds
    cmp bx, 0
    jl  .finished
    cmp bx, ax
    jg  .finished

    ; get value at destination position
    mov cl, [CURRENT_LEVEL_4 + bx]
    cmp cl, 4
    je .cant_push ; it's a wall
    test cl, 0x02
    jz .dont_push ; it's not a brick (on spot, or not), so don't try pushing

    ; try pushing brick
    pop cx ; get move offset
    push bx ; store player's destination position (brick's current position)

    mov dx, bx ; dx = current brick position
    add bx, cx ; bx = next brick position

    ; check bounds
    cmp bx, 0
    jl  .cant_push
    cmp bx, ax
    jg  .cant_push

    ; get value at destination position
    mov ch, [CURRENT_LEVEL_4 + bx]
    test ch, 0x0E ; test if the destination is occupied at all by ANDing with 0000 1110
    jnz .cant_push

    ; all checks passed! push the brick

    ; add new brick to screen
    or ch, 0x02 ; add brick bit, by ORing with 0000 0010
    mov [CURRENT_LEVEL_4 + bx], ch

    ; remove old brick from screen
    mov si, dx
    mov cl, [CURRENT_LEVEL_4 + si]
    and cl, 0xFD ; remove brick bit, by ANDing with 1111 1101
    mov [CURRENT_LEVEL_4 + si], cl

    mov dx, [CURRENT_LEVEL + 2] ; dx = current player position
    pop bx ; bx = next player position
    jmp .redraw_player

.cant_push:
    pop bx
    jmp .finished

.dont_push:
    pop cx ; don't need to have this offset in the stack anymore

.redraw_player:
    ; remove old player from screen
    mov si, dx
    mov cl, [CURRENT_LEVEL_4 + si]
    and cl, 0xF7 ; remove player bit, by ANDing with 1111 0111
    mov [CURRENT_LEVEL_4 + si], cl

    ; add new player to screen
    mov ch, [CURRENT_LEVEL_4 + bx]
    or ch, 0x08 ; add player bit, by ORing with 0000 1000
    mov [CURRENT_LEVEL_4 + bx], ch

    ; update player position in memory
    mov [CURRENT_LEVEL + 2], bx

.finished:

    popa
    ret


; data section:

;  0000 0000 EMPTY
;  0000 0001 SPOT
;  0000 0010 BRICK
;  0000 0011 BRICK ON SPOT
;  0000 0100 WALL
;  0000 1000 PLAYER
;  0000 1001 PLAYER ON SPOT
test_level:
    ; this was the original level format, which was quite big:

    ; db 9, 7 ; width, height
    ; dw 32 ; playerxy
    ; db 4,4,4,4,4,4,0,0,0
    ; db 4,0,0,0,0,4,0,0,0
    ; db 4,0,0,2,0,4,4,0,0
    ; db 4,0,2,4,1,9,4,4,4
    ; db 4,4,0,0,3,1,2,0,4
    ; db 0,4,0,0,0,0,0,0,4
    ; db 0,4,4,4,4,4,4,4,4
    ; db 14, 10 ;width, height
    ; dw 63     ;playerxy

    ; when i tried to put in THIS level (from https://www.youtube.com/watch?v=fg8QImlvB-k)
    ; i passed the 512 byte limit...

    ; db 4,4,4,4,4,4,4,4,4,4,4,4,0,0
    ; db 4,1,1,0,0,4,0,0,0,0,0,4,4,4
    ; db 4,1,1,0,0,4,0,2,0,0,2,0,0,4
    ; db 4,1,1,0,0,4,2,4,4,4,4,0,0,4
    ; db 4,1,1,0,0,0,0,8,0,4,4,0,0,4
    ; db 4,1,1,0,0,4,0,4,0,0,2,0,4,4
    ; db 4,4,4,4,4,4,0,4,4,2,0,2,0,4
    ; db 0,0,4,0,2,0,0,2,0,2,0,2,0,4
    ; db 0,0,4,0,0,0,0,4,0,0,0,0,0,4
    ; db 0,0,4,4,4,4,4,4,4,4,4,4,4,4

    ; so i compressed it! high nybble first, low nybble second
    db 14, 10 ;width, height
    dw 63     ;playerxy
    db 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x00
    db 0x41, 0x10, 0x04, 0x00, 0x00, 0x04, 0x44
    db 0x41, 0x10, 0x04, 0x02, 0x00, 0x20, 0x04
    db 0x41, 0x10, 0x04, 0x24, 0x44, 0x40, 0x04
    db 0x41, 0x10, 0x00, 0x08, 0x04, 0x40, 0x04
    db 0x41, 0x10, 0x04, 0x04, 0x00, 0x20, 0x44
    db 0x44, 0x44, 0x44, 0x04, 0x42, 0x02, 0x04
    db 0x00, 0x40, 0x20, 0x02, 0x02, 0x02, 0x04
    db 0x00, 0x40, 0x00, 0x04, 0x00, 0x00, 0x04
    db 0x00, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44



display_chars: db 0,   0x07 ; blank
               db 249, 0x07 ; spot
               db 4,   0x0C ; brick
               db 4,   0x0A ; brick on spot
               db 178, 0x71 ; wall
               db "5", 0x07 ; (no 5)
               db "6", 0x07 ; (no 6)
               db "7", 0x07 ; (no 7)
               db 1,   0x0F ; player
               db 1,   0x0F ; player on spot

str_you_win: db 'YOU WIN! ',1,1,1,0

times 510 - ($-$$) db 0 ; pad remaining 510 bytes with zeroes
dw 0xaa55 ; magic bootloader magic - marks this 512 byte sector bootable!

; if you don't want your resulting file to be as big as a floppy, then comment the following line:

times (1440 * 1024) - ($-$$) db 0 ; pad with zeroes to make a floppy-sized image