     _                 _    ____   _____ 
    | |               | |  / __ \ / ____|
    | |__   ___   ___ | |_| |  | | (___  
    | '_ \ / _ \ / _ \| __| |  | |\___ \ 
    | |_) | (_) | (_) | |_| |__| |____) |
    |_.__/ \___/ \___/ \__|\____/|_____/                                                                           

# bootOS operating system in 512 bytes (boot sector)
### by Oscar Toledo G. Jul/22/2019

[http://nanochess.org](http://nanochess.org)

[https://github.com/nanochess/bootOS](https://github.com/nanochess/bootOS)

It's compatible with 8088 (the original IBM PC).

If you want to assemble it, you must download the Netwide Assembler (nasm) from [www.nasm.us](http://nasm.us/) or Tinyasm from [https://github.com/nanochess/tinyasm](https://github.com/nanochess/tinyasm)

Use this command line:

    nasm -f bin os.asm -l os.lst -o os.img
    
    tinyasm -f bin os.asm -l os.lst -o os.img

        
### What is bootOS:

bootOS is a monolithic operating system that fits in one boot sector. It's able to load, execute, and save programs. Also keeps a filesystem. It can work with any floppy disk size starting at 180K.

It relocates itself at 0000:7a00 and requires further 768 bytes of memory starting at 0000:7700.

This operating system runs programs as boot sectors at 0000:7c00. 

It provides the following services:

     int 0x20   Exit to operating system.
     int 0x21   Input key and show in screen.
                Entry: none
                Output: AL = ASCII key pressed.
                Affects: AH/BX/BP.
     int 0x22   Output character to screen.
                Entry: AL = Character.
                Output: none.
                Affects: AH/BX/BP.
     int 0x23   Load file.
                Entry: DS:BX = Filename terminated with zero.
                       ES:DI = Point to source data (512 bytes)
                Output: Carry flag = 0 = Found, 1 = Not found.
                Affects: All registers (including ES).
     int 0x24   Save file.
                Entry: DS:BX = Filename terminated with zero.
                       ES:DI = Point to data target (512 bytes)
                Output: Carry flag = 0 = Successful. 1 = Error.
                Affects: All registers (including ES).
     int 0x25   Delete file.
                Entry: DS:BX = Filename terminated with zero.
                Affects: All registers (including ES).
        

### Filesystem organization:

bootOS uses tracks from 0 to 32, side 0, sector 1.

The directory is contained in track 0, side 0, sector 2.

Each entry in the directory is 16 bytes wide, and contains the ASCII name of the file finished with a zero byte. A sector has a capacity of 512 bytes, it means only 32 files can be kept on a floppy disk.

Deleting a file is a matter of zeroing a whole entry.

Each file is one sector long. Its location in the disk is derived from its position in the directory.

The 1st file is located at track 1, side 0, sector 1. The 2nd file is located at track 2, side 0, sector 1. The 32nd file is located at track 32, side 0, sector 1.
 

### Starting bootOS:

Just make sure to write it at the boot sector of a floppy disk. It can work with any floppy disk size (360K, 720K, 1.2MB and 1.44MB) and it will waste the disk space as only uses the first two sectors of the disk and then the first sector of each following track.
        
For emulation make sure to deposit it at the start of a .img file of 360K, 720K or 1440K. Note: At least VirtualBox detects the type of disk by the length of the image file.
        
For macOS and Linux you can create a 360K image in this way:

    dd if=/dev/zero of=oszero.img count=719 bs=512
    cat os.img oszero.img >osbase.img

Replace 719 with 1439 for 720K, or 2879 for 1.44M.

Tested with VirtualBox for Mac OS X running Windows XP running it, it also works with qemu:

    qemu-system-x86_64 -fda os.img

### Running bootOS:

The first time you should enter the 'format' command, so it initializes the directory. It also copies itself again to the boot sector, this is useful to init new disks.
        
### bootOS commands:

    ver           Shows the version (none at the moment)
    dir           Shows the directory's content.
    del filename  Deletes the "filename" file.
    format        As explained before.
    enter         Allows to enter up to 512 hexadecimal
                  bytes to create another file.
        
                  Notice the line size is 128 characters so
                  you must break the input into chunks of
                  4, 8 or 16 bytes.
        
                  It also allows to copy the last executed
                  program just press Enter when the 'h' prompt
                  appears and type the new name.
        
For example: (Character + is Enter key)

    $enter+
    hbb 17 7c 8a 07 84 c0 74 0c 53 b4 0e bb 0f 00 cd+
    h10 5b 43 eb ee cd 20 48 65 6c 6c 6f 2c 20 77 6f+
    h72 6c 64 0d 0a 00+
    h+
    *hello+
    $dir+
    hello
    $hello+
    Hello, world
    $
        
### bootOS programs: (Oh yes! we have software support)
        
    cubicDoom     https://github.com/nanochess/cubicDoom
    bricks        https://github.com/nanochess/bricks
    fbird         https://github.com/nanochess/fbird
    Pillman       https://github.com/nanochess/pillman
    invaders      https://github.com/nanochess/invaders
    bootBASIC     https://github.com/nanochess/bootBASIC
    bootLogo      https://github.com/nanochess/bootLogo
    bootRogue     https://github.com/nanochess/bootRogue
    Atomchess     https://github.com/nanochess/Toledo-Atomchess
                (requires minimum 286 processor)
    heart         https://github.com/nanochess/heart
    pi            https://github.com/nanochess/pi
    bootle        https://github.com/nanochess/bootle

Also our first 3rd party programs!!!

    bootSlide     https://github.com/XlogicX/BootSlide
                  (requires minimum 286 processor)
    tetranglix    https://github.com/XlogicX/tetranglix
                  (requires minimum 286 processor)
    snake         https://gitlab.com/pmikkelsen/asm_snake
                  (requires minimum 286 processor)
    bootMine      https://github.com/io12/BootMine
                  (requires minimum Pentium II processor because rdtsc instruction)
    sokoban       https://ish.works/bootsector/bootsector.html
                  (requires minimum 286 processor)

These programs provide a boot sector version and a COM file version. You need the boot sector version as the programs are loaded at address 0000:7c00.

You can copy the machine code directly using the 'enter' command, or you can create a file with signature bytes with the same command and later copy the binary into the .img file using the signature bytes as a clue to locate the right position in the image file.
        
Or you can find a pre-designed disk image along this Git with the name osall.img
        
Enjoy it!

_Special thanks to Maja Kądziołka (meithecatte) for finding some bugs and suggesting enhancements._

There's a bootOS fork by jakiki6 capable of running from an USB stick, and including many other changes. Download from: https://github.com/jakiki6/bootOS


### >> ATTENTION <<        

Would you like to learn 8086/8088 programming? Then you must get my new book Programming Boot Sector Games including a 8086/8088 crash course!

Now available from Lulu:

  Soft-cover  http://www.lulu.com/shop/oscar-toledo-gutierrez/programming-boot-sector-games/paperback/product-24188564.html

  Hard-cover  http://www.lulu.com/shop/oscar-toledo-gutierrez/programming-boot-sector-games/hardcover/product-24188530.html

  eBook       https://nanochess.org/store.html

These are some of the example programs documented profusely
in the book:

  * Guess the number.
  * Tic-Tac-Toe game.
  * Text graphics.
  * Mandelbrot set.
  * F-Bird game.
  * Invaders game.
  * Pillman game.
  * Toledo Atomchess.
  * bootBASIC language.

After the success of my first book, if you need even
More Boot Sector Games then you must get this book!

  Soft-cover  http://www.lulu.com/shop/oscar-toledo-gutierrez/more-boot-sector-games/paperback/product-24462035.html

  Hard-cover  http://www.lulu.com/shop/oscar-toledo-gutierrez/more-boot-sector-games/hardcover/product-24462029.html

  * Follow the Lights
  * bootRogue
  * bricks
  * cubicDoom
  * bootOS
