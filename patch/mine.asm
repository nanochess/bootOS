	; From https://gitlab.com/blevy/boot-sector-minesweeper
	; MIT license.
	; Modified to exit to bootOS by nanochess (Sep/16/2019)

BITS 16
CPU 686

;; CONSTANTS

;; Boot sector load address
%assign BootSector.Begin 0x7c00
%assign BootSector.Size 512
%assign BootSector.End BootSector.Begin + BootSector.Size

%assign WordSize 2

;; Address and dimensions of text buffer
%assign TextBuf.Seg 0xb800
%assign TextBuf.Width 40
%assign TextBuf.Height 25

;; Minefield dimensions
%assign Map.Width TextBuf.Width
%assign Map.Height TextBuf.Height
%assign Map.Size Map.Width * Map.Height

;; Keyboard scan codes
;; http://www.ctyme.com/intr/rb-0045.htm#Table6
%assign Key.Space 0x39
%assign Key.Up 0x48
%assign Key.Down 0x50
%assign Key.Left 0x4b
%assign Key.Right 0x4d

;; GLOBAL VARIABLES

;; TODO: Change global vars to a state struct

;; Global variables are stored after the boot sector at runtime. After the boot
;; sector, there is 480.5K of memory safe to use.
;; https://wiki.osdev.org/Memory_Map_(x86)#Overview

%assign Vars.Begin BootSector.End

;; TODO: Document these
%assign Map.Mines Vars.Begin
%assign Map.Unveiled Map.Mines + Map.Size

;; Distance between Map.Mines and Map.Unveiled
%assign Map.Mines.ToUnveiled (Map.Unveiled - Map.Mines)

;; Seed used for random number generation
%assign RandomSeed Map.Unveiled + Map.Size

%assign Vars.End RandomSeed + WordSize

%assign Vars.Size Vars.End - Vars.Begin

org BootSector.Begin

BootMine:
  ; VGA text mode 0x00
  ; 320x200 pixel resolution
  ; 40x25 text resolution
  ; 16 colors
  ; http://www.ctyme.com/intr/rb-0069.htm
  xor ax, ax
  int 0x10

;; Populate Map.Mines with mines
PopulateMines:
  mov di, Map.Mines
  mov cx, Map.Size
.Loop:
  ; ax = rdtsc() & 0b111 ? 0 : 1
  rdtsc
  test al, 0x07
  jz .Mine
.Empty:
  xor ax, ax
  jmp .WriteCell
.Mine:
  mov ax, 1
.WriteCell:
  stosb
  loop .Loop

;; Number empty cells with amount of neighboring mines
NumCells:
  mov di, Map.Unveiled
  mov cx, Map.Size
.Loop:
  ; Get digit for the cell at DI
  mov al, [di - Map.Mines.ToUnveiled]
  test ax, ax
  jz .Empty
.Mine:
  mov ax, '*'
  jmp .WriteCell
.Empty:
  mov ax, '0'

  ; Straight
  lea bx, [di - 1 - Map.Mines.ToUnveiled]
  call LeftIncIfMineAtCell
  lea bx, [di + 1 - Map.Mines.ToUnveiled]
  call RightIncIfMineAtCell
  lea bx, [di - Map.Width - Map.Mines.ToUnveiled]
  call IncIfMineAtCell
  lea bx, [di + Map.Width - Map.Mines.ToUnveiled]
  call IncIfMineAtCell

  ; Diagonal
  lea bx, [di - 1 - Map.Width - Map.Mines.ToUnveiled]
  call LeftIncIfMineAtCell
  lea bx, [di - 1 + Map.Width - Map.Mines.ToUnveiled]
  call LeftIncIfMineAtCell
  lea bx, [di + 1 - Map.Width - Map.Mines.ToUnveiled]
  call RightIncIfMineAtCell
  lea bx, [di + 1 + Map.Width - Map.Mines.ToUnveiled]
  call RightIncIfMineAtCell

  cmp ax, '0'
  jne .WriteCell
.Zero:
  mov ax, ' '
.WriteCell:
  stosb
  loop .Loop

ClearScreen:
  mov cx, Map.Size
  xor di, di
  mov ax, 0xa0 << 8 | '.'
  mov dx, TextBuf.Seg
  mov es, dx
.Loop:
  stosw
  loop .Loop

  xor dx, dx
  mov es, dx
  xor bp, bp

GameLoop:
  ; Get keystroke
  ; AH = BIOS scan code
  ; AL = ASCII character
  ; http://www.ctyme.com/intr/rb-1754.htm
  xor ax, ax
  int 0x16

.CmpUp:
  cmp ah, Key.Up
  jne .CmpDown
  sub bp, Map.Width
  jmp WrapCursor
.CmpDown:
  cmp ah, Key.Down
  jne .CmpLeft
  add bp, Map.Width
  jmp WrapCursor
.CmpLeft:
  cmp ah, Key.Left
  jne .CmpRight
  dec bp
  jmp WrapCursor
.CmpRight:
  cmp ah, Key.Right
  jne .CmpSpace
  inc bp
  jmp WrapCursor
.CmpSpace:
  cmp ah, Key.Space
  jne GameLoop

ClearCell:
  mov al, [bp + Map.Unveiled]
.CmpEmpty:
  cmp al, ' '
  jne .CmpMine
  call Flood
  jmp GameLoop
.CmpMine:
  cmp al, '*'
  jne .Digit
  jmp GameOver
.Digit:
  call TextBufSetCharAt

WrapCursor:
  cmp bp, Map.Size
  jb SetCursorPos
  xor bp, bp

SetCursorPos:
  xor bx, bx
  call GetCursorPos
  mov dh, al
  mov dl, ah
  ; Set cursor position
  ; DH = Row
  ; DL = Column
  ; http://www.ctyme.com/intr/rb-0087.htm
  mov ah, 0x02
  int 0x10

  jmp GameLoop

;; Split the linear cursor position in BP as COL:ROW in AH:AL
;;
;; Clobbered registers:
;;   * CL
GetCursorPos:
  mov ax, bp
  mov cl, Map.Width
  div cl
  ret

;; TODO: Use this method in more places
;;
;; Get the character at position BP in the text buffer in AL
;;
;; Clobbered registers:
;;   * DX
TextBufGetCharAt:
  push bp
  mov dx, TextBuf.Seg
  mov ds, dx
  add bp, bp
  mov al, [ds:bp]
  xor dx, dx
  mov ds, dx
  pop bp
  ret

;; TODO: Use this method in more places
;;
;; Put the character AL in the text buffer at position BP
;;
;; Clobbered registers:
;;   * DX
TextBufSetCharAt:
  push bp
  mov dx, TextBuf.Seg
  mov ds, dx
  add bp, bp
  mov [ds:bp], al
  xor dx, dx
  mov ds, dx
  pop bp
  ret

RightIncIfMineAtCell:
  push bx
  push ax
  push dx
  sub bx, Map.Mines
  mov ax, bx
  cwd
  mov bx, Map.Width
  idiv bx
  test dx, dx
  pop dx
  pop ax
  pop bx
  jz IncIfMineAtCell.RetZero
  jmp IncIfMineAtCell

LeftIncIfMineAtCell:
  push bx
  push ax
  push dx
  sub bx, Map.Mines
  mov ax, bx
  cwd
  mov bx, Map.Width
  idiv bx
  cmp dx, Map.Width - 1
  pop dx
  pop ax
  pop bx
  je IncIfMineAtCell.RetZero
;; TODO: Update comment
;;
;; Increment AX if there is a mine in Map.Mines at index BX, where BX is a
;; pointer inside Map.Mines. In the case where BX is outside Map.Mines, AX is
;; NOT incremented.
;;
;; Parameters
;;   * BX - Pointer inside Map.Mines
;; Clobbered registers
;;   * AX - either incremented or unchanged, depending on whether there is or
;;          isn't a mine at BX, respectively
IncIfMineAtCell:
  ; Bounds check
  cmp bx, Map.Mines
  jb .RetZero
  cmp bx, Map.Mines + Map.Size
  jae .RetZero
  ; Within map bounds. Dereference and add map pointer.
  add al, [bx]
  ret
.RetZero:
  ; Outside map bounds. Do not increment.
  ret

;; Flood fill empty cells
;;
;; Parameters:
;;   * BP - Cell index
;; Clobbered registers:
;;   * Yes [TODO]
Flood:
  push bp

  ; Base case: bounds check
  cmp bp, Map.Size
  jae .Ret

  ; Base case: visited cell
  call TextBufGetCharAt
  cmp al, '.'
  jne .Ret

  ; Body: unveil cell
  mov al, [bp + Map.Unveiled]
  call TextBufSetCharAt

  ; Base case: nonempty cell
  cmp al, ' '
  jne .Ret

  ; Recursive case: flood adjacent cells

  ; Flood up
  push bp
  sub bp, Map.Width
  call Flood
  pop bp

  ; Flood down
  push bp
  add bp, Map.Width
  call Flood
  pop bp

  ; Flood left
  call GetCursorPos
  test ah, ah
  jz .Right
  push bp
  dec bp
  call Flood
  pop bp

.Right:
  ; Flood right
  inc bp
  call GetCursorPos
  test ah, ah
  jz .Ret
  call Flood

.Ret:
  pop bp
  ret

GameOverStr:
  db 'GAME OVER'
%assign GameOverStr.Len $ - GameOverStr

;; Unveil all the mines, print "GAME OVER" text, and allow restarting
;; TODO: Finish this
GameOver:
  ; Print "GAME OVER" in center of screen
  mov ax, 0x1300
  mov bx, 0x00c0
  mov cx, GameOverStr.Len
  mov dx, ((TextBuf.Height / 2) << 8) | (TextBuf.Width / 2 - GameOverStr.Len / 2)
  mov bp, GameOverStr
  int 0x10

  ; Halt forever
  mov ah, 0x00
  int 0x16
  mov ax, 0x0002
  int 0x10
  int 0x20

;; Print program size at build time
%assign CodeSize $ - $$
;%warning Code is CodeSize bytes

CodeEnd:
  ; Pad to size of boot sector, minus the size of a word for the boot sector
  ; magic value. If the code is too big to fit in a boot sector, the `times`
  ; directive uses a negative value, causing a build error.
  times (BootSector.Size - WordSize) - CodeSize db 0

  ; Boot sector magic
  dw 0xaa55

;; Boot sector ends here
