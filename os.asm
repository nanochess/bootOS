        ;
        ; bootOS, an operating system in 512 bytes
        ;
        ; by Oscar Toledo G.
        ; http://nanochess.org/
        ;
        ; Creation date: Jul/21/2019. 6pm 10pm
        ; Revision date: Jul/22/2019. Optimization, corrections and comments.
        ;

        cpu 8086

        ;
        ; What is bootOS:
        ; 
        ;   bootOS is a monolithic operating system that fits in
        ;   one boot sector. It's able to load, execute, and save
        ;   programs. Also keeps a filesystem. It can work with
        ;   any floppy disk size starting at 180K.
        ; 
        ;   It relocates itself at 0000:7a00 and requires further
        ;   768 bytes of memory starting at 0000:7700.
        ; 
        ;   This operating system runs programs as boot sectors
        ;   at 0000:7c00. 
        ; 
        ;   It provides a single service to exit to the operating
        ;   system using int 0x20.
        ; 
        ; 
        ; Filesystem organization:
        ; 
        ;   bootOS uses tracks from 0 to 32, side 0, sector 1.
        ; 
        ;   The directory is contained in track 0, side 0, sector 2.
        ; 
        ;   Each entry in the directory is 16 bytes wide, and
        ;   contains the ASCII name of the file finished with a
        ;   zero byte. A sector has a capacity of 512 bytes, it
        ;   means only 32 files can be kept on a floppy disk.
        ; 
        ;   Deleting a file is a matter of zeroing a whole entry.
        ; 
        ;   Each file is one sector long. Its location in the
        ;   disk is derived from its position in the directory.
        ; 
        ;   The 1st file is located at track 1, side 0, sector 1.
        ;   The 2nd file is located at track 2, side 0, sector 1.
        ;   The 32nd file is located at track 32, side 0, sector 1.
        ; 
        ; 
        ; Starting bootOS:
        ;   Just make sure to write it at the boot sector of a
        ;   floppy disk. It can work with any floppy disk size
        ;   (360K, 720K, 1.2MB and 1.44MB) and it will waste the
        ;   disk space as only uses the first two sectors of the
        ;   disk and then the first sector of each following
        ;   track.
        ;
        ;   For emulation make sure to deposit it at the start
        ;   of a .img file of 360K, 720K or 1440K. (at least
        ;   VirtualBox detects the type of disk by the length
        ;   of the image file)
        ;
        ;   For Mac OS X and Linux you can create a 360K image
        ;   in this way:
        ; 
        ;     dd if=/dev/zero of=oszero.img count=719 bs=512
        ;     cat os.img oszero.img >osbase.img
        ; 
        ;   Replace 719 with 1439 for 720K, or 2879 for 1.44M.
        ; 
        ;   Tested with VirtualBox for Mac OS X running Windows XP
        ;   running it, it also works with qemu:
        ; 
        ;     qemu-system-x86_64 -fda os.img
        ; 
        ; Running bootOS:
        ;   The first time you should enter the 'format' command,
        ;   so it initializes the directory. It also copies itself
        ;   again to the boot sector, this is useful to init new
        ;   disks.
        ;
        ; bootOS commands:
        ;   ver           Shows the version (none at the moment)
        ;   dir           Shows the directory's content.
        ;   del filename  Deletes the "filename" file.
        ;   format        As explained before.
        ;   enter         Allows to enter up to 512 hexadecimal
        ;                 bytes to create another file.
        ;
        ;                 Notice the line size is 128 characters so
        ;                 you must break the input into chunks of
        ;                 4, 8 or 16 bytes.
        ;
        ; For example: (Character + is Enter key)
        ;   $enter+
        ;   hbb 17 7c 8a 07 84 c0 74 0c 53 b4 0e bb 0f 00 cd+
        ;   h10 5b 43 eb ee cd 20 48 65 6c 6c 6f 2c 20 77 6f+
        ;   h72 6c 64 0d 0a 00+
        ;   h+
        ;   *hello+
        ;   $dir+
        ;   hello
        ;   $hello+
        ;   Hello, world
        ;   $
        ;
        ; bootOS programs: (Oh yes! we have software support)
        ;
        ;   fbird         https://github.com/nanochess/fbird
        ;   Pillman       https://github.com/nanochess/pillman
        ;   invaders      https://github.com/nanochess/invaders
        ;   bootBASIC     https://github.com/nanochess/bootBASIC
        ;
        ; You can copy the machine code directly using the 'enter'
        ; command, or you can create a file with signature bytes
        ; with the same command and later copy the binary into the
        ; .img file using the signature bytes as a clue to locate
        ; the right position in the image file.
        ;
        ; Or you can find a pre-designed disk image along this Git
        ; with the name osall.img
        ;

        org 0x7c00

stack:  equ 0x7700      ; Stack pointer (grows to lower addresses)
line:   equ 0x7780      ; Buffer for line input
sector: equ 0x7800      ; Sector data for directory
osbase: equ 0x7a00      ; bootOS location
boot:   equ 0x7c00      ; Boot sector location  

entry_size:        equ 16        ; Directory entry size
sector_size:    equ 512 ; Sector size

        ;
        ; Notice the mantra: label-boot+osbase
        ;
        ; This is because bootOS is assembled at boot sector
        ; location but it will run at 0x7a00 (osbase label),
        ; while the 0x7c00 location will be replaced by the
        ; executed programs.
        ;

        ;
        ; Cold start of bootOS
        ;
start:
        xor ax,ax       ; Set all segments to zero
        mov ds,ax
        mov es,ax
        mov ss,ax
        mov sp,stack    ; Set stack to guarantee data safety

        cld             ; Clear D flag.
        mov si,boot     ; Copy bootOS boot sector...
        mov di,osbase   ; ...into osbase
        mov cx,sector_size
        rep movsb

        mov si,int_0x20 ; Address of service for...
        mov di,0x0020*4 ; ...int 0x20
        movsw           ; Copy IP address
        movsw           ; Copy CS address

        ;
        ; 'ver' command
        ;
ver_command:
        mov si,intro-boot+osbase
        call output_string

        db 0xea         ; Save bytes, JMP FAR to following vector

int_0x20:
        dw restart-boot+osbase,0x0000   ; IP:CS

        ;
        ; "Warm" start of bootOS
        ;
restart:
        cld             ; Clear D flag.
        push cs         ; Reinit all segment registers
        push cs
        push cs
        pop ds
        pop es
        pop ss
        mov sp,stack    ; Restart stack

        mov al,'$'      ; Command prompt
        call input_line ; Input line

        cmp byte [si],0x00  ; Empty line?
        je restart        ; Yes, get another line

        mov di,commands-boot+osbase ; Point to commands list

os11:   mov al,[di]     ; Read length of command in chars
        inc di
        and ax,0x00ff   ; Is it zero?
        je os12         ; Yes, jump
        xchg ax,cx
        push si         ; Save current position
        rep cmpsb       ; Compare statement
        jne os14        ; Equal? No, jump
        call word [di]  ; Call command process
        jmp restart     ; Get another line

os14:   add di,cx       ; Advance the list pointer
        inc di          ; Avoid the address
        inc di
        pop si
        jmp os11        ; Compare another statement

os12:   push si         ; Input pointer
        pop bx
        mov di,boot     ; Location to read data
        call load_file  ; Load file
        jc os7          ; Jump if error
        jmp boot+boot-osbase    ; Jump to loaded file

        ;
        ; File not found error
        ;
os7:
        mov si,error_message-boot+osbase
        call output_string
        jmp restart     ; Go to expect another command

error_message:
        db "Nope",0x0d,0

        ;
        ; 'dir' command
        ;
dir_command:
        call read_dir   ; Read the directory

        mov si,sector   ; Point to sector
os18:
        cmp byte [si],0         ; Empty entry?
        je os17                 ; Yes, jump
        push si
        call output_string      ; Show name
        call new_line           ; Next line on screen
        pop si
os17:   add si,entry_size       ; Advance one entry
        cmp si,sector+sector_size       ; Finished sector?
        jne os18                ; No, jump
        ret                     ; Return

        ;
        ; 'format' command
        ;
format_command:
        mov ah,0x03     ; Copy bootOS onto first sector
        mov bx,osbase
        mov cx,0x0001
        call disk
        mov di,sector   ; Fill whole sector to zero
        mov cx,sector_size
        mov al,0
        rep stosb
        jmp write_dir   ; Save it as directory

        ;
        ; Get filename length and prepare for directory lookup
        ; Entry:
        ;   SI = pointer to string
        ; Output:
        ;   SI = unaffected
        ;   DI = pointer to start of directory
        ;
filename_length:
        push si
        xor cx,cx       ; cx = 0
os5:
        lodsb           ; Read character.
        inc cx          ; Count character.
        cmp al,0        ; Is it zero (end character)?
        jne os5         ; No, jump.
        dec cx          ; Don't count termination character.

        pop si
        mov di,sector   ; Point to start of directory.
os4:
        ret
        
        ;
        ; Load file
        ; bx = Pointer to filename ended with zero byte.
        ; di = Destination.
        ;
load_file:
        push di         ; Save destination
        call find_file  ; Find the file
        pop bx          ; Restore destination on BX
        jc os4          ; Jump if error
        mov ah,0x02     ; Read sector
        jmp disk        ; Read into BX buffer

        ;
        ; Save file
        ;
        ; Entry:
        ;   bx = Pointer to filename ended with zero byte.
        ;   di = Source.
        ; Output:
        ;   Carry flag = Set = error, clear = good.
        ;
save_file:
        push di
        push bx         ; Save filename pointer
        call delete_file ; Delete previous file
        pop bx          ; Restore filename pointer
        call filename_length    ; Prepare for lookup
os8:    mov al,[di]     ; Read first byte of directory entry
        cmp al,0        ; Is it zero?
        je os9          ; Yes, jump because empty entry.
        add di,entry_size       ; Go to next entry.
        cmp di,sector+sector_size       ; Full directory?
        jne os8         ; No, jump.
        pop bx
        stc             ; Yes, error.
        ret

os9:    push di
        rep movsb       ; Copy full name into directory
        call write_dir  ; Save directory
        pop di
        call get_location       ; Get location of file
        pop bx          ; Source data
        mov ah,0x03     ; Write sector
        jmp disk        ; Do operation with disk.

del_command:
os22:
        cmp byte [si],0x20      ; Avoid spaces
        jne os21
        inc si
        jmp os22

os21:   mov bx,si       ; Copy SI (buffer pointer) to BX
        ;
        ; Delete file
        ; bx = Pointer to filename ended with zero byte.
        ;
delete_file:
        call find_file  ; Find file
        jc os4          ; If carry set then not found, jump.
        mov cx,entry_size
        mov al,0
        rep stosb       ; Fill whole entry with zero.
        jmp write_dir   ; Write directory.

        ;
        ; Find file
        ; Entry:
        ;   bx = Pointer to filename ended with zero byte.
        ; Result:
        ;   di = Pointer to directory entry
        ;   Carry flag = Clear if found, set if not found.
find_file:
        push bx
        call read_dir   ; Read directory
        pop si
        call filename_length    ; Get filename length and setup DI
os6:        push si
        push di
        push cx
        repe cmpsb      ; Compare name with entry
        pop cx
        pop di
        pop si
        je get_location ; Jump if equal.

        add di,entry_size       ; Go to next entry.
        cmp di,sector+sector_size       ; Complete directory?
        jne os6         ; No, jump
        stc             ; Error, not found.
        ret             ; Return

        ;
        ; Get location of file on disk
        ;
        ; Entry:
        ;   DI = Pointer to entry in directory.
        ;
        ; Result
        ;   CH = Track number in disk.
        ;   CL = Sector (always 0x01).
        ;
        ; The position of a file inside the disk depends on its
        ; position in the directory. The first entry goes to
        ; track 1, the second entry to track 2 and so.
        ;
get_location:
        mov ax,di       ; Get entry pointer into directory
        sub ax,sector   ; Get offset from start of directory
        mov cl,4        ; 2^4 = entry_size
        shr ax,cl       ; Shift right and clear Carry flag
        inc ax          ; Files start at track 1
        mov ch,al       ; CH = Track
        mov cl,0x01     ; CL = Sector
        ret

        ;
        ; Read the directory from disk
        ;
read_dir:
        mov ah,0x02
        db 0xb9         ; jmp more_dir
                        ; but instead MOV CX, to jump over opcode
        ;
        ; Write the directory to disk
        ;
write_dir:
        mov ah,0x03
        mov bx,sector
        mov cx,0x0002
disk:
        push ax
        push bx
        push cx
        push es
        mov al,0x01     ; AL = 1 sector
        xor dx,dx       ; DH = Drive A. DL = Head 0.
        int 0x13
        pop es
        pop cx
        pop bx
        pop ax
        jc disk
        ret

        ;
        ; Input line from keyboard
        ; Entry:
        ;   al = prompt character
        ; Result:
        ;   buffer 'line' contains line, finished with CR
        ;   SI points to 'line'.
        ;
input_line:
        call output     ; Output prompt character
        mov si,line     ; Setup SI and DI to start of line buffer
        push si
        pop di          ; Target for writing line
os1:    call input_key  ; Read keyboard
        cmp al,0x08     ; Backspace?
        jne os2         ; No, jump
        dec di          ; Get back one character
        jmp os1         ; Wait another key

os2:    cmp al,0x0d     ; CR pressed?
        jne os10
        mov al,0x00
os10:
        stosb           ; Save key in buffer
        jne os1         ; No, wait another key
        ret             ; Yes, return

        ;
        ; Output string
        ;
        ; Entry:
        ;   si = address
        ;
output_string:
        lodsb           ; Read character
        cmp al,0x00     ; Is it 0x00?
        je os15         ; Yes, terminate
        call output     ; Output to screen
        jmp output_string       ; Repeat loop

        ;
        ; Read a key into al
        ; Also outputs it to screen
        ;
input_key:
        mov ah,0x00
        int 0x16
        ;
        ; Screen output of character contained in al
        ; Expands 0x0d (CR) into 0x0a 0x0d (LF CR)
        ;
output:
        cmp al,0x0d
        jne os3
        ;
        ; Go to next line (generates LF+CR)
        ;
new_line:
        mov al,0x0a
        call os3
        mov al,0x0d
os3:
        mov ah,0x0e
        mov bx,0x0007
        int 0x10
os15:
        ret

        ;
        ; 'enter' command
        ;
enter_command:
        mov di,boot             ; Point to boot sector
os23:   push di
        mov al,'h'              ; Prompt character
        call input_line         ; Input line
        pop di
        cmp byte [si],0         ; Empty line?
        je os20                 ; Yes, jump
os19:   call xdigit             ; Get a hexadecimal digit
        jnc os23
        mov cl,4
        shl al,cl
        xchg ax,cx
        call xdigit             ; Get a hexadecimal digit
        or al,cl
        stosb                   ; Write one byte
        jmp os19                ; Repeat loop to complete line
os20:        
        mov al,'*'              ; Prompt character
        call input_line         ; Input line with filename
        push si
        pop bx
        mov di,boot             ; Point to data entered
        jmp save_file           ; Save new file

        ;
        ; Convert ASCII letter to hexadecimal digit
        ;
xdigit:
        lodsb
        cmp al,0x20             ; Avoid spaces
        jz xdigit
        cmp al,0x00             ; Zero character marks end of line
        je os15
        cmp al,0x40
        jnc os16
        sub al,0x30
        stc
        ret

os16:   sub al,0x37
        and al,0x0f
        stc
        ret

        ;
        ; Our amazing presentation line
        ;
intro:
        db "bootOS",0x0d,0

        ;
        ; Commands supported by bootOS
        ;
commands:
        db 3,"dir"
        dw dir_command-boot+osbase
        db 6,"format"
        dw format_command-boot+osbase
        db 5,"enter"
        dw enter_command-boot+osbase
        db 3,"del"
        dw del_command-boot+osbase
        db 3,"ver"
        dw ver_command-boot+osbase
        db 0

        times 510-($-$$) db 0x4f
        db 0x55,0xaa            ; Make it a bootable sector
