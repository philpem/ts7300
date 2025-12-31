CROSS ?= arm-linux-gnueabi
AS := $(CROSS)-as
LD := $(CROSS)-ld
OBJCOPY := $(CROSS)-objcopy

CFLAGS := -mcpu=arm920t -mthumb -ffreestanding -nostdlib -Wall -Wextra
LDFLAGS := -T bootsec.ld -nostdlib

all: bootsec.bin bootsec_new.bin


bootsec.elf: bootsec.S bootsec.ld
	$(AS) -mcpu=arm920t -mthumb -o bootsec.o bootsec.S
	$(LD) -T bootsec.ld -Map bootsec.map -nostdlib -o $@ bootsec.o

bootsec.bin: bootsec.elf
	$(OBJCOPY) -O binary $< $@
	@test "$$(wc -c < bootsec.bin)" -eq 512


bootsec_new.elf: bootsec_new.S bootsec.ld
	$(AS) -mcpu=arm920t -mthumb -o bootsec_new.o bootsec_new.S
	$(LD) -T bootsec.ld -Map bootsec_new.map -nostdlib -o $@ bootsec_new.o

bootsec_new.bin: bootsec_new.elf
	$(OBJCOPY) -O binary $< $@
	@test "$$(wc -c < bootsec_new.bin)" -eq 512


clean:
	rm -f bootsec.elf bootsec.bin bootsec.o
