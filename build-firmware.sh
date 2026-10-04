#!/bin/sh
# Build the kernel image for the STM32F446 from source: SBCL runs the Thumb-2 assembler
# (asm.lisp) and the metacompiler (kernel.lisp, kernel.fs) and writes kernel-f446.bin.
# No third-party Forth. The image runs on QEMU netduinoplus2, the closest QEMU board
# to the F446 (console: USART2 = QEMU's second -serial); a real board takes it with
#   st-flash write kernel-f446.bin 0x8000000
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
nice "${SBCL:-sbcl}" --script "$HERE/kernel.lisp" "$HERE/kernel-f446.bin"
