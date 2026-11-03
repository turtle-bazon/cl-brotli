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
(defparameter +blen-bits+ #(2 2 2 2 3 3 3 3 4 4 4 4 5 5 5 5 6 6 7 8 9 10 11 12 13 24))
(defparameter +blen-base+ #(1 5 9 13 17 25 33 41 49 65 81 97 113 145 177 209 241 305 369 497 753 1265 2289 4337 8433 16625))
;; insert-and-copy command -> cell start ranges
(defparameter +cmd-ins+ #(0 0 0 0 8 8 0 16 8 16 16))
(defparameter +cmd-cpy+ #(0 8 0 8 0 8 16 0 16 8 16))
;; distance short codes 0..15: ring-buffer slot offset + value offset (RFC 7932 §4).
;; The ring is a rolling buffer indexed by IDX (slots written most-recent-last).
(defparameter +dsc-index+ #(3 2 1 0 3 3 3 3 3 3 2 2 2 2 2 2))
(defparameter +dsc-value+ #(0 0 0 0 -1 1 -2 2 -3 3 -1 1 -2 2 -3 3))
;; These are compile-time constants, but they are DEFPARAMETERs, so SBCL
;; otherwise treats each AREF as a hairy (possibly non-simple) vector access.
(declaim (type simple-vector
                 +ins-bits+ +ins-base+ +cpy-bits+ +cpy-base+
                 +blen-bits+ +blen-base+ +cmd-ins+ +cmd-cpy+
                 +dsc-index+ +dsc-value+))

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

(defstruct blk ntypes (type 0) (prev 1) (count 0) bhuff chuff)

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
  (pos 0 :type fixnum))

(defun %grow (out need)
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
(defparameter +cmd-ilen-base+ (make-array 704 :element-type 'fixnum :initial-element 0))
(defparameter +cmd-ilen-bits+ (make-array 704 :element-type 'fixnum :initial-element 0))
(defparameter +cmd-clen-base+ (make-array 704 :element-type 'fixnum :initial-element 0))
(defparameter +cmd-clen-bits+ (make-array 704 :element-type 'fixnum :initial-element 0))
(declaim (type (simple-array fixnum (704))
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
(defun %copy-tiny-match (data pos src length)
  "Copy a short non-overlapping match.  Returns the new position."
  (declare (optimize (speed 3) (safety 0))
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum pos src)
           (type fixnum length))
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
(defun %copy-match-bytes (data fp src distance len)
  (declare (optimize (speed 3) (safety 0))
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum fp src distance len))
  (cond
    ((= distance 1)
     (fill data (aref data src) :start fp :end (+ fp len)))
    ((and (>= distance len) (<= len 16))
     (%copy-tiny-match data fp src len))
    ((>= distance len)
     (replace data data :start1 fp :start2 src :end2 (+ src len)))
    ((<= len 16)
     (dotimes (i len)
       (setf (aref data (+ fp i))
             (aref data (+ src (mod i distance))))))
    (t
     ;; Copy the seed, then double the written pattern.  This is O(log len)
     ;; replace calls even for distance 1 (a long run of one byte).
     (replace data data :start1 fp :start2 src :end2 (+ src distance))
     (loop with copied = distance
           while (< copied len)
           for n = (min copied (- len copied))
           do (replace data data :start1 (+ fp copied) :start2 fp
                       :end2 (+ fp n))
              (incf copied n)))))

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
    (%copy-match-bytes (outbuf-data out) fp src distance len)))

(defun out-copy-preallocated (out distance len)
  "Like OUT-COPY, but the meta-block capacity was reserved up front.  The
caller has already validated DISTANCE."
  (declare (optimize (speed 3) (safety 0))
           (type outbuf out)
           (type fixnum distance len))
  (let ((fp (outbuf-pos out))
        (src (- (outbuf-pos out) distance)))
    (setf (outbuf-pos out) (+ fp len))
    (%copy-match-bytes (outbuf-data out) fp src distance len)))

(defun out-append-vec (out v)
  (let ((fp (outbuf-pos out)) (n (length v)))
    (%grow out (+ fp n))
    (replace (outbuf-data out) v :start1 fp)
    (setf (outbuf-pos out) (+ fp n))))

(defun out-append-vec-preallocated (out v)
  (let ((fp (outbuf-pos out)) (n (length v)))
    (replace (outbuf-data out) v :start1 fp)
    (setf (outbuf-pos out) (+ fp n))))

(declaim (inline out-copy-preallocated))

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
        #+sbcl (sap (b:brd-sap r)) #-sbcl (sap nil)
        (end (b:brd-end r)))
    (declare (type (or null (simple-array (unsigned-byte 16) (*))) table)
             (type fixnum mask tbits acc nbits p end)
             (type (or null simple-vector) subs)
             #+sbcl (type (or null sb-sys:system-area-pointer) sap)
             #-sbcl (type null sap)
             )
    (when (null table)
      ;; Single-symbol tree: every literal is the same byte.
      (let ((sym (huff-single tree)))
        (declare (type fixnum sym))
        (dotimes (k count) (setf (aref out pos) sym) (incf pos))
        (setf (b:brd-acc r) acc (b:brd-nbits r) nbits (b:brd-pos r) p)
        (return-from %decode-lit-run pos)))
    (macrolet ((refill (need)
                 `(unless (>= nbits ,need)
                    #+sbcl
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
                      ;; reader, which decodes the tail bit-by-bit.
                      (setf (b:brd-acc r) acc (b:brd-nbits r) nbits (b:brd-pos r) p)
                      (loop for j from k below count do
                        (setf (aref out pos) (read-huff r tree))
                        (incf pos))
                      (setf acc (b:brd-acc r) nbits (b:brd-nbits r) p (b:brd-pos r))
                      (return-from %decode-lit-run pos)))))
      (dotimes (k count)
        (refill tbits)
        (let ((entry (aref table (logand acc mask))))
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
               (let ((sub (aref subs (1- (ash entry -4)))))
                 (declare (type (simple-array (unsigned-byte 16) (*)) sub))
                 (setf acc (ash acc (- tbits)) nbits (- nbits tbits))
                 (refill 5)
                 (let ((entry2 (aref sub (logand acc #x1F))))
                   (declare (type fixnum entry2))
                   (let ((rem (logand entry2 15)))
                     (declare (type fixnum rem))
                     (unless (plusp rem)
                       (berr "invalid prefix code"))
                     (setf acc (ash acc (- rem))
                           nbits (- nbits rem)
                           (aref out pos) (ash entry2 -4))
                     (incf pos)))))
              (t (berr "invalid prefix code"))))))
      (setf (b:brd-acc r) acc (b:brd-nbits r) nbits (b:brd-pos r) p)
      pos)))

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
         (let* ((cmd (read-huff r (or cmd-tree
                                      (svref htreei (blk-type blkI)))))
                (dist0 (< cmd 128))
                (ilen (+ (aref +cmd-ilen-base+ cmd)
                         (b:rbits r (aref +cmd-ilen-bits+ cmd))))
                (clen (+ (aref +cmd-clen-base+ cmd)
                         (b:rbits r (aref +cmd-clen-bits+ cmd)))))
           (declare (type fixnum cmd ilen clen))
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
                 (let ((bt (blk-type blkL))
                       (cmodev (svref cmode (blk-type blkL))))
                   (if single-lblock
                       (dotimes (k ilen)
                         (let* ((p1 (if (> pos 0) (aref data (1- pos)) 0))
                                (p2 (if (> pos 1) (aref data (- pos 2)) 0))
                                (cid (%lit-context cmodev p1 p2))
                                (tree (svref lit-trees (+ (* 64 bt) cid))))
                           (declare (type fixnum p1 p2 cid)
                                    (type huff tree))
                           (setf (aref data pos) (read-huff r tree))
                           (incf pos)))
                       (dotimes (k ilen)
                         (blk-maybe-switch r blkL)
                         (setf bt (blk-type blkL)
                               cmodev (svref cmode bt))
                         (let* ((p1 (if (> pos 0) (aref data (1- pos)) 0))
                                (p2 (if (> pos 1) (aref data (- pos 2)) 0))
                                (cid (%lit-context cmodev p1 p2))
                                (tree (svref lit-trees (+ (* 64 bt) cid))))
                           (declare (type fixnum p1 p2 cid)
                                    (type huff tree))
                           (setf (aref data pos) (read-huff r tree))
                           (incf pos))))))
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
                     (setf dcode (read-huff r dtree))
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
                                     (dextra (b:rbits r ndistbits))
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
                                     (dextra (b:rbits r ndistbits))
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
                                              lcode ndirect 1)))))))
                     ;; push real backward references only — dictionary
                     ;; references do NOT update the ring.
                     (when (and (/= dcode 0)
                                (<= distance
                                    (min window (outbuf-pos out))))
                       (setf (aref rb (logand idx 3)) distance
                             (aref rb 4) (1+ idx))))))
             (let ((max-dist (min window (outbuf-pos out))))
               (declare (type fixnum max-dist))
               (when (<= distance 0)
                 (berr "invalid distance ~d" distance))
               (if (<= distance max-dist)
                   (out-copy-preallocated out distance clen)
                   (out-append-vec-preallocated
                    out (dict-word clen distance max-dist))))))))
    (when (/= (outbuf-pos out) target)
      (berr "meta-block produced ~d, expected ~d" (- (outbuf-pos out) start) mlen))))
