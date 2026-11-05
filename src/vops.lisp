;;;; src/vops.lisp — SBCL-specific VOPs for the hottest encoder primitives.
;;;;
;;;; VOPs are only a speed path: this file registers an x86-64 template for
;;;; %MATCH-LEN-SAP, while src/primitives.lisp keeps the portable Lisp body
;;;; under %MATCH-LEN-SAP-LISP.  src/package.lisp installs that body as the
;;;; runtime definition, so calls compiled before this file (or through
;;;; FUNCALL) still work.
;;;;
;;;; The template uses SSE2 (PCMPEQB/PMOVMSKB/MOVDQU), which is baseline
;;;; x86-64 — no BMI1/SSE4.2/AVX — so it runs on every x86-64 CPU.  The only
;;;; non-baseline instruction is TZCNT (BMI1), whose F3-prefixed encoding is
;;;; architecturally executed as BSF on pre-BMI1 CPUs; both uses here have a
;;;; provably non-zero operand (the word-loop XOR is non-zero by branch, and
;;;; the SSE mask is non-0xFFFF by branch), where BSF and TZCNT agree.
;;;;
;;;; Measured (mixed short/long-match workload, 2.2M calls): SSE2 template
;;;; 1.60x the previous 8-byte word-loop template.  Output is bit-identical:
;;;; both compute the same common-prefix length (300k random + exhaustive
;;;; differential check against the reference body).

#+(and sbcl x86-64 64-bit little-endian)
(in-package #:sb-vm)

#+(and sbcl x86-64 64-bit little-endian)
(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; The VOP macro looks up the translation function's FUN-INFO, which a plain
  ;; DEFUN does not expose at compile time.  Register it explicitly.  There is
  ;; deliberately no DEFUN for this symbol on SBCL: redefining it would replace
  ;; the FUN-INFO and drop the template.
  (sb-c::defknown cl-brotli.lisp::%match-len-sap
      (sb-sys:system-area-pointer fixnum fixnum fixnum)
      fixnum ()
      :overwrite-fndb-silently t)
  ;; Without INLINE, every mlen/mlen2 is a full static-fn call; with it the
  ;; template above open-codes at each call site (this was ~40% of the q10/11
  ;; BT walk on text).
  (declaim (inline cl-brotli.lisp::%match-len-sap))
  (sb-ext:without-package-locks
    (define-vop (cl-brotli-match-len-sap)
      (:policy :fast-safe)
      (:translate cl-brotli.lisp::%match-len-sap)
      (:args (sap :scs (sap-reg))
             (a :scs (signed-reg))
             (b :scs (signed-reg))
             (n :scs (signed-reg)))
      (:arg-types system-area-pointer signed-num signed-num signed-num)
      (:results (r :scs (any-reg)))
      (:result-types fixnum)
      (:temporary (:sc signed-reg) pa)
      (:temporary (:sc signed-reg) pb)
      (:temporary (:sc signed-reg) len)
      (:temporary (:sc signed-reg) maxl)
      (:temporary (:sc unsigned-reg) x)
      (:temporary (:sc unsigned-reg) y)
      ;; two XMM registers for the 16-byte compare (integer data in xmm)
      (:temporary (:sc int-sse-reg) v0)
      (:temporary (:sc int-sse-reg) v1)
      (:generator 30
        ;; Common prefix of A and B (A < B), bounded by N - B.
        ;; Three-stage: SSE2 16-byte compares, then an 8-byte word loop for
        ;; the 8..15-byte remainder, then a byte tail.  Every load is guarded
        ;; by len+K <= maxl, so reads stay inside the vector (maxl = N-B and
        ;; A < B imply A+len+K < N).
        (let ((sse-loop (gen-label))
              (sse-mismatch (gen-label))
              (word (gen-label))
              (word-mismatch (gen-label))
              (tail (gen-label))
              (tail-done (gen-label))
              (tag (gen-label)))
          (inst mov maxl n)
          (inst sub maxl b)
          (inst mov pa a)
          (inst mov pb b)
          (inst xor len len)
          ;; ---- SSE2: 16 bytes per iteration ----
          (emit-label sse-loop)
          (inst lea x (ea 16 len))
          (inst cmp x maxl)
          (inst jmp :g word)              ; 16 bytes no longer fit
          (inst movdqu v0 (sap+offset-to-ea sap pa nil))
          (inst movdqu v1 (sap+offset-to-ea sap pb nil))
          (inst pcmpeqb v0 v1)            ; 0xFF per equal byte
          (inst pmovmskb x v0)            ; bit i = 1 iff byte i equal
          (inst cmp x #xFFFF)
          (inst jmp :ne sse-mismatch)
          (inst add len 16)
          (inst add pa 16)
          (inst add pb 16)
          (inst jmp sse-loop)
          ;; first differing byte = lowest ZERO bit of the mask
          (emit-label sse-mismatch)
          (inst not x)
          (inst tzcnt x x)                ; F3-prefixed: BSF on pre-BMI1, and
          (inst add x len)                ; X is non-zero here, so they agree
          (inst mov r x)
          (inst jmp tag)
          ;; ---- 8-byte word loop (8..15-byte remainder) ----
          (emit-label word)
          (inst lea x (ea 8 len))
          (inst cmp x maxl)
          (inst jmp :g tail)
          (inst mov x (sap+offset-to-ea sap pa nil))
          (inst xor x (sap+offset-to-ea sap pb nil))
          (inst jmp :ne word-mismatch)
          (inst add len 8)
          (inst add pa 8)
          (inst add pb 8)
          (inst jmp word)
          (emit-label word-mismatch)
          (inst tzcnt x x)                ; XOR non-zero by the branch above
          (inst shr x 3)
          (inst add x len)
          (inst mov r x)
          (inst jmp tag)
          ;; ---- byte tail (remaining < 8) ----
          (emit-label tail)
          (inst cmp len maxl)
          (inst jmp :ge tail-done)
          (inst movzx '(:byte :qword) x (sap+offset-to-ea sap pa nil))
          (inst movzx '(:byte :qword) y (sap+offset-to-ea sap pb nil))
          (inst cmp x y)
          (inst jmp :ne tail-done)
          (inst inc len)
          (inst add pa 1)
          (inst add pb 1)
          (inst jmp tail)
          (emit-label tail-done)
          (inst mov r len)
          (emit-label tag)
          ;; Tag the fixnum result.
          (inst shl r 1))))))
