;;;; src/decompress.lisp — brotli compressed meta-block decoder (RFC 7932 §9-10).
(in-package #:cl-brotli.lisp)

;; The decoder is validated against the C reference on every test/benchmark
;; stream; safety 0 removes per-symbol bounds checks from the literal and
;; match paths.
(declaim (optimize (speed 3) (safety 0)))

;;; length-code base/extra tables
(defparameter +ins-bits+ #(0 0 0 0 0 0 1 1 2 2 3 3 4 4 5 5 6 7 8 9 10 12 14 24))
(defparameter +ins-base+ #(0 1 2 3 4 5 6 8 10 14 18 26 34 50 66 98 130 194 322 578 1090 2114 6210 22594))
(defparameter +cpy-bits+ #(0 0 0 0 0 0 0 0 1 1 2 2 3 3 4 4 5 5 6 7 8 9 10 24))
(defparameter +cpy-base+ #(2 3 4 5 6 7 8 9 10 12 14 18 22 30 38 54 70 102 134 198 326 582 1094 2118))
(defparameter +blen-bits+ (coerce '(2 2 2 2 3 3 3 3 4 4 4 4 5 5 5 5 6 6 7 8 9 10 11 12 13 24) '(simple-array fixnum (*))))
(defparameter +blen-base+ (coerce '(1 5 9 13 17 25 33 41 49 65 81 97 113 145 177 209 241 305 369 497 753 1265 2289 4337 8433 16625) '(simple-array fixnum (*))))
;; insert-and-copy command -> cell start ranges
(defparameter +cmd-ins+ #(0 0 0 0 8 8 0 16 8 16 16))
(defparameter +cmd-cpy+ #(0 8 0 8 0 8 16 0 16 8 16))
;; distance short codes 0..15: ring-buffer slot offset + value offset (RFC 7932 §4).
;; The ring is a rolling buffer indexed by IDX (slots written most-recent-last).
(defparameter +dsc-index+ (coerce '(3 2 1 0 3 3 3 3 3 3 2 2 2 2 2 2) '(simple-array fixnum (*))))
(defparameter +dsc-value+ (coerce '(0 0 0 0 -1 1 -2 2 -3 3 -1 1 -2 2 -3 3) '(simple-array fixnum (*))))
;; These are compile-time constants, but they are DEFPARAMETERs, so SBCL
;; otherwise treats each AREF as a hairy (possibly non-simple) vector access.
(declaim (type simple-vector
                 +ins-bits+ +ins-base+ +cpy-bits+ +cpy-base+
                 +cmd-ins+ +cmd-cpy+))
(declaim (type (simple-array fixnum (*))
               +blen-bits+ +blen-base+ +dsc-index+ +dsc-value+))

(defun read-nbltypes (r)
  (if (zerop (b:rbit r)) 1
      (let ((n (b:rbits r 3))) (if (zerop n) 2 (+ (1+ (ash 1 n)) (b:rbits r n))))))

(defun read-block-count (r blen-huff)
  (let ((s (read-huff r blen-huff))) (+ (aref +blen-base+ s) (b:rbits r (aref +blen-bits+ s)))))

(defun imtf (v n)
  (let ((mtf (make-array 256)))
    (dotimes (i 256) (setf (aref mtf i) i))
    (dotimes (i n)
      (let* ((idx (aref v i)) (val (aref mtf idx)))
        (setf (aref v i) val)
        (loop for j from idx above 0 do (setf (aref mtf j) (aref mtf (1- j))))
        (setf (aref mtf 0) val)))))

(defun read-context-map (r size ntrees)
  (let* ((rlemax (if (zerop (b:rbit r)) 0 (1+ (b:rbits r 4))))
         (huff (read-prefix-code r (+ ntrees rlemax)))
         (cmap (make-array size :initial-element 0)) (i 0))
    (loop while (< i size) do
      (let ((sym (read-huff r huff)))
        (cond ((zerop sym) (incf i))
              ((<= sym rlemax)
               (let ((rep (+ (ash 1 sym) (b:rbits r sym))))
                 (dotimes (k rep) (when (< i size) (setf (aref cmap i) 0) (incf i)))))
              (t (setf (aref cmap i) (- sym rlemax)) (incf i)))))
    (when (= 1 (b:rbit r)) (imtf cmap size))
    cmap))

(defun lit-context (mode p1 p2)
  (ecase mode
    (0 (logand p1 #x3f))                                   ; LSB6
    (1 (ash p1 -2))                                        ; MSB6
    (2 (logior (aref +lut0+ p1) (aref +lut1+ p2)))         ; UTF8
    (3 (logior (ash (aref +lut2+ p1) 3) (aref +lut2+ p2))))) ; Signed
(declaim (inline lit-context))

(defmacro %lit-context (mode p1 p2)
  "Inline context computation.  Kept as a macro rather than relying on
DECLAIM INLINE: the literal loop is hot enough that a missed inline is
visible, and MODE is loop-invariant between block switches."
  (let ((m (gensym "MODE")) (a (gensym "P1")) (b (gensym "P2")))
    `(let ((,m ,mode) (,a ,p1) (,b ,p2))
       (case ,m
         (0 (logand ,a #x3f))
         (1 (ash ,a -2))
         (2 (logior (aref +lut0+ ,a) (aref +lut1+ ,b)))
         (3 (logior (ash (aref +lut2+ ,a) 3) (aref +lut2+ ,b)))
         (t 0)))))

;; Typed slots: BLK-MAYBE-SWITCH runs per symbol on block-split streams, and
;; untyped slots compiled its arithmetic and comparisons to generic calls.
(defstruct blk
  (ntypes 1 :type (integer 1 256))
  (type 0 :type (integer 0 255))
  (prev 1 :type (integer 0 255))
  (count 0 :type (integer 0 #.(ash 1 25)))
  (bhuff nil :type (or null huff))
  (chuff nil :type (or null huff)))

(defun read-blk-header (r ntypes)
  "Read the optional block-type/count prefix codes + first count for a category."
  (let ((b (make-blk :ntypes ntypes)))
    (if (>= ntypes 2)
        (progn (setf (blk-bhuff b) (read-prefix-code r (+ ntypes 2))
                     (blk-chuff b) (read-prefix-code r 26)
                     (blk-count b) (read-block-count r (blk-chuff b))))
        (setf (blk-count b) 16777216))
    b))

(declaim (inline blk-maybe-switch))
(defun blk-maybe-switch (r b)
  (when (zerop (blk-count b))
    (let* ((sym (read-huff r (blk-bhuff b)))
           (new (cond ((= sym 0) (blk-prev b))
                      ((= sym 1) (mod (1+ (blk-type b)) (blk-ntypes b)))
                      (t (- sym 2)))))
      (setf (blk-prev b) (blk-type b) (blk-type b) new
            (blk-count b) (read-block-count r (blk-chuff b)))))
  (decf (blk-count b)))

(defstruct (outbuf (:constructor make-outbuf (data)))
  (data nil :type (simple-array (unsigned-byte 8) (*)))
  (pos 0 :type fixnum)
  ;; Stream-relative origin: POS - ORIGIN is the number of bytes this stream
  ;; has produced.  DECOMPRESS-INTO starts POS at a nonzero buffer offset;
  ;; distance classification (regular vs dictionary) must not see it.
  (origin 0 :type fixnum)
  ;; Absolute output ceiling for DECOMPRESS-INTO; NIL means growable.  When
  ;; set, DATA is caller-owned and must never be replaced.
  (limit nil :type (or null fixnum)))

(defun %grow (out need)
  (when (and (outbuf-limit out) (> need (outbuf-limit out)))
    (error 'brotli-output-overflow
           :msg (format nil "brotli: output buffer too small (needs ~D bytes)"
                        need)
           :needed need))
  (let* ((data (outbuf-data out)) (len (length data)))
    (when (> need len)
      ;; Small buffers quadruple to avoid repeated copies; large ones grow by
      ;; 1.5x.  A 4x jump on the second block of a 16 MiB stream otherwise
      ;; allocated 64 MiB for a 17 MiB result.
      (let ((new (make-array (max need
                                  (if (< len 65536)
                                      (* 4 len)
                                      (+ len (ash len -1))))
                              :element-type '(unsigned-byte 8))))
        (replace new data)
        (setf (outbuf-data out) new)))))

(defun %grow-exact (out need)
  "Reserve exactly NEED bytes, without the usual growth overshoot."
  (when (and (outbuf-limit out) (> need (outbuf-limit out)))
    (error 'brotli-output-overflow
           :msg (format nil "brotli: output buffer too small (needs ~D bytes)"
                        need)
           :needed need))
  (let ((data (outbuf-data out)))
    (when (> need (length data))
      (let ((new (make-array need :element-type '(unsigned-byte 8))))
        (replace new data)
        (setf (outbuf-data out) new)))))

(defun out-push (out byte)
  (declare (optimize (speed 3) (safety 0)))
  (let ((pos (outbuf-pos out)))
    (%grow out (1+ pos))
    (setf (aref (outbuf-data out) pos) byte)
    (setf (outbuf-pos out) (1+ pos))))

;;; Direct 704-symbol command LUT: the RFC's cell + sub-code arithmetic done
;;; once at load time, so the hot loop needs four loads instead of shifts,
;;; masks, adds, and six table reads.
;; (unsigned-byte 16) LUTs: 704 entries x 4 tables x 2 bytes = 5.6 KB -> 2.8 KB,
;; well inside L1D for the command-dense cells.  Bases fit u16 (max insert
;; base 22594 < 65536), and the extra-bit widths are 0..24, also u16.
(defparameter +cmd-ilen-base+ (make-array 704 :element-type '(unsigned-byte 16) :initial-element 0))
(defparameter +cmd-ilen-bits+ (make-array 704 :element-type '(unsigned-byte 16) :initial-element 0))
(defparameter +cmd-clen-base+ (make-array 704 :element-type '(unsigned-byte 16) :initial-element 0))
(defparameter +cmd-clen-bits+ (make-array 704 :element-type '(unsigned-byte 16) :initial-element 0))
(declaim (type (simple-array (unsigned-byte 16) (704))
               +cmd-ilen-base+ +cmd-ilen-bits+ +cmd-clen-base+ +cmd-clen-bits+))
(dotimes (cmd 704)
  (let* ((cell (ash cmd -6))
         (icode (+ (aref +cmd-ins+ cell) (logand (ash cmd -3) 7)))
         (ccode (+ (aref +cmd-cpy+ cell) (logand cmd 7))))
    (setf (aref +cmd-ilen-base+ cmd) (aref +ins-base+ icode)
          (aref +cmd-ilen-bits+ cmd) (aref +ins-bits+ icode)
          (aref +cmd-clen-base+ cmd) (aref +cpy-base+ ccode)
          (aref +cmd-clen-bits+ cmd) (aref +cpy-bits+ ccode))))

(declaim (inline %copy-tiny-match))
(defun %copy-tiny-match (data pos src length wlimit)
  "Copy a short non-overlapping match.  Returns the new position.  On
little-endian SBCL both loads and both stores are unaligned 64-bit
operations (C Brotli does the same via BrotliShortCopy), so the 16-way
length CASE below is only the slack/other-implementation fallback."
  (declare (optimize (speed 3) (safety 0))
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum pos src wlimit)
           (type fixnum length))
  #-cl-brotli-sap (declare (ignore wlimit))
  #+cl-brotli-sap
  ;; WLIMIT, not (LENGTH DATA): in DECOMPRESS-INTO the bytes past :END
  ;; belong to the caller and the 16-byte store must not reach them.
  (when (and (<= (+ pos 16) wlimit)
             (<= (+ src 16) (length data)))
    ;; Unaligned 8+8 copy: no allocation between the loads and stores, so
    ;; the pin cannot move the vector out from under us.
    (sb-sys:with-pinned-objects (data)
      (let ((sap (sb-sys:vector-sap data)))
        (declare (type sb-sys:system-area-pointer sap))
        (setf (sb-sys:sap-ref-64 sap pos)
              (sb-sys:sap-ref-64 sap src))
        (setf (sb-sys:sap-ref-64 sap (+ pos 8))
              (sb-sys:sap-ref-64 sap (+ src 8)))))
    (return-from %copy-tiny-match (+ pos length)))
  (case length
    (2 (setf (aref data (+ pos 0)) (aref data (+ src 0)) (aref data (+ pos 1)) (aref data (+ src 1))))
    (3 (setf (aref data (+ pos 0)) (aref data (+ src 0)) (aref data (+ pos 1)) (aref data (+ src 1)) (aref data (+ pos 2)) (aref data (+ src 2))))
    (4 (setf (aref data (+ pos 0)) (aref data (+ src 0)) (aref data (+ pos 1)) (aref data (+ src 1)) (aref data (+ pos 2)) (aref data (+ src 2)) (aref data (+ pos 3)) (aref data (+ src 3))))
    (5 (setf (aref data (+ pos 0)) (aref data (+ src 0)) (aref data (+ pos 1)) (aref data (+ src 1)) (aref data (+ pos 2)) (aref data (+ src 2)) (aref data (+ pos 3)) (aref data (+ src 3)) (aref data (+ pos 4)) (aref data (+ src 4))))
    (6 (setf (aref data (+ pos 0)) (aref data (+ src 0)) (aref data (+ pos 1)) (aref data (+ src 1)) (aref data (+ pos 2)) (aref data (+ src 2)) (aref data (+ pos 3)) (aref data (+ src 3)) (aref data (+ pos 4)) (aref data (+ src 4)) (aref data (+ pos 5)) (aref data (+ src 5))))
    (7 (setf (aref data (+ pos 0)) (aref data (+ src 0)) (aref data (+ pos 1)) (aref data (+ src 1)) (aref data (+ pos 2)) (aref data (+ src 2)) (aref data (+ pos 3)) (aref data (+ src 3)) (aref data (+ pos 4)) (aref data (+ src 4)) (aref data (+ pos 5)) (aref data (+ src 5)) (aref data (+ pos 6)) (aref data (+ src 6))))
    (8 (setf (aref data (+ pos 0)) (aref data (+ src 0)) (aref data (+ pos 1)) (aref data (+ src 1)) (aref data (+ pos 2)) (aref data (+ src 2)) (aref data (+ pos 3)) (aref data (+ src 3)) (aref data (+ pos 4)) (aref data (+ src 4)) (aref data (+ pos 5)) (aref data (+ src 5)) (aref data (+ pos 6)) (aref data (+ src 6)) (aref data (+ pos 7)) (aref data (+ src 7))))
    (9 (setf (aref data (+ pos 0)) (aref data (+ src 0)) (aref data (+ pos 1)) (aref data (+ src 1)) (aref data (+ pos 2)) (aref data (+ src 2)) (aref data (+ pos 3)) (aref data (+ src 3)) (aref data (+ pos 4)) (aref data (+ src 4)) (aref data (+ pos 5)) (aref data (+ src 5)) (aref data (+ pos 6)) (aref data (+ src 6)) (aref data (+ pos 7)) (aref data (+ src 7)) (aref data (+ pos 8)) (aref data (+ src 8))))
    (10 (setf (aref data (+ pos 0)) (aref data (+ src 0)) (aref data (+ pos 1)) (aref data (+ src 1)) (aref data (+ pos 2)) (aref data (+ src 2)) (aref data (+ pos 3)) (aref data (+ src 3)) (aref data (+ pos 4)) (aref data (+ src 4)) (aref data (+ pos 5)) (aref data (+ src 5)) (aref data (+ pos 6)) (aref data (+ src 6)) (aref data (+ pos 7)) (aref data (+ src 7)) (aref data (+ pos 8)) (aref data (+ src 8)) (aref data (+ pos 9)) (aref data (+ src 9))))
    (11 (setf (aref data (+ pos 0)) (aref data (+ src 0)) (aref data (+ pos 1)) (aref data (+ src 1)) (aref data (+ pos 2)) (aref data (+ src 2)) (aref data (+ pos 3)) (aref data (+ src 3)) (aref data (+ pos 4)) (aref data (+ src 4)) (aref data (+ pos 5)) (aref data (+ src 5)) (aref data (+ pos 6)) (aref data (+ src 6)) (aref data (+ pos 7)) (aref data (+ src 7)) (aref data (+ pos 8)) (aref data (+ src 8)) (aref data (+ pos 9)) (aref data (+ src 9)) (aref data (+ pos 10)) (aref data (+ src 10))))
    (12 (setf (aref data (+ pos 0)) (aref data (+ src 0)) (aref data (+ pos 1)) (aref data (+ src 1)) (aref data (+ pos 2)) (aref data (+ src 2)) (aref data (+ pos 3)) (aref data (+ src 3)) (aref data (+ pos 4)) (aref data (+ src 4)) (aref data (+ pos 5)) (aref data (+ src 5)) (aref data (+ pos 6)) (aref data (+ src 6)) (aref data (+ pos 7)) (aref data (+ src 7)) (aref data (+ pos 8)) (aref data (+ src 8)) (aref data (+ pos 9)) (aref data (+ src 9)) (aref data (+ pos 10)) (aref data (+ src 10)) (aref data (+ pos 11)) (aref data (+ src 11))))
    (13 (setf (aref data (+ pos 0)) (aref data (+ src 0)) (aref data (+ pos 1)) (aref data (+ src 1)) (aref data (+ pos 2)) (aref data (+ src 2)) (aref data (+ pos 3)) (aref data (+ src 3)) (aref data (+ pos 4)) (aref data (+ src 4)) (aref data (+ pos 5)) (aref data (+ src 5)) (aref data (+ pos 6)) (aref data (+ src 6)) (aref data (+ pos 7)) (aref data (+ src 7)) (aref data (+ pos 8)) (aref data (+ src 8)) (aref data (+ pos 9)) (aref data (+ src 9)) (aref data (+ pos 10)) (aref data (+ src 10)) (aref data (+ pos 11)) (aref data (+ src 11)) (aref data (+ pos 12)) (aref data (+ src 12))))
    (14 (setf (aref data (+ pos 0)) (aref data (+ src 0)) (aref data (+ pos 1)) (aref data (+ src 1)) (aref data (+ pos 2)) (aref data (+ src 2)) (aref data (+ pos 3)) (aref data (+ src 3)) (aref data (+ pos 4)) (aref data (+ src 4)) (aref data (+ pos 5)) (aref data (+ src 5)) (aref data (+ pos 6)) (aref data (+ src 6)) (aref data (+ pos 7)) (aref data (+ src 7)) (aref data (+ pos 8)) (aref data (+ src 8)) (aref data (+ pos 9)) (aref data (+ src 9)) (aref data (+ pos 10)) (aref data (+ src 10)) (aref data (+ pos 11)) (aref data (+ src 11)) (aref data (+ pos 12)) (aref data (+ src 12)) (aref data (+ pos 13)) (aref data (+ src 13))))
    (15 (setf (aref data (+ pos 0)) (aref data (+ src 0)) (aref data (+ pos 1)) (aref data (+ src 1)) (aref data (+ pos 2)) (aref data (+ src 2)) (aref data (+ pos 3)) (aref data (+ src 3)) (aref data (+ pos 4)) (aref data (+ src 4)) (aref data (+ pos 5)) (aref data (+ src 5)) (aref data (+ pos 6)) (aref data (+ src 6)) (aref data (+ pos 7)) (aref data (+ src 7)) (aref data (+ pos 8)) (aref data (+ src 8)) (aref data (+ pos 9)) (aref data (+ src 9)) (aref data (+ pos 10)) (aref data (+ src 10)) (aref data (+ pos 11)) (aref data (+ src 11)) (aref data (+ pos 12)) (aref data (+ src 12)) (aref data (+ pos 13)) (aref data (+ src 13)) (aref data (+ pos 14)) (aref data (+ src 14))))
    (16 (setf (aref data (+ pos 0)) (aref data (+ src 0)) (aref data (+ pos 1)) (aref data (+ src 1)) (aref data (+ pos 2)) (aref data (+ src 2)) (aref data (+ pos 3)) (aref data (+ src 3)) (aref data (+ pos 4)) (aref data (+ src 4)) (aref data (+ pos 5)) (aref data (+ src 5)) (aref data (+ pos 6)) (aref data (+ src 6)) (aref data (+ pos 7)) (aref data (+ src 7)) (aref data (+ pos 8)) (aref data (+ src 8)) (aref data (+ pos 9)) (aref data (+ src 9)) (aref data (+ pos 10)) (aref data (+ src 10)) (aref data (+ pos 11)) (aref data (+ src 11)) (aref data (+ pos 12)) (aref data (+ src 12)) (aref data (+ pos 13)) (aref data (+ src 13)) (aref data (+ pos 14)) (aref data (+ src 14)) (aref data (+ pos 15)) (aref data (+ src 15))))
    (otherwise
     (dotimes (i length)
       (setf (aref data (+ pos i)) (aref data (+ src i))))))
  (+ pos length))

(declaim (inline %copy-match-bytes))
(defun %copy-match-bytes (data fp src distance len wlimit)
  "Copy LEN bytes from SRC = FP - DISTANCE to FP (LZ77 semantics: an
overlapping copy repeats the DISTANCE-byte period).  Nothing at or past
WLIMIT is written."
  (declare (optimize (speed 3) (safety 0))
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum fp src distance len wlimit))
  (cond
    ((= distance 1)
     (fill data (aref data src) :start fp :end (+ fp len)))
    ((and (>= distance len) (<= len 16))
     (%copy-tiny-match data fp src len wlimit))
    ((and (>= distance len) (>= len 256))
     (replace data data :start1 fp :start2 src :end2 (+ src len)))
    ((>= len 256)
     ;; Long overlapping copy: copy the seed, then double the written
     ;; pattern - O(log len) block moves, even for distance 1-8.
     (replace data data :start1 fp :start2 src :end2 (+ src distance))
     (loop with copied of-type fixnum = distance
           while (< copied len)
           do (let ((n (min copied (- len copied))))
                (declare (type fixnum n))
                (replace data data :start1 (+ fp copied) :start2 fp
                                   :end2 (+ fp n))
                (incf copied n))))
    (t
     ;; Medium non-overlapping copies take the word loop below too (a
     ;; REPLACE call costs more than a few 8-byte moves).  Overlapping:  A forward copy reads only bytes it (or the source
     ;; region) already holds, so it repeats the period by itself - no
     ;; MOD per byte.  On SBCL, widen the period to a multiple >= 8 with a
     ;; byte prologue, then move 8 bytes per step (still never reading a
     ;; byte that is not final yet).
     (let ((i 0) (d distance))
       (declare (type fixnum i d))
       #+cl-brotli-sap
       (progn
         (when (< d 8)
           (let ((k (* d (ceiling 8 d))))
             (declare (type fixnum k))
             (loop while (and (< i k) (< i len)) do
               (setf (aref data (+ fp i)) (aref data (+ src i)))
               (incf i))
             (setf d k)))
         (sb-sys:with-pinned-objects (data)
           (let ((sap (sb-sys:vector-sap data)))
             (loop while (<= (+ i 8) len) do
               (setf (sb-sys:sap-ref-64 sap (+ fp i))
                     (sb-sys:sap-ref-64 sap (- (+ fp i) d)))
               (incf i 8)))))
       (loop while (< i len) do
         (setf (aref data (+ fp i)) (aref data (- (+ fp i) d)))
         (incf i))))))

(defun out-copy (out distance len)
  (declare (optimize (speed 3) (safety 0))
           (type outbuf out)
           (type fixnum distance len))
  (when (<= distance 0)
    (berr "invalid distance ~d" distance))
  (let ((fp (outbuf-pos out))
        (src (- (outbuf-pos out) distance)))
    (%grow out (+ fp len))
    (setf (outbuf-pos out) (+ fp len))
    (%copy-match-bytes (outbuf-data out) fp src distance len
                       (or (outbuf-limit out) (length (outbuf-data out))))))

(declaim (inline out-copy-preallocated))
(defun out-copy-preallocated (out distance len)
  "Like OUT-COPY, but the meta-block capacity was reserved up front.  The
caller has already validated DISTANCE."
  (declare (optimize (speed 3) (safety 0))
           (type outbuf out)
           (type fixnum distance len))
  (let ((fp (outbuf-pos out))
        (src (- (outbuf-pos out) distance)))
    (setf (outbuf-pos out) (+ fp len))
    (%copy-match-bytes (outbuf-data out) fp src distance len
                       (or (outbuf-limit out) (length (outbuf-data out))))))

(defun out-append-vec (out v)
  (let ((fp (outbuf-pos out)) (n (length v)))
    (%grow out (+ fp n))
    (replace (outbuf-data out) v :start1 fp)
    (setf (outbuf-pos out) (+ fp n))))

(defun out-append-vec-preallocated (out v)
  (let ((fp (outbuf-pos out)) (n (length v)))
    (replace (outbuf-data out) v :start1 fp)
    (setf (outbuf-pos out) (+ fp n))))


(defun %decode-lit-run (r out pos count tree)
  "Decode COUNT literals from R into OUT at POS using the single literal
TREE, keeping the bit reservoir, bit count, read position, and output
position in locals for the whole run.  The caller has reserved POS+COUNT
bytes of capacity.  Returns the position after the last literal."
  (declare (type b:brd r)
           (type (simple-array (unsigned-byte 8) (*)) out)
           (type fixnum pos count)
           (type huff tree)
           (optimize (speed 3) (safety 0)))
  (let ((table (huff-table tree)) (mask (huff-mask tree))
        (tbits (huff-table-bits tree))
        (subs (huff-subtables tree))
        (acc (b:brd-acc r)) (nbits (b:brd-nbits r)) (p (b:brd-pos r))
        #+cl-brotli-sap (sap (b:brd-sap r)) #-cl-brotli-sap (sap nil)
        (end (b:brd-end r)))
    (declare (type (or null (simple-array (unsigned-byte 16) (*))) table)
             (type fixnum mask tbits acc nbits p end)
             (type (or null simple-vector) subs)
             #+cl-brotli-sap (type (or null sb-sys:system-area-pointer) sap)
             #-cl-brotli-sap (type null sap)
             )
    (when (null table)
      ;; Single-symbol tree: every literal is the same byte.
      (let ((sym (huff-single tree)))
        (declare (type fixnum sym))
        (dotimes (k count) (setf (aref out pos) sym) (incf pos))
        (setf (b:brd-acc r) acc (b:brd-nbits r) nbits (b:brd-pos r) p)
        (return-from %decode-lit-run pos)))
    (let ((tbl (the (simple-array (unsigned-byte 16) (*)) table))
          (subvec (the simple-vector (or subs #()))))
      (declare (type (simple-array (unsigned-byte 16) (*)) tbl)
               (type simple-vector subvec))
    (macrolet ((refill (need)
                 `(unless (>= nbits ,need)
                    #+cl-brotli-sap
                    (when (and sap (<= (+ p 8) end))
                      (let* ((bytes (min 7 (ash (- 59 nbits) -3)))
                             (m (aref b::+wide-masks+ (* 8 bytes)))
                             (w (the fixnum
                                     (logand (sb-sys:sap-ref-64 sap p) m))))
                        (declare (type fixnum bytes m w))
                        (setf acc (the fixnum
                                       (logior acc
                                               (the fixnum
                                                    (ash w nbits))))
                              nbits (+ nbits (* 8 bytes))
                              p (+ p bytes))))
                    (when (< nbits ,need)
                      ;; End-of-stream tail: fewer bits remain than the
                      ;; primary table width, but the code itself may still
                      ;; fit.  Hand the rest of the run over to the generic
                      ;; reader, which decodes the remainder bit-by-bit from
                      ;; this symbol boundary.
                      (setf (b:brd-acc r) acc (b:brd-nbits r) nbits (b:brd-pos r) p)
                      (loop for j from k below count do
                        (setf (aref out pos) (read-huff r tree))
                        (incf pos))
                      (setf acc (b:brd-acc r) nbits (b:brd-nbits r) p (b:brd-pos r))
                      (return-from %decode-lit-run pos)))))
      (dotimes (k count)
        (refill tbits)
        (let ((entry (aref tbl (logand acc mask))))
          (declare (type fixnum entry))
          (let ((len (logand entry 15)))
            (declare (type fixnum len))
            (cond
              ((plusp len)
               (setf acc (ash acc (- len))
                     nbits (- nbits len)
                     (aref out pos) (ash entry -4))
               (incf pos))
              ((plusp entry)
               ;; Secondary table: consume tbits bits, then 5 more.
               (let ((sub (aref subvec (1- (ash entry -4)))))
                 (declare (type (simple-array (unsigned-byte 16) (*)) sub))
                 ;; The slow hand-off must resume at a symbol boundary, so
                 ;; remember the reservoir as it was before this code's
                 ;; primary bits were consumed and restore it when the
                 ;; refill near end-of-input cannot be satisfied (a valid
                 ;; stream may end inside the secondary part of its last
                 ;; code).
                 (let ((saved-acc acc) (saved-nbits nbits) (saved-p p))
                   (declare (type fixnum saved-acc saved-nbits saved-p))
                   (setf acc (ash acc (- tbits)) nbits (- nbits tbits))
                   ;; Top up 5 bits without the symbol-boundary hand-off.
                   (unless (>= nbits 5)
                     #+cl-brotli-sap
                     (when (and sap (<= (+ p 8) end))
                       (let* ((bytes (min 7 (ash (- 59 nbits) -3)))
                              (m (aref b::+wide-masks+ (* 8 bytes)))
                              (w (the fixnum
                                      (logand (sb-sys:sap-ref-64 sap p) m))))
                         (declare (type fixnum bytes m w))
                         (setf acc (the fixnum
                                        (logior acc
                                                (the fixnum
                                                     (ash w nbits))))
                               nbits (+ nbits (* 8 bytes))
                               p (+ p bytes))))
                     (unless (>= nbits 5)
                       ;; End of input inside the secondary part of the
                       ;; current code: restore the state saved before the
                       ;; primary bits were consumed and decode the rest of
                       ;; the run with the slow reader.
                       (setf (b:brd-acc r) saved-acc
                             (b:brd-nbits r) saved-nbits
                             (b:brd-pos r) saved-p)
                       (loop for j from k below count do
                         (setf (aref out pos) (read-huff r tree))
                         (incf pos))
                       (setf acc (b:brd-acc r) nbits (b:brd-nbits r)
                             p (b:brd-pos r))
                       (return-from %decode-lit-run pos)))
                   (let ((entry2 (aref sub (logand acc #x1F))))
                     (declare (type fixnum entry2))
                     (let ((rem (logand entry2 15)))
                       (declare (type fixnum rem))
                       (unless (plusp rem)
                         (berr "invalid prefix code"))
                       (setf acc (ash acc (- rem))
                             nbits (- nbits rem)
                             (aref out pos) (ash entry2 -4))
                       (incf pos))))))
              (t (berr "invalid prefix code"))))))
      (setf (b:brd-acc r) acc (b:brd-nbits r) nbits (b:brd-pos r) p)
      pos))))

;; C's context lookup: for each of the four modes a 512-byte table with
;; context = LUT[mode*512 + p1] | LUT[mode*512 + 256 + p2] - one OR, no
;; per-literal branch on the mode (RFC 7932 7.1).
(defparameter +ctx-lut+
  (let ((v (make-array 2048 :element-type '(unsigned-byte 8) :initial-element 0)))
    (dotimes (b 256 v)
      (setf (aref v b) (logand b #x3f)                          ; LSB6
            (aref v (+ 512 b)) (ash b -2)                       ; MSB6
            (aref v (+ 1024 b)) (aref +lut0+ b)                 ; UTF8
            (aref v (+ 1024 256 b)) (aref +lut1+ b)
            (aref v (+ 1536 b)) (ash (aref +lut2+ b) 3)         ; signed
            (aref v (+ 1536 256 b)) (aref +lut2+ b)))))
(declaim (type (simple-array (unsigned-byte 8) (2048)) +ctx-lut+))

;; Straight-line groups of reads (command symbol + its two extras; distance
;; symbol + extra) with the reservoir in locals instead of the BRD struct:
;; one load and one store of ACC/NBITS/POS per group instead of per read.
;; BODY must not call anything that takes R itself - the slow fallbacks
;; below sync the locals through R around their own calls.
(defmacro with-local-bits ((r) &body body)
  (let ((acc (gensym "ACC")) (nb (gensym "NB")) (p (gensym "P"))
        (end (gensym "END")) (src (gensym "SRC")))
    `(let ((,acc (b:brd-acc ,r)) (,nb (b:brd-nbits ,r)) (,p (b:brd-pos ,r))
           (,end (b:brd-end ,r))
           (,src #+cl-brotli-sap (b:brd-sap ,r) #-cl-brotli-sap (b:brd-bytes ,r)))
       (declare (type fixnum ,acc ,p ,end) (type (integer 0 59) ,nb)
                #+cl-brotli-sap (type (or null sb-sys:system-area-pointer) ,src)
                #-cl-brotli-sap (type (simple-array (unsigned-byte 8) (*)) ,src))
       (macrolet ((%lfill (need)
                    `(when (and (< ,',nb ,need) ,',src (<= (+ ,',p 8) ,',end))
                       (let* ((bytes (min 7 (ash (- 59 ,',nb) -3)))
                              (w (logand (ptr-u64 ,',src ,',p)
                                         (aref b::+wide-masks+ (* 8 bytes)))))
                         (declare (type (integer 0 7) bytes) (type fixnum w))
                         (setf ,',acc (logior ,',acc (the fixnum (ash w ,',nb)))
                               ,',nb (+ ,',nb (* 8 bytes))
                               ,',p (+ ,',p bytes)))))
                  (%lslow (form)
                    `(progn
                       (setf (b:brd-acc ,',r) ,',acc (b:brd-nbits ,',r) ,',nb
                             (b:brd-pos ,',r) ,',p)
                       (prog1 ,form
                         (setf ,',acc (b:brd-acc ,',r) ,',nb (b:brd-nbits ,',r)
                               ,',p (b:brd-pos ,',r)))))
                  (lbits (n)
                    (let ((nn (gensym "N")))
                      `(let ((,nn ,n))
                         (declare (type (integer 0 24) ,nn))
                         (%lfill ,nn)
                         (if (>= ,',nb ,nn)
                             (prog1 (logand ,',acc (1- (ash 1 ,nn)))
                               (setf ,',acc (ash ,',acc (- ,nn))
                                     ,',nb (- ,',nb ,nn)))
                             (%lslow (b:rbits ,',r ,nn))))))
                  (lsym (tree)
                    (let ((tr (gensym "TREE")) (tb (gensym "TBL")))
                      `(let* ((,tr ,tree) (,tb (huff-table ,tr)))
                         (declare (type huff ,tr))
                         (block lsym
                           (when ,tb
                             (let ((tbits (huff-table-bits ,tr)))
                               (declare (type (integer 1 10) tbits))
                               (%lfill tbits)
                               (when (>= ,',nb tbits)
                                 (let* ((entry (aref (the (simple-array (unsigned-byte 16) (*)) ,tb)
                                                     (logand ,',acc (huff-mask ,tr))))
                                        (len (logand entry 15)))
                                   (declare (type (unsigned-byte 16) entry)
                                            (type (integer 0 15) len))
                                   (when (plusp len)
                                     (setf ,',acc (ash ,',acc (- len))
                                           ,',nb (- ,',nb len))
                                     (return-from lsym (ash entry -4)))))))
                           (%lslow (read-huff ,',r ,tr)))))))
         (multiple-value-prog1 (progn ,@body)
           (setf (b:brd-acc ,r) ,acc (b:brd-nbits ,r) ,nb (b:brd-pos ,r) ,p))))))

;; Context-modeled literal run (C ProcessCommands' literal loop for the
;; multi-tree case): reservoir, read position and the two previous bytes
;; live in locals; only the primary-table hit is inlined.  Single-symbol
;; trees, secondary tables and the end of input fall back to READ-HUFF for
;; that one literal, with the reservoir synced through R around the call.
(defun %decode-lit-run-ctx (r out pos count trees base mode)
  (declare (type b:brd r)
           (type (simple-array (unsigned-byte 8) (*)) out)
           (type fixnum pos count base)
           (type simple-vector trees)
           (type (integer 0 3) mode)
           (optimize (speed 3) (safety 0)))
  (let ((acc (b:brd-acc r)) (nbits (b:brd-nbits r)) (p (b:brd-pos r))
        (end (b:brd-end r))
        (src #+cl-brotli-sap (b:brd-sap r) #-cl-brotli-sap (b:brd-bytes r))
        (p1 (if (> pos 0) (aref out (1- pos)) 0))
        (p2 (if (> pos 1) (aref out (- pos 2)) 0))
        (lut +ctx-lut+) (lb (* 512 mode)))
    (declare (type fixnum acc p end) (type (integer 0 59) nbits)
             (type (simple-array (unsigned-byte 8) (2048)) lut)
             (type (integer 0 1536) lb)
             #+cl-brotli-sap (type (or null sb-sys:system-area-pointer) src)
             #-cl-brotli-sap (type (simple-array (unsigned-byte 8) (*)) src)
             (type (unsigned-byte 8) p1 p2))
    (dotimes (k count)
      (let* ((tree (svref trees (+ base (logior (aref lut (+ lb p1))
                                                 (aref lut (+ lb 256 p2))))))
             (tbl (huff-table tree))
             (sym 0))
        (declare (type huff tree) (type (unsigned-byte 8) sym))
        (block one
          (unless tbl
            (setf sym (huff-single tree))
            (return-from one))
          (let ((tbits (huff-table-bits tree)))
            (declare (type (integer 1 10) tbits))
            (when (and (< nbits tbits) src (<= (+ p 8) end))
              (let* ((bytes (min 7 (ash (- 59 nbits) -3)))
                     (w (logand (ptr-u64 src p)
                                (aref b::+wide-masks+ (* 8 bytes)))))
                (declare (type (integer 0 7) bytes) (type fixnum w))
                (setf acc (logior acc (the fixnum (ash w nbits)))
                      nbits (+ nbits (* 8 bytes))
                      p (+ p bytes))))
            (when (>= nbits tbits)
              (let* ((entry (aref (the (simple-array (unsigned-byte 16) (*)) tbl)
                                  (logand acc (huff-mask tree))))
                     (len (logand entry 15)))
                (declare (type (unsigned-byte 16) entry) (type (integer 0 15) len))
                (when (plusp len)
                  (setf acc (ash acc (- len))
                        nbits (- nbits len)
                        sym (ash entry -4))
                  (return-from one)))))
          (setf (b:brd-acc r) acc (b:brd-nbits r) nbits (b:brd-pos r) p)
          (setf sym (read-huff r tree))
          (setf acc (b:brd-acc r) nbits (b:brd-nbits r) p (b:brd-pos r)))
        (setf (aref out pos) sym)
        (incf pos)
        (setf p2 p1 p1 sym)))
    (setf (b:brd-acc r) acc (b:brd-nbits r) nbits (b:brd-pos r) p)
    pos))

(defun decode-compressed-meta-block (r out mlen window rb)
  "Decode one compressed meta-block of MLEN bytes into OUT.  RB is the 4-entry
distance ring buffer (persists across the stream)."
  (let* ((start (outbuf-pos out)) (target (+ start mlen))
         (nbl-l (read-nbltypes r)) (blkL (read-blk-header r nbl-l))
         (nbl-i (read-nbltypes r)) (blkI (read-blk-header r nbl-i))
         (nbl-d (read-nbltypes r)) (blkD (read-blk-header r nbl-d))
         (npostfix (b:rbits r 2))
         (ndirect (ash (b:rbits r 4) npostfix))
         (cmode (make-array nbl-l))
         (postfix-mask (1- (ash 1 npostfix))))
    (dotimes (i nbl-l) (setf (svref cmode i) (b:rbits r 2)))
    (let* ((ntreesl (read-nbltypes r))
           (cmapl (if (>= ntreesl 2) (read-context-map r (* 64 nbl-l) ntreesl)
                      (make-array (* 64 nbl-l) :initial-element 0)))
           (ntreesd (read-nbltypes r))
           (cmapd (if (>= ntreesd 2) (read-context-map r (* 4 nbl-d) ntreesd)
                      (make-array (* 4 nbl-d) :initial-element 0)))
           (htreel (make-array ntreesl)) (htreei (make-array nbl-i))
           (htreed (make-array ntreesd))
           (lit-trees (make-array (* 64 nbl-l)))
           (dist-alpha (+ 16 ndirect (ash 48 npostfix)))
           (single-lit-tree nil) (single-dist-tree nil)
           (cmd-tree nil) (dist-tree nil)
           ;; NBLTYPES is fixed for a meta-block; hoist the one-tree checks out
           ;; of the per-command/per-literal paths.
           (single-lblock (= 1 (blk-ntypes blkL)))
           (single-iblock (= 1 (blk-ntypes blkI)))
           (single-dblock (= 1 (blk-ntypes blkD))))
       (declare (type simple-vector cmode cmapl cmapd htreel htreei htreed
                                 lit-trees)
                (type (simple-array fixnum (*)) rb)
                (type blk blkL blkI blkD)
                (type outbuf out)
                (type b:brd r)
                (type fixnum nbl-l nbl-i nbl-d ntreesl ntreesd mlen window
                      start target npostfix ndirect postfix-mask dist-alpha))
       (%grow out target)
       (dotimes (i ntreesl)
         (setf (svref htreel i) (read-prefix-code r 256)))
       (dotimes (i nbl-i)
         (setf (svref htreei i) (read-prefix-code r 704)))
       (dotimes (i ntreesd)
         (setf (svref htreed i) (read-prefix-code r dist-alpha)))
       (when (= ntreesl 1) (setf single-lit-tree (svref htreel 0)))
       (when (= ntreesd 1) (setf single-dist-tree (svref htreed 0)))
       ;; Hoist the only-tree pointers for the common single-block case.
       (setf cmd-tree (and single-iblock (svref htreei 0))
             dist-tree (and single-dblock single-dist-tree (svref htreed 0)))
       ;; Resolve the (block-type, context) -> literal-tree map once per
       ;; meta-block instead of following CMAPL and HTREEL per literal.
       (unless single-lit-tree
         (dotimes (bt nbl-l)
           (dotimes (cid 64)
             (setf (svref lit-trees (+ (* 64 bt) cid))
                   (svref htreel (svref cmapl (+ (* 64 bt) cid)))))))
       ;; command loop
       (loop while (< (outbuf-pos out) target) do
         (unless single-iblock
           (blk-maybe-switch r blkI))
         (let ((cmd 0) (ilen 0) (clen 0) (dist0 nil))
           (declare (type fixnum cmd ilen clen))
           (with-local-bits (r)
             (setf cmd (lsym (or cmd-tree (svref htreei (blk-type blkI)))))
             (setf ilen (+ (aref +cmd-ilen-base+ cmd)
                           (lbits (aref +cmd-ilen-bits+ cmd)))
                   clen (+ (aref +cmd-clen-base+ cmd)
                           (lbits (aref +cmd-clen-bits+ cmd)))))
           (setf dist0 (< cmd 128))
           ;; A corrupt stream must not write past the meta-block: only
           ;; TARGET bytes are reserved and the writes below are unchecked
           ;; (C: BROTLI_DECODER_ERROR_FORMAT_BLOCK_LENGTH_*).
           (when (> ilen (- target (outbuf-pos out)))
             (berr "insert length ~d exceeds the meta-block" ilen))
           ;; Insert literals through a local array and position.  The
           ;; meta-block output capacity is reserved up front, so no per-run
           ;; growth check is needed on a valid stream.
           (let ((data (outbuf-data out))
                 (pos (outbuf-pos out)))
             (declare (type (simple-array (unsigned-byte 8) (*)) data)
                      (type fixnum pos))
             (if single-lit-tree
                 (if single-lblock
                     ;; The common q0/q1 C stream: one literal block, one
                     ;; tree.  Local reservoir, no per-literal struct work.
                     (setf pos (%decode-lit-run r data pos ilen single-lit-tree))
                     (dotimes (k ilen)
                       (blk-maybe-switch r blkL)
                       (setf (aref data pos) (read-huff r single-lit-tree))
                       (incf pos)))
                 (if single-lblock
                     (setf pos (%decode-lit-run-ctx
                                r data pos ilen lit-trees 0
                                (the (integer 0 3) (svref cmode 0))))
                     ;; Split the insert at block boundaries: each piece is
                     ;; one context run.  BLK-MAYBE-SWITCH accounts for the
                     ;; piece's first literal; the rest come off the count.
                     (let ((left ilen))
                       (declare (type fixnum left))
                       (loop while (plusp left) do
                         (blk-maybe-switch r blkL)
                         (let ((piece (min left (1+ (blk-count blkL))))
                               (bt (blk-type blkL)))
                           (declare (type fixnum piece))
                           (decf (blk-count blkL) (1- piece))
                           (setf pos (%decode-lit-run-ctx
                                      r data pos piece lit-trees (* 64 bt)
                                      (the (integer 0 3) (svref cmode bt))))
                           (decf left piece))))))
             (setf (outbuf-pos out) pos))
           (when (>= (outbuf-pos out) target) (return))
           ;; distance — DCODE 0 (explicit or implicit dist0) reuses the last
           ;; distance without pushing; all other codes compute + push.
           (let ((distance 0) (idx (aref rb 4)) (dcode 0))
             (declare (type fixnum distance idx dcode))
             (if dist0
                 (setf distance (aref rb (logand (+ idx 3) 3))) ; last, no push
                 (progn
                   (unless single-dblock
                     (blk-maybe-switch r blkD))
                   (let ((dtree
                           (or dist-tree
                               (let* ((cidd (cond ((= clen 2) 0)
                                                  ((= clen 3) 1)
                                                  ((= clen 4) 2)
                                                  (t 3))))
                                 (svref htreed
                                        (svref cmapd
                                               (+ (* 4 (blk-type blkD))
                                                  cidd)))))))
                     (with-local-bits (r)
                     (setf dcode (lsym dtree))
                     (cond
                       ((< dcode 16)
                        (setf distance
                              (+ (aref rb (logand (+ idx
                                                    (aref +dsc-index+ dcode))
                                                  3))
                                 (aref +dsc-value+ dcode))))
                       ((< dcode (+ 16 ndirect))
                        (setf distance (- dcode 15)))
                       (t (if (zerop npostfix)
                              ;; Common case: NPOSTFIX=0, so HCODE=D and
                              ;; the variable right shifts disappear.
                              (let* ((d (- dcode ndirect 16))
                                     (ndistbits (+ 1 (ash d -1)))
                                     (dextra (lbits ndistbits))
                                     (offset
                                       (- (ash (+ 2 (logand d 1)) ndistbits)
                                          4)))
                                (declare (type fixnum d ndistbits dextra offset))
                                (setf distance
                                      (the fixnum
                                           (+ offset dextra ndirect 1))))
                              (let* ((d (- dcode ndirect 16))
                                     (ndistbits
                                       (+ 1 (ash d (- (1+ npostfix)))))
                                     (dextra (lbits ndistbits))
                                     (hcode (ash d (- npostfix)))
                                     (lcode (logand d postfix-mask))
                                     (offset
                                       (- (ash (+ 2 (logand hcode 1)) ndistbits)
                                          4)))
                                (declare (type fixnum d ndistbits dextra hcode
                                               lcode offset))
                                (setf distance
                                      (the fixnum
                                           (+ (ash (+ offset dextra) npostfix)
                                              lcode ndirect 1))))))))
                     ;; push real backward references only — dictionary
                     ;; references do NOT update the ring.
                     (when (and (/= dcode 0)
                                (<= distance
                                    (min window
                                         (- (outbuf-pos out)
                                            (outbuf-origin out)))))
                       (setf (aref rb (logand idx 3)) distance
                             (aref rb 4) (1+ idx))))))
             (let ((max-dist (min window
                                   (- (outbuf-pos out)
                                      (outbuf-origin out)))))
               (declare (type fixnum max-dist))
               (when (<= distance 0)
                 (berr "invalid distance ~d" distance))
               (if (<= distance max-dist)
                   (progn
                     (when (> clen (- target (outbuf-pos out)))
                       (berr "copy length ~d exceeds the meta-block" clen))
                     (out-copy-preallocated out distance clen))
                   (setf (outbuf-pos out)
                         (dict-word-into (outbuf-data out) (outbuf-pos out)
                                         target clen distance max-dist))))))))
    (when (/= (outbuf-pos out) target)
      (berr "meta-block produced ~d, expected ~d" (- (outbuf-pos out) start) mlen))))
