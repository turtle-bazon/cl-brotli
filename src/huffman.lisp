;;;; src/huffman.lisp — canonical prefix (Huffman) codes, read LSB-first
;;;; (DEFLATE/zlib convention).  Simple + complex code descriptions (RFC 7932 §3).
(in-package #:cl-brotli.lisp)

(declaim (optimize (speed 3) (safety 0)))

(defconstant +max-bits+ 15)
(defconstant +huff-table-bits+ 10)

(defstruct huff (count nil :type (or null (simple-array fixnum (16))))
  (lengths nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (symbol nil :type (or null simple-vector))
  (single 0 :type (integer 0 703))
  (table nil :type (or null (simple-array (unsigned-byte 16) (*))))
  (table-bits 0 :type fixnum)
  (mask 0 :type fixnum)
  (subtables nil :type (or null simple-vector)))

(defparameter +reverse-byte+
  (let ((v (make-array 256 :element-type '(unsigned-byte 8) :initial-element 0)))
    (dotimes (i 256 v)
      (let ((x i) (r 0))
        (dotimes (k 8)
          (setf r (logior (ash r 1) (logand x 1)) x (ash x -1)))
        (setf (aref v i) r)))))

(declaim (type (simple-array (unsigned-byte 8) (256)) +reverse-byte+))
(declaim (inline %reverse-bits))
(defun %reverse-bits (value bits)
  "Reverse the low BITS bits of VALUE (0 <= BITS <= 15)."
  (declare (type (unsigned-byte 16) value) (type (integer 0 16) bits)
           (optimize (speed 3) (safety 0)))
  (ash (logior (ash (aref +reverse-byte+ (logand value #xff)) 8)
               (aref +reverse-byte+ (logand (ash value -8) #xff)))
       (- bits 16)))

(defun build-huff (lengths n)
  "Canonical Huffman from code LENGTHS[0:n-1] (0 = absent), Mark-Adler style.
Builds a 10-bit primary table plus one 32-entry secondary table per long
prefix, so codes up to 15 bits decode in two lookups.  The sorted symbol
permutation used by the slow path is built lazily, because it is only needed
for the last few bits of a stream.  The code must be complete (the readers
reject anything else), so every table entry is written."
  (declare (type (simple-array (unsigned-byte 8) (*)) lengths)
           (type (integer 0 1024) n)
           (optimize (speed 3) (safety 0)))
  (let ((count (make-array (1+ +max-bits+) :element-type 'fixnum
                                           :initial-element 0))
        (nonzero 0) (last 0) (maxlen 0))
    (declare (type (simple-array fixnum (16)) count)
             (type fixnum nonzero last) (type (integer 0 15) maxlen))
    (dotimes (s n)
      (let ((l (aref lengths s)))
        (declare (type (integer 0 15) l))
        (when (plusp l)
          (incf (aref count l))
          (incf nonzero)
          (setf last s)
          (when (> l maxlen) (setf maxlen l)))))
    (when (<= nonzero 1)
      (return-from build-huff (make-huff :single last)))
    (let* ((table-bits (min +huff-table-bits+ maxlen))
           (tsize (ash 1 table-bits))
           (table (make-array tsize :element-type '(unsigned-byte 16)
                                    :initial-element 0))
           ;; Each long code's 10-bit prefix owns at most one subtable, so
           ;; the number of long codes bounds the subtable count: one
           ;; allocation, no adjustable vector, no final COERCE.
           (nlong (loop for l of-type fixnum from (1+ table-bits) to +max-bits+
                        sum (aref count l) of-type fixnum))
           (subtables (if (plusp nlong) (make-array (min nlong tsize)) #()))
           (nsub 0)
           (next (make-array (1+ +max-bits+) :element-type 'fixnum
                                             :initial-element 0)))
      (declare (type (integer 1 10) table-bits)
               (type (integer 2 1024) tsize)
               (type (simple-array (unsigned-byte 16) (*)) table)
               (type fixnum nlong nsub)
               (type simple-vector subtables)
               (type (simple-array fixnum (16)) next))
      (let ((code 0))
        (declare (type fixnum code))
        (loop for bits of-type fixnum from 1 to +max-bits+ do
          (setf code (ash (+ code (aref count (1- bits))) 1)
                (aref next bits) code)))
      ;; Walk the symbols in input order: canonical codes for a given length
      ;; increase with symbol number, so NEXT[LEN] assigns them directly.
      (dotimes (sym n)
        (let ((len (aref lengths sym)))
          (declare (type (integer 0 15) len))
          (when (plusp len)
            (let ((code (aref next len)))
              (declare (type (unsigned-byte 15) code))
              (setf (aref next len) (1+ code))
              (if (<= len table-bits)
                  (let ((entry (logior (ash sym 4) len))
                        (stride (ash 1 len)))
                    (declare (type (unsigned-byte 16) entry) (type fixnum stride))
                    (loop for base of-type fixnum
                            from (%reverse-bits code len) below tsize by stride
                          do (setf (aref table base) entry)))
                  (let* ((rem (- len table-bits))
                         (rev-prefix (%reverse-bits (ash code (- rem)) table-bits))
                         (marker (aref table rev-prefix))
                         (sub (if (zerop marker)
                                  (let ((new (make-array
                                              32 ; 2^(+max-bits+ - +huff-table-bits+)
                                              :element-type '(unsigned-byte 16)
                                              :initial-element 0)))
                                    (setf (svref subtables nsub) new)
                                    (incf nsub)
                                    (setf (aref table rev-prefix) (ash nsub 4))
                                    new)
                                  (svref subtables (1- (ash marker -4)))))
                         (entry (logior (ash sym 4) rem))
                         (stride (ash 1 rem)))
                    (declare (type (integer 1 5) rem)
                             (type (unsigned-byte 16) marker entry)
                             (type (simple-array (unsigned-byte 16) (32)) sub)
                             (type fixnum stride))
                    (loop for base of-type fixnum
                            from (%reverse-bits (logand code (1- (ash 1 rem))) rem)
                            below 32 by stride
                          do (setf (aref sub base) entry))))))))
      (make-huff :count count :lengths lengths :table table
                 :table-bits table-bits
                 :mask (1- tsize)
                 :subtables subtables))))

(defun huff-ensure-symbols (h)
  "Build H's length-sorted symbol permutation on demand (slow path only)."
  (declare (type huff h))
  (or (huff-symbol h)
      (let* ((lengths (huff-lengths h))
             (n (length lengths))
             (count (huff-count h))
             (offs (make-array (+ 2 +max-bits+) :initial-element 0))
             (symbol (make-array n :initial-element 0)))
        (loop for l from 1 to +max-bits+ do
          (setf (aref offs (1+ l)) (+ (aref offs l) (aref count l))))
        (dotimes (s n)
          (let ((l (aref lengths s)))
            (when (plusp l)
              (setf (aref symbol (aref offs l)) s)
              (incf (aref offs l)))))
        (setf (huff-symbol h) symbol))))

(declaim (inline consume-bits))
(defun consume-bits (r n)
  "Discard N bits that PEEK-BITS has already made available."
  (declare (type b:brd r) (type fixnum n)
           (optimize (speed 3) (safety 0)))
  (setf (b:brd-acc r) (ash (b:brd-acc r) (- n)))
  (decf (b:brd-nbits r) n))

(declaim (inline read-huff))
;; Decoded symbols are < 704 (the largest alphabet).  Without a declared
;; result type every comparison on a symbol (block switches, context maps,
;; the command loop) compiled to generic arithmetic.
(declaim (ftype (function (t t) (values (integer 0 4095) &optional))
                read-huff read-huff-slow))

(defun read-huff-slow (r h)
  (declare (type huff h))
  (let ((code 0) (first 0) (index 0)
        (count (huff-count h)) (sym (huff-ensure-symbols h)))
    (declare (type (simple-array fixnum (16)) count) (type simple-vector sym)
             (type fixnum code first index))
    (loop for len from 1 to +max-bits+ do
      (setf code (logior code (b:rbit r)))
      (let ((c (aref count len)))
        (when (< (- code first) c)
          (return-from read-huff-slow (svref sym (+ index (- code first)))))
        (incf index c) (incf first c) (setf first (ash first 1) code (ash code 1))))
    (berr "invalid prefix code")))

(defun read-huff (r h)
  "Decode one symbol from R using canonical code H.  Short codes use the
10-bit primary table; longer codes use a secondary table.  PEEK-BITS fills
the reservoir or signals end-of-input, so the old BITS-AVAILABLE guards are
redundant on the fast path."
  (declare (type huff h))
  (unless (huff-table h) (return-from read-huff (huff-single h)))
  (let ((table (huff-table h)) (table-bits (huff-table-bits h)))
    (declare (type (simple-array (unsigned-byte 16) (*)) table)
             (type fixnum table-bits))
    ;; A valid stream may end with a code shorter than the primary table
    ;; width.  PEEK-BITS would otherwise insist on TABLE-BITS bits and report
    ;; end-of-input; the canonical slow walk can decode the remaining bits.
    (if (or (>= (b:brd-nbits r) table-bits)
            (>= (b:bits-available r) table-bits))
        (let ((entry (aref table
                           (progn
                              (unless (>= (b:brd-nbits r) table-bits)
                                (b::%fill-bits r table-bits))
                              (logand (b:brd-acc r) (huff-mask h))))))
          (declare (type fixnum entry))
          (cond
            ((plusp (logand entry 15))
             (let ((len (logand entry 15)))
               (declare (type fixnum len))
               (consume-bits r len)
               (ash entry -4)))
            ((plusp entry)
             (if (or (>= (b:brd-nbits r) (+ table-bits 5))
                     (>= (b:bits-available r) (+ table-bits 5)))
                 (progn
                   (consume-bits r table-bits)
                   (let* ((subs (huff-subtables h))
                          (sub (aref subs (1- (ash entry -4))))
                          (entry2 (aref sub
                                          (progn
                                            (unless (>= (b:brd-nbits r) 5)
                                              (b::%fill-bits r 5))
                                            (logand (b:brd-acc r) #x1F)))))
                     (declare (type simple-vector subs)
                              (type (simple-array (unsigned-byte 16) (*)) sub)
                              (type fixnum entry2))
                     (if (plusp (logand entry2 15))
                         (let ((rem (logand entry2 15)))
                           (declare (type fixnum rem))
                           (consume-bits r rem)
                           (ash entry2 -4))
                         (berr "invalid prefix code"))))
                 (read-huff-slow r h)))
            (t (read-huff-slow r h))))
        (read-huff-slow r h))))

(defun alphabet-bits (size) (max 1 (integer-length (1- size))))

;;; fixed clcl code (RFC 7932 §3.5), read LSB-first:
;;; 0->00  3->10  4->01  2->011  1->0111  5->1111
(declaim (inline read-clcl))
(defun read-clcl (r)
  (declare (type b:brd r) (optimize (speed 3) (safety 0)))
  (if (zerop (b:rbit r))
      (if (zerop (b:rbit r)) 0 3)
      (if (zerop (b:rbit r)) 4
          (if (zerop (b:rbit r)) 2
              (if (zerop (b:rbit r)) 1 5)))))

(defparameter +clcl-order+
  (coerce '(1 2 3 4 0 5 17 6 16 7 8 9 10 11 12 13 14 15) '(simple-array fixnum (18))))
(declaim (type (simple-array fixnum (18)) +clcl-order+))

(defun read-complex-prefix (r hskip alphabet-size)
  (declare (type b:brd r) (type (integer 0 3) hskip)
           (type (integer 1 1024) alphabet-size)
           (optimize (speed 3) (safety 0)))
  (let ((cl-lengths (make-array 18 :element-type '(unsigned-byte 8)
                                     :initial-element 0))
          (space2 0) (ncodes 0))
    (declare (type fixnum space2 ncodes))
    (loop for i of-type fixnum from hskip below 18 do
      (let ((len (read-clcl r)))
        (declare (type (integer 0 5) len))
        (setf (aref cl-lengths (aref +clcl-order+ i)) len)
        (when (plusp len)
          (incf ncodes)
          (incf space2 (ash 32 (- len)))
          (when (>= space2 32) (return)))))
    ;; C: BROTLI_DECODER_ERROR_FORMAT_CL_SPACE.  An over- or under-full
    ;; code-length code would make BUILD-HUFF index past its tables.
    (unless (or (= ncodes 1) (= space2 32))
      (cl-brotli.lisp::berr "invalid code-length code"))
    (let ((clh (build-huff cl-lengths 18))
          (lengths (make-array alphabet-size
                                  :element-type '(unsigned-byte 8)
                                  :initial-element 0))
          (symbol 0) (prev-code-len 8) (repeat 0) (repeat-code-len 0) (space 32768))
      (declare (type fixnum symbol repeat space)
               (type (integer 0 15) prev-code-len repeat-code-len))
      (loop while (and (< symbol alphabet-size) (> space 0)) do
        (let ((c (read-huff r clh)))
          (declare (type (integer 0 17) c))
          (if (< c 16)
              (progn (setf repeat 0 (aref lengths symbol) c) (incf symbol)
                     (when (plusp c) (setf prev-code-len c) (decf space (ash 32768 (- c)))))
              (let* ((extra-bits (- c 14))                  ; 16->2, 17->3
                     (new-len (if (= c 16) prev-code-len 0)))
                (declare (type (integer 2 3) extra-bits) (type (integer 0 15) new-len))
                (unless (= repeat-code-len new-len) (setf repeat 0 repeat-code-len new-len))
                (let ((old-repeat repeat))
                  (when (plusp repeat) (setf repeat (ash (- repeat 2) extra-bits)))
                  (incf repeat (+ (b:rbits r extra-bits) 3))
                  (let ((delta (- repeat old-repeat)))
                    (declare (type fixnum delta))
                    (when (plusp new-len) (decf space (ash delta (- 15 new-len))))
                    (dotimes (k delta)
                      (when (< symbol alphabet-size) (setf (aref lengths symbol) new-len) (incf symbol)))))))))
      ;; C: BROTLI_DECODER_ERROR_FORMAT_HUFFMAN_SPACE - the code must be
      ;; exactly complete.
      (unless (zerop space)
        (cl-brotli.lisp::berr "incomplete or oversubscribed prefix code"))
      (build-huff lengths alphabet-size))))

(defun read-prefix-code (r alphabet-size)
  "Read a prefix code (simple or complex); return a HUFF."
  (let ((kind (b:rbits r 2)))
    (if (= kind 1)
        (let* ((nsym (1+ (b:rbits r 2))) (ab (alphabet-bits alphabet-size)) (syms (make-array nsym)))
          (dotimes (i nsym)
            (let ((v (b:rbits r ab)))
              ;; C: ..._SIMPLE_HUFFMAN_ALPHABET / ..._SIMPLE_HUFFMAN_SAME
              (when (>= v alphabet-size)
                (cl-brotli.lisp::berr "prefix symbol ~d outside alphabet ~d" v alphabet-size))
              (dotimes (j i)
                (when (= v (aref syms j))
                  (cl-brotli.lisp::berr "duplicate symbol in simple prefix code")))
              (setf (aref syms i) v)))
          (if (= nsym 1)
              (make-huff :single (aref syms 0))
              (let ((lengths (make-array alphabet-size
                                  :element-type '(unsigned-byte 8)
                                  :initial-element 0)))
                (ecase nsym
                  (2 (setf (aref lengths (aref syms 0)) 1 (aref lengths (aref syms 1)) 1))
                  (3 (setf (aref lengths (aref syms 0)) 1 (aref lengths (aref syms 1)) 2 (aref lengths (aref syms 2)) 2))
                  (4 (if (= 1 (b:rbit r))
                         (setf (aref lengths (aref syms 0)) 1 (aref lengths (aref syms 1)) 2
                               (aref lengths (aref syms 2)) 3 (aref lengths (aref syms 3)) 3)
                         (dotimes (i 4) (setf (aref lengths (aref syms i)) 2)))))
                (build-huff lengths alphabet-size))))
        (read-complex-prefix r kind alphabet-size))))
