;;;; src/huffman.lisp — canonical prefix (Huffman) codes, read LSB-first
;;;; (DEFLATE/zlib convention).  Simple + complex code descriptions (RFC 7932 §3).
(in-package #:cl-brotli.lisp)

(defconstant +max-bits+ 15)
(defconstant +huff-table-bits+ 10)

(defstruct huff (count nil :type (or null simple-vector))
  (symbol nil :type (or null simple-vector))
  (single nil)
  (table nil :type (or null simple-vector))
  (table-bits 0 :type fixnum)
  (subtables nil :type (or null vector)))

(defun %reverse-bits (value bits)
  (let ((result 0))
    (dotimes (i bits result)
      (setf result (logior (ash result 1) (logand value 1)))
      (setf value (ash value -1)))))

(defun build-huff (lengths n)
  "Canonical Huffman from code LENGTHS[0:n-1] (0 = absent), Mark-Adler style.
Builds a 10-bit primary table plus one 32-entry secondary table per long
prefix, so codes up to 15 bits decode in two lookups."
  (let ((count (make-array (1+ +max-bits+) :initial-element 0))
        (nonzero 0) (last -1) (maxlen 0))
    (dotimes (s n)
      (let ((l (aref lengths s)))
        (when (plusp l)
          (incf (aref count l))
          (incf nonzero)
          (setf last s)
          (when (> l maxlen) (setf maxlen l)))))
    (when (<= nonzero 1)
      (return-from build-huff (make-huff :single (if (= nonzero 1) last 0))))
    (let ((offs (make-array (+ 2 +max-bits+) :initial-element 0))
          (symbol (make-array n :initial-element 0)))
      (loop for l from 1 to +max-bits+ do
        (setf (aref offs (1+ l)) (+ (aref offs l) (aref count l))))
      (dotimes (s n)
        (let ((l (aref lengths s)))
          (when (plusp l)
            (setf (aref symbol (aref offs l)) s)
            (incf (aref offs l)))))
      (let* ((table-bits (min +huff-table-bits+ maxlen))
             (table (make-array (ash 1 table-bits) :initial-element 0))
             (subtables (make-array 0 :adjustable t :fill-pointer 0))
             (groups (make-hash-table :test #'eql))
             (next (make-array (1+ +max-bits+) :initial-element 0)))
        (let ((code 0))
          (loop for bits from 1 to +max-bits+ do
            (setf code (ash (+ code (aref count (1- bits))) 1)
                  (aref next bits) code)))
        (loop for len from 1 to maxlen do
          (let ((start (- (aref offs len) (aref count len))))
            (dotimes (k (aref count len))
              (let* ((sym (aref symbol (+ start k)))
                     (code (aref next len)))
                (incf (aref next len))
                (if (<= len table-bits)
                    (let ((rev (%reverse-bits code len))
                          (entry (logior (ash sym 4) len))
                          (stride (ash 1 len)))
                      (loop for base from rev below (ash 1 table-bits)
                            by stride
                            do (setf (aref table base) entry)))
                    (let* ((rem (- len table-bits))
                           (prefix (ash code (- rem)))
                           (rev-prefix (%reverse-bits prefix table-bits)))
                      (push (list sym code len)
                            (gethash rev-prefix groups))))))))
        (maphash
         (lambda (prefix items)
           (let ((sub-index (fill-pointer subtables))
                 (sub (make-array (ash 1 (- +max-bits+ table-bits))
                                  :initial-element 0)))
             (dolist (item items)
               (destructuring-bind (sym code len) item
                 (let* ((rem (- len table-bits))
                        (low (logand code (1- (ash 1 rem))))
                        (rev (%reverse-bits low rem))
                        (entry (logior (ash sym 4) rem))
                        (stride (ash 1 rem)))
                   (loop for base from rev below (length sub) by stride
                         do (setf (aref sub base) entry)))))
             (setf (aref table prefix) (ash (1+ sub-index) 4))
             (vector-push-extend sub subtables)))
         groups)
        (make-huff :count count :symbol symbol :table table
                   :table-bits table-bits :subtables subtables)))))

(declaim (inline read-huff))

(defun read-huff-slow (r h)
  (let ((code 0) (first 0) (index 0)
        (count (huff-count h)) (sym (huff-symbol h)))
    (declare (type simple-vector count sym)
             (type fixnum code first index))
    (loop for len from 1 to +max-bits+ do
      (setf code (logior code (b:rbit r)))
      (let ((c (aref count len)))
        (when (< (- code first) c)
          (return-from read-huff-slow (aref sym (+ index (- code first)))))
        (incf index c) (incf first c) (setf first (ash first 1) code (ash code 1))))
    (berr "invalid prefix code")))

(defun read-huff (r h)
  "Decode one symbol from R using canonical code H.  Short codes use the
10-bit primary table; longer codes use a secondary table."
  (when (huff-single h) (return-from read-huff (huff-single h)))
  (let ((table (huff-table h)) (table-bits (huff-table-bits h)))
    (declare (type simple-vector table)
             (type fixnum table-bits))
    (if (and table (>= (b:bits-available r) table-bits))
        (let ((entry (aref table (b:peek-bits r table-bits))))
          (declare (type fixnum entry))
          (cond
            ((plusp (logand entry 15))
             (let ((len (logand entry 15)))
               (declare (type fixnum len))
               (b:rbits r len)
               (ash entry -4)))
            ((plusp entry)
             (if (>= (b:bits-available r) (+ table-bits 5))
                 (progn
                   (b:rbits r table-bits)
                   (let* ((sub (aref (huff-subtables h)
                                     (1- (ash entry -4))))
                          (entry2 (aref sub (b:peek-bits r 5))))
                     (declare (type vector sub)
                              (type fixnum entry2))
                     (if (plusp (logand entry2 15))
                         (let ((rem (logand entry2 15)))
                           (declare (type fixnum rem))
                           (b:rbits r rem)
                           (ash entry2 -4))
                         (berr "invalid prefix code"))))
                 (read-huff-slow r h)))
            (t (read-huff-slow r h))))
        (read-huff-slow r h))))

(defun alphabet-bits (size) (max 1 (integer-length (1- size))))

;;; fixed clcl code (RFC 7932 §3.5), read LSB-first:
;;; 0->00  3->10  4->01  2->011  1->0111  5->1111
(defun read-clcl (r)
  (if (zerop (b:rbit r))
      (if (zerop (b:rbit r)) 0 3)
      (if (zerop (b:rbit r)) 4
          (if (zerop (b:rbit r)) 2
              (if (zerop (b:rbit r)) 1 5)))))

(defparameter +clcl-order+ #(1 2 3 4 0 5 17 6 16 7 8 9 10 11 12 13 14 15))

(defun read-complex-prefix (r hskip alphabet-size)
  (let ((cl-lengths (make-array 18 :initial-element 0)) (space2 0))
    (loop for i from hskip below 18 do
      (let ((len (read-clcl r)))
        (setf (aref cl-lengths (aref +clcl-order+ i)) len)
        (when (plusp len) (incf space2 (ash 32 (- len))) (when (>= space2 32) (return)))))
    (let ((clh (build-huff cl-lengths 18))
          (lengths (make-array alphabet-size :initial-element 0))
          (symbol 0) (prev-code-len 8) (repeat 0) (repeat-code-len 0) (space 32768))
      (loop while (and (< symbol alphabet-size) (> space 0)) do
        (let ((c (read-huff r clh)))
          (if (< c 16)
              (progn (setf repeat 0 (aref lengths symbol) c) (incf symbol)
                     (when (plusp c) (setf prev-code-len c) (decf space (ash 32768 (- c)))))
              (let* ((extra-bits (- c 14))                  ; 16->2, 17->3
                     (new-len (if (= c 16) prev-code-len 0)))
                (unless (= repeat-code-len new-len) (setf repeat 0 repeat-code-len new-len))
                (let ((old-repeat repeat))
                  (when (plusp repeat) (setf repeat (ash (- repeat 2) extra-bits)))
                  (incf repeat (+ (b:rbits r extra-bits) 3))
                  (let ((delta (- repeat old-repeat)))
                    (when (plusp new-len) (decf space (ash delta (- 15 new-len))))
                    (dotimes (k delta)
                      (when (< symbol alphabet-size) (setf (aref lengths symbol) new-len) (incf symbol)))))))))
      (build-huff lengths alphabet-size))))

(defun read-prefix-code (r alphabet-size)
  "Read a prefix code (simple or complex); return a HUFF."
  (let ((kind (b:rbits r 2)))
    (if (= kind 1)
        (let* ((nsym (1+ (b:rbits r 2))) (ab (alphabet-bits alphabet-size)) (syms (make-array nsym)))
          (dotimes (i nsym) (setf (aref syms i) (b:rbits r ab)))
          (if (= nsym 1)
              (make-huff :single (aref syms 0))
              (let ((lengths (make-array alphabet-size :initial-element 0)))
                (ecase nsym
                  (2 (setf (aref lengths (aref syms 0)) 1 (aref lengths (aref syms 1)) 1))
                  (3 (setf (aref lengths (aref syms 0)) 1 (aref lengths (aref syms 1)) 2 (aref lengths (aref syms 2)) 2))
                  (4 (if (= 1 (b:rbit r))
                         (setf (aref lengths (aref syms 0)) 1 (aref lengths (aref syms 1)) 2
                               (aref lengths (aref syms 2)) 3 (aref lengths (aref syms 3)) 3)
                         (dotimes (i 4) (setf (aref lengths (aref syms i)) 2)))))
                (build-huff lengths alphabet-size))))
        (read-complex-prefix r kind alphabet-size))))
