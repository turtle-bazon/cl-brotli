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

(declaim (inline %hash4-sap %hash4-tail))
(declaim (inline %hashf-sap))
(defun %hashf-sap (sap i shift hmask)
  "C Brotli's fast-fragment hash: take the TOP table-bits of the 64-bit
product (input << 24) * kHashMul32 with shift = 64 - table-bits, like
compress_fragment.c's Hash().  The whole chain stays inside
(unsigned-byte 64) locals, which SBCL keeps untagged.  SHIFT is passed in
so q0 (15-bit table) and q1 (17-bit) both get C's exact hash."
  (declare (type ptr sap) (type fixnum i shift hmask)
            (optimize (speed 3) (safety 0)))
  (let* ((w (ptr-u64 sap i))
         (b (the (unsigned-byte 64)
                 (ash (the (unsigned-byte 40) (logand w #xFFFFFFFFFF))
                      24)))
         (c (the (unsigned-byte 64)
                 (logand (* b #x1E35A7BD)
                         #xFFFFFFFFFFFFFFFF)))
         (h (the (unsigned-byte 31) (ash c shift))))
    (the (unsigned-byte 32) (logand h hmask))))

;; Tail-hash byte: DATA[J], or 0 past the end.
(defmacro %tail-byte (data j)
  (let ((d (gensym)) (k (gensym)))
    `(let ((,d ,data) (,k ,j))
       (declare (type (simple-array (unsigned-byte 8) (*)) ,d) (type fixnum ,k))
       (if (< ,k (length ,d)) (aref ,d ,k) 0))))

(defun %hashf-tail (data i shift hmask)
  "The last few trawl positions cannot use the unaligned 8-byte load
(xs the head of the vector is only n bytes); build the same (w<<24)*k
value from five byte loads instead.  Slow path: at most a handful of
positions per compress call."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum i shift hmask)
           (optimize (speed 3) (safety 0)))
  ;; Bytes past the end read as zero, like C's zero-filled ring-buffer
  ;; slack: the last position's 5-byte hash would otherwise read DATA[N],
  ;; whatever happens to follow the vector in memory.
  (let* ((w (logior (%tail-byte data i)
                    (ash (%tail-byte data (+ i 1)) 8)
                    (ash (%tail-byte data (+ i 2)) 16)
                    (ash (%tail-byte data (+ i 3)) 24)
                    (ash (%tail-byte data (+ i 4)) 32)))
         (c (logand (* (logand (ash w 24) (1- (ash 1 64))) #x1E35A7BD)
                    (1- (ash 1 64)))))
    (logand (ash c shift) hmask)))

(defun %hash4-sap (sap i shift hmask)
  "The chain matcher's hash, same u64 algebra as %hashf-sap: the top
table-bits of ((input<<24) mod 2^64) * kHashMul32, via untagged
(unsigned-byte 64) locals.  The old load-32 + fixnum-tagged version took
bits 15..30 of the 32-bit product, so the 17-bit chain table's top half
was never reachable; this restores the full spread."
  (declare (type ptr sap) (type fixnum i shift hmask)
           (optimize (speed 3) (safety 0)))
  (let* ((w (ptr-u64 sap i))
         (b (the (unsigned-byte 64)
                 (ash (the (unsigned-byte 40) (logand w #xFFFFFFFFFF))
                      24)))
         (c (the (unsigned-byte 64)
                 (logand (* b #x1E35A7BD)
                         #xFFFFFFFFFFFFFFFF)))
         (h (the (unsigned-byte 31) (ash c shift))))
    (the (unsigned-byte 32) (logand h hmask))))

(defun %hash4-tail (data i shift hmask)
  "Chain-hash tail build for positions within 3 bytes of the data end
(the 8-byte load in %hash4-sap would cross the boundary)."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum i shift hmask)
           (optimize (speed 3) (safety 0)))
  ;; Bytes past the end read as zero, like C's zero-filled ring-buffer
  ;; slack: the last position's 5-byte hash would otherwise read DATA[N],
  ;; whatever happens to follow the vector in memory.
  (let* ((w (logior (%tail-byte data i)
                    (ash (%tail-byte data (+ i 1)) 8)
                    (ash (%tail-byte data (+ i 2)) 16)
                    (ash (%tail-byte data (+ i 3)) 24)
                    (ash (%tail-byte data (+ i 4)) 32)))
         (c (logand (* (logand (ash w 24) (1- (ash 1 64))) #x1E35A7BD)
                    (1- (ash 1 64)))))
    (logand (ash c shift) hmask)))

(declaim (inline %trailing-zeros))
(defun %trailing-zeros (x)
  (declare (type (unsigned-byte 64) x)
           (optimize (speed 3) (safety 0)))
  (ctz64 x))

#-cl-brotli-x86-64
(declaim (inline %match-len-sap))
(defun #+cl-brotli-x86-64 %match-len-sap-lisp #-cl-brotli-x86-64 %match-len-sap (sap a b n)
  "Portable body behind the %MATCH-LEN-SAP VOP.  Word-at-a-time match
extension; A < B and A+MAXL < N, so 8-byte loads at both ends stay inside
the vector.  On a mismatch inside a word, TZCNT finds the first differing
byte in one step (the same trick as C Brotli's FindMatchLengthWithLimit)."
  (declare (type ptr sap)
           (type fixnum a b n)
           (optimize (speed 3) (safety 0)))
  (let ((len 0) (maxl (- n b)))
    (declare (type fixnum len maxl))
    (loop while (<= (+ len 8) maxl)
          do (let ((x (logxor (ptr-u64 sap (+ a len))
                              (ptr-u64 sap (+ b len)))))
               (declare (type (unsigned-byte 64) x))
               (unless (zerop x)
                 (return-from #+cl-brotli-x86-64 %match-len-sap-lisp
                              #-cl-brotli-x86-64 %match-len-sap
                   (+ len (ash (%trailing-zeros x) -3))))
               (incf len 8)))
    (loop while (and (< len maxl)
                     (= (ptr-u8 sap (+ a len))
                        (ptr-u8 sap (+ b len))))
          do (incf len))
    len))

(declaim (inline %match-len-sap-frag))
(defun %match-len-sap-frag (sap a b n)
  "Single-expansion copy of %MATCH-LEN-SAP for the fragment matcher."
  (declare (type ptr sap)
           (type fixnum a b n)
           (optimize (speed 3) (safety 0)))
  (let ((len 0) (maxl (- n b)))
    (declare (type fixnum len maxl))
    (loop while (<= (+ len 8) maxl)
          do (let ((x (logxor (ptr-u64 sap (+ a len))
                              (ptr-u64 sap (+ b len)))))
               (declare (type (unsigned-byte 64) x))
               (unless (zerop x)
                 (return-from %match-len-sap-frag
                   (+ len (ash (%trailing-zeros x) -3))))
               (incf len 8)))
    (loop while (and (< len maxl)
                     (= (ptr-u8 sap (+ a len))
                        (ptr-u8 sap (+ b len))))
          do (incf len))
    len))

(declaim (inline %match-len-sap-frag2))
(defun %match-len-sap-frag2 (sap a b n)
  "Second single-expansion copy of %MATCH-LEN-SAP."
  (declare (type ptr sap)
           (type fixnum a b n)
           (optimize (speed 3) (safety 0)))
  (let ((len 0) (maxl (- n b)))
    (declare (type fixnum len maxl))
    (loop while (<= (+ len 8) maxl)
          do (let ((x (logxor (ptr-u64 sap (+ a len))
                              (ptr-u64 sap (+ b len)))))
               (declare (type (unsigned-byte 64) x))
               (unless (zerop x)
                 (return-from %match-len-sap-frag2
                   (+ len (ash (%trailing-zeros x) -3))))
               (incf len 8)))
    (loop while (and (< len maxl)
                     (= (ptr-u8 sap (+ a len))
                        (ptr-u8 sap (+ b len))))
          do (incf len))
    len))

(defun %match-len-sap-call (sap a b n)
  "%MATCH-LEN-SAP behind a non-inlined call boundary.  The fragment matcher
uses this so the inlined RETURN-FROM block exists only once per expansion."
  (declare (type ptr sap) (type fixnum a b n)
           (optimize (speed 3) (safety 0)))
  (%match-len-sap sap a b n))
