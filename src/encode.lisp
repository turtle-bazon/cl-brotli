;;;; src/encode.lisp — Brotli compressed encoder (entropy-coded meta-blocks).
;;;;
;;;; A real compressor: greedy LZ77 (hash-chain match finder) producing
;;;; insert-and-copy commands, then canonical (length-limited) Huffman coding of
;;;; the literal / command / distance alphabets.  One literal/command/distance
;;;; tree each (NBLTYPES = 1, no context maps, NPOSTFIX = NDIRECT = 0); distances
;;;; use the ring buffer's "last distance" (code 0) when they repeat.  The output
;;;; is a standard brotli stream, decodable by the reference (node/python).
;;;; COMPRESS falls back to stored meta-blocks when entropy coding wouldn't help.
(in-package #:cl-brotli.lisp)

(declaim (optimize (speed 3) (safety 0)))

;;; ---- canonical code construction --------------------------------------

(defun canonical-codes (lengths n)
  "Codes per symbol for code LENGTHS, matching BUILD-HUFF/READ-HUFF (codes are
emitted MSB-first; DEFLATE canonical assignment)."
  (let ((count (make-array (1+ +max-bits+) :element-type 'fixnum
                           :initial-element 0))
        (next (make-array (1+ +max-bits+) :element-type 'fixnum
                          :initial-element 0))
        (codes (make-array n :element-type 'fixnum :initial-element 0)))
    (dotimes (s n) (let ((l (aref lengths s))) (when (plusp l) (incf (aref count l)))))
    (let ((code 0))
      (loop for bits from 1 to +max-bits+ do
        (setf code (ash (+ code (aref count (1- bits))) 1)
              (aref next bits) code)))
    (dotimes (s n)
      (let ((l (aref lengths s)))
        (when (plusp l) (setf (aref codes s) (aref next l)) (incf (aref next l)))))
    codes))

(defun limit-lengths (lengths freqs n maxlen)
  "Clamp code LENGTHS to <= MAXLEN, restoring the Kraft equality, then reassign
lengths to symbols by frequency (most frequent -> shortest)."
  (let ((count (make-array 64 :initial-element 0)) (maxl 0))
    (dotimes (s n) (let ((ll (aref lengths s))) (when (plusp ll) (incf (aref count ll)) (setf maxl (max maxl ll)))))
    (when (> maxl maxlen)
      (loop for ll from (1+ maxlen) to maxl do
        (incf (aref count maxlen) (aref count ll)) (setf (aref count ll) 0))
      (let ((total 0))
        (loop for ll from 1 to maxlen do (incf total (ash (aref count ll) (- maxlen ll))))
        (loop while (> total (ash 1 maxlen)) do
          (decf (aref count maxlen))
          (let ((bits (1- maxlen)))
            (loop while (zerop (aref count bits)) do (decf bits))
            (decf (aref count bits))
            (incf (aref count (1+ bits)) 2))
          (decf total)))
      (let ((syms (sort (loop for s below n when (plusp (aref lengths s)) collect s)
                        (lambda (x y) (or (> (aref freqs x) (aref freqs y))
                                          (and (= (aref freqs x) (aref freqs y)) (< x y))))))
            (idx 0))
        (setf syms (coerce syms 'vector))
        (loop for ll from 1 to maxlen do
          (dotimes (i (aref count ll))
            (setf (aref lengths (aref syms idx)) ll) (incf idx)))))))

;;; ---- array-based length-limited Huffman (C entropy_encode.c port) -----
;;;
;;; build-code-lengths above is cons-heavy (per-merge REMOVE on lists, a
;;; generic STABLE-SORT in limit-lengths).  This reimplementation keeps
;;; C BrotliCreateHuffmanTree/BrotliSetDepth's exact shape with flat typed
;;; scratch arrays (fresh per call, so concurrent COMPRESSes do not race
;;; over a shared scratch — allocation is noise next to the old consing):
;;;
;;;   TC  weights  (leaves then parents, sentinel-separated)
;;;   IL  left child / -1 for leaves
;;;   RV  right child / symbol for leaves
;;;
;;; Leaves are sorted rising-weight (equal weight: larger symbol first),
;;; parents fill from NNZ+1, the root ends at 2*NNZ-1, and the whole
;;; build is retried with a doubled minimum count while any leaf exceeds
;;; MAXBITS.  Everything is one pass over typed local arrays: no lists,
;;; no generic arithmetic, no per-symbol conses.

;; (scratch arrays are allocated per call inside BUILD-CODE-LENGTHS-A: the
;;  original r81 shared globals would make COMPRESS non-reentrant.)

(declaim (inline %huf-shell-sort))
(defun %huf-shell-sort (tc rv nnz)
  "Sort leaves [0..NNZ) by rising TC weight, ties: larger RV symbol first
(the SortHuffmanTree comparator), over the C shell-gap sequence."
  (declare (type (simple-array (unsigned-byte 32) (*)) tc)
           (type (simple-array fixnum (*)) rv)
           (type fixnum nnz)
           (optimize (speed 3) (safety 0)))
  (loop with n of-type fixnum = nnz
        for gap of-type fixnum in '(132 57 23 10 4 1)
        do (loop for i of-type fixnum from gap below n
                 do (let ((wt (aref tc i)) (sym (aref rv i)) (j (- i gap)))
                      (declare (type fixnum wt j))
                      (loop while (and (>= j 0)
                                       (or (> (aref tc j) wt)
                                           (and (= (aref tc j) wt)
                                                (< (aref rv j) sym))))
                             do (setf (aref tc (+ j gap)) (aref tc j)
                                      (aref rv (+ j gap)) (aref rv j))
                                (decf j gap))
                      (setf (aref tc (+ j gap)) wt
                            (aref rv (+ j gap)) sym)))))

(declaim (inline %huf-set-depth))
(defun %huf-set-depth (p0 tc il rv depth max-depth)
  "Write leaf depths into DEPTH by walking the parent pointers with the
explicit stack of C's BrotliSetDepth.  NIL when any leaf would exceed
MAX-DEPTH; the caller raises the minimum count and rebuilds."
  (declare (type fixnum p0 max-depth)
           (type (simple-array (unsigned-byte 32) (*)) tc)
           (type (simple-array fixnum (*)) il rv depth)
           (optimize (speed 3) (safety 0)))
  (let ((stack (make-array 16 :element-type 'fixnum :initial-element -1))
        (level 0) (p p0) (ok t))
    (declare (type fixnum level p) (type boolean ok))
    (loop
      (if (>= (aref il p) 0)
          (progn
            (incf level)
            (when (> level max-depth)
              (setf ok nil)
              (return))
            (setf (aref stack level) (aref rv p)
                  p (aref il p)))
          (progn
            (setf (aref depth (aref rv p)) level)
            (loop while (and (>= level 0) (= (aref stack level) -1))
                  do (decf level))
            (when (< level 0)
              (return))
            (setf p (aref stack level)
                  (aref stack level) -1))))
    ok))

(defun build-code-lengths-a (freqs n maxbits)
  "Optimal canonical code lengths (<= MAXBITS) for FREQS[0..N); Kraft-exact.
Port of C BrotliCreateHuffmanTree; >= 2 nonzero frequencies assumed."
  (declare (type (simple-array fixnum (*)) freqs)
           (type fixnum n maxbits)
           (optimize (speed 3) (safety 0)))
  (let ((tc (make-array (* 2 (+ n 2)) :element-type '(unsigned-byte 32)))
        (il (make-array (* 2 (+ n 2)) :element-type 'fixnum))
        (rv (make-array (* 2 (+ n 2)) :element-type 'fixnum))
        (depth (make-array (max n 2) :element-type 'fixnum)))
    (declare (type (simple-array (unsigned-byte 32) (*)) tc)
             (type (simple-array fixnum (*)) il rv depth))
    ;; C retries with a doubled minimum while any leaf exceeds MAXBITS
    ;; (the count-limit clamp flattens the histogram until the tree fits).
    (do ((count-limit 1 (* 2 count-limit)))
        (nil)
      ;; leaves, descending symbol order so equal-weight ties sort like C's
      ;; comparator (larger symbol first) after the shell sort
      (let ((nnz 0))
        (declare (type fixnum nnz))
        (loop for i of-type fixnum from (1- n) downto 0
              do (let ((f (aref freqs i)))
                   (declare (type fixnum f))
                   (when (plusp f)
                     (setf (aref tc nnz) (the (unsigned-byte 32)
                                            (max f count-limit))
                           (aref il nnz) -1
                           (aref rv nnz) i)
                     (incf nnz))))
        (cond
          ((zerop nnz)
           (return-from build-code-lengths-a
             (make-array n :element-type 'fixnum :initial-element 0)))
          ((= 1 nnz)
           (let ((r (make-array n :element-type 'fixnum
                                  :initial-element 0)))
             (declare (type (simple-array fixnum (*)) r))
             (setf (aref r (aref rv 0)) 1)
             (return-from build-code-lengths-a r)))
          (t
           (%huf-shell-sort tc rv nnz)
           ;; sentinels at NNZ and NNZ+1; parents rise from NNZ+1; the
           ;; root sits at 2*NNZ-1 when the merge finishes
           (setf (aref tc nnz) #xFFFFFFFF (aref il nnz) -1 (aref rv nnz) -1)
           (setf (aref tc (+ nnz 1)) #xFFFFFFFF
                 (aref il (+ nnz 1)) -1
                 (aref rv (+ nnz 1)) -1)
           (let ((i 0) (j (+ nnz 1)))
             (declare (type fixnum i j))
             (loop for k of-type fixnum from (1- nnz) downto 0
                   do (let ((left 0) (right 0))
                        (declare (type fixnum left right))
                        ;; pick 1: C advances the pointer as part of the pick
                        (cond
                          ((<= (aref tc i) (aref tc j))
                           (setf left i) (incf i))
                          (t (setf left j) (incf j)))
                        ;; pick 2: sees the advanced pointers
                        (cond
                          ((<= (aref tc i) (aref tc j))
                           (setf right i) (incf i))
                          (t (setf right j) (incf j)))
                        (let ((jend (- (* 2 nnz) k)))
                          (declare (type fixnum jend))
                          (setf (aref tc jend)
                                (+ (aref tc left) (aref tc right))
                                (aref il jend) left
                                (aref rv jend) right)
                          ;; re-add the sentinel one slot below jend
                          (setf (aref tc (+ jend 1)) #xFFFFFFFF
                                (aref il (+ jend 1)) -1
                                (aref rv (+ jend 1)) -1)))))))
        ;; depth walk; on failure the DO retries with the doubled clamp
        (when (%huf-set-depth (- (* 2 nnz) 1) tc il rv depth maxbits)
          (let ((r (make-array n :element-type 'fixnum
                                  :initial-element 0)))
            (declare (type (simple-array fixnum (*)) r))
            (dotimes (s (the fixnum n))
              (setf (aref r s)
                    (if (plusp (aref freqs s))
                        (aref depth s) 0)))
            (return-from build-code-lengths-a r)))))))

(defun build-code-lengths (freqs n maxlen)
  "Optimal canonical code lengths (<= MAXLEN) for FREQS.  Assumes >= 2 nonzero."
  (let* ((sv (coerce (loop for s below n when (plusp (aref freqs s)) collect s) 'vector))
         (k (length sv))
         (cap (max 2 (1- (* 2 k))))
         (fr (make-array cap :element-type 'fixnum :initial-element 0))
         (lf (make-array cap :element-type 'fixnum :initial-element -1))
         (rg (make-array cap :element-type 'fixnum :initial-element -1))
         (lengths (make-array n :element-type 'fixnum :initial-element 0))
         (cnt k))
    (dotimes (i k) (setf (aref fr i) (aref freqs (aref sv i))))
    (let ((active (loop for i below k collect i)))
      (loop while (> (length active) 1) do
        (let (a b)
          (dolist (x active)
            (cond ((or (null a) (< (aref fr x) (aref fr a))) (setf b a a x))
                  ((or (null b) (< (aref fr x) (aref fr b))) (setf b x))))
          (let ((p cnt))
            (setf (aref fr p) (+ (aref fr a) (aref fr b)) (aref lf p) a (aref rg p) b)
            (incf cnt)
            (setf active (cons p (remove a (remove b active)))))))
      (labels ((dfs (node d)
                 (if (< node k)
                     (setf (aref lengths (aref sv node)) (max 1 d))
                     (progn (dfs (aref lf node) (1+ d)) (dfs (aref rg node) (1+ d))))))
        (dfs (car active) 0)))
    (limit-lengths lengths freqs n maxlen)
    lengths))

;;; ---- encoder tree (single-symbol -> simple code, else complex) --------

(defstruct etree
  (lengths nil :type (or null (simple-array fixnum (*))))
  (codes nil :type (or null (simple-array fixnum (*))))
  (rcodes nil :type (or null (simple-array fixnum (*))))
  single
  simple)

(defparameter +empty-fixnums+ (make-array 0 :element-type 'fixnum))
(declaim (type (simple-array fixnum (*)) +empty-fixnums+))

(defun reverse-code (code len)
  "Reverse the low LEN bits of CODE.  The canonical codes are MSB-first but
the bit writer is LSB-first; precomputing the reversal lets ETREE-EMIT issue
one WBITS call per symbol instead of one per bit."
  (let ((r 0))
    (dotimes (i len r)
      (setf r (logior (ash r 1) (logand code 1)))
      (setf code (ash code -1)))))

(defun reversed-codes (codes lengths size)
  (let ((r (make-array size :element-type 'fixnum :initial-element 0)))
    (dotimes (s size r)
      (let ((len (aref lengths s)))
        (when (plusp len)
          (setf (aref r s) (reverse-code (aref codes s) len)))))))

(defun build-etree (freqs size maxbits)
  (let ((nz (loop for s below size when (plusp (aref freqs s)) collect s)))
    (cond
      ((<= (length nz) 1)
       (make-etree :single (if nz (first nz) 0)))
      ((<= (length nz) 4)
       (let* ((lengths (make-array size :element-type 'fixnum
                                    :initial-element 0))
              (n (length nz)))
         (loop for s in nz for i from 0 do
           (setf (aref lengths s)
                 (case n (2 1) (3 (if (zerop i) 1 2)) (t 2))))
         (let ((codes (canonical-codes lengths size)))
           (make-etree :lengths lengths :codes codes
                       :rcodes (reversed-codes codes lengths size)
                       :simple nz))))
      (t
       (let* ((lengths (build-code-lengths-a freqs size maxbits))
              (codes (canonical-codes lengths size)))
         (make-etree :lengths lengths :codes codes
                     :rcodes (reversed-codes codes lengths size)))))))

(defun emit-bits-msb (w code len)
  (loop for i from (1- len) downto 0 do (b:wbits w (logand (ash code (- i)) 1) 1)))

(declaim (inline etree-emit))
(defun etree-emit (w et sym)
  (declare (type b:bwr w) (type etree et) (type fixnum sym))
  (unless (etree-single et)
    (b:wbits w (the fixnum (aref (etree-rcodes et) sym))
             (the fixnum (aref (etree-lengths et) sym)))))

;;; ---- prefix-code description writer (inverse of READ-PREFIX-CODE) ------

(defun write-clcl-len (w v)
  "Emit one code-length-code length V (0-5) with the fixed code (inverse of
READ-CLCL): bits written in read order."
  (ecase v
    (0 (b:wbits w 0 1) (b:wbits w 0 1))
    (3 (b:wbits w 0 1) (b:wbits w 1 1))
    (4 (b:wbits w 1 1) (b:wbits w 0 1))
    (2 (b:wbits w 1 1) (b:wbits w 1 1) (b:wbits w 0 1))
    (1 (b:wbits w 1 1) (b:wbits w 1 1) (b:wbits w 1 1) (b:wbits w 0 1))
    (5 (b:wbits w 1 1) (b:wbits w 1 1) (b:wbits w 1 1) (b:wbits w 1 1))))

(defun clcl-lengths (clfreq)
  "Code-length-code lengths (0-5) forming a COMPLETE code with >= 2 symbols."
  (let ((nz (loop for s below 18 when (plusp (aref clfreq s)) collect s))
        (l (make-array 18 :initial-element 0)))
    (cond
      ((null nz) (setf (aref l 0) 1 (aref l 1) 1))
      ((= 1 (length nz))
       (let ((s (first nz))) (setf (aref l s) 1 (aref l (if (= s 0) 1 0)) 1)))
      (t (setf l (build-code-lengths-a clfreq 18 5))))
    l))

(defun cl-lengths-rle (lengths m)
  "Encode LENGTHS[0..M] as (symbol extra-value extra-bits) triples.
Long runs are split with a literal reset between repeat codes so consecutive
16/17 codes cannot accumulate in the decoder."
  (let ((out nil) (s 0))
    (loop while (<= s m) do
      (let ((v (aref lengths s)))
        (if (zerop v)
            (let ((run 0) (j s))
              (loop while (and (<= j m) (zerop (aref lengths j)))
                    do (incf run) (incf j))
              (setf s j)
              (loop while (>= run 3) do
                (let ((n (min run 10)))
                  (push (list 17 (- n 3) 3) out)
                  (decf run n))
                (when (plusp run)
                  (push (list 0 0 0) out)
                  (decf run)))
              (loop repeat run do (push (list 0 0 0) out)))
            (let ((run 0) (j s))
              (loop while (and (<= j m) (= (aref lengths j) v))
                    do (incf run) (incf j))
              (setf s j)
              (push (list v 0 0) out)
              (decf run)
              (loop while (>= run 3) do
                (let ((n (min run 6)))
                  (push (list 16 (- n 3) 2) out)
                  (decf run n))
                (when (plusp run)
                  (push (list v 0 0) out)
                  (decf run)))
              (loop repeat run do (push (list v 0 0) out))))))
    (nreverse out)))

(defun write-complex-code (w lengths size)
  "Write a complex prefix-code description for code LENGTHS (>= 2 symbols)."
  (let* ((m (loop for s from (1- size) downto 0 when (plusp (aref lengths s)) return s))
         (rle (cl-lengths-rle lengths m))
         (clfreq (make-array 18 :initial-element 0)))
    (dolist (r rle) (incf (aref clfreq (first r))))
    (let* ((cll (clcl-lengths clfreq))
           (clcodes (canonical-codes cll 18))
           (first-nz (loop for i from 0 below 18
                           when (plusp (aref cll (aref +clcl-order+ i)))
                             return i))
           ;; The 2-bit field is both kind and HSKIP.  HSKIP=1 means
           ;; "simple code", so complex blocks skip 0, 2, or 3 entries.
           (hskip (cond ((<= first-nz 1) 0)
                        ((= first-nz 2) 2)
                        (t 3)))
           (lastL (loop for i from 17 downto 0
                        when (plusp (aref cll (aref +clcl-order+ i))) return i)))
      (b:wbits w hskip 2)
      (loop for i from hskip to lastL
            do (write-clcl-len w (aref cll (aref +clcl-order+ i))))
      (dolist (r rle)
        (emit-bits-msb w (aref clcodes (first r)) (aref cll (first r)))
        (when (plusp (third r))
          (b:wbits w (second r) (third r)))))))

(defun write-simple-code (w symbols size)
  "Write a simple prefix code for 2-4 SYMBOLS."
  (b:wbits w 1 2)
  (b:wbits w (1- (length symbols)) 2)
  (let ((ab (alphabet-bits size)))
    (dolist (s symbols) (b:wbits w s ab)))
  (when (= (length symbols) 4)
    (b:wbits w 0 1)))                    ; all four lengths = 2

(defun write-etree (w et size)
  (cond
    ((etree-single et)
     (b:wbits w 1 2)
     (b:wbits w 0 2)
     (b:wbits w (etree-single et) (alphabet-bits size)))
    ((etree-simple et)
     (write-simple-code w (etree-simple et) size))
    (t
     (write-complex-code w (etree-lengths et) size))))

;;; ---- command / distance code computation ------------------------------

(defparameter +celltab+ #(#(2 3 6) #(4 5 8) #(7 9 10)))   ; [ins-range][copy-range] -> cmd cell

(defun make-length-code-table (base bits maxlen)
  "Precompute (code, extra-value, extra-bits) for lengths 0..MAXLEN.
The encoder emits a command for every match; the linear search in
LENGTH-CODE was ~20% of low-quality compression time."
  (let ((code (make-array (1+ maxlen) :element-type 'fixnum :initial-element 0))
        (xval (make-array (1+ maxlen) :element-type 'fixnum :initial-element 0))
        (xbits (make-array (1+ maxlen) :element-type 'fixnum :initial-element 0)))
    (declare (type (simple-array fixnum (*)) code xval xbits))
    (loop for len from 0 to maxlen do
      (loop for c from (1- (length base)) downto 0
            when (>= len (aref base c))
              do (setf (aref code len) c
                       (aref xval len) (- len (aref base c))
                       (aref xbits len) (aref bits c))
                 (return)))
    (list code xval xbits)))

(defparameter +ins-lc+ (make-length-code-table +ins-base+ +ins-bits+ 4096))
(defparameter +cpy-lc+ (make-length-code-table +cpy-base+ +cpy-bits+ 4096))

(declaim (inline length-code))
(defun length-code (len tables base bits)
  "Largest code C with BASE[C] <= LEN; returns (values C extra-val extra-bits).
Common lengths use the precomputed TABLES; longer ones fall back to the
canonical search."
  (let ((code (first tables)) (xval (second tables)) (xbits (third tables)))
    (declare (type (simple-array fixnum (*)) code xval xbits))
    (if (< len (length code))
        (values (aref code len) (aref xval len) (aref xbits len))
        (loop for c from (1- (length base)) downto 0
              when (>= len (aref base c))
                do (return (values c (- len (aref base c)) (aref bits c)))))))

(defparameter +cmd-symbol-table+
  (let ((v (make-array (* 24 24) :element-type 'fixnum :initial-element 0)))
    (declare (type (simple-array fixnum (*)) v))
    (dotimes (i 24 v)
      (dotimes (c 24)
        (let* ((ir (cond ((< i 8) 0) ((< i 16) 1) (t 2)))
               (cr (cond ((< c 8) 0) ((< c 16) 1) (t 2)))
               (cell (aref (aref +celltab+ ir) cr)))
          (setf (aref v (+ (* i 24) c))
                (+ (* cell 64) (ash (- i (* ir 8)) 3) (- c (* cr 8)))))))))
(declaim (type (simple-array fixnum (*)) +cmd-symbol-table+))

(declaim (inline cmd-symbol))
(defun cmd-symbol (icode ccode)
  (aref +cmd-symbol-table+ (+ (* icode 24) ccode)))

(defun cmd-symbol-dist0 (icode ccode)
  "Command symbol for the implicit-distance form.  Only valid for insert
codes 0..7 and copy codes 0..15 (command symbols 0..127)."
  (+ (* (ash ccode -3) 64) (* icode 8) (logand ccode 7)))

(declaim (inline encode-distance))
(defun encode-distance (d)
  "Distance D (>=1) -> (values dcode dextra-val dextra-bits) for NPOSTFIX=NDIRECT=0.
The loop-free form partitions D by NBITS = INTEGER-LENGTH(D+4)-2."
  (declare (type fixnum d))
  (let* ((nbits (- (integer-length (+ d 3)) 2))
         (b (if (>= d (- (* 3 (ash 1 nbits)) 3)) 1 0))
         (offset (- (ash (+ 2 b) nbits) 4)))
    (values (+ 16 (* 2 (1- nbits)) b) (- d offset 1) nbits)))

(declaim (inline special-distance-code))
(defun special-distance-code (rb d)
  "If D is one of the short distance-ring codes, return (values CODE 0 0).
RB is the 4-slot ring plus a write index in slot 4."
  (flet ((try (code offset delta)
           (let ((candidate (+ (aref rb (logand (+ (aref rb 4) offset) 3))
                               delta)))
             (when (and (> candidate 0) (= candidate d))
               (return-from special-distance-code (values code 0 0))))))
    (try 1 2 0)                       ; second-to-last
    (try 2 1 0)                       ; third-to-last
    (try 3 0 0)                       ; fourth-to-last
    (try 4 3 -1) (try 5 3 1)          ; last -/+ 1
    (try 6 3 -2) (try 7 3 2)          ; last -/+ 2
    (try 8 3 -3) (try 9 3 3)          ; last -/+ 3
    (try 10 2 -1) (try 11 2 1)        ; second-to-last -/+ 1
    (try 12 2 -2) (try 13 2 2)        ; second-to-last -/+ 2
    (try 14 2 -3) (try 15 2 3)        ; second-to-last -/+ 3
    (values nil 0 0)))

;;; ---- static dictionary index (base words, no transforms) ---------------

(defvar *dict-index* nil)

(declaim (inline dict-key4))
(defun dict-key4 (vec pos)
  (declare (type (simple-array (unsigned-byte 8) (*)) vec)
           (type fixnum pos)
           (optimize (speed 3) (safety 0)))
  (logior (aref vec pos) (ash (aref vec (1+ pos)) 8)
          (ash (aref vec (+ pos 2)) 16) (ash (aref vec (+ pos 3)) 24)))

(defun dict-index ()
  "Hash first four bytes -> list of (length . word-index) base dictionary words."
  (or *dict-index*
      (let ((h (make-hash-table :test #'eql))
            (dict (load-dict)))
        (loop for len from 4 to 24 do
          (let ((nw (nwords len))
                (base (aref +doffset+ len)))
            (dotimes (idx nw)
              (let* ((off (+ base (* idx len)))
                     (key (dict-key4 dict off)))
                (push (cons len idx) (gethash key h))))))
        (setf *dict-index* h))))

(defparameter +dict-transforms+
  (loop for tid from 0 below (length +transforms+)
        for tr = (aref +transforms+ tid)
        when (and (zerop (length (first tr)))
                  (member (second tr) '(:identity :upper-first :upper-all))
                  (zerop (length (third tr))))
          collect tid)
  "Dictionary transforms that preserve word length (identity and uppercase).")

(defparameter +dict-transform-kinds+
  (loop for tid in +dict-transforms+
        for tr = (aref +transforms+ tid)
        collect (cons tid (case (second tr)
                            (:identity 0)
                            (:upper-first 1)
                            (t 2))))
  "Transform id plus a small kind tag, so the encoder can compare bytes
without materialising the transformed word.")

(declaim (inline %dict-word-match-p))
(defun %dict-word-match-p (data p dict off len kind)
  "Compare DATA[P..P+LEN) with the dictionary word DICT[OFF..OFF+LEN) after
KIND (0 identity, 1 upper-first, 2 upper-all).  No temporary vectors."
  (declare (type (simple-array (unsigned-byte 8) (*)) data dict)
           (type fixnum p off len kind)
           (optimize (speed 3) (safety 0)))
  (case kind
    (0
     (loop for i below len
           always (= (aref data (+ p i)) (aref dict (+ off i)))))
    (1
     ;; %FERMENT-FIRST changes only the first UTF-8 character.
     (let ((c (aref dict off)))
       (cond
         ((< c 192)
          (and (= (aref data p) (if (<= 97 c 122) (logxor c 32) c))
               (loop for i from 1 below len
                     always (= (aref data (+ p i)) (aref dict (+ off i))))))
         ((< c 224)
          (and (= (aref data p) c)
               (= (aref data (1+ p)) (logxor (aref dict (1+ off)) 32))
               (loop for i from 2 below len
                     always (= (aref data (+ p i)) (aref dict (+ off i))))))
         (t
          (and (= (aref data p) c)
               (= (aref data (1+ p)) (aref dict (1+ off)))
               (= (aref data (+ p 2)) (logxor (aref dict (+ off 2)) 5))
               (loop for i from 3 below len
                     always (= (aref data (+ p i)) (aref dict (+ off i)))))))))
    (t
     ;; %FERMENT-ALL walks the UTF-8 characters, uppercasing each one.
     (loop with i = 0
           while (< i len)
           always (let ((c (aref dict (+ off i))))
                    (cond
                      ((< c 192)
                       (prog1 (= (aref data (+ p i))
                                 (if (<= 97 c 122) (logxor c 32) c))
                         (incf i)))
                      ((< c 224)
                       (prog1 (and (= (aref data (+ p i)) c)
                                   (or (>= (1+ i) len)
                                       (= (aref data (+ p (1+ i)))
                                          (logxor (aref dict (+ off (1+ i))) 32))))
                         (incf i 2)))
                      (t
                       (prog1 (and (= (aref data (+ p i)) c)
                                   (or (>= (1+ i) len)
                                       (= (aref data (+ p (1+ i)))
                                          (aref dict (+ off (1+ i)))))
                                   (or (>= (+ i 2) len)
                                       (= (aref data (+ p i 2))
                                          (logxor (aref dict (+ off i 2)) 5))))
                         (incf i 3)))))))))

(defun dict-match-at (data p n)
  "Longest dictionary word starting at DATA[P], as
\(values length index transform-id).  Only length-preserving transforms are
considered so command copy lengths remain the base-word lengths."
  (let ((cands (gethash (dict-key4 data p) (dict-index)))
        (best-len 0) (best-idx nil) (best-tid 0)
        (dict (load-dict)))
    (dolist (cand cands)
      (let* ((len (car cand))
             (idx (cdr cand)))
        (when (and (<= len (- n p)) (> len best-len))
          (let ((off (+ (aref +doffset+ len) (* idx len))))
            (dolist (tk +dict-transform-kinds+)
              (when (%dict-word-match-p data p dict off len (cdr tk))
                (setf best-len len best-idx idx best-tid (car tk))
                (return)))))))
    (values best-len best-idx best-tid)))

(defun text-like-data-p (data)
  "T when DATA is mostly printable ASCII/whitespace, where the static
dictionary is worth consulting."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (optimize (speed 3) (safety 0)))
  (let* ((n (length data))
         (sample (min n 4096))
         (text 0))
    (declare (type fixnum n sample text))
    (dotimes (i sample)
      (let ((b (aref data i)))
        (when (or (= b 9) (= b 10) (= b 13) (<= 32 b 126))
          (incf text))))
    (> text (/ (* 9 (max 1 sample)) 10))))

(defun %lz77 (data sap window use-dict dict-limit base-pos max-chain lazy
              skip-match insert-interior &optional (score-p nil) (checks 1))
  "Implementation of LZ77.  SAP is a system-area pointer for DATA on SBCL,
or NIL on other implementations.  With SCORE-P (q5+), match selection uses
C's BackwardReferenceScore over the CHECKS-entry prepared distance cache
(4/10/16); otherwise the legacy length-maximizing search runs byte-exact."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum window base-pos max-chain checks)
           (type boolean score-p)
           (optimize (speed 3) (safety 0)))
  #+sbcl (declare (type sb-sys:system-area-pointer sap))
  #-sbcl (declare (ignore sap))
  (let* ((n (length data)) (min-match 4))
    (if (< n min-match)
        (if (zerop n) '() (list (list n 0 0 0 nil)))
        (let* ((hbits 17) (hmask (1- (ash 1 hbits)))
               (chained (> max-chain 1))
               (head (make-array (ash 1 hbits)
                                 :element-type '(unsigned-byte 32)
                                 :initial-element #xFFFFFFFF))
               ;; Every entry read from PREV was written when that position
               ;; was inserted, so no initial fill is needed.
               (prev (and chained
                          (make-array n :element-type '(unsigned-byte 32))))
               (cmds '()) (lit-start 0) (p 0) (last (- n min-match))
               (skip 32) (dict-used 0) (last-dist 0)
               (shift (the fixnum (- hbits 64)))
               ;; C score mode (q5+): the CHECKS-entry distance cache with
               ;; PrepareDistanceCache's +-1/2/3 cascade, seeded exactly like
               ;; encode.c's dist_cache_ = {4, 11, 15, 16} (the same history
               ;; the emit-side RB ring starts from).
               (dc (and score-p
                        (let ((a (make-array 16 :element-type 'fixnum
                                             :initial-element 0)))
                          (setf (aref a 0) 4 (aref a 1) 11
                                (aref a 2) 15 (aref a 3) 16)
                          (when (> checks 4)
                            (setf (aref a 4) 3 (aref a 5) 5 (aref a 6) 2
                                  (aref a 7) 6 (aref a 8) 1 (aref a 9) 7))
                          (when (> checks 10)
                            (setf (aref a 10) 10 (aref a 11) 12 (aref a 12) 9
                                  (aref a 13) 13 (aref a 14) 8 (aref a 15) 14))
                          a)))
               ;; C accepts 2/3-byte cache hits as copies (copy length codes
               ;; start at 2); the length-maximizing path keeps min-match.
               (min-cop (if score-p 2 min-match)))
          (declare (type (simple-array (unsigned-byte 32) (*)) head)
                   (type (or null (simple-array (unsigned-byte 32) (*))) prev)
                   (type (or null (simple-array fixnum (*))) dc)
                   (type fixnum p lit-start last skip dict-used last-dist
                            shift min-cop))
          (labels (#+sbcl
                   (hash (i)
                     ;; the 8-byte load in %hash4-sap needs the tail branch
                     ;; for i within 3 bytes of the end
                     (if (and sap (<= (+ i 8) n))
                         (%hash4-sap sap i shift hmask)
                         (%hash4-tail data i shift hmask)))
                   #-sbcl
                   (hash (i) (%hash4 data i hmask))
                   #+(and sbcl x86-64 64-bit little-endian)
                   (mlen (a b) (%match-len-sap sap a b n))
                   #-(and sbcl x86-64 64-bit little-endian)
                   (mlen (a b) (%match-len data a b n))
                   (ins (q h)
                     (declare (type fixnum q h))
                     (let ((old (aref head h)))
                       (declare (type fixnum old))
                       (setf (aref head h) q)
                       (when chained (setf (aref prev q) old))))
                   (probe-ok (cand pos best-len)
                     (declare (type fixnum cand pos best-len))
                     #+(and sbcl x86-64 64-bit little-endian)
                     (cond
                       ;; Once BEST-LEN is long enough, an 8-byte compare
                       ;; ending at BEST-LEN filters more candidates than the
                       ;; 4-byte probe while staying inside the buffer.
                       ((>= best-len 7)
                        (and (< best-len (- n pos))
                             (= (sb-sys:sap-ref-64 sap (+ cand (- best-len 7)))
                                (sb-sys:sap-ref-64 sap (+ pos (- best-len 7))))))
                       (t
                        (let ((probe (if (>= best-len 3) best-len 3)))
                          (if (<= (+ pos probe 4) n)
                              (= (sb-sys:sap-ref-32 sap (+ cand (- probe 3)))
                                 (sb-sys:sap-ref-32 sap (+ pos (- probe 3))))
                              t))))
                     #-(and sbcl x86-64 64-bit little-endian)
                     (declare (ignore cand pos best-len))
                     #-(and sbcl x86-64 64-bit little-endian)
                     t)
                   (find-match (pos h)
                     (declare (type fixnum pos h))
                     (let ((cand (aref head h)) (best-len 0) (best-dist 0))
                       (declare (type fixnum cand best-len best-dist))
                       ;; C checks the last distance before walking the
                       ;; chain.  A good hit also raises BEST-LEN, which
                       ;; makes PROBE-OK reject more chain candidates.
                       (when (plusp last-dist)
                         (let ((prev (- pos last-dist)))
                           (declare (type fixnum prev))
                           (when (and (>= prev 0) (<= last-dist window)
                                      (probe-ok prev pos best-len))
                             (let ((ml (mlen prev pos)))
                               (declare (type fixnum ml))
                               (when (> ml best-len)
                                 (setf best-len ml best-dist last-dist))))))
                       (if chained
                           (let ((chain max-chain))
                             (declare (type fixnum chain))
                             (loop while (and (/= cand #xFFFFFFFF) (> chain 0)) do
                               (when (> (- pos cand) window) (return))
                               (when (probe-ok cand pos best-len)
                                 (let ((ml (mlen cand pos)))
                                   (declare (type fixnum ml))
                                   (when (> ml best-len)
                                     (setf best-len ml best-dist (- pos cand)))))
                               (setf cand (the fixnum (aref prev cand))) (decf chain)))
                           (when (and (/= cand #xFFFFFFFF) (<= (- pos cand) window))
                             (when (probe-ok cand pos best-len)
                               (let ((ml (mlen cand pos)))
                                 (declare (type fixnum ml))
                                 (when (> ml best-len)
                                   (setf best-len ml best-dist (- pos cand)))))))
                       (values best-len best-dist 0)))
                   (penalty (i)
                     "C BackwardReferencePenaltyUsingLastDistance:
39 + ((0x1CA10 >> (i & 0xE)) & 0xE)."
                     (declare (type fixnum i))
                     (+ 39 (logand (ash #x1CA10 (- (logand i #xE))) #xE)))
                   (prepare-dc ()
                     "C PrepareDistanceCache: fill the +-1/2/3 cascade for
the CHECKS-entry candidate window."
                     (when dc
                       (let ((d0 (aref dc 0)) (d1 (aref dc 1)))
                         (declare (type fixnum d0 d1))
                         (setf (aref dc 4) (1- d0) (aref dc 5) (1+ d0)
                               (aref dc 6) (- d0 2) (aref dc 7) (+ d0 2)
                               (aref dc 8) (- d0 3) (aref dc 9) (+ d0 3))
                         (when (> checks 10)
                           (setf (aref dc 10) (1- d1) (aref dc 11) (1+ d1)
                                 (aref dc 12) (- d1 2) (aref dc 13) (+ d1 2)
                                 (aref dc 14) (- d1 3) (aref dc 15) (+ d1 3))))))
                   (find-match-score (pos h)
                     "C's FindLongestMatch shape with BackwardReferenceScore
selection: cache candidates first (i < CHECKS), then the chain walk, best by
score rather than length.  Returns (values len dist score)."
                     (declare (type fixnum pos h))

                     (let ((cand (aref head h)) (best-len 0) (best-dist 0)
                           ;; kMinScore = BROTLI_SCORE_BASE (1920) + 100
                           (best-score 2020))
                       (declare (type fixnum cand best-len best-dist
                                      best-score))
                       (let ((i 0))
                         (declare (type fixnum i))
                         (loop while (< i checks) do
                           (let* ((dist (aref dc i))
                                  (prev (- pos dist)))
                             (declare (type fixnum dist prev))
                             (when (and (plusp dist) (<= dist window)
                                        (>= prev 0)
                                        ;; C probes the byte at BEST-LEN
                                        (< best-len (- n pos))
                                        (< best-len (- n prev))
                                        (= (aref data (+ pos best-len))
                                           (aref data (+ prev best-len))))
                               (let ((ml (mlen prev pos)))
                                 (declare (type fixnum ml))
                                 (when (or (>= ml 3) (and (= ml 2) (< i 2)))
                                   (let ((score (- (+ 1935 (* 135 ml))
                                                   (if (plusp i)
                                                       (penalty i) 0))))
                                     (declare (type fixnum score))
                                     (when (> score best-score)
                                       (setf best-score score
                                             best-len ml best-dist dist)))))))
                           (incf i)))
                       (if chained
                           (let ((chain max-chain))
                             (declare (type fixnum chain))
                             (loop while (and (/= cand #xFFFFFFFF)
                                              (> chain 0)) do
                               (let ((d (- pos cand)))
                                 (declare (type fixnum d))
                                 (when (> d window) (return))
                                 (when (probe-ok cand pos best-len)
                                   (let ((ml (mlen cand pos)))
                                     (declare (type fixnum ml))
                                     (when (>= ml 4)
                                       ;; SCORE = 1920 + 135*len
                                       ;;             - 30*floor(log2(dist))
                                       (let ((score (+ 1920 (* 135 ml)
                                                       (- (* 30 (1- (integer-length d)))))))
                                         (declare (type fixnum score))
                                         (when (> score best-score)
                                           (setf best-score score
                                                 best-len ml
                                                 best-dist d)))))))
                               (setf cand (the fixnum (aref prev cand)))
                               (decf chain)))
                           (when (and (/= cand #xFFFFFFFF)
                                      (<= (- pos cand) window))
                             (when (probe-ok cand pos best-len)
                               (let ((ml (mlen cand pos)))
                                 (declare (type fixnum ml))
                                 (when (>= ml 4)
                                   (let ((score (+ 1920 (* 135 ml)
                                                   (- (* 30 (1- (integer-length (- pos cand))))))))
                                     (declare (type fixnum score))
                                     (when (> score best-score)
                                       (setf best-score score
                                             best-len ml
                                             best-dist (- pos cand)))))))))
                       (values best-len best-dist best-score)))
                   (emit-normal (best-len best-dist inserted h)
                     (declare (type fixnum best-len best-dist h))
                     (unless inserted (ins p h))
                     (if (>= best-len min-cop)
                         (progn
                           (push (list (- p lit-start) lit-start best-len
                                       best-dist nil)
                                 cmds)
                           (setf last-dist best-dist)
                           (when (and dc (/= best-dist (aref dc 0)))
                             ;; C rotates the cache for every copy except a
                             ;; repeat of dc[0] (distance short code 0).
                             (setf (aref dc 3) (aref dc 2)
                                   (aref dc 2) (aref dc 1)
                                   (aref dc 1) (aref dc 0)
                                   (aref dc 0) best-dist)
                             (prepare-dc))
                           (when (and chained insert-interior)
                             ;; C's StoreRange: for a short distance relative
                             ;; to the match, only store the tail positions to
                             ;; avoid poisoning the chain on RLE-like data.
                             (let* ((range-end (min (+ p best-len) (1+ last)))
                                    (range-start (1+ p)))
                               (declare (type fixnum range-end range-start))
                               (when (< best-dist (ash (- range-end p) -2))
                                 (setf range-start
                                       (max range-start
                                            (- range-end (ash best-dist 2)))))
                               (loop for q from range-start below range-end
                                     do (ins q (hash q)))))
                           (setf skip 32)
                           (incf p best-len)
                           (setf lit-start p))
                         (if skip-match
                             (let ((step (max 1 (ash skip -5))))
                               (incf p step)
                               (incf skip))
                             (incf p)))))
            (declare (inline hash ins mlen probe-ok penalty))
            (loop while (<= p last) do
              (let* ((ph (hash p)))
                (multiple-value-bind (best-len best-dist best-score)
                    (if score-p
                        (find-match-score p ph)
                        (find-match p ph))
                  (declare (type fixnum best-len best-dist best-score))
                  (let ((dict-p nil))
                    (when (and use-dict
                               (or (null dict-limit) (< dict-used dict-limit)))
                      (multiple-value-bind (dict-len dict-idx dict-tid)
                          (dict-match-at data p n)
                        (when (and (>= dict-len 9) (> dict-len best-len))
                          (setf dict-p t)
                          (let ((dist (+ (min window (+ base-pos p)) 1 dict-idx
                                         (* dict-tid (nwords dict-len)))))
                            (push (list (- p lit-start) lit-start dict-len dist t)
                                  cmds)
                            (incf dict-used)
                            (ins p ph)
                            (when (and chained insert-interior)
                              (loop for q from (1+ p)
                                    below (min (+ p dict-len) (1+ last))
                                    do (ins q (hash q))))
                            (setf skip 32)
                            (incf p dict-len)
                            (setf lit-start p)))))
                    (unless dict-p
                      (if (not score-p)
                          ;; Legacy shape: length-maximizing selection, kept
                          ;; byte-exact for q2-q4.
                          (if (and lazy (>= best-len min-match)
                                   (< best-len 64) (< p last))
                              (progn
                                (ins p ph)
                                (multiple-value-bind (next-len next-dist)
                                    (find-match (1+ p) (hash (1+ p)))
                                  (declare (ignore next-dist))
                                  (if (and (>= next-len min-match)
                                           (> next-len best-len))
                                      (incf p)
                                      (emit-normal best-len best-dist t ph))))
                              (emit-normal best-len best-dist nil ph))
                          ;; C score shape: accept at score > kMinScore,
                          ;; lazy gate next-score >= best-score + 175 with
                          ;; the 4-delay cap (backward_references_inc.h).
                          ;; Delayed positions carry sr2 forward exactly as
                          ;; C's inner loop does — every position is searched
                          ;; once; the earlier re-search shape searched each
                          ;; delayed position twice and cost ~20-35%.
                          (cond
                            ((not (and lazy (> best-score 2020)))
                             (emit-normal best-len best-dist nil ph))
                            (t
                             (ins p ph)
                             (let ((bl best-len) (bd best-dist)
                                   (bs best-score) (d 0) (done nil))
                               (declare (type fixnum bl bd bs d)
                                        (type boolean done))
                               (loop until done do
                                 (if (< p last)
                                     (let ((h2 (hash (1+ p))))
                                       (multiple-value-bind (nl nd ns)
                                           (find-match-score (1+ p) h2)
                                         (declare (type fixnum nl nd ns))
                                         (if (>= ns (+ bs 175))
                                             (progn
                                               ;; delay: position++, sr=sr2
                                               (incf p)
                                               (ins p h2)
                                               (setf bl nl bd nd bs ns
                                                     d (1+ d))
                                               (when (>= d 4)
                                                 ;; C breaks here and emits
                                                 ;; sr2 at the new position
                                                 (setf done t)
                                                 (emit-normal nl nd t ph)))
                                             (progn
                                               (setf done t)
                                               (emit-normal bl bd t ph)))))
                                     (progn
                                       (setf done t)
                                       (emit-normal bl bd t ph)))))))))))))
            (when (< lit-start n)
              (push (list (- n lit-start) lit-start 0 0 nil) cmds))
            (nreverse cmds))))))

;;; ---- C Brotli's q0/q1 fast-fragment entropy coding --------------------

(defun q0-cmd-symbol (c)
  "Map C's 64 fast command codes onto the full Brotli command alphabet."
  (declare (type fixnum c))
  (cond ((< c 8) c)
        ((< c 16) (+ 64 (- c 8)))
        ((< c 24) (+ 128 (- c 16)))
        ((< c 32) (+ 192 (- c 24)))
        ((< c 40) (+ 384 (- c 32)))
        ((< c 48) (+ 128 (* 8 (- c 40))))
        ((< c 56) (+ 256 (* 8 (- c 48))))
        (t (+ 448 (* 8 (- c 56))))))

(defparameter +q0-cmd-map+
  (let ((v (make-array 64 :element-type 'fixnum)))
    (dotimes (c 64 v) (setf (aref v c) (q0-cmd-symbol c)))))

;; C's kCmdHistoSeed: a prior that keeps every command code the fast path can
;; emit encodable and avoids degenerate one-symbol command trees.
(defparameter +q0-seed-cmd+
  #(0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    0 0 0 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 0 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1))

(defparameter +q0-seed-dist+
  #(1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 0 0 0 0))

(defun make-fixed-etree (lengths n)
  (let ((codes (canonical-codes lengths n)))
    (make-etree :lengths lengths :codes codes
                :rcodes (reversed-codes codes lengths n))))

(defun fast-cmd-etree (et)
  "Map a 64-symbol fast command etree onto the full 704-symbol alphabet."
  (if (etree-single et)
      (make-etree :single (aref +q0-cmd-map+ (etree-single et)))
      (let ((full (make-array 704 :element-type 'fixnum :initial-element 0))
            (fl (etree-lengths et)))
        (dotimes (c 64)
          (let ((d (aref fl c)))
            (when (plusp d)
              (setf (aref full (aref +q0-cmd-map+ c)) d))))
        (make-fixed-etree full 704))))

(declaim (inline q0-insert-len q0-copy-len q0-copy-last-len q0-distance))
(defun q0-insert-len (insert)
  (declare (type fixnum insert) (optimize (speed 3) (safety 0)))
  (cond ((< insert 6) (values (+ insert 40) 0 0))
        ((< insert 130)
         (let* ((tail (- insert 2))
                (nb (- (integer-length tail) 2))
                (prefix (ash tail (- nb))))
           (values (+ (* nb 2) prefix 42)
                   (- tail (ash prefix nb)) nb)))
        ((< insert 2114)
         (let* ((tail (- insert 66))
                (nb (1- (integer-length tail))))
           (values (+ nb 50) (- tail (ash 1 nb)) nb)))
        ((< insert 6210) (values 61 (- insert 2114) 12))
        ((< insert 22594) (values 62 (- insert 6210) 14))
        (t (values 63 (- insert 22594) 24))))

(defun q0-copy-len (copylen)
  (declare (type fixnum copylen) (optimize (speed 3) (safety 0)))
  (cond ((< copylen 10) (values (+ copylen 14) 0 0))
        ((< copylen 134)
         (let* ((tail (- copylen 6))
                (nb (- (integer-length tail) 2))
                (prefix (ash tail (- nb))))
           (values (+ (* nb 2) prefix 20)
                   (- tail (ash prefix nb)) nb)))
        ((< copylen 2118)
         (let* ((tail (- copylen 70))
                (nb (1- (integer-length tail))))
           (values (+ nb 28) (- tail (ash 1 nb)) nb)))
        (t (values 39 (- copylen 2118) 24))))

(defun q0-copy-last-len (copylen)
  (declare (type fixnum copylen) (optimize (speed 3) (safety 0)))
  (cond ((< copylen 12) (values (- copylen 4) 0 0))
        ((< copylen 72)
         (let* ((tail (- copylen 8))
                (nb (- (integer-length tail) 2))
                (prefix (ash tail (- nb))))
           (values (+ (* nb 2) prefix 4)
                   (- tail (ash prefix nb)) nb)))
        ((< copylen 136)
         (let ((tail (- copylen 8)))
           (values (+ (ash tail -5) 30) (logand tail 31) 5)))
        ((< copylen 2120)
         (let* ((tail (- copylen 72))
                (nb (1- (integer-length tail))))
           (values (+ nb 28) (- tail (ash 1 nb)) nb)))
        (t (values 39 (- copylen 2120) 24))))

(defun q0-distance (distance)
  (declare (type fixnum distance) (optimize (speed 3) (safety 0)))
  (let* ((d (+ distance 3))
         (nb (- (integer-length d) 2))
         (prefix (logand (ash d (- nb)) 1))
         (offset (ash (+ 2 prefix) nb)))
    (values (+ (* 2 (1- nb)) prefix 80)
            (- d offset) nb)))


(declaim (inline note-fast-command))
(defun note-fast-command (data litf cmdf distf last-dist ins ls cpy dist)
  "Update the fast command/distance histograms for one command and return
the new last-distance.  Mirrors WRITE-FAST-BLOCK-BODY's emission decisions."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type (simple-array fixnum (256)) litf)
           (type (simple-array fixnum (64)) cmdf distf)
           (type fixnum last-dist ins ls cpy dist)
           (optimize (speed 3) (safety 0)))
  (loop for i from ls below (+ ls ins)
        do (incf (aref litf (aref data i))))
  (cond
    ((and (plusp ins) (plusp cpy))
     (multiple-value-bind (cc e nb) (q0-insert-len ins)
       (declare (ignore e nb))
       (incf (aref cmdf cc)))
     (if (= dist last-dist)
         (incf (aref distf 0))
         (progn
           (multiple-value-bind (cc e nb) (q0-distance dist)
             (declare (ignore e nb))
             (incf (aref distf (- cc 64))))
           (setf last-dist dist)))
     (multiple-value-bind (cc e nb) (q0-copy-last-len cpy)
       (declare (ignore e nb))
       (incf (aref cmdf cc))
       (when (>= (aref +q0-cmd-map+ cc) 128)
         (incf (aref distf 0)))))
    ((plusp cpy)
     (multiple-value-bind (cc e nb) (q0-copy-len cpy)
       (declare (ignore e nb))
       (incf (aref cmdf cc)))
     (multiple-value-bind (cc e nb) (q0-distance dist)
       (declare (ignore e nb))
       (incf (aref distf (- cc 64))))
     (setf last-dist dist))
    (t
     (multiple-value-bind (cc e nb) (q0-insert-len ins)
       (declare (ignore e nb))
       (incf (aref cmdf cc)))))
  last-dist)

;;; C Brotli's fast-fragment matcher, used for q0/q1.  It keeps a single
;;; entry per hash (no chain), uses a 5-byte minimum match for q0 and 6-byte
;;; for q1, checks the last distance before the table, and re-inserts hashes
;;; for the bytes inside a just-emitted copy so the next copy can start
;;; immediately.  See c/enc/compress_fragment.c and
;;; compress_fragment_two_pass.c.
#+(and sbcl x86-64 64-bit little-endian)
(defun %lz77-fragment (data sap window table-bits)
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type sb-sys:system-area-pointer sap)
           (type fixnum window table-bits)
           (optimize (speed 3) (safety 0)))
  (let* ((n (length data))
         (k (if (<= table-bits 16) 5 6))
         (min-match k)
         (hmask (1- (ash 1 table-bits)))
         (table (make-array (ash 1 table-bits)
                            :element-type '(unsigned-byte 32)
                            :initial-element #xFFFFFFFF))
         (cv (make-array (* 4 (max 4096 (ash n -5)))
                         :element-type '(unsigned-byte 32)))
         (nc 0)
         (litf (make-array 256 :element-type 'fixnum :initial-element 0))
         (cmdf (make-array 64 :element-type 'fixnum :initial-element 0))
         (distf (make-array 64 :element-type 'fixnum :initial-element 0))
         (lit-start 0) (p 1) (limit (- n k))
         (last-dist -1) (back (if (= k 5) 3 5))
         (shift (the fixnum (- table-bits 64))))
    (declare (type fixnum k min-match p lit-start limit last-dist back nc shift)
             (type (simple-array (unsigned-byte 32) (*)) table cv)
             (type (simple-array fixnum (256)) litf)
             (type (simple-array fixnum (64)) cmdf distf))
    (replace cmdf +q0-seed-cmd+)
    (replace distf +q0-seed-dist+)
    (labels ((hash (i)
               ;; The 8-byte load in %HASHF-SAP reads i..i+7; within 3 bytes
               ;; of the end that crosses the vector boundary (C's matcher
               ;; keeps a 16-byte margin we do not have), so the tail
               ;; positions compute the same hash from a 5-byte u40 build.
               (if (<= (+ i 8) n)
                   (%hashf-sap sap i shift hmask)
                   (%hashf-tail data i shift hmask)))
             (prefix-match (a b)
               (and (= (sb-sys:sap-ref-32 sap a)
                       (sb-sys:sap-ref-32 sap b))
                    (if (= k 5)
                        (= (sb-sys:sap-ref-8 sap (+ a 4))
                           (sb-sys:sap-ref-8 sap (+ b 4)))
                        (= (sb-sys:sap-ref-16 sap (+ a 4))
                           (sb-sys:sap-ref-16 sap (+ b 4))))))
             (mlen (a b) (%match-len-sap-call sap a b n))
             (push-cmd (ins ls cpy dist)
               (when (>= (* 4 nc) (length cv))
                 (let ((new (make-array (* 2 (length cv))
                                        :element-type '(unsigned-byte 32))))
                   (replace new cv)
                   (setf cv new)))
               (let ((b (* 4 nc)))
                 (setf (aref cv b) ins
                       (aref cv (+ b 1)) ls
                       (aref cv (+ b 2)) cpy
                       (aref cv (+ b 3)) dist))
               (incf nc)))
        (declare (inline hash prefix-match push-cmd))
      (when (> n k)
        (let ((next-hash (hash p)))
          (declare (type fixnum next-hash))
          (block scan
            (loop
              ;; Step 1: trawl for a k-byte match, with C's skip heuristic.
              (let ((skip 32) (cand #xFFFFFFFF) (next-ip p))
                (declare (type fixnum skip next-ip)
                         (type (unsigned-byte 32) cand))
                (block trawl
                  (loop
                    (let* ((h next-hash)
                           (step (ash skip -5)))
                      (declare (type fixnum h step))
                      (incf skip)
                      (setf p next-ip)
                      (setf next-ip (+ p step))
                      (when (> next-ip limit) (return-from scan nil))
                      (setf next-hash (hash next-ip))
                      ;; C checks the previous distance before the table.
                      (when (> last-dist 0)
                        (let ((ld (- p last-dist)))
                          (when (and (>= ld 0) (prefix-match p ld))
                            (setf (aref table h) p
                                  cand ld)
                            (return-from trawl nil))))
                      (let ((c2 (aref table h)))
                        (setf (aref table h) p)
                        (when (and (/= c2 #xFFFFFFFF)
                                   (< c2 p)
                                   (<= (- p c2) window)
                                   (prefix-match p c2))
                          (setf cand c2)
                          (return-from trawl nil))))))
                ;; Step 2: emit the found match plus the pending literals.
                (let* ((base p)
                       (matched (+ min-match (%match-len-sap-frag sap (+ cand k) (+ p k) n)))
                       (distance (- base cand))
                       (insert (- base lit-start)))
                  (declare (type fixnum matched distance insert))
                  (push-cmd insert lit-start matched distance)
                  (setf last-dist
                        (note-fast-command data litf cmdf distf last-dist
                                           insert lit-start matched distance))
                  (incf p matched)
                  (setf lit-start p))
                (when (>= p limit) (return-from scan nil))
                ;; Insert hashes for positions inside the copy.
                (loop for q from (max 0 (- p back)) below p
                      do (setf (aref table (hash q)) q))
                (let* ((cur-hash (hash p))
                       (cand2 (aref table cur-hash)))
                  (declare (type fixnum cur-hash)
                           (type (unsigned-byte 32) cand2))
                  (setf (aref table cur-hash) p)
                  ;; Consecutive copies with no literal bytes in between.
                  (loop while (and (/= cand2 #xFFFFFFFF)
                                   (< cand2 p)
                                   (<= (- p cand2) window)
                                   (prefix-match p cand2))
                        do
                        (let* ((base p)
                               (matched (+ min-match
                                           (%match-len-sap-frag2
                                            sap (+ cand2 k) (+ p k) n)))
                               (distance (- base cand2)))
                          (declare (type fixnum matched distance))
                          (push-cmd 0 p matched distance)
                          (setf last-dist
                                (note-fast-command data litf cmdf distf
                                                   last-dist 0 p matched distance))
                          (incf p matched)
                          (setf lit-start p))
                        (when (>= p limit) (return-from scan nil))
                        (loop for q from (max 0 (- p back)) below p
                              do (setf (aref table (hash q)) q))
                        (setf cur-hash (hash p)
                              cand2 (aref table cur-hash))
                        (setf (aref table cur-hash) p))))
              ;; No match at P: advance one byte and continue trawling.
              (incf p)
              (when (> p limit) (return-from scan nil))
              (setf next-hash (hash p))))))
      (when (< lit-start n)
        (let ((insert (- n lit-start)))
          (push-cmd insert lit-start 0 0)
          (setf last-dist
                (note-fast-command data litf cmdf distf last-dist
                                   insert lit-start 0 0))))
      (values cv nc litf cmdf distf))))

(defun lz77 (data window &key (use-dict (text-like-data-p data)) dict-limit
                              (base-pos 0) (max-chain 128) (lazy t)
                              (skip-match nil) (insert-interior t)
                              (score-p nil) (checks 1))
  "Return commands (insert-len lit-start copy-len distance dict-p); copy-len 0
marks a trailing insert-only command.  BASE-POS is the number of bytes already
produced before DATA; it is needed to encode dictionary distances correctly
when DATA is one chunk of a multi-meta-block stream.  MAX-CHAIN and LAZY trade
compression ratio for encoder throughput."
  #+sbcl
  (sb-sys:with-pinned-objects (data)
    #+(and sbcl x86-64 64-bit little-endian)
    (if (and skip-match (not lazy) (not use-dict) (<= max-chain 2))
        (%lz77-fragment data (sb-sys:vector-sap data) window
                        (if (<= max-chain 1) 15 17))
        (%lz77 data (sb-sys:vector-sap data) window use-dict dict-limit
               base-pos max-chain lazy skip-match insert-interior
               score-p checks)))
  #-sbcl
  (%lz77 data nil window use-dict dict-limit base-pos max-chain lazy
         skip-match insert-interior score-p checks))

;;; A "trivial" entropy path for q2-q4: one literal/command/distance tree,
;;; no context maps, no block splits.  Unlike PLAN-COMMANDS it does not
;;; allocate or write a 10-fixnum record per command; the code values are
;;; recomputed in the emission pass.
(defun write-trivial-block-body (w data cmds rb
                                 &key (short-dist nil)
                                   (max-lit-bits 15))
  (declare (type b:bwr w)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type (simple-array fixnum (*)) rb)
           (optimize (speed 3) (safety 0)))
  (let* ((litf (make-array 256 :element-type 'fixnum :initial-element 0))
         (cmdf (make-array 704 :element-type 'fixnum :initial-element 0))
         (distf (make-array 64 :element-type 'fixnum :initial-element 0))
         (probe-rb (copy-seq rb)))
    (declare (type (simple-array fixnum (256)) litf)
             (type (simple-array fixnum (*)) cmdf distf probe-rb))
    ;; Pass 1: histograms only.
    (dolist (c cmds)
      (let* ((ins (car c)) (lit-start (cadr c)) (cpy (caddr c))
             (dist (cadddr c)) (dictp (car (cddddr c))))
        (declare (type fixnum ins lit-start cpy dist))
        (loop for i from lit-start below (+ lit-start ins)
              do (incf (aref litf (aref data i))))
        (multiple-value-bind (icode ixv ixb)
            (length-code ins +ins-lc+ +ins-base+ +ins-bits+)
          (declare (ignore ixv ixb))
          (multiple-value-bind (ccode cxv cxb)
              (if (plusp cpy)
                  (length-code cpy +cpy-lc+ +cpy-base+ +cpy-bits+)
                  (values 0 0 0))
            (declare (ignore cxv cxb))
            (let* ((ring-pos (aref probe-rb 4))
                   (repeat (and (plusp cpy) (not dictp)
                                (= dist (aref probe-rb
                                              (logand (+ ring-pos 3) 3)))))
                   (dist0 (and repeat (<= icode 7) (< ccode 16)))
                   (csym (if dist0
                             (cmd-symbol-dist0 icode ccode)
                             (cmd-symbol icode ccode))))
              (declare (type fixnum ring-pos csym))
              (incf (aref cmdf csym))
              (when (and (plusp cpy) (not dist0))
                (let ((dcode nil))
                  (if repeat
                      (setf dcode 0)
                      (multiple-value-bind (scode sxv sxb)
                          (if short-dist
                              (special-distance-code probe-rb dist)
                              (values nil 0 0))
                        (declare (ignore sxv sxb))
                        (if scode
                            (setf dcode scode)
                            (multiple-value-bind (code xv xb)
                                (encode-distance dist)
                              (declare (ignore xv xb))
                              (setf dcode code)))))
                  (incf (aref distf dcode))
                  (unless (or dictp (= dcode 0))
                    (setf (aref probe-rb (logand ring-pos 3)) dist)
                    (setf (aref probe-rb 4) (1+ ring-pos))))))))))
    (let* ((lit (build-etree litf 256 max-lit-bits))
           (cmd (build-etree cmdf 704 15))
           (dist (build-etree distf 64 15))
           (lit-single (etree-single lit))
           (cmd-single (etree-single cmd))
           (dist-single (etree-single dist))
           (lit-rc (or (etree-rcodes lit) +empty-fixnums+))
           (lit-ln (or (etree-lengths lit) +empty-fixnums+))
           (cmd-rc (or (etree-rcodes cmd) +empty-fixnums+))
           (cmd-ln (or (etree-lengths cmd) +empty-fixnums+))
           (dist-rc (or (etree-rcodes dist) +empty-fixnums+))
           (dist-ln (or (etree-lengths dist) +empty-fixnums+))
           (slack 0))
      (declare (type (simple-array fixnum (*))
                     lit-rc lit-ln cmd-rc cmd-ln dist-rc dist-ln)
               (type fixnum slack))
      (b:wbits w 0 1) (b:wbits w 0 1) (b:wbits w 0 1)
      (b:wbits w 0 2) (b:wbits w 0 4) (b:wbits w 0 2)
      (b:wbits w 0 1) (b:wbits w 0 1)
      (write-etree w lit 256)
      (write-etree w cmd 704)
      (write-etree w dist 64)
      ;; Pass 2: recompute the compact codes and emit.
      (dolist (c cmds)
        (let* ((ins (car c)) (lit-start (cadr c)) (cpy (caddr c))
               (dist (cadddr c)) (dictp (car (cddddr c))))
          (declare (type fixnum ins lit-start cpy dist))
          (let ((cost (+ 24 (* 2 ins))))
            (declare (type fixnum cost))
            (when (> cost slack)
              (setf slack 65536)
              (b:w-ensure w (+ slack cost)))
            (decf slack cost))
          (multiple-value-bind (icode ixv ixb)
              (length-code ins +ins-lc+ +ins-base+ +ins-bits+)
            (multiple-value-bind (ccode cxv cxb)
                (if (plusp cpy)
                    (length-code cpy +cpy-lc+ +cpy-base+ +cpy-bits+)
                    (values 0 0 0))
              (let* ((ring-pos (aref rb 4))
                     (repeat (and (plusp cpy) (not dictp)
                                  (= dist (aref rb (logand (+ ring-pos 3) 3)))))
                     (dist0 (and repeat (<= icode 7) (< ccode 16)))
                     (csym (if dist0
                               (cmd-symbol-dist0 icode ccode)
                               (cmd-symbol icode ccode)))
                     (dcode -1) (dxv 0) (dxb 0))
                (declare (type fixnum ring-pos csym dcode dxv dxb))
                (when (and (plusp cpy) (not dist0))
                  (if repeat
                      (setf dcode 0)
                      (multiple-value-bind (scode sxv sxb)
                          (if short-dist
                              (special-distance-code rb dist)
                              (values nil 0 0))
                        (if scode
                            (setf dcode scode dxv sxv dxb sxb)
                            (multiple-value-setq (dcode dxv dxb)
                              (encode-distance dist)))))
                  (unless (or dictp (= dcode 0))
                    (setf (aref rb (logand ring-pos 3)) dist)
                    (setf (aref rb 4) (1+ ring-pos))))
                (unless cmd-single
                  (b:%wbits-raw-pm w (aref cmd-rc csym) (aref cmd-ln csym)))
                (b:%wbits-raw-pm w ixv ixb)
                (b:%wbits-raw-pm w cxv cxb)
                (unless lit-single
                  (if (>= ins 16)
                      (b:w-emit-run w data lit-start (+ lit-start ins)
                                    lit-rc lit-ln)
                      (loop for i from lit-start below (+ lit-start ins)
                            do (let ((sym (aref data i)))
                                 (b:%wbits-raw w (aref lit-rc sym)
                                               (aref lit-ln sym))))))
                (when (>= dcode 0)
                  (unless dist-single
                    (b:%wbits-raw-pm w (aref dist-rc dcode)
                                                     (aref dist-ln dcode)))
                  (b:%wbits-raw w dxv dxb))))))))))

;;; ---- compressed meta-block --------------------------------------------

(defun write-fast-block-body (w data cv nc litf cmdf distf)
  "Emit a q0/q1 meta-block body from the flat fast-fragment command vector,
using the fast command/distance alphabet with trees built from the actual
histograms.  The MLEN header must already have been written."
  (declare (type b:bwr w)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type (simple-array (unsigned-byte 32) (*)) cv)
           (type fixnum nc)
           (type (simple-array fixnum (256)) litf)
           (type (simple-array fixnum (64)) cmdf distf)
           (optimize (speed 3) (safety 0)))
  (let* ((lit (build-etree litf 256 15))
           (cmd-et (fast-cmd-etree (build-etree cmdf 64 15)))
           (dist-et (build-etree distf 64 14))
           (lit-single (etree-single lit))
           (cmd-single (etree-single cmd-et))
           (dist-single (etree-single dist-et))
           (lit-rc (or (etree-rcodes lit) +empty-fixnums+))
           (lit-ln (or (etree-lengths lit) +empty-fixnums+))
           (cmd-rc (or (etree-rcodes cmd-et) +empty-fixnums+))
           (cmd-ln (or (etree-lengths cmd-et) +empty-fixnums+))
           (cmd-map +q0-cmd-map+)
           (dist-rc (or (etree-rcodes dist-et) +empty-fixnums+))
           (dist-ln (or (etree-lengths dist-et) +empty-fixnums+))
           (last-dist -1) (slack 0))
      (declare (type fixnum last-dist slack)
               (type (simple-array fixnum (*))
                     lit-rc lit-ln cmd-rc cmd-ln cmd-map dist-rc dist-ln))
      ;; NBLTYPES 1/1/1, NPOSTFIX=0, NDIRECT=0, context mode 0,
      ;; NTREESL=1, NTREESD=1; then literal, command, distance codes.
      (b:wbits w 0 1) (b:wbits w 0 1) (b:wbits w 0 1)
      (b:wbits w 0 2)
      (b:wbits w 0 4)
      (b:wbits w 0 2)
      (b:wbits w 0 1) (b:wbits w 0 1)
      (write-etree w lit 256)
      (write-etree w cmd-et 704)
      (write-etree w dist-et 64)
      (macrolet ((emit-cmd (code extra nbits)
                   `(unless cmd-single
                      (let ((c ,code))
                        (declare (type fixnum c))
                        (b:%wbits-raw-pm w (aref cmd-rc (aref cmd-map c))
                                         (aref cmd-ln (aref cmd-map c)))
                        (when (plusp ,nbits)
                          (b:%wbits-raw w ,extra ,nbits)))))
                 (emit-dist (code extra nbits)
                   `(unless dist-single
                      (let ((c ,code))
                        (declare (type fixnum c))
                        (b:%wbits-raw w (aref dist-rc (- c 64))
                                      (aref dist-ln (- c 64)))
                        (when (plusp ,nbits)
                          (b:%wbits-raw w ,extra ,nbits)))))
                 (lits (start count)
                   `(if (>= ,count 8)
                        (b:w-emit-run w data ,start (+ ,start ,count)
                                      lit-rc lit-ln)
                        (loop for i from ,start below (+ ,start ,count)
                              do (let ((sym (aref data i)))
                                   (b:%wbits-raw-pm w (aref lit-rc sym)
                                                    (aref lit-ln sym)))))))
        (dotimes (ci nc)
          (let* ((base (* 4 ci))
                 (ins (aref cv base))
                 (lit-start (aref cv (+ base 1)))
                 (cpy (aref cv (+ base 2)))
                 (dist (aref cv (+ base 3))))
            (declare (type fixnum ins lit-start cpy dist))
            ;; Ensure capacity in 64 KiB chunks instead of once per command.
            ;; The per-command upper bound is 32 bytes of command/distance
            ;; overhead plus two bytes per literal.
            (let ((cost (+ 32 (* 2 ins))))
              (declare (type fixnum cost))
              (when (> cost slack)
                (setf slack 65536)
                (b:w-ensure w (+ slack cost)))
              (decf slack cost))
            (cond
              ((and (plusp ins) (plusp cpy))
               (multiple-value-bind (cc e nb) (q0-insert-len ins)
                 (emit-cmd cc e nb))
               (unless lit-single
                 (lits lit-start ins))
               (if (= dist last-dist)
                   (emit-dist 64 0 0)
                   (progn
                     (multiple-value-bind (cc e nb) (q0-distance dist)
                       (emit-dist cc e nb))
                     (setf last-dist dist)))
               (multiple-value-bind (cc e nb) (q0-copy-last-len cpy)
                 (emit-cmd cc e nb)
                 (when (>= (aref cmd-map cc) 128)
                   (emit-dist 64 0 0))))
              ((plusp cpy)
               (multiple-value-bind (cc e nb) (q0-copy-len cpy)
                 (emit-cmd cc e nb))
               (multiple-value-bind (cc e nb) (q0-distance dist)
                 (emit-dist cc e nb))
               (setf last-dist dist))
              (t
               (multiple-value-bind (cc e nb) (q0-insert-len ins)
                 (emit-cmd cc e nb))
               (unless lit-single
                 (lits lit-start ins)))))))))


;;; Flat command records: 10 fixnums per command.  A struct per command was
;;; ~15% of low-quality compression time; CPY is not needed by the emitter,
;;; and a negative DCODE means "no distance bits".
(defconstant +cmd-stride+ 10)
;; offsets: 0 ins, 1 lit-start, 2 csym, 3 ixv, 4 ixb, 5 cxv, 6 cxb,
;;          7 dcode (-1 = none), 8 dxv, 9 dxb

(defun plan-commands (data cmds
                      &optional (rb (make-array 5 :element-type 'fixnum
                                                  :initial-contents '(16 15 11 4 4)))
                      &key (short-dist t) (quality 5))
  "Turn raw LZ77 commands into flat fixnum records and tally literal/command/
distance frequencies.  Returns (values RECS NCOMMANDS LITFREQ CMDFREQ DISTFREQ).
RB is the distance ring shared by all meta-blocks of the stream; it must
persist across chunks just like the decoder's ring.  SHORT-DIST enables the 15
short distance-ring codes; low qualities disable them to avoid 15 comparisons
per command."
  (let* ((ncmd (length cmds))
         (recs (make-array (* +cmd-stride+ ncmd)
                           :element-type 'fixnum))
         (ri 0)
         (ctx (multiple-value-list (literal-contexts data quality)))
         (lit-k (first ctx))
         (lit-cmap (second ctx))
         (litfreq (make-array (* lit-k 256) :element-type 'fixnum
                                            :initial-element 0))
         (cmdfreq (make-array 704 :element-type 'fixnum :initial-element 0))
         (distfreq (make-array 64 :element-type 'fixnum :initial-element 0)))
    (declare (type fixnum ri)
             (type (simple-array (unsigned-byte 8) (*)) data)
             (type (simple-array fixnum (*)) recs litfreq cmdfreq distfreq rb))
    ;; Explicit CAR/CDR access instead of DESTRUCTURING-BIND: the latter
    ;; expands to SB-C::CHECK-DS-LIST in this hot loop.
    (dolist (c cmds)
      (let* ((ins (car c))
             (lit-start (cadr c))
             (cpy (caddr c))
             (dist (cadddr c))
             (dictp (car (cddddr c)))
             (ring-pos (aref rb 4)))
        (declare (type fixnum ins lit-start cpy dist ring-pos))
        (multiple-value-bind (icode ixv ixb)
            (length-code ins +ins-lc+ +ins-base+ +ins-bits+)
          (declare (type fixnum icode ixv ixb))
          (let ((copyp (plusp cpy)))
            (multiple-value-bind (ccode cxv cxb)
                (if copyp
                    (length-code cpy +cpy-lc+ +cpy-base+ +cpy-bits+)
                    (values 0 0 0))
              (declare (type fixnum ccode cxv cxb))
              (let* ((repeat (and copyp (not dictp)
                                  (= dist (aref rb (logand (+ ring-pos 3) 3)))))
                     (dist0 (and repeat (<= icode 7) (< ccode 16)))
                     (csym (if dist0
                               (cmd-symbol-dist0 icode ccode)
                               (cmd-symbol icode ccode)))
                     (dcode -1) (dxv 0) (dxb 0))
                (declare (type fixnum csym dcode dxv dxb))
                (incf (aref cmdfreq csym))
                (if (null lit-cmap)
                    (loop for i from lit-start below (+ lit-start ins)
                          do (incf (aref litfreq (aref data i))))
                    (loop for i from lit-start below (+ lit-start ins)
                          do (let* ((sym (aref data i))
                                    (p1 (if (plusp i) (aref data (1- i)) 0))
                                    (p2 (if (> i 1) (aref data (- i 2)) 0))
                                    (cid (aref lit-cmap
                                               (logior (aref +lut0+ p1)
                                                       (aref +lut1+ p2)))))
                               (declare (type fixnum sym p1 p2 cid))
                               (incf (aref litfreq (+ (* cid 256) sym))))))
                (when copyp
                  (unless dist0
                    (if repeat
                        (setf dcode 0)
                        (multiple-value-bind (scode sxv sxb)
                            (if short-dist
                                (special-distance-code rb dist)
                                (values nil 0 0))
                          (if scode
                              (setf dcode scode dxv sxv dxb sxb)
                              (multiple-value-setq (dcode dxv dxb)
                                (encode-distance dist)))))
                    (incf (aref distfreq dcode))
                    ;; Distance symbol 0 reuses the last distance without
                    ;; pushing; dictionary references are not pushed either.
                    (unless (or dictp (= dcode 0))
                      (setf (aref rb (logand ring-pos 3)) dist)
                      (setf (aref rb 4) (1+ ring-pos)))))
                (setf (aref recs ri) ins
                      (aref recs (+ ri 1)) lit-start
                      (aref recs (+ ri 2)) csym
                      (aref recs (+ ri 3)) ixv
                      (aref recs (+ ri 4)) ixb
                      (aref recs (+ ri 5)) cxv
                      (aref recs (+ ri 6)) cxb
                      (aref recs (+ ri 7)) dcode
                      (aref recs (+ ri 8)) dxv
                      (aref recs (+ ri 9)) dxb)
                (incf ri +cmd-stride+)))))))
    (values recs ncmd litfreq cmdfreq distfreq lit-k lit-cmap)))

(defun write-mlen-header (w n last)
  (let* ((m1 (1- n)) (nib (cond ((<= m1 #xFFFF) 4) ((<= m1 #xFFFFF) 5) (t 6))))
    (b:wbits w (if last 1 0) 1)                          ; ISLAST
    (when last (b:wbits w 0 1))                          ; ISLASTEMPTY=0
    (b:wbits w (- nib 4) 2)                              ; MNIBBLES
    (b:wbits w m1 (* 4 nib))                             ; MLEN-1
    (unless last (b:wbits w 0 1))))                      ; ISUNCOMPRESSED=0


;; ---- literal context modeling (C encode.c: DecideOverLiteralContext
;; ---- / ChooseContextMap / ShouldUseComplexStaticContextMap) --------------

(defparameter +ctx-simple-utf8+
  #(0 0 1 1 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0))

(defparameter +ctx-continuation+
  #(1 1 2 2 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0))

(defparameter +ctx-complex-utf8+
  #(11 11 12 12 0 0 0 0 1 1 9 9 2 2 2 2
    1 1 1 1 8 3 3 3 1 1 1 1 2 2 2 2
    8 4 4 4 8 7 4 4 8 0 0 0 3 3 3 3
    5 5 10 5 5 5 10 5 6 6 6 6 6 6 6 6))

(declaim (type simple-vector +ctx-simple-utf8+ +ctx-continuation+
                         +ctx-complex-utf8+))

(defun estimate-entropy (histo off size)
  "C EstimateEntropy (encode.c): total*log2(total) - sum p*log2(p)."
  (declare (type (simple-array fixnum (*)) histo)
           (type fixnum off size)
           (optimize (speed 3) (safety 0)))
  (let ((total 0) (result 0.0d0))
    (declare (type fixnum total) (type double-float result))
    (dotimes (i size)
      (let ((p (aref histo (+ off i))))
        (declare (type fixnum p))
        (incf total p)
        (when (plusp p)
          (incf result (* (float p 1.0d0) (log (float p 1.0d0) 2.0d0))))))
    (if (zerop total)
        0.0d0
        (- (* (float total 1.0d0) (log (float total 1.0d0) 2.0d0)) result))))

(defun complex-context-map (data n)
  "C ShouldUseComplexStaticContextMap: entropy gate over5-bit literal
histograms per complex-map context.  Returns the13-context map or NIL."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum n)
           (optimize (speed 3) (safety 0)))
  (let ((combined (make-array 32 :element-type 'fixnum :initial-element 0))
        (chisto (make-array (* 32 64) :element-type 'fixnum
                                    :initial-element 0))
        (total 0))
    (declare (type (simple-array fixnum (*)) combined chisto)
             (type fixnum total))
    (loop for start of-type fixnum from 0 to (- n 64) by 4096 do
      (let ((prev2 (aref data start)) (prev1 (aref data (1+ start))))
        (declare (type fixnum prev1 prev2))
        (loop for pos of-type fixnum from (+ start 2) below (+ start 64)
              do (let* ((lit (aref data pos))
                        (ctx (aref +ctx-complex-utf8+
                                   (logior (aref +lut0+ prev1)
                                           (aref +lut1+ prev2)))))
                   (declare (type fixnum lit ctx))
                   (incf total)
                   (incf (aref combined (ash lit -3)))
                   (incf (aref chisto (+ (ash ctx 5) (ash lit -3))))
                   (setf prev2 prev1 prev1 lit)))))
    (when (plusp total)
      (let ((e1 (* (estimate-entropy combined 0 32)
                   (/ 1.0d0 total)))
            (e2 0.0d0))
        (declare (type double-float e1 e2))
        (dotimes (i 64)
          (incf e2 (estimate-entropy chisto (* i 32) 32)))
        (setf e2 (* e2 (/ 1.0d0 total)))
        (unless (or (> e2 3.0d0) (< (- e1 e2) 0.2d0))
          (return-from complex-context-map +ctx-complex-utf8+))))
    nil))

(defun bigram-context-map (data n quality)
  "C DecideOverLiteralContextModeling's bigram path + ChooseContextMap.
Returns (values K CMAP) with K in {1,2,3}."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum n quality)
           (optimize (speed 3) (safety 0)))
  (let ((bigram (make-array 9 :element-type 'fixnum :initial-element 0))
        (lut #(0 0 1 2)))
    (declare (type (simple-array fixnum (*)) bigram) (type simple-vector lut))
    (loop for start of-type fixnum from 0 to (- n 64) by 4096 do
      (let ((prev (* 3 (aref lut (ash (aref data start) -6)))))
        (declare (type fixnum prev))
        (loop for pos of-type fixnum from (1+ start) below (+ start 64)
              do (let ((cls (* 3 (aref lut (ash (aref data pos) -6)))))
                   (declare (type fixnum cls))
                   (incf (aref bigram (+ prev cls)))
                   (setf prev cls)))))
    (let ((mono (make-array 3 :element-type 'fixnum :initial-element 0))
          (two (make-array 6 :element-type 'fixnum :initial-element 0))
          (total 0))
      (declare (type (simple-array fixnum (*)) mono two) (type fixnum total))
      (dotimes (i 9)
        (incf (aref mono (mod i 3)) (aref bigram i))
        (incf (aref two (mod i 6)) (aref bigram i))
        (incf total (aref bigram i)))
      (if (zerop total)
          (values 1 nil)
          (let* ((scale (/ 1.0d0 total))
                 (e1 (* (estimate-entropy mono 0 3) scale))
                 (e2 (* (+ (estimate-entropy two 0 3)
                           (estimate-entropy two 3 3))
                        scale))
                 (e3 0.0d0))
            (declare (type double-float e1 e2 e3))
            (dotimes (i 3)
              (incf e3 (estimate-entropy bigram (* i 3) 3)))
            (setf e3 (* e3 scale))
            (when (< quality 7)        ; MIN_QUALITY_FOR_HQ_CONTEXT_MODELING
              (setf e3 (* e1 10.0d0)))
            (cond ((and (< (- e1 e2) 0.2d0) (< (- e1 e3) 0.2d0))
                   (values 1 nil))
                  ((< (- e2 e3) 0.02d0)
                   (values 2 +ctx-simple-utf8+))
                  (t (values 3 +ctx-continuation+))))))))

(defun literal-contexts (data quality)
  "C DecideOverLiteralContextModeling.  Returns (values K CMAP64)."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum quality))
  (let ((n (length data)))
    (cond ((< quality 5) (values 1 nil))
          ((< n 64) (values 1 nil))
          ((and (>= n #.(ash 1 20)) (complex-context-map data n))
           (values 13 +ctx-complex-utf8+))
          (t (bigram-context-map data n quality)))))

(defun write-nbltypes (w n)
  "Inverse of the decoder's READ-NBLTYPES varint (N >= 1)."
  (declare (type b:bwr w) (type fixnum n))
  (cond ((= n 1) (b:wbits w 0 1))
        ((= n 2) (b:wbits w 1 1) (b:wbits w 0 3))
        (t (let ((k 0))
             (declare (type fixnum k))
             (loop while (not (and (<= (1+ (ash 1 k)) n)
                                   (<= n (ash 1 (1+ k)))))
                   do (incf k))
             (b:wbits w 1 1)
             (b:wbits w k 3)
             (b:wbits w (- n (1+ (ash 1 k))) k)))))

(defun write-lit-context-map (w cmap k)
  "Write the64-static-context -> K-tree map in READ-CONTEXT-MAP's format
with RLEMAX=0 and the IMTF bit clear."
  (declare (type b:bwr w) (type fixnum k))
  (b:wbits w 0 1)                             ; RLEMAX = 0
  (let* ((freqs (make-array k :element-type 'fixnum :initial-element 1))
         (et (build-etree freqs k 15)))
    (write-etree w et k)
    (dotimes (cid 64)
      (declare (type fixnum cid))
      (etree-emit w et (aref cmap cid))))
  (b:wbits w 0 1))                            ; no IMTF

(defun lit-slice (litf k)
  "The K-th256-symbol histogram of a K*256 flat literal frequency array."
  (declare (type (simple-array fixnum (*)) litf) (type fixnum k))
  (let ((f (make-array 256 :element-type 'fixnum :initial-element 0)))
    (declare (type (simple-array fixnum (*)) f))
    (dotimes (j 256 f)
      (declare (type fixnum j))
      (setf (aref f j) (aref litf (+ (* k 256) j))))))

(defun write-compressed-block-body (w data base-pos window use-dict dict-limit rb
                                    &key (max-chain 128) (lazy t) (short-dist t)
                                      (skip-match nil) (insert-interior t)
                                      (score-p nil) (checks 1)
                                      (quality 5)
                                      cmds)
  "Write the NBLTYPES/trees/commands part of a compressed meta-block.  The
MLEN header must already have been written.  RB is the stream-wide distance
ring shared with the decoder.  CMDS, when supplied, is a precomputed command
list covering exactly this block."
  (declare (type b:bwr w)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum base-pos window)
           (type (or null fixnum) dict-limit)
           (type (simple-array fixnum (*)) rb)
           (type fixnum max-chain))
  (multiple-value-bind (recs ncmd litf cmdf distf lit-k lit-cmap)
        (plan-commands
         data
         (or cmds
             (lz77 data window :use-dict use-dict :dict-limit dict-limit
                            :base-pos base-pos :max-chain max-chain :lazy lazy
                            :skip-match skip-match
                            :insert-interior insert-interior
                            :score-p score-p :checks checks))
         rb :short-dist short-dist :quality quality)
      (declare (type (simple-array fixnum (*)) recs litf cmdf distf)
               (type fixnum ncmd lit-k)
               (type (or null simple-vector) lit-cmap))
      (let* ((cmd (build-etree cmdf 704 15))
             (dist (build-etree distf 64 15))
             (lit (when (= lit-k 1) (build-etree litf 256 15)))
             (lits (when (>= lit-k 2)
                     (let ((v (make-array lit-k)))
                       (dotimes (k lit-k v)
                         (setf (aref v k)
                               (build-etree (lit-slice litf k) 256 15)))))))
        (b:wbits w 0 1) (b:wbits w 0 1) (b:wbits w 0 1)   ; NBLTYPES L/I/D = 1
        (b:wbits w 0 2)                                   ; NPOSTFIX=0
        (b:wbits w 0 4)                                   ; NDIRECT=0
        (if (= lit-k 1)
            (b:wbits w 0 2)                               ; context mode (unused)
            (b:wbits w 2 2))                              ; context mode 2 = UTF8
        (if (= lit-k 1)
            (b:wbits w 0 1)                               ; NTREESL=1
            (write-nbltypes w lit-k))
        (when (>= lit-k 2)
          (write-lit-context-map w lit-cmap lit-k))       ; before NTREESD
        (b:wbits w 0 1)                                   ; NTREESD=1
        (if (= lit-k 1)
            (write-etree w lit 256)
            (dotimes (k lit-k)
              (write-etree w (aref lits k) 256)))
        (write-etree w cmd 704)
        (write-etree w dist 64)
        ;; Hoist the per-tree slot reads and the "single symbol" tests out of
        ;; the per-command loop.  Literal-heavy blocks otherwise re-read four
        ;; slots and re-test a branch for every literal.
        (let ((cmd-single (etree-single cmd))
              (lit-single (and lit (etree-single lit)))
              (dist-single (etree-single dist))
              (cmd-rc (or (etree-rcodes cmd) +empty-fixnums+))
              (cmd-ln (or (etree-lengths cmd) +empty-fixnums+))
              (lit-rc (or (and lit (etree-rcodes lit)) +empty-fixnums+))
              (lit-ln (or (and lit (etree-lengths lit)) +empty-fixnums+))
              (lit-rcl (when (>= lit-k 2)
                         (let ((v (make-array lit-k)))
                           (dotimes (k lit-k v)
                             (setf (aref v k)
                                   (or (etree-rcodes (aref lits k))
                                       +empty-fixnums+))))))
              (lit-lnl (when (>= lit-k 2)
                         (let ((v (make-array lit-k)))
                           (dotimes (k lit-k v)
                             (setf (aref v k)
                                   (or (etree-lengths (aref lits k))
                                       +empty-fixnums+))))))
              (lit-sng (when (>= lit-k 2)
                         (let ((v (make-array lit-k :initial-element nil)))
                           (dotimes (k lit-k v)
                             (setf (aref v k)
                                   (etree-single (aref lits k)))))))
              (dist-rc (or (etree-rcodes dist) +empty-fixnums+))
              (dist-ln (or (etree-lengths dist) +empty-fixnums+))
              (slack 0))
          (declare (type (simple-array fixnum (*))
                         cmd-rc cmd-ln lit-rc lit-ln dist-rc dist-ln)
                   (type fixnum slack))
          (dotimes (k ncmd)
            (let ((b (* k +cmd-stride+)))
              (declare (type fixnum b))
              (let ((ins (aref recs b))
                    (ls (aref recs (+ b 1))))
                (declare (type fixnum ins ls))
                ;; One capacity check covers every bit this command can emit:
                ;; at most ~13 bytes of command/distance overhead plus two
                ;; bytes per literal (code lengths are <= 15 bits), plus the
                ;; eight-byte slack the raw writer needs for its final store.
                ;; Reserve 64 KiB at a time instead of checking per command.
                (let ((cost (+ 24 (* 2 ins))))
                  (declare (type fixnum cost))
                  (when (> cost slack)
                    (setf slack 65536)
                    (b:w-ensure w (+ slack cost)))
                  (decf slack cost))
                (unless cmd-single
                  (b:%wbits-raw w (aref cmd-rc (aref recs (+ b 2)))
                                (aref cmd-ln (aref recs (+ b 2)))))
                (b:%wbits-raw-pm w (aref recs (+ b 3)) (aref recs (+ b 4)))
                (b:%wbits-raw-pm w (aref recs (+ b 5)) (aref recs (+ b 6)))
                (if (>= lit-k 2)
                    (loop for i of-type fixnum from ls below (+ ls ins)
                          do (let* ((sym (aref data i))
                                    (p1 (if (plusp i) (aref data (1- i)) 0))
                                    (p2 (if (> i 1) (aref data (- i 2)) 0))
                                    (cid (aref lit-cmap
                                               (logior (aref +lut0+ p1)
                                                       (aref +lut1+ p2)))))
                               (declare (type fixnum sym p1 p2 cid))
                               (unless (aref lit-sng cid)
                                 (b:%wbits-raw w (aref (aref lit-rcl cid) sym)
                                               (aref (aref lit-lnl cid) sym)))))
                    (unless lit-single
                      ;; Long runs amortize the pin/state setup of the run
                      ;; writer; short runs are cheaper inline.
                      (if (>= ins 16)
                          (b:w-emit-run w data ls (+ ls ins) lit-rc lit-ln)
                          (loop for i from ls below (+ ls ins)
                                do (let ((sym (aref data i)))
                                     (b:%wbits-raw w (aref lit-rc sym)
                                                   (aref lit-ln sym)))))))
                (let ((dcode (aref recs (+ b 7))))
                  (declare (type fixnum dcode))
                  (when (>= dcode 0)
                    (unless dist-single
                      (b:%wbits-raw w (aref dist-rc dcode)
                                    (aref dist-ln dcode)))
                    (b:%wbits-raw-pm w (aref recs (+ b 8))
                                     (aref recs (+ b 9))))))))))))

(defun command-output-length (cmd)
  (+ (first cmd) (third cmd)))

(defun split-copy-length (cpy space)
  "Split CPY into (values A B) with A+B=CPY, A<=SPACE, and each part either
zero or a valid Brotli copy length (>=2)."
  (cond
    ((< cpy 2) (error "invalid copy length ~D" cpy))
    ((and (>= space 2) (>= (- cpy space) 2))
     (values space (- cpy space)))
    ((and (>= space 2) (= (- cpy space) 1))
     (if (>= (1- space) 2)
         (values (1- space) 2)
         (values 0 cpy)))
    (t
     (values 0 cpy))))

(defun split-command-at (cmd space)
  "Split CMD so the first piece produces at most SPACE bytes.  Returns
\(values FIRST REST); FIRST may be NIL when a dictionary command cannot be
split and the current meta-block must be closed first."
  (destructuring-bind (ins lit-start cpy dist dictp) cmd
    (let ((out (+ ins cpy)))
      (cond
        ((<= out space)
         (values cmd nil))
        ((>= ins space)
         (values (list space lit-start 0 0 nil)
                 (list (- ins space) (+ lit-start space) cpy dist dictp)))
        (t
         (cond
           (dictp
            (if (plusp ins)
                (values (list ins lit-start 0 0 nil)
                        (list 0 0 cpy dist dictp))
                (values nil cmd)))
           (t
            (multiple-value-bind (first-copy rest-copy)
                (split-copy-length cpy (- space ins))
              (cond
                ((and (zerop ins) (zerop first-copy))
                 (values nil cmd))
                ((zerop first-copy)
                 (values (list ins lit-start 0 0 nil)
                         (list 0 0 rest-copy dist nil)))
                (t
                 (values (list ins lit-start first-copy dist nil)
                         (list 0 0 rest-copy dist nil))))))))))))

(defun partition-commands (cmds limit)
  "Partition CMDS into meta-blocks whose total output length is <= LIMIT.
Normal copies and literal runs may be split; dictionary copies are kept
whole and moved to the next block when necessary."
  (let ((blocks '()) (current '()) (used 0))
    (flet ((finish ()
             (when current
               (push (nreverse current) blocks)
               (setf current '() used 0))))
      (dolist (cmd cmds)
        (loop
          (let ((space (- limit used)))
            (cond
              ((zerop space) (finish))
              (t
               (multiple-value-bind (first rest)
                   (split-command-at cmd space)
                 (cond
                   (first
                    (push first current)
                    (incf used (command-output-length first))
                    (if rest
                        (setf cmd rest)
                        (return)))
                   ((plusp (length current))
                    (finish))
                   (t
                    (error "command does not fit an empty meta-block")))))))))
      (finish))
    (nreverse blocks)))

(defun compress-entropy (input &key (use-dict nil) (dict-limit nil)
                                    (max-chain 128) (lazy t) (short-dist t)
                                    (skip-match nil) (insert-interior t)
                                    (fast-fragment nil)
                                    (trivial nil)
                                    (max-lit-bits 15)
                                    (score-p nil) (checks 1)
                                    (quality 5))
  "Entropy-coded brotli stream for INPUT.  Inputs larger than one meta-block
are split into <= 2^24-byte compressed meta-blocks followed by an empty last
meta-block."
  (let* ((data (b:to-octets input))
         (n (length data))
         (w (b:make-bwr (min (+ n 1024) 65536)))
         (wbits (min 24 (max 10 (integer-length (max 1 n)))))
         (window (- (ash 1 wbits) 16))
         (rb (make-array 5 :element-type 'fixnum
                          :initial-contents '(16 15 11 4 4))))
    (write-wbits w wbits)
    (cond
      ((zerop n)
       (b:wbits w 1 1) (b:wbits w 1 1))                    ; ISLAST + ISLASTEMPTY
      ((<= n #.(ash 1 24))
       (write-mlen-header w n t)
       (cond
         (fast-fragment
          (multiple-value-bind (cv nc litf cmdf distf)
              (lz77 data window
                     :max-chain max-chain :lazy nil :skip-match t
                     :use-dict nil :insert-interior nil)
            (write-fast-block-body w data cv nc litf cmdf distf)))
         (trivial
          (write-trivial-block-body
           w data
           (lz77 data window :use-dict use-dict :dict-limit dict-limit
                          :base-pos 0 :max-chain max-chain :lazy lazy
                          :skip-match skip-match
                          :insert-interior insert-interior)
           rb :short-dist short-dist
              :max-lit-bits max-lit-bits))
         (t
          (write-compressed-block-body w data 0 window use-dict dict-limit rb
                                       :max-chain max-chain :lazy lazy
                                       :short-dist short-dist
                                       :skip-match skip-match
                                       :insert-interior insert-interior
                                       :score-p score-p :checks checks
                                       :quality quality))))
      (t
       (let* ((mb-chain (if fast-fragment 32 max-chain))
              (mb-lazy (if fast-fragment t lazy))
              (mb-skip (if fast-fragment nil skip-match))
              (mb-interior (if fast-fragment t insert-interior))
              (cmds (lz77 data window :use-dict use-dict
                                   :dict-limit dict-limit :base-pos 0
                                   :max-chain mb-chain :lazy mb-lazy
                                   :skip-match mb-skip
                                   :insert-interior mb-interior
                                   :score-p score-p :checks checks))
              (remaining (partition-commands cmds #.(ash 1 24)))
              (pos 0))
         (loop while remaining do
           (let* ((block (pop remaining))
                  (lastp (null remaining))
                  (outlen (reduce #'+ block :key #'command-output-length
                                        :initial-value 0)))
             (write-mlen-header w outlen lastp)
             (if trivial
                 (write-trivial-block-body w data block rb
                                           :short-dist short-dist
                                           :max-lit-bits max-lit-bits)
                 (write-compressed-block-body w data 0 window use-dict dict-limit
                                              rb :max-chain max-chain
                                                 :lazy lazy :short-dist short-dist
                                                 :skip-match skip-match
                                                 :insert-interior insert-interior
                                                 :quality quality
                                                 :cmds block))
             (incf pos outlen)))
         (unless (= pos n)
           (error "multi-block encoder produced ~D bytes, expected ~D" pos n)))))
    (b:w-align w)
    (b:bwr-result w)))

(defun incompressible-p (data)
  "Cheap sample check: lots of distinct bytes, no dominant byte, and almost no
repeated 4-byte sequences means the entropy coder is unlikely to beat a stored
meta-block.  The 4-byte test is important: a periodic ramp has 256 distinct
byte values and a flat byte distribution, but repeats every 4-byte window and
compresses extremely well."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (optimize (speed 3) (safety 0)))
  (let* ((n (length data))
         (sample (min n 16384))
         (seen (make-array 256 :initial-element 0))
         (unique 0) (maxfreq 0))
    (when (< sample 4) (return-from incompressible-p nil))
    (dotimes (i sample)
      (let* ((b (aref data i)) (c (1+ (aref seen b))))
        (setf (aref seen b) c)
        (when (= c 1) (incf unique))
        (when (> c maxfreq) (setf maxfreq c))))
    (and (> unique 230)
         (< maxfreq (/ sample 10))
         ;; A 2^21-bit hashed set: equal 4-byte keys collide exactly, and
         ;; the false-collision rate for 16K keys is ~64, below the
         ;; acceptance threshold.  Far cheaper than an EQL hash table.
         (let ((bits (make-array (ash 1 16) :element-type '(unsigned-byte 8)
                                 :initial-element 0))
               (duplicates 0))
           (declare (type (simple-array (unsigned-byte 8) (65536)) bits)
                    (type fixnum duplicates))
           (loop for i from 0 below (- sample 3) by 4 do
             (let* ((key (dict-key4 data i))
                    (h (logand (* key #x9E3779B1) #x7FFFF))
                    (byte (ash h -3))
                    (mask (ash 1 (logand h 7))))
               (declare (type fixnum key h byte mask))
               (if (logtest (aref bits byte) mask)
                   (incf duplicates)
                   (setf (aref bits byte) (logior (aref bits byte) mask)))))
           (< duplicates (max 16 (/ sample 100)))))))

(defun quality-params (quality)
  "Encoder effort settings for QUALITY 0..11.  q0/q1 use the C-style
fast-fragment matcher; q2-q4 use the greedy chain with the trivial entropy
writer; q5-q11 add lazy matching, widen the chain, and enable the static
dictionary at q10/q11."
  (case quality
    ;; Quality 0 is the fast path, not raw stored blocks: stored would be
    ;; ~30x larger than C q0 on text-like data.  The stored fallback is still
    ;; used whenever entropy coding cannot beat the input size.
    (0 '(:max-chain 1 :lazy nil :use-dict nil :short-dist nil :skip-match t
          :insert-interior nil :fast-fragment t))
    ;; C's q1 (compress_fragment_two_pass) uses a 128K-entry table with a
    ;; 6-byte minimum match; with max-chain 2 the fragment dispatcher selects
    ;; table-bits 17 / min-match 6.  max-chain 1 gave q1 the same 15-bit/5-byte
    ;; table as q0, producing byte-identical output and a 5-13% ratio loss.
    (1 '(:max-chain 2 :lazy nil :use-dict nil :short-dist nil :skip-match t
          :insert-interior nil :fast-fragment t))
    (2 '(:max-chain 3 :lazy nil :use-dict nil :short-dist nil :skip-match t
          :insert-interior nil :trivial t :max-lit-bits 15))
    (3 '(:max-chain 5 :lazy nil :use-dict nil :short-dist nil :skip-match t
          :insert-interior nil :trivial t :max-lit-bits 15))
    (4 '(:max-chain 10 :lazy nil :use-dict nil :short-dist nil :skip-match t
          :insert-interior nil :trivial t :max-lit-bits 15))
    ;; Score machinery is enabled where its measured trade fits: q5/q6
    ;; (-14% speed for -1.5% size at q5, and q5 is the 10%-cap violator)
    ;; and q10/q11 (17-20x speed headroom, sizes 13-21% over C).  q7/q8/q9
    ;; run WITHOUT it: the score-accepted best-len stays below the greedy
    ;; max, which weakens probe-ok and blows up mlen scans (+26..137% with
    ;; long chains) — measured -25% speed for -1.2% size at q7, -25% for
    ;; -1.0% at q9 (json q9 even grew 477 B), outside the recorded 5-15%
    ;; envelope at levels whose sizes are already inside the cap.
    ;; See GAP-ANALYSIS for the full per-level table.
    (5 '(:max-chain 6 :lazy t :use-dict nil :short-dist t :quality 5
          :score-p t :checks 4))
    (6 '(:max-chain 8 :lazy t :use-dict nil :short-dist t :quality 6
          :score-p t :checks 4))
    (7 '(:max-chain 24 :lazy t :use-dict nil :short-dist t :quality 7))
    (8 '(:max-chain 32 :lazy t :use-dict nil :short-dist t :quality 8))
    (9 '(:max-chain 128 :lazy t :use-dict nil :short-dist t :quality 9))
    (10 '(:max-chain 256 :lazy t :use-dict t :short-dist t :quality 10
           :score-p t :checks 16))
    (t '(:max-chain 512 :lazy t :use-dict t :short-dist t :quality 11
          :score-p t :checks 16))))

(defun %compress-bytes (data n params)
  "The COMPRESS selection (entropy candidates plus stored fallback),
returning fresh octets.  Shared by COMPRESS and COMPRESS-INTO."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum n)
           (type list params))
  (if (or (eq (getf params :mode) :stored) (incompressible-p data))
        (compress-stored data)
        (let* ((max-chain (getf params :max-chain 128))
               (lazy (getf params :lazy t))
               (short-dist (getf params :short-dist t))
               (skip-match (getf params :skip-match nil))
               (insert-interior (getf params :insert-interior t))
               (fast-fragment (getf params :fast-fragment nil))
               (trivial (getf params :trivial nil))
               (max-lit-bits (getf params :max-lit-bits 15))
               (score-p (getf params :score-p nil))
               (checks (getf params :checks 1))
               (quality (getf params :quality 5))
               (dict-ok (and (getf params :use-dict) (text-like-data-p data)))
               ;; Run the dictionary parse first.  For normal text it is
               ;; equal to or better than the plain parse, and re-running the
               ;; whole matcher just to compare doubled q10/q11 time and
               ;; allocation.  Tiny outputs can still lose (e.g. a tiled
               ;; dictionary test vector), so keep the plain parse there.
               (best (if dict-ok
                         (compress-entropy data :use-dict t
                                                :max-chain max-chain
                                                :lazy lazy
                                                :short-dist short-dist
                                                :skip-match skip-match
                                                :insert-interior insert-interior
                                                :fast-fragment fast-fragment
                                                :trivial trivial
                                                :max-lit-bits max-lit-bits
                                                :score-p score-p
                                                :checks checks
                                                :quality quality)
                         (compress-entropy data :use-dict nil
                                                :max-chain max-chain
                                                :lazy lazy
                                                :short-dist short-dist
                                                :skip-match skip-match
                                                :insert-interior insert-interior
                                                :fast-fragment fast-fragment
                                                :trivial trivial
                                                :max-lit-bits max-lit-bits
                                                :score-p score-p
                                                :checks checks
                                                :quality quality))))
          (when (and dict-ok (< (length best) 4096))
            (let ((plain (compress-entropy data :use-dict nil
                                                :max-chain max-chain
                                                :lazy lazy
                                                :short-dist short-dist
                                                :skip-match skip-match
                                                :insert-interior insert-interior
                                                :fast-fragment fast-fragment
                                                :trivial trivial
                                                :max-lit-bits max-lit-bits
                                                :score-p score-p
                                                :checks checks
                                                :quality quality)))
              (when (< (length plain) (length best)) (setf best plain))))
          (when (>= (length best) (+ n 32))
            (let ((stored (compress-stored data)))
              (when (< (length stored) (length best)) (setf best stored))))
          best)))

(defun compress (input &key (quality 11))
  "Compress INPUT to a brotli stream.  QUALITY is an effort level 0..11:
0-1 use the fast-fragment matcher, 2-4 a short greedy hash chain with the
trivial entropy writer, and high levels use lazy matching, a wider chain, and
dictionary-assisted matching.  The stored fallback is only built when the
entropy-coded candidates are not already smaller than the input."
  (let* ((data (b:to-octets input))
         (n (length data))
         (params (quality-params quality)))
    (%compress-bytes data n params)))

(defun compress-into (input output &key (start 0) (end (length output))
                                     (quality 11))
  "Compress INPUT into OUTPUT[START..END), writing bytes in place without
allocating the result.  Returns the end offset.  Size OUTPUT with
(MAX-COMPRESSED-SIZE (LENGTH INPUT)); smaller buffers signal
BROTLI-OUTPUT-OVERFLOW.  Stored (incompressible) inputs encode directly into
OUTPUT; entropy-coded inputs use a bounded temporary that is copied once."
  (check-type output (simple-array (unsigned-byte 8) (*)))
  (check-type start fixnum) (check-type end fixnum)
  (assert (<= 0 start end (length output)) (start end)
          "brotli: invalid output range ~D..~D for ~D bytes" start end
          (length output))
  (let* ((data (b:to-octets input))
         (n (length data))
         (params (quality-params quality)))
    (if (or (eq (getf params :mode) :stored) (incompressible-p data))
        (let ((w (b:make-bwr-into output start end)))
          (compress-stored data :w w)
          (b:bwr-pos w))
        (let ((best (%compress-bytes data n params)))
          (let ((len (length best)))
            (when (> (+ start len) end)
              (error 'brotli-output-overflow
                     :msg (format nil "brotli: output buffer too small (needs ~D bytes)"
                                  (+ start len))
                     :needed (+ start len)))
            (replace output best :start1 start)
            (+ start len))))))
