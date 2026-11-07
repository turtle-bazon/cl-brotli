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
         ;; bytes: tree indexes are < 256 (8x less garbage than a T vector)
         (cmap (make-array size :element-type '(unsigned-byte 8) :initial-element 0))
         (i 0))
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
  ;; input position where the stream began, and input / output positions
  ;; at the last growth check (growth estimates)
  (in-start 0 :type fixnum)
  (last-in 0 :type fixnum)
  (last-out 0 :type fixnum)
  ;; Absolute output ceiling for DECOMPRESS-INTO; NIL means growable.  When
  ;; set, DATA is caller-owned and must never be replaced.
  (limit nil :type (or null fixnum)))

(defun %grow (out need &optional r)
  (when (and (outbuf-limit out) (> need (outbuf-limit out)))
    (error 'brotli-output-overflow
           :msg (format nil "brotli: output buffer too small (needs ~D bytes)"
                        need)
           :needed need))
  (let* ((data (outbuf-data out)) (len (length data))
         (est 0))
    (declare (type fixnum len est))
    (when r
      ;; Extrapolate the final size from the output per input byte - over
      ;; the whole stream so far, or over the last meta-block if that is
      ;; higher (the first block also carries the trees) - plus 1/4 (1/2
      ;; while only the first block has been seen: its trees make it look
      ;; less compressible, and an estimate a few KB short costs a copy of
      ;; everything at the last block), at most 8x NEED.  A highly
      ;; compressible stream of many meta-blocks (C's q0/q1 write 64-128
      ;; KiB blocks) otherwise doubled - and copied - all the way up.
      (let ((done (- (outbuf-pos out) (outbuf-origin out)))
            (in (b:brd-pos r)))
        (when (plusp done)
          (let* ((left (max 0 (- (b:brd-end r) in)))
                 (used (max 1 (- in (outbuf-in-start out))))
                 (last-used (max 1 (- in (outbuf-last-in out))))
                 (last-done (- (outbuf-pos out) (outbuf-last-out out)))
                 (per (max (/ done used) (/ last-done last-used)))
                 (margin (if (= (outbuf-last-out out) (outbuf-origin out))
                             3/2 5/4)))
            (setf est (min (* 8 need) (+ need (ceiling (* left per margin)))))))
        (setf (outbuf-last-in out) in
              (outbuf-last-out out) (outbuf-pos out))))
    (when (> need len)
      ;; At least double.  The first meta-block reserves exactly its own
      ;; size (nothing to extrapolate from yet; a stream of one meta-block
      ;; then never over-allocates - the old 8x-input guess allocated
      ;; 4.8 MB for 1 MB of binary at q0); the next growth extrapolates.
      ;; DECOMPRESS trims the result in place, so overshoot costs no copy,
      ;; only zeroing (and page faults on a cold heap).
      (let ((new (make-array (max need (* 2 len) est)
                             :element-type '(unsigned-byte 8))))
        (replace new data :end2 (outbuf-pos out))
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

(defun %decode-simple-meta-block-lisp (r data pos target origin window rb
                                       ctree ltree dtree npostfix ndirect once)
  "The command loop for the common stream shape (one block type and one
tree per category - C's q0-q4 output): no block switches, context maps or
tree lookups, so the live state fits the registers.  Returns the end
position, or a negative error code (-1 insert / -2 copy past the
meta-block, -3 invalid distance): signalling inside the loop would be a
call site, and in SBCL a call site anywhere in a loop costs it registers.
ONCE: decode a single command (the assembly loop's fallback)."
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
          (when (> ilen (- target pos)) (return-from %decode-simple-meta-block-lisp -1))
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
            (when (<= distance 0) (return-from %decode-simple-meta-block-lisp -3))
            (if (<= distance max-dist)
                (progn
                  (when (> clen (- target pos)) (return-from %decode-simple-meta-block-lisp -2))
                  (%copy-match-inline data pos (- pos distance) distance clen target)
                  (incf pos clen))
                (setf pos (dict-word-into data pos target clen distance max-dist))))
          (when once (return)))))
    pos))


#+cl-brotli-x86-64
(progn
(deftable +cmd-lut64+
  ;; the four command LUTs in one word for the assembly loops:
  ;; ilen base | ilen bits << 16 | clen bits << 24 | clen base << 32
  ;; | distance context << 48.  The context (copy length 2, 3, 4, >= 5 ->
  ;; 0..3) is a function of the copy code alone - lengths 2..4 have no
  ;; extra bits - so, as in C's command LUT, it is known before the extra
  ;; bits are read.
  (let ((v (make-array 704 :element-type '(unsigned-byte 64))))
    (dotimes (cmd 704 v)
      (setf (aref v cmd)
            (logior (aref +cmd-ilen-base+ cmd) (ash (aref +cmd-ilen-bits+ cmd) 16)
                    (ash (aref +cmd-clen-bits+ cmd) 24)
                    (ash (aref +cmd-clen-base+ cmd) 32)
                    (ash (min 3 (- (aref +cmd-clen-base+ cmd) 2)) 48))))))

(deftable +no-table+ (make-array 1 :element-type '(unsigned-byte 16) :initial-element 0)
  "Stand-in table of categories without block switches (never read).")

(declaim (inline huff-param))
(defun huff-param (h)
  "A tree's parameters as the assembly loops want them: mask | root bits
<< 16."
  (declare (type huff h))
  (logior (huff-mask h) (ash (huff-table-bits h) 16)))

(defmacro with-asm-state ((st) &body body)
  `(let ((,st (make-array +st-size+ :element-type '(unsigned-byte 64) :initial-element 0)))
     (declare (type (simple-array (unsigned-byte 64) (*)) ,st))
     ,@body))

(defun %asm-state-init (st r pos target origin window npostfix ndirect)
  "The slots both assembly loops share."
  (declare (type (simple-array (unsigned-byte 64) (*)) st) (type b:brd r)
           (type fixnum pos target origin window) (type (integer 0 3) npostfix)
           (type (integer 0 120) ndirect)
           (optimize (speed 3) (safety 0)))
  (setf (aref st +st-target+) target
        (aref st +st-origin+) origin
        (aref st +st-window+) window
        (aref st +st-npostfix+) npostfix
        (aref st +st-ndirect+) ndirect
        (aref st +st-postfix-mask+) (1- (ash 1 npostfix))
        (aref st +st-pos+) pos
        (aref st +st-end8+) (ldb (byte 64 0) (- (b:brd-end r) 8)))
  (dotimes (k 16)
    (setf (aref st (+ +st-dsc0+ k))
          (ldb (byte 64 0) (+ (aref +dsc-index+ k) (* 4 (aref +dsc-value+ k)))))))

(declaim (inline %asm-sync-in %asm-sync-out))
(defun %asm-sync-in (st r rb pos)
  ;; Lisp -> ST: bit reader, output position, distance ring
  (declare (type (simple-array (unsigned-byte 64) (*)) st) (type b:brd r)
           (type (simple-array fixnum (*)) rb) (type fixnum pos))
  (setf (aref st +st-acc+) (ldb (byte 64 0) (b:brd-acc r))
        (aref st +st-nb+) (b:brd-nbits r)
        (aref st +st-p+) (b:brd-pos r)
        (aref st +st-pos+) pos
        (aref st (+ +st-ring0+ 0)) (ldb (byte 64 0) (aref rb 0))
        (aref st (+ +st-ring0+ 1)) (ldb (byte 64 0) (aref rb 1))
        (aref st (+ +st-ring0+ 2)) (ldb (byte 64 0) (aref rb 2))
        (aref st (+ +st-ring0+ 3)) (ldb (byte 64 0) (aref rb 3))
        (aref st +st-ring-idx+) (ldb (byte 64 0) (aref rb 4))))
(defun %asm-sync-out (st r rb)
  ;; ST -> Lisp; returns the output position
  (declare (type (simple-array (unsigned-byte 64) (*)) st) (type b:brd r)
           (type (simple-array fixnum (*)) rb))
  (setf (b:brd-acc r) (the fixnum (aref st +st-acc+))
        (b:brd-nbits r) (the (integer 0 59) (aref st +st-nb+))
        (b:brd-pos r) (the fixnum (aref st +st-p+))
        (aref rb 0) (the fixnum (aref st (+ +st-ring0+ 0)))
        (aref rb 1) (the fixnum (aref st (+ +st-ring0+ 1)))
        (aref rb 2) (the fixnum (aref st (+ +st-ring0+ 2)))
        (aref rb 3) (the fixnum (aref st (+ +st-ring0+ 3)))
        (aref rb 4) (the fixnum (aref st +st-ring-idx+)))
  (the fixnum (aref st +st-pos+)))

(defvar *asm-dict* nil)
(defun %asm-dict ()
  "The dictionary + 32 bytes of padding: the assembly copies words with
fixed 32-byte loads."
  (or *asm-dict*
      (setf *asm-dict*
            (let* ((d (load-dict))
                   (v (make-array (+ (length d) 32) :element-type '(unsigned-byte 8)
                                                     :initial-element 0)))
              (replace v d)
              v))))

(deftable +asm-dict-meta+
  (let ((v (make-array 51 :element-type '(unsigned-byte 64) :initial-element 0)))
    (dotimes (l 25) (setf (aref v l) (aref +ndbits+ l)))
    (dotimes (l 26 v) (setf (aref v (+ 25 l)) (aref +doffset+ l))))
  "ndbits[0..24], doffset[0..25] for the assembly dictionary path.")

(deftable +asm-transforms+
  (let ((v (make-array (* 32 121) :element-type '(unsigned-byte 8) :initial-element 0)))
    (dotimes (tid 121 v)
      (let* ((tr (svref +transforms-c+ tid))
             (prefix (svref tr 0)) (kind (svref tr 1)) (k (svref tr 2))
             (suffix (svref tr 3)) (b (* 32 tid)))
        (setf (aref v b) (length prefix)
              (aref v (+ b 1)) kind
              (aref v (+ b 2)) k
              (aref v (+ b 3)) (length suffix)
              (aref v (+ b 4)) (if (= kind 3) k 0)
              (aref v (+ b 5)) (if (= kind 4) k 0)
              (aref v (+ b 6)) (case kind (1 1) (2 2) (t 0)))
        (replace v prefix :start1 (+ b 8))
        (replace v suffix :start1 (+ b 16)))))
  "The transforms as 32-byte records for the assembly dictionary path.")

(defun %asm-dict-word (st data window)
  "Exit 2 of an assembly loop: write the dictionary word it stopped at."
  (declare (type (simple-array (unsigned-byte 64) (*)) st)
           (type (simple-array (unsigned-byte 8) (*)) data) (type fixnum window)
           (optimize (speed 3) (safety 0)))
  (let ((pos (the fixnum (aref st +st-pos+))))
    (dict-word-into data pos (the fixnum (aref st +st-target+))
                    (the fixnum (aref st +st-clen+)) (the fixnum (aref st +st-dist+))
                    (min window (- pos (the fixnum (aref st +st-origin+)))))))

)

(defun %decode-simple-meta-block (r data pos target origin window rb
                                  ctree ltree dtree npostfix ndirect)
  "Decode a simple-shape meta-block (see %DECODE-SIMPLE-META-BLOCK-LISP).
On x86-64 SBCL the command loop runs in assembly (src/dvops.lisp); a
command it leaves to Lisp - near the end of the input, anything invalid -
is decoded by the Lisp loop, one at a time."
  (declare (type b:brd r)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum pos target origin window)
           (type (integer 0 3) npostfix) (type (integer 0 120) ndirect)
           (type (simple-array fixnum (*)) rb)
           (type huff ctree ltree dtree)
           (optimize (speed 3) (safety 0)))
  #-cl-brotli-x86-64
  (%decode-simple-meta-block-lisp r data pos target origin window rb
                                  ctree ltree dtree npostfix ndirect nil)
  #+cl-brotli-x86-64
  (with-asm-state (st)
    (let ((ctx (make-array +ctx-size+ :initial-element 0)))
      (setf (svref ctx +ctx-in+) (b:brd-bytes r)
            (svref ctx +ctx-out+) data
            (svref ctx +ctx-cmdlut+) +cmd-lut64+
            (svref ctx +ctx-ctable+) (huff-table ctree)
            (svref ctx +ctx-ltable+) (huff-table ltree)
            (svref ctx +ctx-dtable+) (huff-table dtree)
            (svref ctx +ctx-dict+) (%asm-dict)
            (svref ctx +ctx-dtrans+) +asm-transforms+
            (svref ctx +ctx-dmeta+) +asm-dict-meta+)
      (%asm-state-init st r pos target origin window npostfix ndirect)
      (setf (aref st +st-cmd-param+) (huff-param ctree)
            (aref st +st-lparam+) (huff-param ltree)
            (aref st +st-dparam+) (huff-param dtree))
      (loop
        (%asm-sync-in st r rb pos)
        (%asm-simple-meta-block st ctx)
        (setf pos (%asm-sync-out st r rb))
        (case (aref st +st-exit+)
          (0 (return pos))
          (2 (setf pos (%asm-dict-word st data window)))
          (t (setf pos (%decode-simple-meta-block-lisp
                        r data pos target origin window rb
                        ctree ltree dtree npostfix ndirect t))))
        (when (or (minusp pos) (>= pos target)) (return pos))))))

#+cl-brotli-x86-64
(defun %decode-general-meta-block-asm (r data pos target origin window rb
                                       blkL blkI blkD single-lblock single-iblock
                                       single-dblock cmode lit-trees lit-tables htreei htreed
                                       cmapd single-lit-tree cmd-tree dist-tree
                                       npostfix ndirect postfix-mask htreel cmapl)
  "%DECODE-GENERAL-META-BLOCK with the command loop in assembly; a command
it leaves to Lisp is decoded by the Lisp loop, one at a time."
  (declare (type b:brd r)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum pos target origin window postfix-mask)
           (type (integer 0 3) npostfix) (type (integer 0 120) ndirect)
           (type (simple-array fixnum (*)) rb)
           (type blk blkL blkI blkD)
           (type simple-vector cmode htreei htreed htreel)
           (type (simple-array (unsigned-byte 8) (*)) cmapd cmapl)
           (type (or null simple-vector) lit-trees)
           (optimize (speed 3) (safety 0)))
  (flet ((u8s (v) (let ((o (make-array (length (the simple-vector v))
                                       :element-type '(unsigned-byte 8))))
                    (dotimes (i (length o) o) (setf (aref o i) (svref v i)))))
         (params (trees) (let ((o (make-array (length (the simple-vector trees))
                                              :element-type '(unsigned-byte 64))))
                           (dotimes (i (length o) o)
                             (setf (aref o i) (huff-param (svref trees i))))))
         (tabs (trees) (map 'simple-vector #'huff-table trees)))
    (let* ((nbl-l (blk-ntypes blkL))
           (cparams (params htreei))
           (ltriv (make-array nbl-l :element-type '(unsigned-byte 64)))
           (ctx (make-array +ctx-size+ :initial-element 0)))
      (declare (type (simple-array (unsigned-byte 64) (*)) cparams ltriv))
      ;; a block type whose 64 contexts all use one tree needs no context
      (dotimes (bt nbl-l)
        (let ((tree (aref cmapl (* 64 bt))))
          (setf (aref ltriv bt)
                (if (loop for c from 1 below 64
                          always (= (aref cmapl (+ (* 64 bt) c)) tree))
                    tree
                    (ldb (byte 64 0) -1)))))
      (macrolet ((bt-table (b) `(if (blk-bhuff ,b) (huff-table (blk-bhuff ,b)) +no-table+))
                 (bl-table (b) `(if (blk-chuff ,b) (huff-table (blk-chuff ,b)) +no-table+))
                 (bt-param (b) `(if (blk-bhuff ,b) (huff-param (blk-bhuff ,b)) 0))
                 (bl-param (b) `(if (blk-chuff ,b) (huff-param (blk-chuff ,b)) 0)))
        (setf (svref ctx +ctx-in+) (b:brd-bytes r)
              (svref ctx +ctx-out+) data
              (svref ctx +ctx-cmdlut+) +cmd-lut64+
              (svref ctx +ctx-ctx-table+) +ctx-lut+
              (svref ctx +ctx-ctabs+) (tabs htreei)
              (svref ctx +ctx-cparams+) cparams
              (svref ctx +ctx-cmapl+) cmapl
              (svref ctx +ctx-ltabs+) (tabs htreel)
              (svref ctx +ctx-lparams+) (params htreel)
              (svref ctx +ctx-cmapd+) cmapd
              (svref ctx +ctx-dtabs+) (tabs htreed)
              (svref ctx +ctx-dparams+) (params htreed)
              (svref ctx +ctx-lbt+) (bt-table blkL)
              (svref ctx +ctx-lbl+) (bl-table blkL)
              (svref ctx +ctx-ibt+) (bt-table blkI)
              (svref ctx +ctx-ibl+) (bl-table blkI)
              (svref ctx +ctx-dbt+) (bt-table blkD)
              (svref ctx +ctx-dbl+) (bl-table blkD)
              (svref ctx +ctx-cmodes+) (u8s cmode)
              (svref ctx +ctx-ltriv+) ltriv
              (svref ctx +ctx-dict+) (%asm-dict)
              (svref ctx +ctx-dtrans+) +asm-transforms+
              (svref ctx +ctx-dmeta+) +asm-dict-meta+
              (svref ctx +ctx-ctxtabs+) lit-tables)
        (with-asm-state (st)
          (%asm-state-init st r pos target origin window npostfix ndirect)
          (setf (aref st +st-lntypes+) (blk-ntypes blkL)
                (aref st +st-intypes+) (blk-ntypes blkI)
                (aref st +st-dntypes+) (blk-ntypes blkD)
                (aref st +st-lbt-param+) (bt-param blkL)
                (aref st +st-lbl-param+) (bl-param blkL)
                (aref st +st-ibt-param+) (bt-param blkI)
                (aref st +st-ibl-param+) (bl-param blkI)
                (aref st +st-dbt-param+) (bt-param blkD)
                (aref st +st-dbl-param+) (bl-param blkD))
          (dotimes (k 26)
            (setf (aref st (+ +st-blen0+ k))
                  (logior (aref +blen-base+ k) (ash (aref +blen-bits+ k) 32))))
          (flet ((blocks-in ()
                   ;; block state Lisp -> ST, with the values derived from it
                   (let ((lt (blk-type blkL)) (it (blk-type blkI)) (dt (blk-type blkD)))
                     (setf (aref st +st-ltype+) lt (aref st +st-lprev+) (blk-prev blkL)
                           (aref st +st-lcount+) (blk-count blkL)
                           (aref st +st-itype+) it (aref st +st-iprev+) (blk-prev blkI)
                           (aref st +st-icount+) (blk-count blkI)
                           (aref st +st-dtype+) dt (aref st +st-dprev+) (blk-prev blkD)
                           (aref st +st-dcount+) (blk-count blkD)
                           (aref st +st-lutoff+) (* 512 (the (integer 0 3) (svref cmode lt)))
                           (aref st +st-litrow+) (* 64 lt)
                           (aref st +st-triv+) (aref ltriv lt)
                           (aref st +st-cmd-param+) (aref cparams it)
                           (aref st +st-drow+) (* 4 dt))))
                 (blocks-out ()
                   (setf (blk-type blkL) (aref st +st-ltype+)
                         (blk-prev blkL) (aref st +st-lprev+)
                         (blk-count blkL) (aref st +st-lcount+)
                         (blk-type blkI) (aref st +st-itype+)
                         (blk-prev blkI) (aref st +st-iprev+)
                         (blk-count blkI) (aref st +st-icount+)
                         (blk-type blkD) (aref st +st-dtype+)
                         (blk-prev blkD) (aref st +st-dprev+)
                         (blk-count blkD) (aref st +st-dcount+))))
            (blocks-in)
            ;; pinned: the literal loop indexes these through raw pointers
            (sb-sys:with-pinned-objects (lit-tables +ctx-lut+)
            (loop
              (%asm-sync-in st r rb pos)
              (%asm-general-meta-block st ctx)
              (setf pos (%asm-sync-out st r rb))
              (case (aref st +st-exit+)
                (0 (blocks-out) (return pos))
                (2 (setf pos (%asm-dict-word st data window)))
                (t (blocks-out)
                   (when (and (null lit-trees) (null single-lit-tree))
                     (setf lit-trees (make-array (length cmapl)))
                     (dotimes (i (length cmapl))
                       (setf (svref lit-trees i) (svref htreel (aref cmapl i)))))
                   (setf pos (%decode-general-meta-block
                              r data pos target origin window rb blkL blkI blkD
                              single-lblock single-iblock single-dblock cmode
                              (or lit-trees #()) lit-tables htreei htreed cmapd
                              single-lit-tree cmd-tree dist-tree npostfix ndirect
                              postfix-mask t))
                   (blocks-in)))
              (when (or (minusp pos) (>= pos target)) (return pos))))))))))

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
                                   npostfix ndirect postfix-mask &optional once)
  "The general command loop (block switches, context-modeled literals,
distance context maps) as its own function: only what the loop needs is
live, not the meta-block setup state.  Returns the end position or a
negative error code like %DECODE-SIMPLE-META-BLOCK.  ONCE: decode a single
command (the assembly loop's fallback)."
  (declare (type b:brd r)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum pos target origin window postfix-mask)
           (type (integer 0 3) npostfix) (type (integer 0 120) ndirect)
           (type (simple-array fixnum (*)) rb)
           (type blk blkL blkI blkD)
           (type boolean single-lblock single-iblock single-dblock)
           (type simple-vector cmode lit-trees lit-tables htreei htreed)
           (type (simple-array (unsigned-byte 8) (*)) cmapd)
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
                    ;; bytes before ORIGIN are the caller's, not stream
                    ;; history: the stream's first literals see p1 = p2 = 0
                    (let ((p1 (if (> pos origin) (aref data (1- pos)) 0))
                          (p2 (if (> pos (1+ origin)) (aref data (- pos 2)) 0))
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
                                            (aref cmapd
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
                                                 max-dist)))))
               (when once (return))))))
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
                      (make-array (* 64 nbl-l) :element-type '(unsigned-byte 8)
                                                :initial-element 0)))
           (ntreesd (read-nbltypes r))
           (cmapd (if (>= ntreesd 2) (read-context-map r (* 4 nbl-d) ntreesd)
                      (make-array (* 4 nbl-d) :element-type '(unsigned-byte 8)
                                              :initial-element 0)))
           (htreel (make-array ntreesl)) (htreei (make-array nbl-i))
           (htreed (make-array ntreesd))
           ;; the Lisp loop's per-(block type, context) trees; the assembly
           ;; loop only needs their tables (and builds the trees only if it
           ;; ever falls back)
           (lit-trees #-cl-brotli-x86-64 (make-array (* 64 nbl-l))
                      #+cl-brotli-x86-64 nil)
           (dist-alpha (+ 16 ndirect (ash 48 npostfix)))
           (single-lit-tree nil) (single-dist-tree nil)
           (cmd-tree nil) (dist-tree nil)
           ;; NBLTYPES is fixed for a meta-block; hoist the one-tree checks out
           ;; of the per-command/per-literal paths.
           (single-lblock (= 1 (blk-ntypes blkL)))
           (single-iblock (= 1 (blk-ntypes blkI)))
           (single-dblock (= 1 (blk-ntypes blkD))))
       (declare (type simple-vector cmode htreel htreei htreed)
                (type (simple-array (unsigned-byte 8) (*)) cmapl cmapd)
                (type (or null simple-vector) lit-trees)
                (type (simple-array fixnum (*)) rb)
                (type blk blkL blkI blkD)
                (type outbuf out)
                (type b:brd r)
                (type fixnum nbl-l nbl-i nbl-d ntreesl ntreesd mlen window
                      start target postfix-mask dist-alpha)
                (type (integer 0 3) npostfix) (type (integer 0 120) ndirect))
       (%grow out target r)
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
       #-cl-brotli-x86-64
       (unless single-lit-tree
         (dotimes (i (* 64 nbl-l))
           (setf (svref lit-trees i) (svref htreel (aref cmapl i)))))
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
       (let ((e (#-cl-brotli-x86-64 %decode-general-meta-block
                 #+cl-brotli-x86-64 %decode-general-meta-block-asm
                 r (outbuf-data out) (outbuf-pos out) target (outbuf-origin out)
                 window rb blkL blkI blkD single-lblock single-iblock
                 single-dblock cmode lit-trees
                 ;; tables of the (block type, context) literal trees; only
                 ;; filled (and used) when literals are context-modeled
                 (if single-lit-tree
                     #()
                     (let ((v (make-array (* 64 nbl-l))))
                       (dotimes (i (* 64 nbl-l) v)
                         (setf (svref v i) (huff-table (svref htreel (aref cmapl i)))))))
                 htreei htreed cmapd
                 single-lit-tree cmd-tree dist-tree npostfix ndirect
                 postfix-mask #+cl-brotli-x86-64 htreel #+cl-brotli-x86-64 cmapl)))
         (declare (type fixnum e))
         (case e
           (-1 (berr "insert length exceeds the meta-block"))
           (-2 (berr "copy length exceeds the meta-block"))
           (-3 (berr "invalid distance"))
           (-4 (berr "invalid prefix code")))
         (setf (outbuf-pos out) e)))
    (when (/= (outbuf-pos out) target)
      (berr "meta-block produced ~d, expected ~d" (- (outbuf-pos out) start) mlen))))
