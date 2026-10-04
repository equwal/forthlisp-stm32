# forthlisp-stm32

A Forth kernel for the STM32F446 (Cortex-M4F, 128 KiB RAM, 512 KiB flash), written from
scratch: a Thumb-2 assembler in SBCL builds it, and the shared Scheme from
[forthlisp](https://github.com/equwal/forthlisp) runs on it. No third-party Forth.

```
 4  LISP     the Scheme (forthlisp core: lisp.fs, prims.lisp, prelude.scm), loaded through
             the kernel's console
 3  FORTH    kernel.lisp + kernel.fs: indirect-threaded Forth. Primitives are Thumb-2
             templates; the outer interpreter is Forth, metacompiled by the host
 2  SBCL     asm.lisp: Thumb-2 + FPv4-SP encoders on SBCL's sb-assem segments and labels,
             with its own fixup pass; kernel.lisp lays out headers and writes the image
 1  ASM      Thumb-2 / ARMv7-M, FPv4-SP single-precision floats
```

## Quickstart

```sh
git clone https://github.com/equwal/forthlisp            # the core, next to this repo
git clone https://github.com/equwal/forthlisp-stm32
cd forthlisp-stm32
./build-firmware.sh        # SBCL writes kernel-f446.bin (about 10 KiB)
./stm32-forth              # the kernel's own prompt:  1 2 + .  ->  3
./stm32-lisp               # Scheme:  (+ 1 2)  ->  3
./test.sh                  # all layers; SUITE=1 also runs the R7RS suite (about 10 minutes)
```

Needs SBCL, `qemu-system-arm` (machine `netduinoplus2`), `arm-none-eabi-as` and
`arm-none-eabi-objcopy`, and `nc`. Override the tools with `SBCL`, `QEMU`, `ARM_AS`,
`ARM_OBJCOPY`, `NC`, `STTY`. `PORT` picks the TCP port of the emulated console.

A real board takes the image with `st-flash write kernel-f446.bin 0x8000000`.

## Board and emulation

- QEMU has no F446 board. `netduinoplus2` (STM32F405) is the closest. The kernel uses only
  what the F446 has: RAM ends at `0x20020000`, and the image fits in 512 KiB of flash.
- The console is USART2 at 115200 baud from the 16 MHz HSI. It is QEMU's second `-serial`.
- QEMU breaks on writes to the last 32 bytes of RAM, so the stacks stop short of them.
- QEMU does not model the F4 flash controller, so words compile to RAM.

## Memory map and registers

- Flash `0x08000000`: vector table, primitives, kernel headers and threads.
- RAM `0x20000000`: system variables, the 512-byte input buffer, then the dictionary.
- Data stack: 4 KiB below `0x2001EFE0`. Return stack (`sp`): 4 KiB below `0x2001FFE0`.
- r4 = IP, r5 = data stack pointer, r6 = top of stack, r7 = W.
  NEXT is `ldr r7,[r4],#4; ldr r0,[r7]; bx r0`.

## Tests, in layer order

| Layer | Test | Result file | At publication |
|---|---|---|---|
| 1-2 | `asm-test.lisp`: every encoder form byte-identical to GNU as | `asm-tests.txt` | 105/105 |
| 3 | `forth-tests.txt`: kernel words over the serial console | `kernel-tests.txt` | 71/71 |
| 4 | the core's `r7rs-tests.scm` | core `conformance.txt` | 297/297 |
| 4 | chibi-scheme's R7RS suite | core `tests/r7rs/results.txt` | 486 pass / 123 fail / 523 skip |

## Limits

- 23.5 KiB RAM stays free after the Scheme loads. The cons heap is 48 KiB, the blob heap
  16 KiB.
- Floats are single precision.
- A runtime `flash!` is not written yet, because QEMU cannot test it.

## Influences

- Paul Khuong, "SBCL: the ultimate assembly code breadboard"
  (https://pvk.ca/Blog/2014/03/15/sbcl-the-ultimate-assembly-code-breadboard/)
- Ron Garret, gll-mag-patch (https://github.com/rongarret/gll-mag-patch)
- Ron Garret, "Lisping at JPL" (https://flownet.com/gat/jpl-lisp.html)

## Licence

MIT (see `LICENSE`).
