;;;; src/primitives.lisp — hot byte/SAP primitives shared by the encoder.
(in-package #:cl-brotli.lisp)

;;; ---- LZ77 (greedy hash-chain match finder) ----------------------------

(declaim (inline %hash4 %match-len))
(defun %hash4 (data i hmask)
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum i hmask)
           (optimize (speed 3) (safety 0)))
  (let ((v (logior (aref data i) (ash (aref data (1+ i)) 8)
                   (ash (aref data (+ i 2)) 16) (ash (aref data (+ i 3)) 24))))
    (logand (ash (logand (the (unsigned-byte 64)
                              (* (the (unsigned-byte 32) v) 2654435761))
                         #xffffffff)
                 -15)
            hmask)))

(defun %match-len (data a b n)
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum a b n)
           (optimize (speed 3) (safety 0)))
  (let ((len 0) (maxl (- n b)))
    (declare (type fixnum len maxl))
    (loop while (and (< len maxl) (= (aref data (+ a len)) (aref data (+ b len)))) do (incf len))
    len))

#+sbcl
(declaim (inline %hash4-sap))
#+sbcl
(declaim (inline %hashf-sap))
#+sbcl
(defun %hashf-sap (sap i hmask)
  "C Brotli's fast-fragment hash: multiply the low 32-bit word by kHashMul32
and take the high bits, masked to the table size.  The constant -15 shift
keeps ASH inline."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum i hmask)
           (optimize (speed 3) (safety 0)))
  (let ((v (sb-sys:sap-ref-32 sap i)))
    (logand (ash (logand (the (unsigned-byte 64)
                              (* (the (unsigned-byte 32) v) #x1E35A7BD))
                         #xFFFFFFFF)
                 -15)
            hmask)))

#+sbcl
(defun %hash4-sap (sap i hmask)
  (declare (type sb-sys:system-area-pointer sap) (type fixnum i hmask)
           (optimize (speed 3) (safety 0)))
  (let ((v (sb-sys:sap-ref-32 sap i)))
    (logand (ash (logand (the (unsigned-byte 64)
                              (* (the (unsigned-byte 32) v) 2654435761))
                         #xffffffff)
                 -15)
            hmask)))

#+(and sbcl x86-64 64-bit little-endian)
(declaim (inline %trailing-zeros))
#+(and sbcl x86-64 64-bit little-endian)
(defun %trailing-zeros (x)
  (declare (type (unsigned-byte 64) x)
           (optimize (speed 3) (safety 0)))
  (sb-kernel:count-trailing-zeros x))

#+(and sbcl x86-64 64-bit little-endian)
(defun %match-len-sap-lisp (sap a b n)
  "Portable body behind the %MATCH-LEN-SAP VOP.  Word-at-a-time match
extension; A < B and A+MAXL < N, so 8-byte loads at both ends stay inside
the vector.  On a mismatch inside a word, TZCNT finds the first differing
byte in one step (the same trick as C Brotli's FindMatchLengthWithLimit)."
  (declare (type sb-sys:system-area-pointer sap)
           (type fixnum a b n)
           (optimize (speed 3) (safety 0)))
  (let ((len 0) (maxl (- n b)))
    (declare (type fixnum len maxl))
    (loop while (<= (+ len 8) maxl)
          do (let ((x (logxor (sb-sys:sap-ref-64 sap (+ a len))
                              (sb-sys:sap-ref-64 sap (+ b len)))))
               (declare (type (unsigned-byte 64) x))
               (unless (zerop x)
                 (return-from %match-len-sap-lisp
                   (+ len (ash (%trailing-zeros x) -3))))
               (incf len 8)))
    (loop while (and (< len maxl)
                     (= (sb-sys:sap-ref-8 sap (+ a len))
                        (sb-sys:sap-ref-8 sap (+ b len))))
          do (incf len))
    len))

#+(and sbcl x86-64 64-bit little-endian)
(declaim (inline %match-len-sap-frag))
#+(and sbcl x86-64 64-bit little-endian)
(defun %match-len-sap-frag (sap a b n)
  "Single-expansion copy of %MATCH-LEN-SAP for the fragment matcher."
  (declare (type sb-sys:system-area-pointer sap)
           (type fixnum a b n)
           (optimize (speed 3) (safety 0)))
  (let ((len 0) (maxl (- n b)))
    (declare (type fixnum len maxl))
    (loop while (<= (+ len 8) maxl)
          do (let ((x (logxor (sb-sys:sap-ref-64 sap (+ a len))
                              (sb-sys:sap-ref-64 sap (+ b len)))))
               (declare (type (unsigned-byte 64) x))
               (unless (zerop x)
                 (return-from %match-len-sap-frag
                   (+ len (ash (%trailing-zeros x) -3))))
               (incf len 8)))
    (loop while (and (< len maxl)
                     (= (sb-sys:sap-ref-8 sap (+ a len))
                        (sb-sys:sap-ref-8 sap (+ b len))))
          do (incf len))
    len))

#+(and sbcl x86-64 64-bit little-endian)
(declaim (inline %match-len-sap-frag2))
#+(and sbcl x86-64 64-bit little-endian)
(defun %match-len-sap-frag2 (sap a b n)
  "Second single-expansion copy of %MATCH-LEN-SAP."
  (declare (type sb-sys:system-area-pointer sap)
           (type fixnum a b n)
           (optimize (speed 3) (safety 0)))
  (let ((len 0) (maxl (- n b)))
    (declare (type fixnum len maxl))
    (loop while (<= (+ len 8) maxl)
          do (let ((x (logxor (sb-sys:sap-ref-64 sap (+ a len))
                              (sb-sys:sap-ref-64 sap (+ b len)))))
               (declare (type (unsigned-byte 64) x))
               (unless (zerop x)
                 (return-from %match-len-sap-frag2
                   (+ len (ash (%trailing-zeros x) -3))))
               (incf len 8)))
    (loop while (and (< len maxl)
                     (= (sb-sys:sap-ref-8 sap (+ a len))
                        (sb-sys:sap-ref-8 sap (+ b len))))
          do (incf len))
    len))

#+(and sbcl x86-64 64-bit little-endian)
(defun %match-len-sap-call (sap a b n)
  "%MATCH-LEN-SAP behind a non-inlined call boundary.  The fragment matcher
uses this so the inlined RETURN-FROM block exists only once per expansion."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum a b n)
           (optimize (speed 3) (safety 0)))
  (%match-len-sap sap a b n))
