# platform	:= k210
# platform	:= qemu
platform	:= vf2
# board           := BOARD_GENERIC
# board           := BOARD_KD233
board           := BOARD_VF2
# mode := debug
mode := release
K=kernel
U=xv6-user
T=target

OBJS =
ifeq ($(platform), k210)
OBJS += $K/entry_k210.o
else ifeq ($(platform), qemu)
OBJS += $K/entry_qemu.o
else ifeq ($(platform), vf2)
OBJS += $K/entry_vf2.o
endif

OBJS += \
  $K/printf.o \
  $K/kalloc.o \
  $K/intr.o \
  $K/spinlock.o \
  $K/string.o \
  $K/main.o \
  $K/vm.o \
  $K/proc.o \
  $K/swtch.o \
  $K/trampoline.o \
  $K/trap.o \
  $K/syscall.o \
  $K/sysproc.o \
  $K/bio.o \
  $K/sleeplock.o \
  $K/file.o \
  $K/pipe.o \
  $K/exec.o \
  $K/sysfile.o \
  $K/kernelvec.o \
  $K/timer.o \
  $K/disk.o \
  $K/ramdisk.o \
  $K/fat32.o \
  $K/plic.o \
  $K/console.o

ifeq ($(platform), k210)
OBJS += \
  $K/spi.o \
  $K/gpiohs.o \
  $K/fpioa.o \
  $K/utils.o \
  $K/sdcard.o \
  $K/dmac.o \
  $K/sysctl.o 
endif

ifeq ($(platform), vf2)
OBJS += \
  $K/uart.o 
endif

QEMU = qemu-system-riscv64

ifeq ($(platform), k210)
RUSTSBI = ./bootloader/SBI/sbi-k210
else
RUSTSBI = ./bootloader/SBI/sbi-qemu
endif

TOOLPREFIX	:= riscv64-unknown-elf-
# TOOLPREFIX	:= riscv64-linux-gnu-
CC = $(TOOLPREFIX)gcc
AS = $(TOOLPREFIX)as
LD = $(TOOLPREFIX)ld
OBJCOPY = $(TOOLPREFIX)objcopy
OBJDUMP = $(TOOLPREFIX)objdump

CFLAGS = -Wall -Werror -O0 -fno-omit-frame-pointer -ggdb -g3
CFLAGS += -D$(board)
CFLAGS += -MD
CFLAGS += -mcmodel=medany
CFLAGS += -ffreestanding -fno-common -nostdlib -mno-relax
CFLAGS += -I.
CFLAGS += $(shell $(CC) -fno-stack-protector -E -x c /dev/null >/dev/null 2>&1 && echo -fno-stack-protector)
CFLAGS += -Wa,--gen-debug,-D,--nocompress-debug-sections,--gdwarf-5## otherwise 'No source file named /home/oslab/xv6-vf2/kernel/trampoline.S'

ifeq ($(mode), debug) 
CFLAGS += -DDEBUG 
endif 

ifeq ($(platform), qemu)
CFLAGS += -DQEMU
endif

ifeq ($(platform), vf2)
CFLAGS += -DVF2 
endif


LDFLAGS = -z max-page-size=4096 -g

ifeq ($(platform), k210)
linker = ./linker/k210.ld
endif

ifeq ($(platform), qemu)
linker = ./linker/qemu.ld
endif

ifeq ($(platform), vf2)
linker = ./linker/vf2.ld
endif

DWOs = $(shell ls $K/*.dwo)

# Compile Kernel
$T/kernel.bin: $(OBJS) $(linker) $U/initcode
	@if [ ! -d "./target" ]; then mkdir target; fi
	@$(LD) $(LDFLAGS) -T $(linker) -o $T/kernel $(OBJS)
	@$(OBJDUMP) -S $T/kernel > $T/kernel.asm
	@$(OBJDUMP) -t $T/kernel | sed '1,/SYMBOL TABLE/d; s/ .* / /; /^$$/d' > $T/kernel.sym
	@$(OBJCOPY) -O binary $T/kernel $T/kernel.bin
  
# make sure you already did hardcoded_ramdisk
build: $T/kernel userprogs 

# Compile RustSBI
RUSTSBI:
ifeq ($(platform), k210)
	@cd ./bootloader/SBI/rustsbi-k210 && cargo build && cp ./target/riscv64gc-unknown-none-elf/debug/rustsbi-k210 ../sbi-k210
	@$(OBJDUMP) -S ./bootloader/SBI/sbi-k210 > $T/rustsbi-k210.asm
else
	@cd ./bootloader/SBI/rustsbi-qemu && cargo build && cp ./target/riscv64gc-unknown-none-elf/debug/rustsbi-qemu ../sbi-qemu
	@$(OBJDUMP) -S ./bootloader/SBI/sbi-qemu > $T/rustsbi-qemu.asm
endif

rustsbi-clean:
	@cd ./bootloader/SBI/rustsbi-k210 && cargo clean
	@cd ./bootloader/SBI/rustsbi-qemu && cargo clean

image = $T/kernel.bin
k210 = $T/k210.bin
k210-serialport := /dev/ttyUSB0

ifndef CPUS
CPUS := 4
endif

QEMUOPTS = -machine virt -kernel $T/kernel -m 8M -nographic

# use multi-core 
QEMUOPTS += -smp $(CPUS)

QEMUOPTS += -bios $(RUSTSBI)

# import virtual disk image
QEMUOPTS += -drive file=fs.img,if=none,format=raw,id=x0 
QEMUOPTS += -device virtio-blk-device,drive=x0,bus=virtio-mmio-bus.0

run: build
ifeq ($(platform), k210)
	@$(OBJCOPY) $T/kernel --strip-all -O binary $(image)
	@$(OBJCOPY) $(RUSTSBI) --strip-all -O binary $(k210)
	@dd if=$(image) of=$(k210) bs=128k seek=1
	@$(OBJDUMP) -D -b binary -m riscv $(k210) > $T/k210.asm
	@sudo chmod 777 $(k210-serialport)
	@python3 ./tools/kflash.py -p $(k210-serialport) -b 1500000 -t $(k210)
else
	@$(QEMU) $(QEMUOPTS)
endif

$U/initcode: $U/initcode.S
	$(CC) $(CFLAGS) -march=rv64g -nostdinc -I. -Ikernel -c $U/initcode.S -o $U/initcode.o
	$(LD) $(LDFLAGS) -N -e start -Ttext 0 -o $U/initcode.out $U/initcode.o
	$(OBJCOPY) -S -O binary $U/initcode.out $U/initcode
	$(OBJDUMP) -S $U/initcode.o > $U/initcode.asm

tags: $(OBJS) _init
	@etags *.S *.c

ULIB = $U/ulib.o $U/usys.o $U/printf.o $U/umalloc.o

_%: %.o $(ULIB)
	$(LD) $(LDFLAGS) -N -e main -Ttext 0 -o $@ $^
	$(OBJDUMP) -S $@ > $*.asm
	$(OBJDUMP) -t $@ | sed '1,/SYMBOL TABLE/d; s/ .* / /; /^$$/d' > $*.sym

# $K/trampoline.o : $K/trampoline.S
# 	$(CC) $(CFLAGS) -Wa,--gstabs+ -c -o $K/trampoline.o $K/trampoline.S

$U/usys.S : $U/usys.pl
	@perl $U/usys.pl > $U/usys.S

$U/usys.o : $U/usys.S
	$(CC) $(CFLAGS) -c -o $U/usys.o $U/usys.S

$U/_forktest: $U/forktest.o $(ULIB)
	# forktest has less library code linked in - needs to be small
	# in order to be able to max out the proc table.
	$(LD) $(LDFLAGS) -N -e main -Ttext 0 -o $U/_forktest $U/forktest.o $U/ulib.o $U/usys.o
	$(OBJDUMP) -S $U/_forktest > $U/forktest.asm



# Prevent deletion of intermediate files, e.g. cat.o, after first build, so
# that disk image changes after first build are persistent until clean.  More
# details:
# http://www.gnu.org/software/make/manual/html_node/Chained-Rules.html
.PRECIOUS: %.o

UPROGS=\
	$U/_init\
	$U/_sh\
	$U/_cat\
	$U/_echo\
	$U/_grep\
	$U/_ls\
	$U/_kill\
	$U/_mkdir\
	$U/_xargs\
	$U/_sleep\
	$U/_find\
	$U/_rm\
	$U/_wc\
	$U/_test\
	$U/_usertests\
	$U/_strace\
	$U/_mv\

	# $U/_forktest\
	# $U/_ln\
	# $U/_stressfs\
	# $U/_grind\
	# $U/_zombie\

userprogs: $(UPROGS)

dst=/mnt

# @sudo cp $U/_init $(dst)/init
# @sudo cp $U/_sh $(dst)/sh
# Make fs image
fs: $(UPROGS)
	@if [ `uname -s` = "Linux" -a ! -f "fs.img" ]; then \
			echo "making fs image..."; \
			dd if=/dev/zero of=fs.img bs=8k count=32; \
			mkfs.vfat -F 32 fs.img; \
	fi
	@if [ `uname -s` = "Linux" ]; then \
		sudo mount fs.img $(dst); \
	fi
	@if [ `uname -s` = "Darwin" ]; then \
		hdiutil create -fs FAT32 -volname xv6 -type UDIF -size 128M -layout none fs; \
		mv fs.dmg fs.img; \
		mkdir mnt; \
		hdiutil mount -mountpoint `pwd`/mnt fs.img; \
	fi
	@if [ ! -d "$(dst)/bin" ]; then sudo mkdir $(dst)/bin; fi
	@sudo cp README.md $(dst)/README
	@sudo cp $U/_cat $(dst)/cat
	@sudo cp $U/_ls $(dst)/ls
	@sudo cp $U/_init $(dst)/init
	@sudo cp $U/_sh $(dst)/sh
#	@for file in $$( ls $U/_* ); do \
# 		sudo cp $$file $(dst)/$${file#$U/_};\
# 		sudo cp $$file $(dst)/bin/$${file#$U/_}; done
	@sudo umount $(dst)

hardcoded_ramdisk:fs
	@cp fs.img fs_img
	@xxd -i fs_img > $K/include/ramdisk.h

# Write sdcard
sdcard: fs
	@if [ "$(sd)" != "" ]; then \
		echo "flashing into sd card..."; \
		sudo dd if=fs.img of=$(sd); \
	else \
		echo "sd card not detected!"; fi

# .asm is considered generated and will be removed. So always use .S if you write an asm file on your own.
clean: 
	rm -f *.tex *.dvi *.idx *.aux *.log *.ind *.ilg \
	*/*.o */*.d */*.asm */*.sym */*.dwo */*.dwp \
	$T/* \
	$U/initcode $U/initcode.out \
	$K/kernel \
	.gdbinit \
	$U/usys.S \
	$(UPROGS) \
	fs_img \
	fs.img
