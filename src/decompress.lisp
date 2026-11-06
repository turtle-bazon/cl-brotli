;;;; src/decompress.lisp — brotli compressed meta-block decoder (RFC 7932 §9-10).
(in-package #:cl-brotli.lisp)

;; The decoder is validated against the C reference on every test/benchmark
;; stream; safety 0 removes per-symbol bounds checks from the literal and
;; match paths.
(declaim (optimize (speed 3) (safety 0)))

;;; length-code base/extra tables
(deftable +ins-bits+ #(0 0 0 0 0 0 1 1 2 2 3 3 4 4 5 5 6 7 8 9 10 12 14 24))
(deftable +ins-base+ #(0 1 2 3 4 5 6 8 10 14 18 26 34 50 66 98 130 194 322 578 1090 2114 6210 22594))
(deftable +cpy-bits+ #(0 0 0 0 0 0 0 0 1 1 2 2 3 3 4 4 5 5 6 7 8 9 10 24))
(deftable +cpy-base+ #(2 3 4 5 6 7 8 9 10 12 14 18 22 30 38 54 70 102 134 198 326 582 1094 2118))
(deftable +blen-bits+ (coerce '(2 2 2 2 3 3 3 3 4 4 4 4 5 5 5 5 6 6 7 8 9 10 11 12 13 24) '(simple-array fixnum (*))))
(deftable +blen-base+ (coerce '(1 5 9 13 17 25 33 41 49 65 81 97 113 145 177 209 241 305 369 497 753 1265 2289 4337 8433 16625) '(simple-array fixnum (*))))
;; insert-and-copy command -> cell start ranges
(deftable +cmd-ins+ #(0 0 0 0 8 8 0 16 8 16 16))
(deftable +cmd-cpy+ #(0 8 0 8 0 8 16 0 16 8 16))
;; distance short codes 0..15: ring-buffer slot offset + value offset (RFC 7932 §4).
;; The ring is a rolling buffer indexed by IDX (slots written most-recent-last).
(deftable +dsc-index+ (coerce '(3 2 1 0 3 3 3 3 3 3 2 2 2 2 2 2) '(simple-array fixnum (*))))
(deftable +dsc-value+ (coerce '(0 0 0 0 -1 1 -2 2 -3 3 -1 1 -2 2 -3 3) '(simple-array fixnum (*))))
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
  ;; DECOMPRESS's size guess for the first growth (0 = none)
  (hint 0 :type fixnum)
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
      ;; Double (the first growth jumps to %OUT's size hint): DECOMPRESS
      ;; trims the result in place, so overshoot costs no copy.
      (let ((new (make-array (max need (* 2 len) (outbuf-hint out))
                              :element-type '(unsigned-byte 8))))
        (setf (outbuf-hint out) 0)
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
(deftable +cmd-ilen-base+ (make-array 704 :element-type '(unsigned-byte 16) :initial-element 0))
(deftable +cmd-ilen-bits+ (make-array 704 :element-type '(unsigned-byte 16) :initial-element 0))
(deftable +cmd-clen-base+ (make-array 704 :element-type '(unsigned-byte 16) :initial-element 0))
(deftable +cmd-clen-bits+ (make-array 704 :element-type '(unsigned-byte 16) :initial-element 0))
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
  #+cl-brotli-sap
  (when (and (>= distance 8) (<= (+ fp len 16) wlimit) (< len 256))
    ;; C's memmove16 shape: whole 16-byte chunks (8 when the period is
    ;; 8..15), the last one running into slack below WLIMIT - no tail loop.
    ;; Chunks never read a byte the copy has not written yet.
    (sb-sys:with-pinned-objects (data)
      (let ((sap (sb-sys:vector-sap data)) (i 0))
        (declare (type fixnum i))
        (if (>= distance 16)
            (loop do (setf (sb-sys:sap-ref-64 sap (+ fp i))
                           (sb-sys:sap-ref-64 sap (+ src i))
                           (sb-sys:sap-ref-64 sap (+ fp i 8))
                           (sb-sys:sap-ref-64 sap (+ src i 8)))
                     (incf i 16)
                  while (< i len))
            (loop do (setf (sb-sys:sap-ref-64 sap (+ fp i))
                           (sb-sys:sap-ref-64 sap (+ src i)))
                     (incf i 8)
                  while (< i len)))))
    (return-from %copy-match-bytes nil))
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

(defmacro %copy-match-inline (data fp src distance len wlimit)
  "Call-free LZ77 copy for the hot command loops (same result as
%COPY-MATCH-BYTES).  No FILL/REPLACE: in SBCL no register survives a full
call, so a call anywhere in a loop body pushes the loop's state into stack
slots (the copy loop's position lived in [RBP-192])."
  (let ((d (gensym)) (f (gensym)) (sr (gensym)) (n (gensym)) (wl (gensym)))
    `(let ((,d ,data) (,f ,fp) (,sr ,src) (,n ,len) (,wl ,wlimit) (dist ,distance))
       (declare (type (simple-array (unsigned-byte 8) (*)) ,d)
                (type fixnum ,f ,sr ,n ,wl dist))
       #+cl-brotli-sap
       (sb-sys:with-pinned-objects (,d)
         (let ((sap (sb-sys:vector-sap ,d)) (i 0))
           (declare (type fixnum i))
           (cond
             ((>= ,n 4096)
              ;; Very long copies are bandwidth-bound: the library block
              ;; moves (vectorized) beat any per-word loop, and the call
              ;; cost is noise at this length.
              (%copy-match-bytes ,d ,f ,sr dist ,n ,wl))
             ((and (>= dist 16) (<= (+ ,f ,n 16) ,wl))
              (loop do (setf (sb-sys:sap-ref-64 sap (+ ,f i))
                             (sb-sys:sap-ref-64 sap (+ ,sr i))
                             (sb-sys:sap-ref-64 sap (+ ,f i 8))
                             (sb-sys:sap-ref-64 sap (+ ,sr i 8)))
                       (incf i 16)
                    while (< i ,n)))
             ((and (>= dist 8) (<= (+ ,f ,n 8) ,wl))
              (loop do (setf (sb-sys:sap-ref-64 sap (+ ,f i))
                             (sb-sys:sap-ref-64 sap (+ ,sr i)))
                       (incf i 8)
                    while (< i ,n)))
             (t
              ;; period widening: a byte prologue to a multiple of the
              ;; period >= 8, then 8-byte moves (never reading an unwritten
              ;; byte), then a byte tail
              (let ((pd dist))
                (declare (type fixnum pd))
                (when (< pd 8)
                  (let ((k (case pd (1 8) (2 8) (3 9) (4 8) (5 10) (6 12) (t 14))))
                    (declare (type fixnum k))
                    (loop while (and (< i k) (< i ,n)) do
                      (setf (sb-sys:sap-ref-8 sap (+ ,f i)) (sb-sys:sap-ref-8 sap (+ ,sr i)))
                      (incf i))
                    (setf pd k)))
                (loop while (<= (+ i 8) ,n) do
                  (setf (sb-sys:sap-ref-64 sap (+ ,f i))
                        (sb-sys:sap-ref-64 sap (- (+ ,f i) pd)))
                  (incf i 8)
                  ;; Long runs (zeros, short periods): grow the period to
                  ;; the largest multiple <= I already written, so loads
                  ;; stop depending on the previous iteration's store and
                  ;; 16-byte steps become possible.
                  (when (and (>= i (* 2 pd)) (>= (- ,n i) 64))
                    (setf pd (* pd (floor i pd)))
                    (loop while (<= (+ i 16) ,n) do
                      (setf (sb-sys:sap-ref-64 sap (+ ,f i))
                            (sb-sys:sap-ref-64 sap (- (+ ,f i) pd))
                            (sb-sys:sap-ref-64 sap (+ ,f i 8))
                            (sb-sys:sap-ref-64 sap (- (+ ,f i 8) pd)))
                      (incf i 16))))
                (loop while (< i ,n) do
                  (setf (sb-sys:sap-ref-8 sap (+ ,f i)) (sb-sys:sap-ref-8 sap (- (+ ,f i) pd)))
                  (incf i)))))))
       #-cl-brotli-sap
       (progn ,wl
         (dotimes (i ,n) (setf (aref ,d (+ ,f i)) (aref ,d (+ ,sr i))))))))

(defun %copy-match-ool (data fp distance len wlimit)
  "%COPY-MATCH-INLINE as its own function: inside the command loops the
copy competes with ~25 live values for 14 registers and its loop ran on
stack temporaries; here it gets every register.  Returns FP + LEN."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum fp distance len wlimit)
           (optimize (speed 3) (safety 0)))
  (%copy-match-inline data fp (- fp distance) distance len wlimit)
  (+ fp len))

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

;; C's context lookup: for each of the four modes a 512-byte table with
;; context = LUT[mode*512 + p1] | LUT[mode*512 + 256 + p2] - one OR, no
;; per-literal branch on the mode (RFC 7932 7.1).
(deftable +ctx-lut+
  (let ((v (make-array 2048 :element-type '(unsigned-byte 8) :initial-element 0)))
    (dotimes (b 256 v)
      (setf (aref v b) (logand b #x3f)                          ; LSB6
            (aref v (+ 512 b)) (ash b -2)                       ; MSB6
            (aref v (+ 1024 b)) (aref +lut0+ b)                 ; UTF8
            (aref v (+ 1024 256 b)) (aref +lut1+ b)
            (aref v (+ 1536 b)) (ash (aref +lut2+ b) 3)         ; signed
            (aref v (+ 1536 256 b)) (aref +lut2+ b)))))
(declaim (type (simple-array (unsigned-byte 8) (2048)) +ctx-lut+))

(defun %decode-simple-meta-block (r data pos target origin window rb
                                  ctree ltree dtree npostfix ndirect)
  "The command loop for the common stream shape (one block type and one
tree per category - C's q0-q4 output): no block switches, context maps or
tree lookups, so the live state fits the registers.  Returns the end
position, or a negative error code (-1 insert / -2 copy past the
meta-block, -3 invalid distance): signalling inside the loop would be a
call site, and in SBCL a call site anywhere in a loop costs it registers."
  (declare (type b:brd r)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum pos target origin window)
           (type (integer 0 3) npostfix) (type (integer 0 120) ndirect)
           (type (simple-array fixnum (*)) rb)
           (type huff ctree ltree dtree)
           (optimize (speed 3) (safety 0)))
  (let ((ct (huff-table ctree)) (cb (if (huff-table ctree) (huff-table-bits ctree) 1))
        (cm (huff-mask ctree))
        (lt (huff-table ltree)) (lbt (if (huff-table ltree) (huff-table-bits ltree) 1))
        (lm (huff-mask ltree))
        (dt (huff-table dtree)) (db (if (huff-table dtree) (huff-table-bits dtree) 1))
        (dm (huff-mask dtree))
        (postfix-mask (1- (ash 1 npostfix))))
    (declare (type (or null (simple-array (unsigned-byte 16) (*))) ct lt dt)
             (type (integer 1 10) cb lbt db)
             (type fixnum cm lm dm postfix-mask))
    (with-local-bits (r)
      (loop while (< pos target) do
        (let* ((cmd (lsym* ctree ct cb cm))
               (ilen (+ (aref +cmd-ilen-base+ cmd) (lbits (aref +cmd-ilen-bits+ cmd))))
               (clen (+ (aref +cmd-clen-base+ cmd) (lbits (aref +cmd-clen-bits+ cmd)))))
          (declare (type fixnum cmd ilen clen))
          (when (> ilen (- target pos)) (return-from %decode-simple-meta-block -1))
          (let ((pend (+ pos ilen)))
            (declare (type fixnum pend))
            (loop while (< pos pend) do
              (setf (aref data pos) (the (unsigned-byte 8) (lsym* ltree lt lbt lm)))
              (incf pos)))
          (when (>= pos target) (return))
          (let ((distance 0) (idx (aref rb 4)) (dcode 0)
                (max-dist (min window (- pos origin))))
            (declare (type fixnum distance idx dcode max-dist))
            (if (< cmd 128)
                (setf distance (aref rb (logand (+ idx 3) 3)))
                (progn
                  (setf dcode (lsym* dtree dt db dm))
                  (cond
                    ((< dcode 16)
                     (setf distance
                           (+ (aref rb (logand (+ idx (aref +dsc-index+ dcode)) 3))
                              (aref +dsc-value+ dcode))))
                    ((< dcode (+ 16 ndirect))
                     (setf distance (- dcode 15)))
                    ((zerop npostfix)
                     (let* ((d (- dcode ndirect 16))
                            (ndistbits (+ 1 (ash d -1)))
                            (dextra (lbits ndistbits))
                            (offset (- (ash (+ 2 (logand d 1)) ndistbits) 4)))
                       (declare (type fixnum d ndistbits dextra offset))
                       (setf distance (the fixnum (+ offset dextra ndirect 1)))))
                    (t
                     (let* ((d (- dcode ndirect 16))
                            (ndistbits (+ 1 (ash d (- (1+ npostfix)))))
                            (dextra (lbits ndistbits))
                            (hcode (ash d (- npostfix)))
                            (lcode (logand d postfix-mask))
                            (offset (- (ash (+ 2 (logand hcode 1)) ndistbits) 4)))
                       (declare (type fixnum d ndistbits dextra hcode lcode offset))
                       (setf distance
                             (the fixnum (+ (ash (+ offset dextra) npostfix)
                                            lcode ndirect 1))))))
                  (when (and (/= dcode 0) (<= distance max-dist))
                    (setf (aref rb (logand idx 3)) distance
                          (aref rb 4) (1+ idx)))))
            (when (<= distance 0) (return-from %decode-simple-meta-block -3))
            (if (<= distance max-dist)
                (progn
                  (when (> clen (- target pos)) (return-from %decode-simple-meta-block -2))
                  (%copy-match-inline data pos (- pos distance) distance clen target)
                  (incf pos clen))
                (setf pos (dict-word-into data pos target clen distance max-dist)))))))
    pos))

(defun blk-switch-ool (r b)
  "BLK-MAYBE-SWITCH out of line, for the general loop: its inline expansion
brought READ-HUFF (with several slow-path call sites) to each of the three
switch points."
  (declare (type b:brd r) (type blk b) (optimize (speed 3) (safety 0)))
  (blk-maybe-switch r b))
(declaim (notinline blk-switch-ool))

(defun %decode-general-meta-block (r data pos target origin window rb
                                   blkL blkI blkD single-lblock single-iblock
                                   single-dblock cmode lit-trees lit-tables htreei htreed
                                   cmapd single-lit-tree cmd-tree dist-tree
                                   npostfix ndirect postfix-mask)
  "The general command loop (block switches, context-modeled literals,
distance context maps) as its own function: only what the loop needs is
live, not the meta-block setup state.  Returns the end position or a
negative error code like %DECODE-SIMPLE-META-BLOCK."
  (declare (type b:brd r)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum pos target origin window postfix-mask)
           (type (integer 0 3) npostfix) (type (integer 0 120) ndirect)
           (type (simple-array fixnum (*)) rb)
           (type blk blkL blkI blkD)
           (type boolean single-lblock single-iblock single-dblock)
           (type simple-vector cmode lit-trees lit-tables htreei htreed cmapd)
           (type (or null huff) single-lit-tree cmd-tree dist-tree)
           (optimize (speed 3) (safety 0)))
  (let ((cmode0 (the (integer 0 3) (svref cmode 0)))
        (lut +ctx-lut+))
    (declare (type (integer 0 3) cmode0)
             (type (simple-array (unsigned-byte 8) (2048)) lut))
         (with-local-bits (r)
           (macrolet ((switch (b)
                        ;; BLK-MAYBE-SWITCH, with the common no-switch case
                        ;; inline and the reservoir synced only for a switch
                        `(if (zerop (blk-count ,b))
                             (%lslow (blk-switch-ool r ,b))
                             (decf (blk-count ,b)))))
             (loop while (< pos target) do
               (unless single-iblock (switch blkI))
               (let* ((cmd (if cmd-tree
                               (lsym cmd-tree)
                               (lsym (svref htreei (blk-type blkI)))))
                      (ilen (+ (aref +cmd-ilen-base+ cmd)
                               (lbits (aref +cmd-ilen-bits+ cmd))))
                      (clen (+ (aref +cmd-clen-base+ cmd)
                               (lbits (aref +cmd-clen-bits+ cmd)))))
                 (declare (type fixnum cmd ilen clen))
                 ;; A corrupt stream must not write past the meta-block:
                 ;; only TARGET bytes are reserved and the writes below are
                 ;; unchecked (C: BROTLI_DECODER_ERROR_FORMAT_BLOCK_LENGTH_*).
                 (when (> ilen (- target pos))
                   (return-from %decode-general-meta-block -1))
                 (cond
                   ((zerop ilen))
                   (single-lit-tree
                    (if single-lblock
                        (let ((pend (+ pos ilen))
                              (ltb (huff-table single-lit-tree)))
                          (declare (type fixnum pend)
                                   (type (simple-array (unsigned-byte 16) (*)) ltb))
                          ;; literal trees have 8-bit roots: constant mask/width;
                          ;; call-free when the input holds 2 bytes per literal
                          (if (fast-input-p (+ 16 (* 2 ilen)))
                              (loop while (< pos pend) do
                                (let ((sym (lsym-fast single-lit-tree ltb 8 255)))
                                  (declare (type fixnum sym))
                                  (when (minusp sym)
                                    (return-from %decode-general-meta-block -4))
                                  (setf (aref data pos) sym)
                                  (incf pos)))
                              (loop while (< pos pend) do
                                (setf (aref data pos)
                                      (the (unsigned-byte 8) (lsym* single-lit-tree ltb 8 255)))
                                (incf pos))))
                        (dotimes (k ilen)
                          (switch blkL)
                          (setf (aref data pos)
                                (the (unsigned-byte 8) (lsym single-lit-tree)))
                          (incf pos))))
                   (t
                    ;; context-modeled literals (C: context = LUT[p1] |
                    ;; LUT[256 + p2] for the block type's mode).  The run is
                    ;; split at literal-block boundaries, so the inner loop
                    ;; has no per-literal switch test; every literal tree has
                    ;; an 8-bit root (constant mask/width) and LIT-TABLES
                    ;; holds the tables directly - one load less per literal.
                    (let ((p1 (if (> pos 0) (aref data (1- pos)) 0))
                          (p2 (if (> pos 1) (aref data (- pos 2)) 0))
                          (left ilen))
                      (declare (type (unsigned-byte 8) p1 p2) (type fixnum left))
                      (loop while (plusp left) do
                        (let ((piece left) (base 0) (lb (* 512 cmode0)))
                          (declare (type fixnum piece base lb))
                          (unless single-lblock
                            (switch blkL)       ; accounts the piece's first literal
                            (setf piece (min left (1+ (blk-count blkL))))
                            (decf (blk-count blkL) (1- piece))
                            (let ((bt (blk-type blkL)))
                              (setf base (* 64 bt)
                                    lb (* 512 (the (integer 0 3) (svref cmode bt))))))
                          (let ((pend (+ pos piece)))
                            (declare (type fixnum pend))
                            (if (fast-input-p (+ 16 (* 2 piece)))
                                ;; call-free: enough input for every literal
                                (loop while (< pos pend) do
                                  (let* ((ci (+ base (logior (aref lut (+ lb p1))
                                                             (aref lut (+ lb 256 p2)))))
                                         (sym (lsym-fast (svref lit-trees ci)
                                                         (the (simple-array (unsigned-byte 16) (*))
                                                              (svref lit-tables ci))
                                                         8 255)))
                                    (declare (type fixnum ci sym))
                                    (when (minusp sym)
                                      (return-from %decode-general-meta-block -4))
                                    (setf (aref data pos) sym)
                                    (incf pos)
                                    (setf p2 p1 p1 sym)))
                                (loop while (< pos pend) do
                                  (let* ((ci (+ base (logior (aref lut (+ lb p1))
                                                             (aref lut (+ lb 256 p2)))))
                                         (sym (the (unsigned-byte 8)
                                                   (lsym* (svref lit-trees ci)
                                                          (the (simple-array (unsigned-byte 16) (*))
                                                               (svref lit-tables ci))
                                                          8 255))))
                                    (declare (type fixnum ci))
                                    (setf (aref data pos) sym)
                                    (incf pos)
                                    (setf p2 p1 p1 sym)))))
                          (decf left piece))))))
                 (when (>= pos target) (return))
                 ;; distance - DCODE 0 (explicit or implicit dist0) reuses
                 ;; the last distance without pushing; all other codes
                 ;; compute + push.
                 (let ((distance 0) (idx (aref rb 4)) (dcode 0)
                       (max-dist (min window (- pos origin))))
                   (declare (type fixnum distance idx dcode max-dist))
                   (if (< cmd 128)
                       (setf distance (aref rb (logand (+ idx 3) 3))) ; last, no push
                       (progn
                         (unless single-dblock (switch blkD))
                         (let ((dtree
                                 (or dist-tree
                                     (svref htreed
                                            (svref cmapd
                                                   (+ (* 4 (blk-type blkD))
                                                      (cond ((= clen 2) 0)
                                                            ((= clen 3) 1)
                                                            ((= clen 4) 2)
                                                            (t 3))))))))
                           (setf dcode (if dist-tree
                                           (lsym dist-tree)
                                           (lsym dtree)))
                           (cond
                             ((< dcode 16)
                              (setf distance
                                    (+ (aref rb (logand (+ idx (aref +dsc-index+ dcode)) 3))
                                       (aref +dsc-value+ dcode))))
                             ((< dcode (+ 16 ndirect))
                              (setf distance (- dcode 15)))
                             ((zerop npostfix)
                              ;; Common case: NPOSTFIX=0, so HCODE=D and the
                              ;; variable right shifts disappear.
                              (let* ((d (- dcode ndirect 16))
                                     (ndistbits (+ 1 (ash d -1)))
                                     (dextra (lbits ndistbits))
                                     (offset (- (ash (+ 2 (logand d 1)) ndistbits) 4)))
                                (declare (type fixnum d ndistbits dextra offset))
                                (setf distance (the fixnum (+ offset dextra ndirect 1)))))
                             (t
                              (let* ((d (- dcode ndirect 16))
                                     (ndistbits (+ 1 (ash d (- (1+ npostfix)))))
                                     (dextra (lbits ndistbits))
                                     (hcode (ash d (- npostfix)))
                                     (lcode (logand d postfix-mask))
                                     (offset (- (ash (+ 2 (logand hcode 1)) ndistbits) 4)))
                                (declare (type fixnum d ndistbits dextra hcode lcode offset))
                                (setf distance
                                      (the fixnum (+ (ash (+ offset dextra) npostfix)
                                                     lcode ndirect 1))))))
                           ;; push real backward references only - dictionary
                           ;; references do NOT update the ring.
                           (when (and (/= dcode 0) (<= distance max-dist))
                             (setf (aref rb (logand idx 3)) distance
                                   (aref rb 4) (1+ idx))))))
                   (when (<= distance 0)
                     (return-from %decode-general-meta-block -3))
                   (if (<= distance max-dist)
                       (progn
                         (when (> clen (- target pos))
                           (return-from %decode-general-meta-block -2))
                         ;; Write limit = the meta-block end: any copy
                         ;; overrun lands on bytes this meta-block rewrites,
                         ;; never past the output the caller gets back.
                         (%copy-match-inline data pos (- pos distance) distance clen target)
                         (incf pos clen))
                       (setf pos (dict-word-into data pos target clen distance
                                                 max-dist)))))))))
  pos)

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
                      start target postfix-mask dist-alpha)
                (type (integer 0 3) npostfix) (type (integer 0 120) ndirect))
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
       (when (and single-iblock single-dblock single-lblock
                  single-lit-tree cmd-tree dist-tree)
         ;; the common q0-q4 shape gets the small specialized loop
         (let ((e (%decode-simple-meta-block r (outbuf-data out) (outbuf-pos out)
                                             target (outbuf-origin out) window rb
                                             cmd-tree single-lit-tree dist-tree
                                             npostfix ndirect)))
           (declare (type fixnum e))
           (case e
             (-1 (berr "insert length exceeds the meta-block"))
             (-2 (berr "copy length exceeds the meta-block"))
             (-3 (berr "invalid distance")))
           (setf (outbuf-pos out) e))
         (return-from decode-compressed-meta-block nil))
       ;; command loop (its own function - see %DECODE-GENERAL-META-BLOCK)
       (let ((e (%decode-general-meta-block
                 r (outbuf-data out) (outbuf-pos out) target (outbuf-origin out)
                 window rb blkL blkI blkD single-lblock single-iblock
                 single-dblock cmode lit-trees
                 ;; tables of the (block type, context) literal trees; only
                 ;; filled (and used) when literals are context-modeled
                 (if single-lit-tree
                     #()
                     (map 'simple-vector #'huff-table lit-trees))
                 htreei htreed cmapd
                 single-lit-tree cmd-tree dist-tree npostfix ndirect
                 postfix-mask)))
         (declare (type fixnum e))
         (case e
           (-1 (berr "insert length exceeds the meta-block"))
           (-2 (berr "copy length exceeds the meta-block"))
           (-3 (berr "invalid distance"))
           (-4 (berr "invalid prefix code")))
         (setf (outbuf-pos out) e)))
    (when (/= (outbuf-pos out) target)
      (berr "meta-block produced ~d, expected ~d" (- (outbuf-pos out) start) mlen))))
