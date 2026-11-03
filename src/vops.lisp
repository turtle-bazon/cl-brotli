;;;; src/vops.lisp — SBCL-specific VOPs for the hottest encoder primitives.
;;;;
;;;; VOPs are only a speed path: this file registers an x86-64 template for
;;;; %MATCH-LEN-SAP, while src/primitives.lisp keeps the portable Lisp body
;;;; under %MATCH-LEN-SAP-LISP.  src/package.lisp installs that body as the
;;;; runtime definition, so calls compiled before this file (or through
;;;; FUNCALL) still work.

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
      (:generator 20
        (let ((loop (gen-label))
              (bytes (gen-label))
              (bytes-done (gen-label))
              (mismatch (gen-label))
              (tag (gen-label)))
          (inst mov maxl n)
          (inst sub maxl b)
          (inst mov pa a)
          (inst mov pb b)
          (inst xor len len)
          ;; Word loop: 8 bytes per iteration, first mismatching byte via TZCNT.
          (emit-label loop)
          (inst lea x (ea 8 len))
          (inst cmp x maxl)
          (inst jmp :g bytes)
          (inst mov x (sap+offset-to-ea sap pa nil))
          (inst xor x (sap+offset-to-ea sap pb nil))
          (inst jmp :ne mismatch)
          (inst add len 8)
          (inst add pa 8)
          (inst add pb 8)
          (inst jmp loop)
          (emit-label mismatch)
          (inst tzcnt x x)
          (inst shr x 3)
          (inst add x len)
          (inst mov r x)
          (inst jmp tag)
          ;; Byte tail for the final < 8 bytes.
          (emit-label bytes)
          (inst cmp len maxl)
          (inst jmp :ge bytes-done)
          (inst movzx '(:byte :qword) x (sap+offset-to-ea sap pa nil))
          (inst movzx '(:byte :qword) y (sap+offset-to-ea sap pb nil))
          (inst cmp x y)
          (inst jmp :ne bytes-done)
          (inst inc len)
          (inst inc pa)
          (inst inc pb)
          (inst jmp bytes)
          (emit-label bytes-done)
          (inst mov r len)
          (emit-label tag)
          ;; Tag the fixnum result.
          (inst shl r 1))))))
