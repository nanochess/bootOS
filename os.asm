        ;
        ; bootOS, an operating system in 512 bytes
        ;
        ; by Oscar Toledo G.
        ; http://nanochess.org/
        ;
        ; Creation date: Jul/21/2019. 6pm 10pm
        ; Revision date: Jul/22/2019. Optimization, corrections and comments.
        ; Revision date: Jul/31/2019. Added a service table and allows
        ;                             filenames/sources/targets from any segment.
        ;                             'del' command now shows errors.
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
        ;   It provides the following services:
        ;      int 0x20   Exit to operating system.
        ;      int 0x21   Input key and show in screen.
        ;                 Entry: none
        ;                 Output: AL = ASCII key pressed.
        ;                 Affects: AH/BX/BP.
        ;      int 0x22   Output character to screen.
        ;                 Entry: AL = Character.
        ;                 Output: none.
        ;                 Affects: AH/BX/BP.
        ;      int 0x23   Load file.
        ;                 Entry: DS:BX = Filename terminated with zero.
        ;                        ES:DI = Point to source data (512 bytes)
        ;                 Output: Carry flag = 0 = Found, 1 = Not found.
        ;                 Affects: All registers (including ES).
        ;      int 0x24   Save file.
        ;                 Entry: DS:BX = Filename terminated with zero.
        ;                        ES:DI = Point to data target (512 bytes)
        ;                 Output: Carry flag = 0 = Successful. 1 = Error.
        ;                 Affects: All registers (including ES).
        ;      int 0x25   Delete file.
        ;                 Entry: DS:BX = Filename terminated with zero.
        ;                 Affects: All registers (including ES).
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
        ;
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
        ;
        ;   The first time you should enter the 'format' command,
        ;   so it initializes the directory. It also copies itself
        ;   again to the boot sector, this is useful to init new
        ;   disks.
        ;
        ; bootOS commands:
        ;
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
        ;                 It also allows to copy the last executed
        ;                 program just press Enter when the 'h' prompt
        ;                 appears and type the new name.
        ;
        ; For example: (Character + is Enter key)
        ;   
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

stack:  equ 0x7700      ; Stack pointer (grows to lower addresses)
line:   equ 0x7780      ; Buffer for line input
sector: equ 0x7800      ; Sector data for directory
osbase: equ 0x7a00      ; bootOS location
boot:   equ 0x7c00      ; Boot sector location  

entry_size:     equ 16  ; Directory entry size
sector_size:    equ 512 ; Sector size
max_entries:    equ sector_size/entry_size

        ;
        ; Cold start of bootOS
        ;
        ; Notice it is loaded at 0x7c00 (boot) and needs to
        ; relocate itself to 0x7a00 (osbase), the instructions
        ; between 'start' and 'ver_command' shouldn't depend
        ; on the assembly location (osbase) because these
        ; are running at boot location (boot).
        ;
        org osbase
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

        mov si,int_0x20 ; SI now points to int_0x20 
        mov di,0x0020*4 ; Address of service for int 0x20
        mov cl,6
.load_vec:
        movsw           ; Copy IP address
        stosw           ; Copy CS address
        loop .load_vec

        ;
        ; 'ver' command
        ;
ver_command:
        mov si,intro
        call output_string
        int int_restart ; Restart bootOS

        ;
        ; Warm start of bootOS
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
        je restart          ; Yes, get another line

        mov di,commands ; Point to commands list

        ; Notice that filenames starting with same characters
        ; won't be recognized as such (so file dirab cannot be
        ; executed).
os11:
        mov al,[di]     ; Read length of command in chars
        inc di
        and ax,0x00ff   ; Is it zero?
        je os12         ; Yes, jump
        xchg ax,cx
        push si         ; Save current position
        rep cmpsb       ; Compare statement
        jne os14        ; Equal? No, jump
        call word [di]  ; Call command process
        jmp restart     ; Go to expect another command

os14:   add di,cx       ; Advance the list pointer
        inc di          ; Avoid the address
        inc di
        pop si
        jmp os11        ; Compare another statement

os12:   mov bx,si       ; Input pointer
        mov di,boot     ; Location to read data
        int int_load_file       ; Load file
        jc os7          ; Jump if error
        jmp bx

        ;
        ; File not found error
        ;
os7:
        mov si,error_message
        call output_string
        int int_restart ; Go to expect another command

        ;
        ; >> COMMAND <<
        ; del filename
        ;
del_command:
os22:
        mov bx,si       ; Copy SI (buffer pointer) to BX
        lodsb
        cmp al,0x20     ; Avoid spaces
        je os22
        int int_delete_file
        jc os7
        ret

        ;
        ; 'dir' command
        ;
dir_command:
        call read_dir           ; Read the directory
        mov di,bx
os18:
        cmp byte [di],0         ; Empty entry?
        je os17                 ; Yes, jump
        mov si,di               ; Point to data
        call output_string      ; Show name
os17:   call next_entry
        jne os18                ; No, jump
        ret                     ; Return

        ;
        ; Get filename length and prepare for directory lookup
        ; Entry:
        ;   si = pointer to string
        ; Output:
        ;   si = unaffected
        ;   di = pointer to start of directory
        ;   cx = length of filename including zero terminator
        ;
filename_length:
        push si
        xor cx,cx       ; cx = 0
.loop:
        lodsb           ; Read character.
        inc cx          ; Count character.
        cmp al,0        ; Is it zero (end character)?
        jne .loop       ; No, jump.

        pop si
        mov di,sector   ; Point to start of directory.
        ret
        
        ;
        ; >> SERVICE <<
        ; Load file
        ;
        ; Entry:
        ;   ds:bx = Pointer to filename ended with zero byte.
        ;   es:di = Destination.
        ; Output:
        ;   Carry flag = Set = not found, clear = successful.
        ;
load_file:
        push di         ; Save destination
        push es
        call find_file  ; Find the file (sanitizes ES)
        mov ah,0x02     ; Read sector
shared_file:
        pop es
        pop bx          ; Restore destination on BX
        jc ret_cf       ; Jump if error
        call disk       ; Do operation with disk
                        ; Carry guaranteed to be clear.
ret_cf:
        mov bp,sp
        rcl byte [bp+4],1       ; Insert Carry flag in Flags (automatic usage of SS)
        iret

        ;
        ; >> SERVICE <<
        ; Save file
        ;
        ; Entry:
        ;   ds:bx = Pointer to filename ended with zero byte.
        ;   es:di = Source.
        ; Output:
        ;   Carry flag = Set = error, clear = good.
        ;
save_file:
        push di                 ; Save origin
        push es
        push bx                 ; Save filename pointer
        int int_delete_file     ; Delete previous file (sanitizes ES)
        pop bx                  ; Restore filename pointer
        call filename_length    ; Prepare for lookup

.find:  es cmp byte [di],0      ; Found empty directory entry?
        je .empty               ; Yes, jump and fill it.
        call next_entry
        jne .find
        jmp shared_file

.empty: push di
        rep movsb               ; Copy full name into directory
        call write_dir          ; Save directory
        pop di
        call get_location       ; Get location of file
        mov ah,0x03             ; Write sector
        jmp shared_file

        ;
        ; >> SERVICE <<
        ; Delete file
        ;
        ; Entry:
        ;   ds:bx = Pointer to filename ended with zero byte.
        ; Output:
        ;   Carry flag = Set = not found, clear = deleted.
        ;
delete_file:
        call find_file          ; Find file (sanitizes ES)
        jc ret_cf               ; If carry set then not found, jump.
        mov cx,entry_size
        call write_zero_dir     ; Fill whole entry with zero. Write directory.
        jmp ret_cf

        ;
        ; Find file
        ;
        ; Entry:
        ;   ds:bx = Pointer to filename ended with zero byte.
        ; Result:
        ;   es:di = Pointer to directory entry
        ;   Carry flag = Clear if found, set if not found.
find_file:
        push bx
        call read_dir   ; Read directory (sanitizes ES)
        pop si
        call filename_length    ; Get filename length and setup DI
os6:
        push si
        push di
        push cx
        repe cmpsb      ; Compare name with entry
        pop cx
        pop di
        pop si
        je get_location ; Jump if equal.
        call next_entry
        jne os6         ; No, jump
        ret             ; Return

next_entry:
        add di,byte entry_size          ; Go to next entry.
        cmp di,sector+sector_size       ; Complete directory?
        stc                             ; Error, not found.
        ret

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
        lea ax,[di-(sector-entry_size)] ; Get entry pointer into directory
                        ; Plus one entry (files start on track 1)
        mov cl,4        ; 2^(8-4) = entry_size
        shl ax,cl       ; Shift left and clear Carry flag
        inc ax          ; AL = Sector 1
        xchg ax,cx      ; CH = Track, CL = Sector
        ret

        ;
        ; >> COMMAND <<
        ; format
        ;
format_command:
        mov di,sector   ; Fill whole sector to zero
        mov cx,sector_size
        call write_zero_dir
        mov bx,osbase   ; Copy bootOS onto first sector
        dec cx
        jmp short disk

        ;
        ; Read the directory from disk
        ;
read_dir:
        push cs         ; bootOS code segment...
        pop es          ; ...to sanitize ES register
        mov ah,0x02
        jmp short disk_dir

write_zero_dir:
        mov al,0
        rep stosb

        ;
        ; Write the directory to disk
        ;
write_dir:
        mov ah,0x03
disk_dir:
        mov bx,sector
        mov cx,0x0002
        ;
        ; Do disk operation.
        ;
        ; Input:
        ;   AH = 0x02 read disk, 0x03 write disk
        ;   ES:BX = data source/target
        ;   CH = Track number
        ;   CL = Sector number
        ;
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
        jc disk         ; Retry
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
        int int_output_char ; Output prompt character
        mov si,line     ; Setup SI and DI to start of line buffer
        mov di,si       ; Target for writing line
os1:    cmp al,0x08     ; Backspace?
        jne os2
        dec di          ; Undo the backspace write
        dec di          ; Erase a character
os2:    int int_input_key  ; Read keyboard
        cmp al,0x0d     ; CR pressed?
        jne os10
        mov al,0x00
os10:   stosb           ; Save key in buffer
        jne os1         ; No, wait another key
        ret             ; Yes, return

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
output_char:
        cmp al,0x0d
        jne os3
        mov al,0x0a
        int int_output_char
        mov al,0x0d
os3:
        mov ah,0x0e     ; Output character to TTY
        mov bx,0x0007   ; Gray. Required for graphic modes
        int 0x10        ; BIOS int 0x10 = Video
        iret

        ;
        ; Output string
        ;
        ; Entry:
        ;   SI = address
        ;
        ; Implementation:
        ;   It supposes that SI never points to a zero length string.
        ;
output_string:
        lodsb                   ; Read character
        int int_output_char     ; Output to screen
        cmp al,0x00             ; Is it 0x00 (terminator)?
        jne output_string       ; No, the loop continues
        mov al,0x0d
        int int_output_char
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
        int int_save_file       ; Save new file
        ret

        ;
        ; Convert ASCII letter to hexadecimal digit
        ;
xdigit:
        lodsb
        cmp al,0x00             ; Zero character marks end of line
        je os15
        sub al,0x30             ; Avoid spaces (anything below ASCII 0x30)
        jc xdigit
        cmp al,0x0a
        jc os15
        sub al,0x07
        and al,0x0f
        stc
os15:
        ret

        ;
        ; Our amazing presentation line
        ;
intro:
        db "bootOS",0

error_message:
        db "Oops",0

        ;
        ; Commands supported by bootOS
        ;
commands:
        db 3,"dir"
        dw dir_command
        db 6,"format"
        dw format_command
        db 5,"enter"
        dw enter_command
        db 3,"del"
        dw del_command
        db 3,"ver"
        dw ver_command
        db 0

int_restart:            equ 0x20
int_input_key:          equ 0x21
int_output_char:        equ 0x22
int_load_file:          equ 0x23
int_save_file:          equ 0x24
int_delete_file:        equ 0x25

int_0x20:
        dw restart          ; int 0x20
        dw input_key        ; int 0x21
        dw output_char      ; int 0x22
        dw load_file        ; int 0x23
        dw save_file        ; int 0x24
        dw delete_file      ; int 0x25

        times 510-($-$$) db 0x4f
        db 0x55,0xaa            ; Make it a bootable sector
