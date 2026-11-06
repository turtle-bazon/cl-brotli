;;;; src/bitio.lisp — brotli bit I/O: LSB-first (low bit of each byte first),
;;;; same convention as DEFLATE.
(in-package #:cl-brotli.lisp.bitio)
(deftype octets () '(simple-array (unsigned-byte 8) (*)))
(defun to-octets (s)
  (cond ((typep s 'octets) s)
        ((stringp s)
         (map '(simple-array (unsigned-byte 8) (*)) #'char-code s))
        (t (coerce s '(simple-array (unsigned-byte 8) (*))))))

(deftable +masks+
  (let ((v (make-array 25 :element-type 'fixnum :initial-element 0)))
    (dotimes (i 25 v) (setf (aref v i) (1- (ash 1 i))))))
(declaim (type (simple-array fixnum (25)) +masks+))

(deftable +wide-masks+
  (let ((v (make-array 57 :element-type 'fixnum :initial-element 0)))
    (dotimes (i 57 v) (setf (aref v i) (1- (ash 1 i))))))
(declaim (type (simple-array fixnum (57)) +wide-masks+))

(defstruct (brd (:constructor make-brd (bytes &optional (pos 0) (end (length bytes)))))
  (bytes nil :type octets) (pos 0 :type fixnum) (end 0 :type fixnum)
  ;; Bit accumulator: ACC holds NBITS unconsumed bits, least-significant bit
  ;; first.  NBITS <= 59 at all times so ACC always fits a fixnum; every
  ;; refill adds at most 59-NBITS bits.  All shifts/masks on ACC are fixnum
  ;; operations: no bignums, no generic arithmetic.  Callers never request
  ;; more than 24 bits.
  (acc 0 :type fixnum) (nbits 0 :type (integer 0 59))
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
      ;; The loop guard implies NBITS < N <= 24, so at least 4 refill
      ;; bytes always fit under the 59-bit fixnum bound.
      (declare (type fixnum pos end) (type (integer 0 23) nbits))
      (cond
        ((>= pos end) (error 'cl-brotli.lisp::brotli-error :msg "end of input"))
        #+cl-brotli-sap
        ((and (brd-sap r) (<= (+ pos 8) end))
         ;; Refill with the widest 8-byte read that still keeps ACC below
         ;; 2^59, so every shift and logior below stays in fixnum.
         (let* ((bytes (min 7 (ash (- 59 nbits) -3)))
                ;; NBITS < N <= 24 here, so at least 4 bytes always fit.
                (mask (aref +wide-masks+ (* 8 bytes)))
                (word (the fixnum
                           (logand (sb-sys:sap-ref-64 (brd-sap r) pos)
                                   mask))))
           (setf (brd-acc r)
                 (the fixnum
                      (logior (brd-acc r)
                              (the fixnum (ash word nbits)))))
           (incf (brd-nbits r) (* 8 bytes))
           (incf (brd-pos r) bytes)))
        ((<= (+ pos 4) end)
         (setf (brd-acc r)
               (the fixnum
                    (logior (brd-acc r)
                            (the fixnum
                                 (ash (the fixnum
                                           (%word-at (brd-bytes r) pos))
                                      nbits)))))
         (incf (brd-nbits r) 32)
         (incf (brd-pos r) 4))
        (t
         (setf (brd-acc r)
               (the fixnum
                    (logior (brd-acc r)
                            (the fixnum
                                 (ash (aref (brd-bytes r) pos) nbits)))))
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
  ;; END - POS is a byte count of a real vector, so 8x it is a fixnum; say
  ;; so, or SBCL compiles this per-symbol guard to GENERIC-+.
  (the fixnum (+ (brd-nbits r)
                 (the fixnum
                      (* 8 (the (integer #.(- (ash most-positive-fixnum -4))
                                         #.(ash most-positive-fixnum -4))
                                (- (brd-end r) (brd-pos r))))))))

(defun r-align (r)
  "Discard bits up to the next byte boundary."
  (let ((drop (mod (brd-nbits r) 8)))
    (declare (type (integer 0 7) drop))
    (when (plusp drop)
      (setf (brd-acc r) (ash (brd-acc r) (- drop)))
      (decf (brd-nbits r) drop))))

(defun r-bytes-into (r out start n)
  "Copy N bytes from R into OUT starting at START.  Unlike R-BYTES this
does not allocate an intermediate vector."
  (declare (type brd r) (type fixnum start n)
           (type (simple-array (unsigned-byte 8) (*)) out)
           (optimize (speed 3) (safety 0)))
  (if (zerop (mod (brd-nbits r) 8))
      ;; Byte-aligned: drain whole bytes already in ACC, then bulk-copy.
      (let* ((acc-bytes (ash (brd-nbits r) -3))
             (take (min n acc-bytes))
             (i 0))
        (declare (type fixnum acc-bytes take i))
        (loop while (< i take) do
          (setf (aref out (+ start i)) (logand (brd-acc r) #xff))
          (setf (brd-acc r) (ash (brd-acc r) -8))
          (incf i))
        (decf (brd-nbits r) (* 8 take))
        (when (< i n)
          (let ((pos (brd-pos r)) (count (- n i)))
            (declare (type fixnum pos count))
            (unless (<= (+ pos count) (brd-end r))
              (error 'cl-brotli.lisp::brotli-error :msg "end of input"))
            (replace out (brd-bytes r) :start1 (+ start i) :start2 pos
                     :end2 (+ pos count))
            (incf (brd-pos r) count))))
      (dotimes (i n)
        (if (>= (brd-nbits r) 8)
            (progn
              (setf (aref out (+ start i)) (logand (brd-acc r) #xff))
              (setf (brd-acc r) (ash (brd-acc r) -8))
              (decf (brd-nbits r) 8))
            (progn
              (when (>= (brd-pos r) (brd-end r))
                (error 'cl-brotli.lisp::brotli-error :msg "end of input"))
              (setf (aref out (+ start i)) (aref (brd-bytes r) (brd-pos r)))
              (incf (brd-pos r)))))))

(defun r-bytes (r n)
  (declare (type brd r) (type fixnum n) (optimize (speed 3) (safety 0)))
  (let ((out (make-array n :element-type '(unsigned-byte 8))))
    (r-bytes-into r out 0 n)
    out))

(defstruct (bwr (:constructor make-bwr (&optional (capacity 1024))))
  ;; A simple array plus an explicit position: the old adjustable vector with
  ;; VECTOR-PUSH-EXTEND dominated the encoder profile on small outputs.
  (out (make-array capacity :element-type '(unsigned-byte 8))
   :type (simple-array (unsigned-byte 8) (*)))
  (pos 0 :type fixnum)
  (acc 0 :type (unsigned-byte 64)) (nbits 0 :type (integer 0 7))
  ;; Absolute output ceiling for COMPRESS-INTO; NIL means growable.  When set,
  ;; OUT is caller-owned and must never be replaced.
  (limit nil :type (or null fixnum)))

(declaim (inline %w-grow))
(defun %w-grow (w need)
  (declare (type bwr w) (type fixnum need)
           (optimize (speed 3) (safety 0)))
  ;; The class name is quoted: BWR is defined before CL-BROTLI.LISP's
  ;; BROTLI-OUTPUT-OVERFLOW (serial system), so the class is resolved at
  ;; signal time, when the whole system is loaded.
  (when (and (bwr-limit w) (> need (bwr-limit w)))
    (error 'cl-brotli.lisp::brotli-output-overflow
           :msg (format nil "brotli: output buffer too small (needs ~D bytes)"
                        need)
           :needed need))
  (let ((out (bwr-out w)))
    (when (> need (length out))
      (let ((new (make-array (max need (* 2 (length out)))
                              :element-type '(unsigned-byte 8))))
        (replace new out)
        (setf (bwr-out w) new)))))

;; The SBCL writers are branchless (C's BrotliWriteBits shape): every write
;; stores the whole 64-bit accumulator at POS - the caller-guaranteed
;; eight bytes of slack make that safe - then advances POS by the completed
;; bytes.  The old (WHEN (PLUSP EMIT) ...) flush was a data-dependent branch
;; on every symbol (~3.2 vs ~1.8 ns/literal measured on 1 MiB of HTML).
;; Bytes past the new POS are scratch: they are rewritten by the next store.
(defmacro %wbits-body (w vbits n)
  `(let* ((prev (bwr-nbits ,w))
          (acc (logior (the (unsigned-byte 64) (bwr-acc ,w))
                       (the (unsigned-byte 32) (ash ,vbits prev))))
          (nbits (+ prev ,n))
          (emit (ash nbits -3))
          (pos (bwr-pos ,w))
          (out (bwr-out ,w)))
     (declare (type (unsigned-byte 64) acc) (type fixnum nbits pos)
              (type (integer 0 3) emit)
              (type (integer 0 7) prev)
              (type (simple-array (unsigned-byte 8) (*)) out))
     #+cl-brotli-sap
     (sb-sys:with-pinned-objects (out)
       (setf (sb-sys:sap-ref-64 (sb-sys:vector-sap out) pos) acc))
     #-cl-brotli-sap
     (loop for i below emit
           do (setf (aref out (+ pos i))
                    (logand (ash acc (* -8 i)) #xff)))
     (setf (bwr-acc ,w) (ash acc (- (ash emit 3)))
           (bwr-nbits ,w) (logand nbits 7)
           (bwr-pos ,w) (+ pos emit))))

(declaim (inline %wbits-raw))
(defun %wbits-raw (w v n)
  "Write N <= 24 bits without a capacity check.  The caller must have
ensured at least eight bytes of slack at the current position (see
W-ENSURE)."
  (declare (type bwr w) (type fixnum v) (type (integer 0 24) n)
           (optimize (speed 3) (safety 0)))
  (let ((vbits (the (unsigned-byte 32) (logand v (aref +masks+ n)))))
    (%wbits-body w vbits n)))

(declaim (inline %wbits-raw-pm))
(defun %wbits-raw-pm (w v n)
  "PRE-MASKED writer: V must already satisfy 0 <= V < 2^N, N <= 24 (the
writer's hot paths emit reversed codes / extra values from width-exact
tables).  No mask-table load, no logand; the call sites that can carry a
negative or un-masked value (the special-distance offsets) keep using
%WBITS-RAW."
  (declare (type bwr w) (type fixnum v) (type (integer 0 24) n)
           (optimize (speed 3) (safety 0)))
  (let ((vbits (the (unsigned-byte 32) v)))
    (%wbits-body w vbits n)))

(defun w-ensure (w slack)
  "Ensure SLACK writable bytes after the current output position."
  (declare (type bwr w) (type fixnum slack)
           (optimize (speed 3) (safety 0)))
  (let ((need (+ (bwr-pos w) slack)))
    (when (> need (length (bwr-out w)))
      (%w-grow w need))))

(defun w-emit-run (w data start end rcodes lengths)
  "Emit DATA[START..END) through the prefix code (RCODES, LENGTHS), keeping
the accumulator, bit count, and output position in locals for the whole run.
The caller must ensure two bytes per symbol plus eight bytes of slack."
  (declare (type bwr w)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum start end)
           (type (simple-array fixnum (*)) rcodes lengths)
           (optimize (speed 3) (safety 0)))
  (let ((acc (bwr-acc w)) (nbits (bwr-nbits w)) (pos (bwr-pos w))
        (out (bwr-out w)))
    (declare (type (unsigned-byte 64) acc) (type fixnum nbits pos)
             (type (integer 0 7) nbits)
             (type (simple-array (unsigned-byte 8) (*)) out))
    #+cl-brotli-sap
    ;; Lazy 48-bit reservoir for the run: flush six bytes only when 48 bits
    ;; are pending (one predictable branch per ~6 literals), then normalize
    ;; back to the writer's < 8 pending bits.  Every store lands at or
    ;; before the run's final position, inside the caller's slack.
    (sb-sys:with-pinned-objects (out)
      (let ((sap (sb-sys:vector-sap out))
            (nb nbits))
        (declare (type sb-sys:system-area-pointer sap)
                 (type (integer 0 63) nb))
        (loop for i of-type fixnum from start below end do
          (let* ((sym (aref data i))
                 (v (aref rcodes sym))
                 (n (aref lengths sym)))
            (declare (type (unsigned-byte 32) v) (type (integer 0 15) n))
            (setf acc (logior acc (the (unsigned-byte 64)
                                       (ash v (the (integer 0 47) nb)))))
            (setf nb (+ (the (integer 0 47) nb) n))
            (when (>= nb 48)
              (setf (sb-sys:sap-ref-64 sap pos) acc)
              (incf pos 6)
              (setf acc (ash acc -48))
              (setf nb (- nb 48)))))
        (loop while (>= nb 8) do
          (setf (sb-sys:sap-ref-8 sap pos) (logand acc #xff))
          (incf pos)
          (setf acc (ash acc -8))
          (decf nb 8))
        (setf nbits nb)))
    #-cl-brotli-sap
    (loop for i from start below end do
      (let* ((sym (aref data i))
             (new-acc (logior acc (ash (logand (aref rcodes sym)
                                               (aref +masks+ (aref lengths sym)))
                                       nbits)))
             (new-nbits (+ nbits (aref lengths sym)))
             (emit (ash new-nbits -3)))
        (loop for j below emit
              do (setf (aref out (+ pos j))
                       (logand (ash new-acc (* -8 j)) #xff)))
        (incf pos emit)
        (setf acc (ash new-acc (* -8 emit)))
        (setf nbits (logand new-nbits 7))))
    (setf (bwr-acc w) acc (bwr-nbits w) nbits (bwr-pos w) pos)))

(declaim (inline wbits))
(defun wbits (w v n)
  (declare (type bwr w) (type fixnum v n)
           (optimize (speed 3) (safety 0)))
  (when (> (+ (bwr-pos w) 8) (length (bwr-out w)))
    (%w-grow w (+ (bwr-pos w) 8)))
  (%wbits-raw w v n))

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

(defun w-bytes-range (w vec start end)
  "Append VEC[START..END) without an intermediate SUBSEQ."
  (declare (type bwr w)
           (type (simple-array (unsigned-byte 8) (*)) vec)
           (type fixnum start end)
           (optimize (speed 3) (safety 0)))
  (let ((pos (bwr-pos w)) (n (- end start)))
    (%w-grow w (+ pos n))
    (replace (bwr-out w) vec :start1 pos :start2 start :end2 end)
    (setf (bwr-pos w) (+ pos n))))

(defun bwr-result (w)
  "The bytes written so far as a fresh simple octet vector."
  (declare (type bwr w))
  (subseq (bwr-out w) 0 (bwr-pos w)))

(defun make-bwr-into (array start end)
  "A bounded writer over the caller-owned ARRAY, writing at START and never
growing past END.  Excess writes signal BROTLI-OUTPUT-OVERFLOW."
  (check-type array (simple-array (unsigned-byte 8) (*)))
  (check-type start fixnum) (check-type end fixnum)
  (assert (<= 0 start end (length array)) (start end)
          "brotli: invalid output range ~D..~D for ~D bytes" start end
          (length array))
  (let ((w (make-bwr 0)))
    (setf (bwr-out w) array (bwr-pos w) start (bwr-limit w) end)
    w))
