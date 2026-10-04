#!/bin/sh
# test.sh -- run the test layers in order, each on a freshly booted chip:
#   1-2 assembler encodings vs GNU as (asm-tests.txt)
#   3   kernel words over the serial console (kernel-tests.txt)
#   4   the Scheme regression suite (conformance.txt in the core)
#   4   SUITE=1: chibi-scheme's R7RS suite (tests/r7rs/results.txt in the core; about 10 minutes)
# Tools come from PATH unless set: SBCL, QEMU, ARM_AS, ARM_OBJCOPY. PORT is the first TCP port.
HERE=$(cd "$(dirname "$0")" && pwd)
CORE=${FORTHLISP_CORE:-$HERE}; [ -f "$CORE/host.lisp" ] || CORE=$HERE/../forthlisp   # core repo checkout
SBCL=${SBCL:-sbcl}
PORT=${PORT:-4480}
rc=0
"$SBCL" --script "$HERE/asm-test.lisp" > "$HERE/asm-tests.txt" 2>&1 || rc=1
tail -1 "$HERE/asm-tests.txt"
"$HERE/build-firmware.sh" || exit 1
onchip() {  # onchip OUTFILE host.lisp-args...
  out=$1; shift
  "${QEMU:-qemu-system-arm}" -M netduinoplus2 -kernel "$HERE/kernel-f446.bin" -display none \
    -monitor none -serial null -serial tcp:127.0.0.1:$PORT,server,nowait 2>/dev/null &
  qp=$!
  PORT=$PORT "$SBCL" --script "$CORE/host.lisp" "$@" > /tmp/forthlisp-test-$PORT.log 2>&1 || rc=1
  kill $qp 2>/dev/null
  grep -E "^FAIL|tests: |conformance: |r7rs suite: |^FAILED" /tmp/forthlisp-test-$PORT.log > "$out"
  tail -1 "$out"
  PORT=$((PORT + 1))
}
onchip "$HERE/kernel-tests.txt" ktest "$HERE/forth-tests.txt"
onchip "$CORE/conformance.txt" test
[ -n "$SUITE" ] && onchip /tmp/forthlisp-suite-summary.txt suite
exit $rc
