/*
 * Recreation of the boot sector from the Technologic Systems TS7300 EP9302
 * single-board computer.
 *
 * Reverse engineered by Phil Pemberton, copyright rests with
 * Technologic Systems.
 *
 * Target: Cirrus EP9302 (ARM920T / ARMv4T), Thumb state
 * Tooling: GNU as/ld via arm-none-eabi-gcc (or any gcc/binutils that supports ARM/Thumb)
 *
 * When assembled with the included Makefile and Binutils 2.42, the binary
 * should match the original TS boot code included in the 2GB SD Card image.
 *
 * The boot ROM (running in the Ethernet MAC RAM) loads the 512-byte boot
 * sector into into SDRAM at 0x0000_1000. R0 and R1 provide pointers to
 * two utility functions:
 *   r0 = void sdread  (unsigned start_sector, char *buffer, int num_sectors)
 *          (read sectors from the SD Card)
 *   r1 = void ser_puts(char *buffer)
 *          (print an ASCIIZ string to the serial port)
 * The boot ROM then jumps to the first byte of the boot code in Thumb mode.
 * The stack remains in the latter part of the Ethernet MAC RAM.
 *
 * In theory you can use all 512 bytes for boot code, but the TS boot sector
 * uses a standard MBR partition table with bytes 0x1BE..1FF filled with the
 * partition table and boot signature (giving 445 bytes for boot code).
 *
 * Macros are used to create the partition table, for convenience.
 *
 * This boot sector loads the first two partitions with type 0xDA into
 * SDRAM at the following addresses:
 *   First  partition = load address 0x0021_8000 (kernel)
 *   Second partition = load address 0x0100_0000 (initramfs/initrd)
 *
 * If an initramfs partition is present, the ATAGS entry will set its length
 * to 4 MiB irrespective of the partition size.
 *
 * Once the partition table has been parsed, the registers are set per the
 * ARM Linux booting spec (r0=0, r1=machine type, r2=ATAGS address).
 */

.syntax unified
.cpu arm920t
.thumb
.thumb_func

/* -------------------------------------------------------------------------- */
/* Build-time constants / addresses                                           */
/* -------------------------------------------------------------------------- */

/* MAC RAM temporary buffers */
.equ ATAGS_DECODEBUF,    0x2000      /* scratch buffer used by DecodeAtags() */
.equ ATAGS_WRITE_PTR,    0x2014      /* pointer to the current ATAGS address */

/* Image load addresses -- initrd is optional */
.equ ATAGS_LOAD_ADDR,    0x100       /* ATAGS start address in SDRAM */
.equ KERNEL_LOAD_ADDR,   0x00218000  /* Kernel */
.equ INITRD_LOAD_ADDR,   0x01000000  /* Initrd/Initramfs */
  /*
   * NOTE: if the initrd address is changed, the compressed ATAGS will also
   * need to be updated.
   */

/* Linux machine type passed to the kernel
 * NOTE: This is 0x0163 = 355 in the original TS bootloader, which maps to
 * the CX861xx platform.
 * The correct ID is 673, which is available here as an option.
 */
// Incorrect value used by original loader
.equ LINUX_MACH_TYPE,    355
// TS72xx, per https://www.arm.linux.org.uk/developer/machines/
//.equ LINUX_MACH_TYPE,    673

/* -------------------------------------------------------------------------- */
/* Convenience macros for MBR partition entries                               */
/* -------------------------------------------------------------------------- */

/* Geometry for LBA->CHS conversion */
.set MBR_HEADS, 16
.set MBR_SPT,   32
.set MBR_SPC,   (MBR_HEADS * MBR_SPT)   /* sectors per cylinder = 512 */

/* Maximum CHS representable in an MBR partition entry */
.set MBR_MAX_CYL, 1023
.set MBR_MAX_HEAD, (MBR_HEADS - 1)     /* 15 */
.set MBR_MAX_SECT, MBR_SPT             /* 32 */

/* Encode numeric CHS into the 3 on-disk bytes */
.macro MBR_CHS_ENC head, sect, cyl
  .byte (\head)
  .byte (((\sect) & 0x3f) | (((\cyl) >> 2) & 0xc0))
  .byte ((\cyl) & 0xff)
.endm

/* Convert an LBA to numeric CHS (cyl/head/sect) using MBR geometry.
 * If cyl > 1023, saturate to 1023/15/32.
 *
 * Outputs are symbols you name: out_cyl, out_head, out_sect
 */
.macro MBR_CHS_FROM_LBA out_cyl, out_head, out_sect, lba
  .set __lba_\@,      (\lba)
  .set __cyl_\@,      (__lba_\@ / MBR_SPC)

  .if __cyl_\@ > MBR_MAX_CYL
    .set \out_cyl,  MBR_MAX_CYL
    .set \out_head, MBR_MAX_HEAD
    .set \out_sect, MBR_MAX_SECT
  .else
    .set __tmp_\@,     (__lba_\@ % MBR_SPC)
    .set \out_cyl,     __cyl_\@
    .set \out_head,    (__tmp_\@ / MBR_SPT)
    .set \out_sect,    ((__tmp_\@ % MBR_SPT) + 1)
  .endif
.endm

/* -------------------------------------------------------------------------- */
/* One 16-byte MBR partition entry: specify LBA start/size; CHS is derived    */
/* -------------------------------------------------------------------------- */
.macro MBR_PART_LBA boot, type, lba_start, lba_size
  .set __lba_start_\@, (\lba_start)
  .set __lba_size_\@,  (\lba_size)
  .set __lba_end_\@,   (__lba_start_\@ + __lba_size_\@ - 1)

  /* Derive CHS start/end (saturating when needed) */
  MBR_CHS_FROM_LBA __c1_\@, __h1_\@, __s1_\@, __lba_start_\@
  MBR_CHS_FROM_LBA __c2_\@, __h2_\@, __s2_\@, __lba_end_\@

  .byte \boot

  /* CHS first */
  MBR_CHS_ENC __h1_\@, __s1_\@, __c1_\@

  .byte \type

  /* CHS last */
  MBR_CHS_ENC __h2_\@, __s2_\@, __c2_\@

  /* LBA fields */
  .long __lba_start_\@
  .long __lba_size_\@
.endm

/* A truly empty entry (avoids CHS math on 0/0) */
.macro MBR_PART_EMPTY
  .fill 16, 1, 0
.endm



/* -------------------------------------------------------------------------- */
/* Section: boot sector (kept as a single 512-byte image)                     */
/* -------------------------------------------------------------------------- */

.section .text._start, "ax", %progbits
.global _start
.type _start, %function
.thumb_func

/* The boot sector is entered at LOAD_ADDR + 0x000 (i.e. 0x1000). */
_start:
  /* Save entry-provided function pointers and default load addresses on stack. */
  ldr   r3, =kernel_initrd_addrs                /* pc-relative literal in original */
  str   r0, [sp, #4]                    /* save sdread ptr */
  ldr   r4, [r3, #4]                    /* INITRD_LOAD_ADDR */
  ldr   r3, [r3, #0]                    /* KERNEL_LOAD_ADDR */
  str   r1, [sp, #0]                    /* save ser_puts ptr */
  str   r3, [sp, #12]                   /* save kernel load addr */
  str   r4, [sp, #16]                   /* save initrd load addr */

  /* Print ".\r\n" to indicate control has passed to the boot sector */
  ldr   r0, =dot_string
  bl    call_ser_puts                   /* bx r1 */

  /* Fill RAM on 16MB increments with a simple pattern 0..0x4F (verbatim). */
  movs  r2, #0
1:
  adds  r3, r2, #0                      /* r3 = (i + 0xC0) << 24 */
  adds  r3, #0xC0
  lsls  r3, r3, #24
  str   r2, [r3]                        /* [r3] = i  */
  adds  r2, #1                          /* next loop, do up to 0x50 loops */
  cmp   r2, #0x50
  bne   1b

  /* Now RAM from 0xE000_0000 wrapping around to 0x4000_0000 will be filled
   * with an incrementing pattern.
   *
   * Except: the SDRAM is non-contiguous. SDRAM on a 32MB board would look like:
   *  0000_0000 - 007F_FFFF (8MB)
   *  0100_0000 - 017F_FFFF (8MB)
   *  0400_0000 - 047F_FFFF (8MB)
   *  0500_0000 - 057F_FFFF (8MB)
   *
   * Some of these addresses wrap ... see later!
   */

  /* Initialize ATAGS_WRITE_PTR and clear a small scratch area. */
  ldr   r2, =ATAGS_WRITE_PTR
  movs  r3, #0x80                       /* R3 = 0x100 */
  lsls  r3, r3, #1

  ldr   r0, =ATAGS_DECODEBUF
  str   r3, [r2]                        /* *(0x2014) = 0x100 (ATAGS base later) */

  movs  r1, #0
2:
  movs  r3, #0x3F
  adds  r2, r1, #0
  ands  r2, r3
  adds  r1, #1
  movs  r3, #0
  strb  r3, [r0, r2]                    /* zero ATAGS_DECODEBUF[r2] */
  cmp   r1, #0x14
  bne   2b

  /* Start decoding the ATAGS */
  ldr   r0, =AtagsRawData
  movs  r4, #2                          /* Process 2 blocks of ATAGS */
3:
  bl    DecodeAtags                     /* Decode first ATAGS block */

  /* Check for RAM wraparound at address 0x0000_0000
   *
   * If 0x0000_0000 = 0x48, then address 0x0800_0000 is aliased, which means
   * the SDRAM bank size is 8MB or less. That means this is a 32MB board.
   */
  movs  r3, #0
  ldr   r3, [r3]                        /* read address 0x00000000 */
  cmp   r3, #0x48
  bne   4f
  bl    DecodeAtags                     /* Addr 0x0000_0000 = 0x48 -> decode more Atags */
  b     5f
4:
  adds  r0, #4                          /* Addr 0x0000_0000 not 0x48, skip 4 bytes */
5:
  subs  r4, #1
  cmp   r4, #0
  bne   3b

  /* Read 0xE0000000 and decide how much RAM wraps */
  movs  r3, #0xE0                       /* R3 = 0xE000_0000 */
  lsls  r3, r3, #24
  ldr   r4, [r3]                        /* Read into R4 */
  cmp   r4, #0x2A                       /* If 0x2A or 0x28, go to 6f, otherwise 7f */
  beq   6f
  cmp   r4, #0x28
  bne   7f
6:
  bl    DecodeAtags
  cmp   r4, #0x28
  bne   8f
  bl    DecodeAtags
  adds  r6, r0, #0
  b     9f
8:
  adds  r6, r0, #0
  adds  r6, #8
  b     9f
7:
  adds  r6, r0, #0
  adds  r6, #0x10
9:

  /* Use [sp+8] as a 'cursor' pointer to the Build a load address list on the stack, starting at sp+0x0C (verbatim). */
  mov   r3, sp
  adds  r3, #0x0C
  str   r3, [sp, #8]                    /* running “cursor” pointer */


  /* Scan MBR partition table for type 0xDA and load each found partition.
   * r0 = start_sector, r1 = dest, r2 = num_sectors
   * Calls sdread via call_any_r3() (bx r3) with r3 holding saved sdread ptr.
   */
  movs  r7, #0
10:
  ldr   r3, =mbr_partition_table
  lsls  r2, r7, #4                      /* entry index * 16 */
  adds  r5, r2, r3                      /* r5 = entry base */
  ldrb  r3, [r5, #4]                    /* r3 = partition type */
  cmp   r3, #0xDA
  bne   12f                             /* if not 0xDA, ignore */

  /* Pop next destination address from our list (kernel then initrd). */
  ldr   r2, [sp, #8]                    /* get cursor */
  ldm   r2!, {r1}                       /* r1=(*r2) then increment r2 */
  str   r2, [sp, #8]                    /* save updated cursor */

  /* Decode LBA start (u32) from bytes 8..11, and length (u32) from 12..15, */
  ldrb  r0, [r5, #9]
  ldrb  r3, [r5, #8]
  lsls  r0, r0, #8
  orrs  r0, r3
  ldrb  r3, [r5, #11]
  ldrb  r2, [r5, #10]
  lsls  r3, r3, #8
  orrs  r3, r2
  lsls  r3, r3, #16
  ldrb  r2, [r5, #13]
  adds  r0, r0, r3                      /* r0 = start_sector */

  ldrb  r3, [r5, #12]
  lsls  r2, r2, #8
  orrs  r2, r3
  ldrb  r3, [r5, #15]
  ldrb  r4, [r5, #14]
  lsls  r3, r3, #8
  orrs  r3, r4
  lsls  r3, r3, #16
  adds  r2, r2, r3                      /* r2 = num_sectors */

  /* Call sdread(start_sector=r0, buffer=r1, num_sectors=r2). */
  ldr   r3, [sp, #4]                    /* saved sdread pointer */
  bl    call_any_r3                     /* bx r3 */

  /* Print a dot/newline etc using ser_puts (verbatim). */
  ldr   r0, =dot_string
  ldr   r2, [sp, #0]                    /* saved ser_puts pointer into r2 */
  bl    call_ser_puts_via_r2            /* bx r2 */

12:
  adds  r7, #1
  cmp   r7, #4
  bne   10b

  /* If we loaded >1 item, append the ATAG_INITRD2 ATAG */
  ldr   r2, [sp, #8]
  add   r3, sp, #0x0C
  subs  r3, r2, r3
  asrs  r3, r3, #2
  cmp   r3, #1
  ble   13f
  adds  r0, r6, #0
  bl    DecodeAtags
13:
  /* Terminate the ATAGS */
  ldr   r3, =ATAGS_WRITE_PTR
  movs  r0, #0                          /* r0 for kernel ABI later */
  ldr   r2, [r3]                        /* r2 = current ATAGS pointer */
  movs  r3, #0                          /* length 0 is an ATAGS terminator */
  str   r3, [r2]

  /* Jump to kernel: r0=0, r1=machine type, r2=atags, pc=kernel */
  movs  r3, #0x86
  movs  r2, #0x80
  lsls  r3, r3, #14                     /* r3 = 0x218000 */
  ldr   r1, =LINUX_MACH_TYPE            /* r1 = 0x163 */
  lsls  r2, r2, #1                      /* r2 = 0x100 */
  bl    call_any_r3                     /* bx r3 (kernel should not return) */

  /* The kernel is now in control, and will never return. */

/* -------------------------------------------------------------------------- */
/* Indirection stubs                                                          */
/* -------------------------------------------------------------------------- */

.section .text.call_ser_puts, "ax", %progbits
.global call_ser_puts
.type call_ser_puts, %function
.thumb_func
call_ser_puts:
  bx    r1                              /* used early: ser_puts(r0) */

.section .text.call_ser_puts_via_r2, "ax", %progbits
.global call_ser_puts_via_r2
.type call_ser_puts_via_r2, %function
.thumb_func
call_ser_puts_via_r2:
  bx    r2                              /* used later: call through r2 */

.section .text.call_any_r3, "ax", %progbits
.global call_any_r3
.type call_any_r3, %function
.thumb_func
call_any_r3:
  bx    r3                              /* used to call sdread(start, buf, n) */

  /* padding to match original binary */
  nop

.section .text.DecodeAtags, "ax", %progbits
.global DecodeAtags
.type DecodeAtags, %function
.thumb_func

/* -------------------------------------------------------------------------- */
/* DecodeAtags() — compact serial output encoder (verbatim)                  */
/* -------------------------------------------------------------------------- */
/* This routine consumes a byte stream at r0:
 *   - It writes bytes into ATAGS_DECODEBUF indexed by (byte0 & 0x3F)
 *   - If (byte0 & 0x80) is set, it flushes by copying a number of bytes
 *     from ATAGS_DECODEBUF to the destination pointed to by *(ATAGS_WRITE_PTR),
 *     then updates *(ATAGS_WRITE_PTR).
 * The exact encoding is preserved; tables below are copied verbatim.
 */
DecodeAtags:
  push  {r4, r5, lr}
  ldr   r3, =ATAGS_WRITE_PTR
  ldr   r5, =ATAGS_DECODEBUF
  ldr   r4, [r3]                        /* current output pointer/state */

14:
  ldrb  r1, [r0]
  ldrb  r2, [r0, #1]
  movs  r3, #0x3F
  ands  r3, r1
  strb  r2, [r5, r3]
  movs  r3, #0x80
  adds  r0, #2
  tst   r1, r3
  beq   17f

  movs  r2, #0
  b     16f
15:
  ldrb  r3, [r2, r5]
  adds  r2, #1
  strb  r3, [r4]
  adds  r4, #1

16:
  ldrb  r3, [r5]
  lsls  r3, r3, #2
  cmp   r2, r3
  blo   15b

17:
  lsls  r3, r1, #25
  bpl   14b

  ldr   r3, =ATAGS_WRITE_PTR
  str   r4, [r3]
  pop   {r4, r5, pc}

  /* ---------------------------------------------------------------------- */
  /* kernel_initrd_addrs + message bytecode tables (verbatim bytes)                  */
  /* ---------------------------------------------------------------------- */

.section .rodata.consts, "a", %progbits
kernel_initrd_addrs:
  .word KERNEL_LOAD_ADDR
  .word INITRD_LOAD_ADDR

dot_string:
    .ascii  ".\r\n\0"

/*
 * Compressed ATAGS.
 */
AtagsRawData:
  // First 2 runs are output into the ATAGS as standard
  // Run 1: ATAG_CORE, size=5, flags = 0x00000000, pagesize= 0x00000000, rootdev = 0x00000000
  .byte 0x00,0x05
  .byte 0x04,0x01
  .byte 0x06,0x41
  .byte 0x87,0x54

  // Run 2: ATAG_MEM, size=4, mem.size = 0x00800000 (8 MiB), mem.start = 0x00000000
  // All boards should have this RAM stripe.
  .byte 0x00,0x04
  .byte 0x04,0x02
  .byte 0x8a,0x80

  // Run 3: ATAG_MEM, size=4, mem.size = 0x00800000 (8 MiB), mem.start = 0x01000000
  .byte 0xcf,0x01

  // Run 4: ATAG_MEM, size=4, mem.size = 0x00800000 (8 MiB), mem.start = 0x02000000
  .byte 0x8f,0x02

  // Run 5: ATAG_MEM, size=4, mem.size = 0x00800000 (8 MiB), mem.start = 0x03000000
  .byte 0xcf,0x03

  // Run 4: ATAG_MEM, size=4, mem.size = 0x00800000 (8 MiB), mem.start = 0x04000000
  .byte 0x8f,0x04

  // Run 5: ATAG_MEM, size=4, mem.size = 0x00800000 (8 MiB), mem.start = 0x05000000
  .byte 0xcf,0x05

  // Run 6: ATAG_MEM, size=4, mem.size = 0x00800000 (8 MiB), mem.start = 0x06000000
  .byte 0x8f,0x06

  // Run 7: ATAG_MEM, size=4, mem.size = 0x00800000 (8 MiB), mem.start = 0x07000000
  .byte 0xcf,0x07

  // Four banks, SD_CS2 (2nd chip), 8MiB stripes at E0, E1, E4, E5 (32MB chip)
  .byte 0x8f,0xe0
  .byte 0x8f,0xe1
  .byte 0x8f,0xe4
  .byte 0xcf,0xe5

  // Four banks, SD_CS2 (2nd chip), 8MiB stripes at E2, E3, E6, E7 (64MB chip)
  .byte 0x8f,0xe2
  .byte 0x8f,0xe3
  .byte 0x8f,0xe6
  .byte 0xcf,0xe7

  // The INITRD2 block is only inserted if an initrd was loaded.
  // ATAG_INITRD2, initrd.start = 0x01000000, initrd.size = 0x00400000 (4MiB)
  .byte 0x04,0x05
  .byte 0x06,0x42
  .byte 0x0a,0x00
  .byte 0x0b,0x01
  .byte 0x0e,0x40
  .byte 0xcf,0x00

  .byte 0x00


/* ---------------------------------------------------------------------- */
/* MBR partition table (exactly 4 entries)                                 */
/* ---------------------------------------------------------------------- */

.section .rodata.mbr_ptable, "a", %progbits
.global mbr_partition_table
mbr_partition_table:
  /* Entry 0 - Kernel */
  MBR_PART_LBA 0x00, 0xDA, 32,   3040

  /* Entry 1 - Initrd */
  MBR_PART_LBA 0x00, 0xDA, 3072, 2048

  /* Entry 2 - Rootfs */
  MBR_PART_LBA 0x00, 0x83, 9728, 3765145

  /* Entry 3: empty */
  MBR_PART_EMPTY

.section .rodata.mbr_sig, "a", %progbits
  .hword 0xAA55

