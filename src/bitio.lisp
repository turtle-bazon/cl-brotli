;;;; src/bitio.lisp — brotli bit I/O: LSB-first (low bit of each byte first),
;;;; same convention as DEFLATE.
(in-package #:cl-brotli.lisp.bitio)
(deftype octets () '(simple-array (unsigned-byte 8) (*)))
(defun to-octets (s)
  (cond ((typep s 'octets) s)
        ((stringp s)
         (map '(simple-array (unsigned-byte 8) (*)) #'char-code s))
        (t (coerce s '(simple-array (unsigned-byte 8) (*))))))

(defstruct (brd (:constructor make-brd (bytes &optional (pos 0) (end (length bytes)))))
  (bytes nil :type octets) (pos 0 :type fixnum) (end 0 :type fixnum)
  ;; Bit accumulator: ACC holds NBITS unconsumed bits, least-significant bit
  ;; first.  A 64-bit reservoir lets %FILL-BITS load four input bytes at a
  ;; time instead of one; NBITS stays <= 55 after a refill because callers
  ;; never request more than 24 bits.
  (acc 0 :type (unsigned-byte 64)) (nbits 0 :type (integer 0 63))
  (sap nil))

(defun r-eof-p (r)
  (and (>= (brd-pos r) (brd-end r)) (zerop (brd-nbits r))))

(declaim (inline %fill-bits rbits rbit peek-bits bits-available))
(declaim (inline %word-at))
(defun %word-at (bytes pos)
  "Little-endian 32-bit load at POS.  Caller guarantees four bytes exist."
  (declare (type octets bytes) (type fixnum pos)
           (optimize (speed 3) (safety 0)))
  (the (unsigned-byte 32)
       (logior (aref bytes pos)
               (ash (aref bytes (+ pos 1)) 8)
               (ash (aref bytes (+ pos 2)) 16)
               (ash (aref bytes (+ pos 3)) 24))))

(defun %fill-bits (r n)
  (declare (type brd r) (type (integer 0 24) n)
           (optimize (speed 3) (safety 0)))
  (loop while (< (brd-nbits r) n) do
    (let ((pos (brd-pos r)) (end (brd-end r)) (nbits (brd-nbits r)))
      (cond
        ((>= pos end) (error "brotli: end of input"))
        #+(and sbcl little-endian)
        ((and (brd-sap r) (<= (+ pos 8) end))
         (let* ((bytes (min 7 (ash (- 63 nbits) -3)))
                (mask (1- (ash 1 (* 8 bytes))))
                (word (logand (sb-sys:sap-ref-64 (brd-sap r) pos) mask)))
           (setf (brd-acc r) (logior (brd-acc r) (ash word nbits)))
           (incf (brd-nbits r) (* 8 bytes))
           (incf (brd-pos r) bytes)))
        ((<= (+ pos 4) end)
         (setf (brd-acc r)
               (logior (brd-acc r)
                       (ash (%word-at (brd-bytes r) pos) nbits)))
         (incf (brd-nbits r) 32)
         (incf (brd-pos r) 4))
        (t
         (setf (brd-acc r)
               (logior (brd-acc r)
                       (ash (aref (brd-bytes r) pos) nbits)))
         (incf (brd-nbits r) 8)
         (incf (brd-pos r)))))))

(defun rbits (r n)
  "Read N bits, LSB-first, as an integer."
  (declare (type brd r) (type (integer 0 24) n)
           (optimize (speed 3) (safety 0)))
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
  (declare (type brd r) (type (integer 0 24) n)
           (optimize (speed 3) (safety 0)))
  (if (zerop n)
      0
      (progn
        (%fill-bits r n)
        (logand (brd-acc r) (1- (ash 1 n))))))

(defun bits-available (r)
  "Number of bits remaining, including bits already buffered in ACC."
  (declare (type brd r) (optimize (speed 3) (safety 0)))
  (the fixnum (+ (brd-nbits r)
                 (* 8 (- (brd-end r) (brd-pos r))))))

(defun r-align (r)
  "Discard bits up to the next byte boundary."
  (let ((drop (mod (brd-nbits r) 8)))
    (declare (type (integer 0 7) drop))
    (when (plusp drop)
      (setf (brd-acc r) (ash (brd-acc r) (- drop)))
      (decf (brd-nbits r) drop))))

(defun r-bytes (r n)
  (declare (type brd r) (type fixnum n) (optimize (speed 3) (safety 0)))
  (let ((out (make-array n :element-type '(unsigned-byte 8))))
    (if (zerop (mod (brd-nbits r) 8))
        ;; Byte-aligned: drain whole bytes already in ACC, then bulk-copy.
        (let* ((acc-bytes (ash (brd-nbits r) -3))
               (take (min n acc-bytes))
               (i 0))
          (declare (type fixnum acc-bytes take i))
          (loop while (< i take) do
            (setf (aref out i) (logand (brd-acc r) #xff))
            (setf (brd-acc r) (ash (brd-acc r) -8))
            (incf i))
          (decf (brd-nbits r) (* 8 take))
          (when (< i n)
            (let ((start (brd-pos r)) (count (- n i)))
              (declare (type fixnum start count))
              (unless (<= (+ start count) (brd-end r))
                (error "brotli: end of input"))
              (replace out (brd-bytes r) :start1 i :start2 start
                       :end2 (+ start count))
              (incf (brd-pos r) count)))
          out)
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
                (incf (brd-pos r))))))))

(defstruct (bwr (:constructor make-bwr (&optional (capacity 1024))))
  ;; A simple array plus an explicit position: the old adjustable vector with
  ;; VECTOR-PUSH-EXTEND dominated the encoder profile on small outputs.
  (out (make-array capacity :element-type '(unsigned-byte 8))
   :type (simple-array (unsigned-byte 8) (*)))
  (pos 0 :type fixnum)
  (acc 0 :type integer) (nbits 0 :type fixnum))

(declaim (inline %w-grow))
(defun %w-grow (w need)
  (declare (type bwr w) (type fixnum need)
           (optimize (speed 3) (safety 0)))
  (let ((out (bwr-out w)))
    (when (> need (length out))
      (let ((new (make-array (max need (* 2 (length out)))
                              :element-type '(unsigned-byte 8))))
        (replace new out)
        (setf (bwr-out w) new)))))

(defun wbits (w v n)
  (declare (type bwr w) (type fixnum v n)
           (optimize (speed 3) (safety 0)))
  (let* ((acc (logior (bwr-acc w)
                      (ash (logand v (1- (ash 1 n))) (bwr-nbits w))))
         (nbits (+ (bwr-nbits w) n))
         (out (bwr-out w))
         (pos (bwr-pos w)))
    (declare (type integer acc) (type fixnum nbits pos)
             (type (simple-array (unsigned-byte 8) (*)) out))
    ;; One capacity check per call instead of one per emitted byte.
    (let ((need (+ pos (1+ (ash nbits -3)))))
      (when (> need (length out))
        (%w-grow w need)
        (setf out (bwr-out w))))
    (loop while (>= nbits 8) do
      (setf (aref out pos) (logand acc #xff))
      (incf pos)
      (setf acc (ash acc -8))
      (decf nbits 8))
    (setf (bwr-acc w) acc (bwr-nbits w) nbits (bwr-pos w) pos)))

(defun w-align (w)
  (declare (type bwr w) (optimize (speed 3) (safety 0)))
  (when (plusp (bwr-nbits w))
    (let ((pos (bwr-pos w)))
      (%w-grow w (1+ pos))
      (setf (aref (bwr-out w) pos) (logand (bwr-acc w) #xff))
      (setf (bwr-pos w) (1+ pos)))
    (setf (bwr-acc w) 0 (bwr-nbits w) 0)))

(defun w-bytes (w vec)
  (declare (type bwr w) (type (simple-array (unsigned-byte 8) (*)) vec)
           (optimize (speed 3) (safety 0)))
  (let ((pos (bwr-pos w)) (n (length vec)))
    (%w-grow w (+ pos n))
    (replace (bwr-out w) vec :start1 pos)
    (setf (bwr-pos w) (+ pos n))))

(defun bwr-result (w)
  "The bytes written so far as a fresh simple octet vector."
  (declare (type bwr w))
  (subseq (bwr-out w) 0 (bwr-pos w)))
