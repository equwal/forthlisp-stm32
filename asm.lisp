;;;; asm.lisp -- layer 2: a Thumb-2 (ARMv7-M + FPv4-SP) assembler on SBCL's sb-assem.
;;;;
;;;; sb-assem supplies the ISA-neutral parts: segments and labels; `fixup` resolves references. The encoders
;;;; below are plain functions, one per instruction form, that emit little-endian halfwords
;;;; into *seg*. asm-test.lisp checks every form against arm-none-eabi-as byte for byte.

(defpackage :thumb (:use :cl)
  (:export #:*seg* #:*base* #:new-segment #:segment-bytes #:here #:label #:mark #:label-address
           #:h16 #:w32 #:abs32 #:align4 #:reg))
(in-package :thumb)

(defvar *seg*)
(defvar *base* #x08000000 "Address of segment position 0.")
(defvar *fixups* '() "(position size function): bytes computed after all labels are placed.")

(defun new-segment () (setf *fixups* '() *seg* (sb-assem:make-segment)))
(defun fixup (size fn)
  "Reserve SIZE bytes; segment-bytes later calls (FN position) to emit them with labels known.
sb-assem's emit-back-patch resolved only the first of several patches in a row here (SBCL
2.6.9), so label references go through this list instead."
  (push (list (sb-assem::segment-current-posn *seg*) size fn) *fixups*)
  (dotimes (i size) (sb-assem:emit-byte *seg* 0)))
(defun segment-bytes ()
  (sb-assem:finalize-segment *seg*)
  (let ((v (copy-seq (coerce (sb-assem:segment-contents-as-vector *seg*) '(simple-array (unsigned-byte 8) (*)))))
        (main *seg*))
    (unwind-protect
         (dolist (f *fixups* v)
           (destructuring-bind (posn size fn) f
             (setf *seg* (sb-assem:make-segment))
             (funcall fn posn)
             (sb-assem:finalize-segment *seg*)
             (let ((bytes (sb-assem:segment-contents-as-vector *seg*)))
               (assert (= (length bytes) size) () "fixup at ~d wrote ~d bytes, not ~d" posn (length bytes) size)
               (replace v bytes :start1 posn))))
      (setf *seg* main))))
(defun here () (sb-assem::segment-current-posn *seg*))
(defun label () (sb-assem:gen-label))
(defun mark (l) (sb-assem::%emit-label *seg* nil l) l)
(defun label-address (l) (+ *base* (sb-assem:label-position l)))

(defun h16 (h) (sb-assem:emit-byte *seg* (ldb (byte 8 0) h)) (sb-assem:emit-byte *seg* (ldb (byte 8 8) h)))
(defun w32 (w) (h16 (ldb (byte 16 0) w)) (h16 (ldb (byte 16 16) w)))
(defun h32 (hw1 hw2) (h16 hw1) (h16 hw2))
(defun align4 () (loop until (zerop (mod (here) 4)) do (sb-assem:emit-byte *seg* 0)))

(defun abs32 (l &optional (addend 0))
  "A 32-bit cell holding label L's absolute address plus ADDEND (resolved at finalize)."
  (fixup 4 (lambda (posn) (declare (ignore posn)) (w32 (+ (label-address l) addend)))))

;;; ---------- operands ----------

(defun reg (r)
  (let ((n (case r (:sp 13) (:lr 14) (:pc 15) (:ip 4) (:psp 5) (:tos 6) (:w 7)
                 (t (if (and (symbolp r) (char= (char (symbol-name r) 0) #\R))
                        (parse-integer (symbol-name r) :start 1)
                        r)))))
    (assert (and (integerp n) (<= 0 n 15)) () "bad register ~s" r)
    n))
(defun sreg (s) (let ((n (parse-integer (symbol-name s) :start 1))) (assert (<= 0 n 31)) n))

(defparameter *conds* '(:eq 0 :ne 1 :cs 2 :hs 2 :cc 3 :lo 3 :mi 4 :pl 5 :vs 6 :vc 7
                        :hi 8 :ls 9 :ge 10 :lt 11 :gt 12 :le 13 :al 14))
(defun cnd (c) (or (getf *conds* c) (error "bad condition ~s" c)))

;;; ---------- 16-bit forms ----------

(defun nop () (h16 #xBF00))
(defun bx (rm) (h16 (logior #x4700 (ash (reg rm) 3))))
(defun blx (rm) (h16 (logior #x4780 (ash (reg rm) 3))))
(defun mov (rd rm) "MOV Rd,Rm (T1, any registers, flags unchanged)."
  (let ((d (reg rd))) (h16 (logior #x4600 (ash (ldb (byte 1 3) d) 7) (ash (reg rm) 3) (ldb (byte 3 0) d)))))
(defun it (c &optional (pattern "")) "IT block: PATTERN (string or keyword) of T/E for the 2nd..4th instructions."
  (let* ((pattern (string pattern)) (fc (cnd c)) (bit0 (ldb (byte 1 0) fc)) (mask 0) (n (length pattern)))
    (loop for ch across pattern for i downfrom 3
          do (setf (ldb (byte 1 i) mask) (if (char-equal ch #\T) bit0 (- 1 bit0))))
    (setf (ldb (byte 1 (- 3 n)) mask) 1)
    (h16 (logior #xBF00 (ash fc 4) mask))))
(defun cmp-imm8 (rn imm) (assert (and (< (reg rn) 8) (<= 0 imm 255))) (h16 (logior #x2800 (ash (reg rn) 8) imm)))

;;; ---------- loads and stores ----------

(defun mem12 (op rt rn off)
  (assert (<= 0 off 4095))
  (h32 (logior op (reg rn)) (logior (ash (reg rt) 12) off)))
(defun mem8 (op rt rn off mode)
  "T4 form. MODE :pre (pre-index with writeback), :post (post-index), :neg (offset, no writeback)."
  (let ((u (if (minusp off) 0 1)) (a (abs off)))
    (assert (<= a 255))
    (multiple-value-bind (p w) (ecase mode (:pre (values 1 1)) (:post (values 0 1)) (:neg (values 1 0)))
      (h32 (logior op (reg rn))
           (logior (ash (reg rt) 12) #x800 (ash p 10) (ash u 9) (ash w 8) a)))))
(macrolet ((def (name op12 op8)
             `(defun ,name (rt rn &optional (off 0) mode)
                (if (and (null mode) (<= 0 off 4095))
                    (mem12 ,op12 rt rn off)
                    (mem8 ,op8 rt rn off (or mode :neg))))))
  (def ldr #xF8D0 #xF850) (def str #xF8C0 #xF840)
  (def ldrb #xF890 #xF810) (def strb #xF880 #xF800)
  (def ldrh #xF8B0 #xF830) (def strh #xF8A0 #xF820)
  (def ldrsb #xF990 #xF910) (def ldrsh #xF9B0 #xF930))
(defun push1 (r) (str r :sp -4 :pre))
(defun pop1 (r) (ldr r :sp 4 :post))

;;; ---------- data processing ----------

(defparameter *shift-types* '(:lsl 0 :lsr 1 :asr 2 :ror 3))
(defun dp-reg (op rd rn rm &optional (shift :lsl) (amount 0) s)
  "Data processing, shifted register (T2/T3 32-bit forms)."
  (let ((amt (if (and (member shift '(:lsr :asr)) (= amount 32)) 0 amount)))
    (assert (<= 0 amt 31))
    (h32 (logior op (if s #x10 0) (reg rn))
         (logior (ash (ldb (byte 3 2) amt) 12) (ash (reg rd) 8) (ash (ldb (byte 2 0) amt) 6)
                 (ash (getf *shift-types* shift) 4) (reg rm)))))
(macrolet ((def (name op)
             `(defun ,name (rd rn rm &optional (shift :lsl) (amount 0) s) (dp-reg ,op rd rn rm shift amount s))))
  (def and-reg #xEA00) (def bic-reg #xEA20) (def orr-reg #xEA40) (def orn-reg #xEA60)
  (def eor-reg #xEA80) (def add-reg #xEB00) (def adc-reg #xEB40) (def sbc-reg #xEB60)
  (def sub-reg #xEBA0) (def rsb-reg #xEBC0))
(defun adds-reg (rd rn rm) (dp-reg #xEB00 rd rn rm :lsl 0 t))
(defun subs-reg (rd rn rm) (dp-reg #xEBA0 rd rn rm :lsl 0 t))
(defun mov-shift (rd rm shift amount) (dp-reg #xEA40 rd 15 rm shift amount))
(defun mvn-reg (rd rm) (dp-reg #xEA60 rd 15 rm))
(defun cmp-reg (rn rm) (dp-reg #xEBA0 15 rn rm :lsl 0 t))
(defun tst-reg (rn rm) (dp-reg #xEA00 15 rn rm :lsl 0 t))
(defun shift-reg (op rd rn rm) (h32 (logior op (reg rn)) (logior #xF000 (ash (reg rd) 8) (reg rm))))
(defun lsl-reg (rd rn rm) (shift-reg #xFA00 rd rn rm))
(defun lsr-reg (rd rn rm) (shift-reg #xFA20 rd rn rm))
(defun asr-reg (rd rn rm) (shift-reg #xFA40 rd rn rm))

(defun imm12-form (op rd rn imm)
  (assert (<= 0 imm 4095))
  (h32 (logior op (ash (ldb (byte 1 11) imm) 10) (reg rn))
       (logior (ash (ldb (byte 3 8) imm) 12) (ash (reg rd) 8) (ldb (byte 8 0) imm))))
(defun addw (rd rn imm) (imm12-form #xF200 rd rn imm))
(defun subw (rd rn imm) (imm12-form #xF2A0 rd rn imm))
(defun mov16-form (op rd imm)
  (assert (<= 0 imm #xFFFF))
  (h32 (logior op (ash (ldb (byte 1 11) imm) 10) (ldb (byte 4 12) imm))
       (logior (ash (ldb (byte 3 8) imm) 12) (ash (reg rd) 8) (ldb (byte 8 0) imm))))
(defun movw (rd imm) (mov16-form #xF240 rd imm))
(defun movt (rd imm) (mov16-form #xF2C0 rd imm))
(defun li (rd value)
  "Load a 32-bit constant, or a label's absolute address, with MOVW (+ MOVT)."
  (if (integerp value)
      (let ((v (ldb (byte 32 0) value)))
        (movw rd (ldb (byte 16 0) v))
        (unless (zerop (ldb (byte 16 16) v)) (movt rd (ldb (byte 16 16) v))))
      (fixup 8 (lambda (posn) (declare (ignore posn))
                 (let ((v (label-address value)))
                   (movw rd (ldb (byte 16 0) v)) (movt rd (ldb (byte 16 16) v)))))))
(defun mvn-0 (rd) "MVN.W Rd,#0, i.e. Rd = -1." (h32 #xF06F (ash (reg rd) 8)))
(defun mul (rd rn rm) (h32 (logior #xFB00 (reg rn)) (logior #xF000 (ash (reg rd) 8) (reg rm))))
(defun mls (rd rn rm ra) "Rd = Ra - Rn*Rm" (h32 (logior #xFB00 (reg rn)) (logior (ash (reg ra) 12) (ash (reg rd) 8) #x10 (reg rm))))
(defun sdiv (rd rn rm) (h32 (logior #xFB90 (reg rn)) (logior #xF0F0 (ash (reg rd) 8) (reg rm))))
(defun udiv (rd rn rm) (h32 (logior #xFBB0 (reg rn)) (logior #xF0F0 (ash (reg rd) 8) (reg rm))))
(defun smull (lo hi rn rm) (h32 (logior #xFB80 (reg rn)) (logior (ash (reg lo) 12) (ash (reg hi) 8) (reg rm))))
(defun umull (lo hi rn rm) (h32 (logior #xFBA0 (reg rn)) (logior (ash (reg lo) 12) (ash (reg hi) 8) (reg rm))))
(defun clz (rd rm) (h32 (logior #xFAB0 (reg rm)) (logior #xF080 (ash (reg rd) 8) (reg rm))))

;;; ---------- branches ----------

(defun branch-patch (target encode)
  (fixup 4 (lambda (posn) (funcall encode (- (sb-assem:label-position target) (+ posn 4))))))
(defun enc-b-t4 (off link)
  (assert (and (evenp off) (<= (- (ash 1 24)) off (1- (ash 1 24)))) () "branch out of range")
  (let* ((s (ldb (byte 1 24) off)) (i1 (ldb (byte 1 23) off)) (i2 (ldb (byte 1 22) off))
         (j1 (logxor 1 i1 s)) (j2 (logxor 1 i2 s)))
    (h32 (logior #xF000 (ash s 10) (ldb (byte 10 12) off))
         (logior (if link #xD000 #x9000) (ash j1 13) (ash j2 11) (ldb (byte 11 1) off)))))
(defun enc-bcond-t3 (c off)
  (assert (and (evenp off) (<= (- (ash 1 20)) off (1- (ash 1 20)))) () "conditional branch out of range")
  (h32 (logior #xF000 (ash (ldb (byte 1 20) off) 10) (ash (cnd c) 6) (ldb (byte 6 12) off))
       (logior #x8000 (ash (ldb (byte 1 18) off) 13) (ash (ldb (byte 1 19) off) 11) (ldb (byte 11 1) off))))
(defun b (target) (branch-patch target (lambda (off) (enc-b-t4 off nil))))
(defun bl (target) (branch-patch target (lambda (off) (enc-b-t4 off t))))
(defun bcc (c target) (branch-patch target (lambda (off) (enc-bcond-t3 c off))))
;;; ---------- FPv4-SP (single-precision VFP) ----------

(defun sreg (s) (let ((n (parse-integer (symbol-name s) :start 1))) (assert (<= 0 n 31)) n))
(defun vfp-dnm (op1 op2 sd sn sm)
  "Three-register VFP data processing: OP1/OP2 are the fixed bits of hw1/hw2."
  (let ((d (sreg sd)) (n (sreg sn)) (m (sreg sm)))
    (h32 (logior op1 (ash (ldb (byte 1 0) d) 6) (ash n -1))
         (logior op2 (ash (ash d -1) 12) (ash (ldb (byte 1 0) n) 7) (ash (ldb (byte 1 0) m) 5) (ash m -1)))))
(defun vadd (sd sn sm) (vfp-dnm #xEE30 #x0A00 sd sn sm))
(defun vsub (sd sn sm) (vfp-dnm #xEE30 #x0A40 sd sn sm))
(defun vmul (sd sn sm) (vfp-dnm #xEE20 #x0A00 sd sn sm))
(defun vdiv (sd sn sm) (vfp-dnm #xEE80 #x0A00 sd sn sm))
(defun vfp-dm (op1 op2 sd sm)
  (let ((d (sreg sd)) (m (sreg sm)))
    (h32 (logior op1 (ash (ldb (byte 1 0) d) 6))
         (logior op2 (ash (ash d -1) 12) (ash (ldb (byte 1 0) m) 5) (ash m -1)))))
(defun vcvt-f32-s32 (sd sm) (vfp-dm #xEEB8 #x0AC0 sd sm))
(defun vcvt-s32-f32 (sd sm) "Round toward zero." (vfp-dm #xEEBD #x0AC0 sd sm))
(defun vsqrt (sd sm) (vfp-dm #xEEB1 #x0AC0 sd sm))
(defun vcmp (sd sm) (vfp-dm #xEEB4 #x0A40 sd sm))
(defun vmrs-apsr () "VMRS APSR_nzcv, FPSCR" (h32 #xEEF1 #xFA10))
(defun vmov-s-r (sn rt) "VMOV Sn, Rt"
  (let ((n (sreg sn))) (h32 (logior #xEE00 (ash n -1)) (logior (ash (reg rt) 12) #x0A10 (ash (ldb (byte 1 0) n) 7)))))
(defun vmov-r-s (rt sn) "VMOV Rt, Sn"
  (let ((n (sreg sn))) (h32 (logior #xEE10 (ash n -1)) (logior (ash (reg rt) 12) #x0A10 (ash (ldb (byte 1 0) n) 7)))))
