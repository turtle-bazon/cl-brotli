;;;; src/bitio.lisp — brotli bit I/O: LSB-first (low bit of each byte first),
;;;; same convention as DEFLATE.
(in-package #:cl-brotli.pure.bitio)
(deftype octets () '(simple-array (unsigned-byte 8) (*)))
(defun to-octets (s)
  (cond ((typep s 'octets) s)
        ((stringp s)
         (map '(simple-array (unsigned-byte 8) (*)) #'char-code s))
        (t (coerce s '(simple-array (unsigned-byte 8) (*))))))

(defstruct (brd (:constructor make-brd (bytes &optional (pos 0) (end (length bytes)))))
  (bytes nil :type octets) (pos 0 :type fixnum) (end 0 :type fixnum)
  ;; Bit accumulator: ACC holds NBITS unconsumed bits, least-significant bit
  ;; first.  Loading whole bytes at a time avoids the old bit-by-bit loop.
  (acc 0 :type fixnum) (nbits 0 :type fixnum))

(defun r-eof-p (r)
  (and (>= (brd-pos r) (brd-end r)) (zerop (brd-nbits r))))

(declaim (inline %fill-bits rbits rbit))
(defun %fill-bits (r n)
  (declare (type brd r) (type fixnum n) (optimize (speed 3) (safety 0)))
  (loop while (< (brd-nbits r) n) do
    (when (>= (brd-pos r) (brd-end r))
      (error "brotli: end of input"))
    (setf (brd-acc r)
          (logior (brd-acc r)
                  (ash (aref (brd-bytes r) (brd-pos r)) (brd-nbits r))))
    (incf (brd-nbits r) 8)
    (incf (brd-pos r))))

(defun rbits (r n)
  "Read N bits, LSB-first, as an integer."
  (declare (type brd r) (type fixnum n) (optimize (speed 3) (safety 0)))
  (if (zerop n)
      0
      (progn
        (%fill-bits r n)
        (let ((v (logand (brd-acc r) (1- (ash 1 n)))))
          (setf (brd-acc r) (ash (brd-acc r) (- n)))
          (decf (brd-nbits r) n)
          v))))

(defun rbit (r) (rbits r 1))

(defun peek-bits (r n)
  "Return the next N bits without consuming them."
  (declare (type brd r) (type fixnum n) (optimize (speed 3) (safety 0)))
  (if (zerop n)
      0
      (progn
        (%fill-bits r n)
        (logand (brd-acc r) (1- (ash 1 n))))))

(defun bits-available (r)
  "Number of bits remaining, including bits already buffered in ACC."
  (+ (brd-nbits r) (* 8 (- (brd-end r) (brd-pos r)))))

(defun r-align (r)
  "Discard bits up to the next byte boundary."
  (let ((drop (mod (brd-nbits r) 8)))
    (when (plusp drop)
      (setf (brd-acc r) (ash (brd-acc r) (- drop)))
      (decf (brd-nbits r) drop))))

(defun r-bytes (r n)
  (declare (type brd r) (type fixnum n) (optimize (speed 3) (safety 0)))
  (let ((out (make-array n :element-type '(unsigned-byte 8))))
    (if (zerop (brd-nbits r))
        (let ((start (brd-pos r)))
          (unless (<= (+ start n) (brd-end r))
            (error "brotli: end of input"))
          (replace out (brd-bytes r) :start2 start :end2 (+ start n))
          (incf (brd-pos r) n))
        (dotimes (i n out)
          (if (>= (brd-nbits r) 8)
              (progn
                (setf (aref out i) (logand (brd-acc r) #xff))
                (setf (brd-acc r) (ash (brd-acc r) -8))
                (decf (brd-nbits r) 8))
              (progn
                (when (>= (brd-pos r) (brd-end r))
                  (error "brotli: end of input"))
                (setf (aref out i) (aref (brd-bytes r) (brd-pos r)))
                (incf (brd-pos r))))))
    out))

(defstruct (bwr (:constructor make-bwr))
  (out (make-array 64 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
  (acc 0 :type integer) (nbits 0 :type fixnum))
(defun wbits (w v n)
  (setf (bwr-acc w) (logior (bwr-acc w) (ash (logand v (1- (ash 1 n))) (bwr-nbits w))))
  (incf (bwr-nbits w) n)
  (loop while (>= (bwr-nbits w) 8) do
    (vector-push-extend (logand (bwr-acc w) #xff) (bwr-out w))
    (setf (bwr-acc w) (ash (bwr-acc w) -8)) (decf (bwr-nbits w) 8)))
(defun w-align (w)
  (when (plusp (bwr-nbits w))
    (vector-push-extend (logand (bwr-acc w) #xff) (bwr-out w))
    (setf (bwr-acc w) 0 (bwr-nbits w) 0)))
(defun w-bytes (w vec) (loop for x across vec do (vector-push-extend x (bwr-out w))))
