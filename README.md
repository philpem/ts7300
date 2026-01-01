# TS-7300 experiments

Some years ago I picked up a pair of Technologic Systems TS-7300 ARM9-based SBCs. This repository is a chronicle of my efforts to get a modern (later than 2.6.x) kernel running on the board.

Much of the documentation is in the specific subdirectories, but there are some general notes here.

## Components

  * `boot-sector`: Recreated Technologic boot sector source code, and a cleaned-up and improved version.
  * `kernel`: Linux kernel configurations and build scripts.

## Toolchains

The various kernels require different toolchains.

  * Linux 6.x: GCC 9 to 13 (and possibly newer)
  * Linux 5.x: unknown
  * Linux 3.x and 4.x: GCC 6.5.0 (2018-12)

Where I needed older compilers than were available in the Mint/Ubuntu/Debian repositories, I've used the Linaro toolchains:

  * [GCC 6.x Linaro, software floating-point](https://releases.linaro.org/components/toolchain/binaries/latest-6/arm-linux-gnueabi/)
  * [GCC 6.x Linaro, hardware floating-point](https://releases.linaro.org/components/toolchain/binaries/latest-6/arm-linux-gnueabihf/)

Look for the `gcc-linaro-6.5.0-2018.12-...` tarballs.

## MaverickCrunch

While the EP9302 has a MaverickCrunch FPU, it is not widely supported by GCC or the Linux kernel. Software floating-point is usually a better bet for these chips.

## Boot sectors

I've reverse-engineered the boot sector used by TS's Linux images. The source code and makefiles are in the `boot-sector` directory.

There are two versions:

  * The original (which loads the kernel at `0x0021_8000` and initrd at `0x0100_0000`)
  * A modified version which loads the kernel at `0x0400_0000` and 'feeds' the CPLD watchdog timer before jumping to it.

The modified version can load larger kernels, and is particularly useful for the 6.x-series kernels which can be 6MB uncompressed. The limit is around 8MB (kernel code plus data) uncompressed, and the same again for the compressed kernel.

The unmodified loader can boot an uncompressed kernel of up to 8192K - 2144K = 6048K (6193152 bytes) and requires that the kernel offset be changed from 0x8000 to 0x218000.

Neither boot sector supports Device Trees, which is a minor issue for 6.x kernels which require them. The solution is to use a compressed `zImage` kernel and append the device tree binary to the end of the kernel.

