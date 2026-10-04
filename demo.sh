#!/bin/sh
# Scripted proof of the layers: the host compiles Lisp to Forth words, loads the Scheme
# through the Forth console, and checks its answers. Every serial exchange has a timeout.
HERE=$(cd "$(dirname "$0")" && pwd)
CORE=${FORTHLISP_CORE:-$HERE}; [ -f "$CORE/host.lisp" ] || CORE=$HERE/../forthlisp   # core repo checkout
IMG=$HERE/kernel-f446.bin
PORT=${PORT:-4445}
[ -f "$IMG" ] || "$HERE/build-firmware.sh" >/dev/null
"${QEMU:-qemu-system-arm}" -M netduinoplus2 -kernel "$IMG" -display none -monitor none \
  -serial null -serial tcp:127.0.0.1:$PORT,server,nowait 2>/dev/null &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT HUP INT TERM
PORT=$PORT ${TIMEOUT:-timeout} 300 "${SBCL:-sbcl}" --script "$CORE/host.lisp" demo
