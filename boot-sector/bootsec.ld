/* bootsec.ld — place boot sector at 0x1000 and keep it flat */
ENTRY(_start)
SECTIONS
{
  /* The boot sector is loaded to 0x1000. */
  . = 0x1000;

  /* 0x000: entry code */
  .boot 0x1000 : {
    KEEP(*(.text._start))
    *(.text.*)
    *(.rodata.consts)

    /* Ensure we have not grown into the partition table region. */
    __boot_pre_mbr_end = .;
    ASSERT(__boot_pre_mbr_end <= (0x1000 + 0x1BE),
           "Boot code too large: overlaps MBR partition table (0x1BE)");
  }

  /* 0x1BE: MBR partition table */
  .rodata.mbr_ptable 0x1000 + 0x1BE : {
    KEEP(*(.rodata.mbr_ptable))
  }

  /* 0x1FE: signature */
  .rodata.mbr_sig 0x1000 + 0x1FE : {
    KEEP(*(.rodata.mbr_sig))
  }

  /DISCARD/ :
  {
    *(.comment*)
    *(.note*)
    *(.eh_frame*)
    *(.ARM.exidx*)
    *(.ARM.extab*)
    *(.ARM.attributes*)
  }
}
