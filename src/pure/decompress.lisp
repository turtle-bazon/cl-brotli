;;;; src/decompress.lisp — brotli compressed meta-block decoder (RFC 7932 §9-10).
(in-package #:cl-brotli.pure)

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

(defun blk-maybe-switch (r b)
  (when (zerop (blk-count b))
    (let* ((sym (read-huff r (blk-bhuff b)))
           (new (cond ((= sym 0) (blk-prev b))
                      ((= sym 1) (mod (1+ (blk-type b)) (blk-ntypes b)))
                      (t (- sym 2)))))
      (setf (blk-prev b) (blk-type b) (blk-type b) new
            (blk-count b) (read-block-count r (blk-chuff b)))))
  (decf (blk-count b)))

(defun %ensure (out n)
  (let ((need (+ (fill-pointer out) n)))
    (when (> need (array-dimension out 0)) (adjust-array out (max need (* 2 (array-dimension out 0)))))))
(defun out-push (out byte) (%ensure out 1) (vector-push byte out))
(defun out-copy (out distance len)
  (let ((src (- (fill-pointer out) distance)) (fp (fill-pointer out)))
    (%ensure out len) (setf (fill-pointer out) (+ fp len))
    (dotimes (i len) (setf (aref out (+ fp i)) (aref out (+ src i))))))
(defun out-append-vec (out v)
  (let ((fp (fill-pointer out)) (n (length v)))
    (%ensure out n) (setf (fill-pointer out) (+ fp n)) (replace out v :start1 fp)))

(defun decode-compressed-meta-block (r out mlen window rb)
  "Decode one compressed meta-block of MLEN bytes into OUT.  RB is the 4-entry
distance ring buffer (persists across the stream)."
  (let* ((start (fill-pointer out)) (target (+ start mlen))
         (nbl-l (read-nbltypes r)) (blkL (read-blk-header r nbl-l))
         (nbl-i (read-nbltypes r)) (blkI (read-blk-header r nbl-i))
         (nbl-d (read-nbltypes r)) (blkD (read-blk-header r nbl-d))
         (npostfix (b:rbits r 2))
         (ndirect (ash (b:rbits r 4) npostfix))
         (cmode (make-array nbl-l))
         (postfix-mask (1- (ash 1 npostfix))))
    (dotimes (i nbl-l) (setf (aref cmode i) (b:rbits r 2)))
    (let* ((ntreesl (read-nbltypes r))
           (cmapl (if (>= ntreesl 2) (read-context-map r (* 64 nbl-l) ntreesl)
                      (make-array (* 64 nbl-l) :initial-element 0)))
           (ntreesd (read-nbltypes r))
           (cmapd (if (>= ntreesd 2) (read-context-map r (* 4 nbl-d) ntreesd)
                      (make-array (* 4 nbl-d) :initial-element 0)))
           (htreel (make-array ntreesl)) (htreei (make-array nbl-i)) (htreed (make-array ntreesd))
           (dist-alpha (+ 16 ndirect (ash 48 npostfix))))
      (dotimes (i ntreesl) (setf (aref htreel i) (read-prefix-code r 256)))
      (dotimes (i nbl-i) (setf (aref htreei i) (read-prefix-code r 704)))
      (dotimes (i ntreesd) (setf (aref htreed i) (read-prefix-code r dist-alpha)))
      ;; command loop
      (loop while (< (fill-pointer out) target) do
        (blk-maybe-switch r blkI)
        (let* ((cmd (read-huff r (aref htreei (blk-type blkI))))
               (cell (ash cmd -6))
               (icode (+ (aref +cmd-ins+ cell) (logand (ash cmd -3) 7)))
               (ccode (+ (aref +cmd-cpy+ cell) (logand cmd 7)))
               (dist0 (< cmd 128))
               (ilen (+ (aref +ins-base+ icode) (b:rbits r (aref +ins-bits+ icode))))
               (clen (+ (aref +cpy-base+ ccode) (b:rbits r (aref +cpy-bits+ ccode)))))
          ;; insert literals
          (dotimes (k ilen)
            (blk-maybe-switch r blkL)
            (let* ((fp (fill-pointer out))
                   (p1 (if (> fp 0) (aref out (1- fp)) 0))
                   (p2 (if (> fp 1) (aref out (- fp 2)) 0))
                   (cid (lit-context (aref cmode (blk-type blkL)) p1 p2))
                   (tree (aref htreel (aref cmapl (+ (* 64 (blk-type blkL)) cid)))))
              (out-push out (read-huff r tree))))
          (when (>= (fill-pointer out) target) (return))
          ;; distance — DCODE 0 (explicit or implicit dist0) reuses the last
          ;; distance without pushing; all other codes compute + push.
          (let ((distance 0) (idx (aref rb 4)) (dcode 0))
            (if dist0
                (setf distance (aref rb (logand (+ idx 3) 3)))   ; last distance, no push
                (progn
                  (blk-maybe-switch r blkD)
                  (let* ((cidd (cond ((= clen 2) 0) ((= clen 3) 1) ((= clen 4) 2) (t 3)))
                         (dtree (aref htreed (aref cmapd (+ (* 4 (blk-type blkD)) cidd)))))
                    (setf dcode (read-huff r dtree))
                    (cond
                      ((< dcode 16)
                       (setf distance (+ (aref rb (logand (+ idx (aref +dsc-index+ dcode)) 3))
                                         (aref +dsc-value+ dcode))))
                      ((< dcode (+ 16 ndirect)) (setf distance (- dcode 15)))
                      (t (let* ((d (- dcode ndirect 16))
                                (ndistbits (+ 1 (ash d (- (1+ npostfix)))))
                                (dextra (b:rbits r ndistbits))
                                (hcode (ash d (- npostfix)))
                                (lcode (logand d postfix-mask))
                                (offset (- (ash (+ 2 (logand hcode 1)) ndistbits) 4)))
                           (setf distance (+ (ash (+ offset dextra) npostfix) lcode ndirect 1)))))
                    ;; push real backward references only — dictionary references
                    ;; (distance beyond the produced output) do NOT update the ring.
                    (when (and (/= dcode 0) (<= distance (min window (fill-pointer out))))
                      (setf (aref rb (logand idx 3)) distance (aref rb 4) (1+ idx))))))
            (let ((max-dist (min window (fill-pointer out))))
              (if (<= distance max-dist)
                  (out-copy out distance clen)
                  (out-append-vec out (dict-word clen distance max-dist))))))))
    (when (/= (fill-pointer out) target)
      (berr "meta-block produced ~d, expected ~d" (- (fill-pointer out) start) mlen))))
