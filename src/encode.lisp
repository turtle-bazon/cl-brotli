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

;; q10/q11 literal context modeling (HQ-CONTEXT-MAP) and its cost model.
(defvar *hq-context-modeling* t)
;; From q9: there the encoder has speed headroom over C (1.0-2.4x) and the
;; clustered map beats C's static maps (binary q9 1.065 -> 1.011 of C's
;; size); at q5-q7 it would cost up to +66% time on binary input.
(defvar *hq-min-quality* 9)
(defvar *hq-tree-bits-per-symbol* 4.0d0)
(defvar *hq-tree-bits-base* 30.0d0)


;;; ---- per-call array arena ---------------------------------------------
;;; The writers build dozens of small code tables per call (code lengths,
;;; canonical and reversed codes: 64-704 fixnums each).  For a fast call
;;; (1 MiB of repetitive input in ~100 us) their ~40 KiB of fresh pages are
;;; a measurable share, and garbage either way.  A MAKE-COMPRESSOR closure
;;; binds *ARENA* for each call: vectors come from its free lists (zeroed
;;; on reuse) and all return there when the call ends, so nothing handed
;;; out may outlive the call.  Without an arena (plain COMPRESS) these are
;;; ordinary fresh vectors.

(defstruct (arena (:constructor make-arena ()))
  (free (make-hash-table :test 'eql) :type hash-table)
  (used nil :type list)
  (free-u64 (make-hash-table :test 'eql) :type hash-table)
  (used-u64 nil :type list)
  (free-sv (make-hash-table :test 'eql) :type hash-table)
  (used-sv nil :type list))

(defvar *arena* nil
  "The running MAKE-COMPRESSOR call's ARENA, or NIL (thread-local binding).")

(defun arena-fixnums (n)
  "A zero-filled (SIMPLE-ARRAY FIXNUM (N)), from *ARENA* when one is bound."
  (declare (type fixnum n) (optimize (speed 3) (safety 0)))
  (let ((a *arena*))
    (if (null a)
        (make-array n :element-type 'fixnum :initial-element 0)
        (let* ((free (arena-free a))
               (lst (gethash n free))
               (v (if lst
                      (progn (setf (gethash n free) (cdr lst))
                             (fill (the (simple-array fixnum (*)) (car lst)) 0))
                      (make-array n :element-type 'fixnum :initial-element 0))))
          (push v (arena-used a))
          v))))

(defun arena-u64s (n)
  "A zero-filled (SIMPLE-ARRAY (UNSIGNED-BYTE 64) (N)), from *ARENA* when one
is bound."
  (declare (type fixnum n) (optimize (speed 3) (safety 0)))
  (let ((a *arena*))
    (if (null a)
        (make-array n :element-type '(unsigned-byte 64) :initial-element 0)
        (let* ((free (arena-free-u64 a))
               (lst (gethash n free))
               (v (if lst
                      (progn (setf (gethash n free) (cdr lst))
                             (fill (the (simple-array (unsigned-byte 64) (*)) (car lst)) 0))
                      (make-array n :element-type '(unsigned-byte 64) :initial-element 0))))
          (push v (arena-used-u64 a))
          v))))

(defun arena-svec (n)
  "A SIMPLE-VECTOR of N zeros, from *ARENA* when one is bound (cleared again
on release, so it never keeps the caller's arrays alive)."
  (declare (type fixnum n) (optimize (speed 3) (safety 0)))
  (let ((a *arena*))
    (if (null a)
        (make-array n :initial-element 0)
        (let* ((free (arena-free-sv a))
               (lst (gethash n free))
               (v (if lst
                      (progn (setf (gethash n free) (cdr lst)) (car lst))
                      (make-array n :initial-element 0))))
          (push v (arena-used-sv a))
          v))))

(defun arena-release (a)
  "Return every vector handed out during the call to A's free lists."
  (declare (type arena a))
  (let ((free (arena-free a)))
    (dolist (v (arena-used a))
      (push v (gethash (length (the (simple-array fixnum (*)) v)) free)))
    (setf (arena-used a) nil))
  (let ((free (arena-free-u64 a)))
    (dolist (v (arena-used-u64 a))
      (push v (gethash (length (the (simple-array (unsigned-byte 64) (*)) v)) free)))
    (setf (arena-used-u64 a) nil))
  (let ((free (arena-free-sv a)))
    (dolist (v (arena-used-sv a))
      (fill (the simple-vector v) 0)
      (push v (gethash (length (the simple-vector v)) free)))
    (setf (arena-used-sv a) nil)))

;;; ---- canonical code construction --------------------------------------

(defun canonical-codes (lengths n)
  "Codes per symbol for code LENGTHS, matching BUILD-HUFF/READ-HUFF (codes are
emitted MSB-first; DEFLATE canonical assignment)."
  (declare (type (simple-array fixnum (*)) lengths) (type fixnum n)
           (optimize (speed 3) (safety 0)))
  (let ((count (make-array (1+ +max-bits+) :element-type 'fixnum
                           :initial-element 0))
        (next (make-array (1+ +max-bits+) :element-type 'fixnum
                          :initial-element 0))
        (codes (arena-fixnums n)))
    (declare (type (simple-array fixnum (16)) count next)
             (type (simple-array fixnum (*)) codes)
             (dynamic-extent count next))
    (dotimes (s n) (let ((l (aref lengths s))) (declare (type (integer 0 15) l)) (when (plusp l) (incf (aref count l)))))
    (let ((code 0))
      (declare (type fixnum code))
      (loop for bits of-type fixnum from 1 to +max-bits+ do
        (setf code (ash (+ code (aref count (1- bits))) 1)
              (aref next bits) code)))
    (dotimes (s n)
      (let ((l (aref lengths s)))
        (declare (type (integer 0 15) l))
        (when (plusp l) (setf (aref codes s) (aref next l)) (incf (aref next l)))))
    codes))

(defun canonical-rcodes (lengths n)
  "CANONICAL-CODES and REVERSED-CODES in one pass: each symbol's code bit-
reversed (the LSB-first emission order)."
  (declare (type (simple-array fixnum (*)) lengths) (type fixnum n)
           (optimize (speed 3) (safety 0)))
  (let ((count (make-array (1+ +max-bits+) :element-type 'fixnum
                           :initial-element 0))
        (next (make-array (1+ +max-bits+) :element-type 'fixnum
                          :initial-element 0))
        (r (arena-fixnums n)))
    (declare (type (simple-array fixnum (16)) count next)
             (type (simple-array fixnum (*)) r)
             (dynamic-extent count next))
    (dotimes (s n) (let ((l (aref lengths s))) (declare (type (integer 0 15) l)) (when (plusp l) (incf (aref count l)))))
    (let ((code 0))
      (declare (type fixnum code))
      (loop for bits of-type fixnum from 1 to +max-bits+ do
        (setf code (ash (+ code (aref count (1- bits))) 1)
              (aref next bits) code)))
    (dotimes (s n r)
      (let ((l (aref lengths s)))
        (declare (type (integer 0 15) l))
        (when (plusp l)
          (setf (aref r s) (%reverse-bits (aref next l) l))
          (incf (aref next l)))))))

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
    (declare (type fixnum level p) (type boolean ok) (dynamic-extent stack))
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
             (type (simple-array fixnum (*)) il rv depth)
             ;; scratch only (written before read, never escapes): on the
             ;; stack instead of ~30 KB of garbage per tree
             (dynamic-extent tc il rv depth))
    ;; C retries with a doubled minimum while any leaf exceeds MAXBITS
    ;; (the count-limit clamp flattens the histogram until the tree fits).
    (do ((count-limit 1 (* 2 count-limit)))
        (nil)
      (declare (type (integer 1 #.(ash 1 31)) count-limit))
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
             (arena-fixnums n)))
          ((= 1 nnz)
           (let ((r (arena-fixnums n)))
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
                          ;; u32 wrap-around, as C's uint32_t sum (a
                          ;; sentinel operand overflows; never selected)
                          (setf (aref tc jend)
                                (logand (+ (aref tc left) (aref tc right))
                                        #xFFFFFFFF)
                                (aref il jend) left
                                (aref rv jend) right)
                          ;; re-add the sentinel one slot below jend
                          (setf (aref tc (+ jend 1)) #xFFFFFFFF
                                (aref il (+ jend 1)) -1
                                (aref rv (+ jend 1)) -1)))))))
        ;; depth walk; on failure the DO retries with the doubled clamp
        (when (%huf-set-depth (- (* 2 nnz) 1) tc il rv depth maxbits)
          (let ((r (arena-fixnums n)))
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

(deftable +empty-fixnums+ (make-array 0 :element-type 'fixnum))
(declaim (type (simple-array fixnum (*)) +empty-fixnums+))

(declaim (inline reverse-code))
(defun reverse-code (code len)
  "Reverse the low LEN bits of CODE.  The canonical codes are MSB-first but
the bit writer is LSB-first; precomputing the reversal lets ETREE-EMIT issue
one WBITS call per symbol instead of one per bit.  (Code lengths are <= 15:
the decoder's two-byte table reversal.)"
  (declare (type (unsigned-byte 16) code) (type (integer 0 16) len)
           (optimize (speed 3) (safety 0)))
  (%reverse-bits code len))

(defun reversed-codes (codes lengths size)
  (declare (type (simple-array fixnum (*)) codes lengths) (type fixnum size)
           (optimize (speed 3) (safety 0)))
  (let ((r (arena-fixnums size)))
    (dotimes (s size r)
      (let ((len (aref lengths s)))
        (declare (type (integer 0 15) len))
        (when (plusp len)
          (setf (aref r s) (reverse-code (aref codes s) len)))))))

(defun optimize-counts-for-rle (counts length)
  "C BrotliOptimizeHuffmanCountsForRle (q4+ histograms, BrotliOptimize-
Histograms): smooth COUNTS[0..LENGTH) in place so the code lengths form
runs the tree header's repeat codes compress; small or sparse histograms
are left alone.  (Counts are histogram entries, < 2^32; every intermediate
is typed - the untyped version spent most of its time in generic >=,
FLOOR and + calls.)"
  (declare (type (simple-array fixnum (*)) counts) (type (integer 0 1024) length)
           (optimize (speed 3) (safety 0)))
  (macrolet ((cnt (i) `(the (unsigned-byte 32) (aref counts ,i))))
    (let ((nonzero-count (let ((c 0))
                           (declare (type fixnum c))
                           (dotimes (i length c) (when (plusp (cnt i)) (incf c)))))
          (streak-limit 1240))
      (declare (type fixnum nonzero-count streak-limit))
      (when (< nonzero-count 16)
        (return-from optimize-counts-for-rle counts))
      (loop while (and (/= length 0) (zerop (cnt (1- length))))
            do (decf length))
      (when (zerop length)
        (return-from optimize-counts-for-rle counts))
      (let ((nonzeros 0) (smallest (ash 1 32)))
        (declare (type fixnum nonzeros) (type (unsigned-byte 33) smallest))
        (dotimes (i length)
          (let ((c (cnt i)))
            (when (/= c 0)
              (incf nonzeros)
              (setf smallest (min smallest c)))))
        (when (< nonzeros 5)
          (return-from optimize-counts-for-rle counts))
        (when (< smallest 4)
          (when (< (- length nonzeros) 6)
            (loop for i of-type fixnum from 1 below (1- length) do
              (when (and (/= (cnt (1- i)) 0) (zerop (cnt i))
                         (/= (cnt (1+ i)) 0))
                (setf (aref counts i) 1)))))
        (when (< nonzeros 28)
          (return-from optimize-counts-for-rle counts)))
      ;; mark the runs that already RLE-encode well
      (let ((good (make-array 1025 :element-type 'bit :initial-element 0)))
        (declare (dynamic-extent good))
        (let ((symbol (cnt 0)) (step 0))
          (declare (type (unsigned-byte 32) symbol) (type fixnum step))
          (loop for i of-type fixnum from 0 to length do
            (if (or (= i length) (/= (cnt i) symbol))
                (progn
                  (when (or (and (zerop symbol) (>= step 5))
                            (and (/= symbol 0) (>= step 7)))
                    (dotimes (k step) (setf (aref good (- i k 1)) 1)))
                  (setf step 1)
                  (when (/= i length) (setf symbol (cnt i))))
                (incf step))))
        ;; replace counts that lead to more RLE codes (24.8 fixed point)
        (let ((stride 0)
              (limit (+ (floor (* 256 (+ (cnt 0) (cnt 1) (cnt 2))) 3) 420))
              (sum 0))
          (declare (type fixnum stride)
                   (type (unsigned-byte 52) limit sum))
          (loop for i of-type fixnum from 0 to length do
            (when (or (= i length) (= (aref good i) 1)
                      (and (/= i 0) (= (aref good (1- i)) 1))
                      ;; C's size_t test: |256 c - limit| >= streak-limit
                      (let ((d (+ (- (* 256 (cnt i)) limit) streak-limit)))
                        (declare (type (signed-byte 60) d))
                        (or (< d 0) (>= d (* 2 streak-limit)))))
              (when (or (>= stride 4) (and (>= stride 3) (zerop sum)))
                (let ((count (max 1 (floor (+ sum (floor stride 2)) stride))))
                  (declare (type (unsigned-byte 52) count))
                  (when (zerop sum) (setf count 0))
                  (dotimes (k stride)
                    (setf (aref counts (- i k 1)) count))))
              (setf stride 0 sum 0)
              (setf limit
                    (cond ((< i (- length 2))
                           (+ (floor (* 256 (+ (cnt i) (cnt (+ i 1)) (cnt (+ i 2)))) 3)
                              420))
                          ((< i length) (* 256 (cnt i)))
                          (t 0))))
            (incf stride)
            (when (/= i length)
              (incf sum (cnt i))
              (when (>= stride 4)
                (setf limit (floor (+ (* 256 sum) (floor stride 2)) stride)))
              (when (= stride 4)
                (incf limit 120))))))
      counts)))

(defun build-etree (freqs size maxbits &optional rle-optimize)
  "Prefix code for FREQS[0..SIZE) (C BuildAndStoreHuffmanTree's choice):
one symbol -> single, 2-4 -> simple code (C's depths, symbols ordered by
depth), else complex.  RLE-OPTIMIZE (q4+ literal / command / distance
histograms) first applies C's BrotliOptimizeHuffmanCountsForRle to a copy."
  (declare (type (simple-array fixnum (*)) freqs) (type fixnum size maxbits))
  (let* ((nnz (let ((c 0))
                (declare (type fixnum c) (optimize (speed 3) (safety 0)))
                (dotimes (s size c) (when (plusp (aref freqs s)) (incf c)))))
         ;; the symbol list only where it is used (single / simple codes)
         (nz (when (<= nnz 4)
               (loop for s below size when (plusp (aref freqs s)) collect s))))
    (cond
      ((<= nnz 1)
       (make-etree :single (if nz (first nz) 0)))
      ((<= nnz 4)
       ;; C builds the depths with BrotliCreateHuffmanTree (2 -> 1 1,
       ;; 3 -> 1 2 2, 4 -> 2 2 2 2 or 1 2 3 3) and writes the symbols
       ;; sorted by depth (StoreSimpleHuffmanTree)
       (let* ((lengths (build-code-lengths-a freqs size maxbits))
              (sorted (stable-sort (copy-list nz) #'< :key (lambda (s) (aref lengths s)))))
         (make-etree :lengths lengths
                     :rcodes (canonical-rcodes lengths size)
                     :simple sorted)))
      (t
       (let* ((lengths (build-code-lengths-a
                        (if rle-optimize
                            (optimize-counts-for-rle
                             (replace (arena-fixnums (length freqs)) freqs) size)
                            freqs)
                        size maxbits)))
         (make-etree :lengths lengths
                     :rcodes (canonical-rcodes lengths size)))))))

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

(defun huffman-tree-rle (lengths length syms extras)
  "C BrotliWriteHuffmanTree: LENGTHS[0..LENGTH) as code-length symbols
\(0-15 literal, 16 repeat previous, 17 repeat zero) into SYMS with their
extra-bit values in EXTRAS (both >= LENGTH entries); returns the count.
Repeat codes chain (the decoder multiplies consecutive repeats), the
previous length starts at 8, and runs are coded only where C's
DecideOverRleUse finds them worthwhile (alphabets over 50)."
  (declare (type (simple-array fixnum (*)) lengths syms extras)
           (type fixnum length)
           (optimize (speed 3) (safety 0)))
  (let ((count 0) (prev 8) (n length) (rle-nonzero nil) (rle-zero nil))
    (declare (type fixnum count prev n) (type boolean rle-nonzero rle-zero))
    (loop while (and (> n 0) (zerop (aref lengths (1- n)))) do (decf n))
    (when (> length 50)
      ;; C DecideOverRleUse
      (let ((tz 0) (tnz 0) (cz 1) (cnz 1) (i 0))
        (declare (type fixnum tz tnz cz cnz i))
        (loop while (< i n) do
          (let ((v (aref lengths i)) (reps 1))
            (declare (type fixnum v reps))
            (loop for k of-type fixnum from (1+ i) below n
                  while (= (aref lengths k) v) do (incf reps))
            (when (and (>= reps 3) (zerop v)) (incf tz reps) (incf cz))
            (when (and (>= reps 4) (/= v 0)) (incf tnz reps) (incf cnz))
            (incf i reps)))
        (setf rle-nonzero (> tnz (* 2 cnz)) rle-zero (> tz (* 2 cz)))))
    (macrolet ((put (sym x)
                 `(progn (setf (aref syms count) ,sym (aref extras count) ,x)
                         (incf count))))
      (flet ((repeat-codes (code r bits)
               ;; R (>= 3) repetitions as a chain of CODE, most significant
               ;; digit first: C appends the digits then reverses them
               (declare (type fixnum code r bits))
               (let ((start count) (mask (1- (ash 1 bits))))
                 (declare (type fixnum start mask))
                 (decf r 3)
                 (loop (put code (logand r mask))
                       (setf r (ash r (- bits)))
                       (when (zerop r) (return))
                       (decf r))
                 (loop for i of-type fixnum from start
                       for j of-type fixnum downfrom (1- count)
                       while (< i j)
                       do (rotatef (aref extras i) (aref extras j))))))
        (let ((i 0))
          (declare (type fixnum i))
          (loop while (< i n) do
            (let ((v (aref lengths i)) (reps 1))
              (declare (type fixnum v reps))
              (when (if (zerop v) rle-zero rle-nonzero)
                (loop for k of-type fixnum from (1+ i) below n
                      while (= (aref lengths k) v) do (incf reps)))
              (incf i reps)
              (if (zerop v)
                  (progn
                    (when (= reps 11) (put 0 0) (decf reps))
                    (if (< reps 3)
                        (loop repeat reps do (put 0 0))
                        (repeat-codes 17 reps 3)))
                  (progn
                    (when (/= prev v) (put v 0) (decf reps))
                    (when (= reps 7) (put v 0) (decf reps))
                    (if (< reps 3)
                        (loop repeat reps do (put v 0))
                        (repeat-codes 16 reps 2))
                    (setf prev v))))))))
    count))

(defun write-complex-code (w lengths size)
  "C BrotliStoreHuffmanTree: the code lengths LENGTHS (>= 2 used symbols)
as code-length symbols under a code-length code built for them.  When
only one code-length symbol occurs (e.g. 256 literals all of length 8)
that code has a single 0-bit symbol: all 18 code-length-code lengths are
stored and the symbols themselves cost only their extra bits."
  (declare (type (simple-array fixnum (*)) lengths) (type fixnum size)
           (optimize (speed 3) (safety 0)))
  (let ((syms (make-array (max size 18) :element-type 'fixnum))
        (extras (make-array (max size 18) :element-type 'fixnum))
        (hist (make-array 18 :element-type 'fixnum :initial-element 0))
        (num-codes 0) (code 0))
    (declare (dynamic-extent syms extras hist)
             (type fixnum num-codes code))
    (let ((count (huffman-tree-rle lengths size syms extras)))
      (declare (type fixnum count))
      (dotimes (i count) (incf (aref hist (aref syms i))))
      (loop for i of-type fixnum below 18
            when (plusp (aref hist i))
              do (if (zerop num-codes)
                     (setf code i num-codes 1)
                     (progn (setf num-codes 2) (return))))
      (let* ((cll (build-code-lengths-a hist 18 5))
             (clcodes (canonical-codes cll 18))
             (skip (if (and (zerop (aref cll (aref +clcl-order+ 0)))
                            (zerop (aref cll (aref +clcl-order+ 1))))
                       (if (zerop (aref cll (aref +clcl-order+ 2))) 3 2)
                       0))
             (to-store (if (> num-codes 1)
                           (loop for k of-type fixnum from 18 downto 1
                                 when (plusp (aref cll (aref +clcl-order+ (1- k))))
                                   return k
                                 finally (return 0))
                           18)))
        (declare (type (simple-array fixnum (*)) cll clcodes)
                 (type fixnum skip to-store))
        (b:wbits w skip 2)
        (loop for i of-type fixnum from skip below to-store
              do (write-clcl-len w (aref cll (aref +clcl-order+ i))))
        (when (= num-codes 1) (setf (aref cll code) 0))
        ;; codes are canonical MSB-first: reverse once for the LSB-first
        ;; writer
        (dotimes (i count)
          (let* ((sym (aref syms i)) (len (aref cll sym)))
            (declare (type fixnum sym len))
            (when (plusp len)
              (b:wbits w (%reverse-bits (aref clcodes sym) len) len))
            (case sym
              (16 (b:wbits w (aref extras i) 2))
              (17 (b:wbits w (aref extras i) 3)))))))))

(defun write-simple-code (w symbols size &optional lengths)
  "Write a simple prefix code for 2-4 SYMBOLS (ordered by code length).
Four symbols: tree-select 1 (lengths 1 2 3 3) when the first has length 1
in LENGTHS, else 0 (all 2)."
  (b:wbits w 1 2)
  (b:wbits w (1- (length symbols)) 2)
  (let ((ab (alphabet-bits size)))
    (dolist (s symbols) (b:wbits w s ab)))
  (when (= (length symbols) 4)
    (b:wbits w (if (and lengths (= 1 (aref lengths (first symbols)))) 1 0) 1)))

(defun write-etree (w et size)
  (cond
    ((etree-single et)
     (b:wbits w 1 2)
     (b:wbits w 0 2)
     (b:wbits w (etree-single et) (alphabet-bits size)))
    ((etree-simple et)
     (write-simple-code w (etree-simple et) size (etree-lengths et)))
    (t
     (write-complex-code w (etree-lengths et) size))))

;;; ---- command / distance code computation ------------------------------

(deftable +celltab+ #(#(2 3 6) #(4 5 8) #(7 9 10)))   ; [ins-range][copy-range] -> cmd cell

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

(deftable +ins-lc+ (make-length-code-table +ins-base+ +ins-bits+ 4096))
(deftable +cpy-lc+ (make-length-code-table +cpy-base+ +cpy-bits+ 4096))

(deftable +ins-code+ (first +ins-lc+))
(deftable +ins-xval+ (second +ins-lc+))
(deftable +ins-xbits+ (third +ins-lc+))
(deftable +cpy-code+ (first +cpy-lc+))
(deftable +cpy-xval+ (second +cpy-lc+))
(deftable +cpy-xbits+ (third +cpy-lc+))
(declaim (type (simple-array fixnum (*))
               +ins-code+ +ins-xval+ +ins-xbits+
               +cpy-code+ +cpy-xval+ +cpy-xbits+))
(deftable +ins-xbits-f+
  (let ((v (make-array (length +ins-xbits+) :element-type 'single-float
                                             :initial-element 0.0f0)))
    (dotimes (i (length +ins-xbits+) v)
      (setf (aref v i) (float (aref +ins-xbits+ i) 1.0f0))))
  "Insert-length extra bits as single-float for the hot DP loops.")
(deftable +cpy-xbits-f+
  (let ((v (make-array (length +cpy-xbits+) :element-type 'single-float
                                             :initial-element 0.0f0)))
    (dotimes (i (length +cpy-xbits+) v)
      (setf (aref v i) (float (aref +cpy-xbits+ i) 1.0f0))))
  "Copy-length extra bits as single-float for the hot DP loops.")
(declaim (type (simple-array single-float (*)) +ins-xbits-f+ +cpy-xbits-f+))
(declaim (inline length-code1))
(defun length-code1 (len code code-n base)
  (declare (type (simple-array fixnum (*)) code)
           (type fixnum code-n len)
           (type simple-vector base)
           (optimize (speed 3) (safety 0)))
  (if (< len code-n)
      (aref code len)
      (loop for c from (1- (length base)) downto 0
            when (>= len (aref base c)) do (return c))))
(declaim (inline length-code-f))
(defun length-code-f (len code code-n xbits-f base bits)
  "Like LENGTH-CODE but returns the extra bit count as a single-float
(from XBITS-F in the tabled range, converted in the canonical
fallback); the extra value is not returned.  CODE-N is (LENGTH CODE),
bound by the caller: recomputing it per l-loop iteration reloaded the
table object's header tens of millions of times."
  (declare (type (simple-array fixnum (*)) code)
           (type fixnum code-n)
           (type simple-vector base bits)
           (type (simple-array single-float (*)) xbits-f)
           (type fixnum len)
           (optimize (speed 3) (safety 0)))
  (if (< len code-n)
      (values (aref code len) (aref xbits-f len))
      ;; THE: BASE/BITS are T vectors of fixnums; untyped elements made
      ;; this fallback (every length past the table: long copies) a
      ;; generic >= and a full call to %SINGLE-FLOAT per evaluation.
      (loop for c of-type fixnum from (1- (length base)) downto 0
            when (>= len (the fixnum (aref base c)))
              do (return (values c (float (the fixnum (aref bits c)) 1.0f0))))))
(declaim (inline length-code))
(defun length-code (len code xval xbits base bits)
  "Largest code C with BASE[C] <= LEN; returns (values C extra-val extra-bits).
Common lengths use the precomputed CODE/XVAL/XBITS; longer ones fall back to
the canonical search."
  (declare (type (simple-array fixnum (*)) code xval xbits)
           (type simple-vector base bits)
           (type fixnum len)
           (optimize (speed 3) (safety 0)))
  (if (< len (length code))
      (values (aref code len) (aref xval len) (aref xbits len))
      (loop for c of-type fixnum from (1- (length base)) downto 0
            when (>= len (the fixnum (aref base c)))
              do (return (values c (the (integer 0 #.(ash 1 40))
                                        (- len (the fixnum (aref base c))))
                                 (the (integer 0 24) (aref bits c)))))))

(deftable +cmd-symbol-table+
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
  ;; Codes are 0..23; undeclared, (* icode 24) was overflow-checked and the
  ;; index sum GENERIC-+ in every writer's per-command path.
  (declare (type (integer 0 23) icode ccode))
  (aref +cmd-symbol-table+ (+ (* icode 24) ccode)))

(declaim (inline cmd-symbol-dist0))
(defun cmd-symbol-dist0 (icode ccode)
  "Command symbol for the implicit-distance form.  Only valid for insert
codes 0..7 and copy codes 0..15 (command symbols 0..127)."
  (declare (type (integer 0 23) icode ccode))
  (+ (* (ash ccode -3) 64) (* icode 8) (logand ccode 7)))

(declaim (inline encode-distance))
(defun encode-distance (d)
  "Distance D (>=1) -> (values dcode dextra-val dextra-bits) for NPOSTFIX=NDIRECT=0.
The loop-free form partitions D by NBITS = INTEGER-LENGTH(D+4)-2."
  (declare (type (integer 1 #.(ash 1 40)) d))
  (let* ((nbits (- (integer-length (+ d 3)) 2))
         (b (if (>= d (- (* 3 (ash 1 nbits)) 3)) 1 0))
         (offset (- (ash (+ 2 b) nbits) 4)))
    (values (+ 16 (* 2 (1- nbits)) b) (- d offset 1) nbits)))

(declaim (inline special-distance-code))
(defun special-distance-code (rb d)
  "If D is one of the short distance-ring codes, return (values CODE 0 0).
RB is the 4-slot ring plus a write index in slot 4.  C ComputeDistanceCode:
at most six tests instead of trying all 15 candidates in turn (it ran twice
per command in every writer).  D equal to the last distance is the
caller's code 0 and never reaches here."
  (declare (type (simple-array fixnum (5)) rb) (type fixnum d)
           (optimize (speed 3) (safety 0)))
  (let* ((i (aref rb 4))
         (d0 (aref rb (logand (+ i 3) 3)))   ; last
         (d1 (aref rb (logand (+ i 2) 3)))   ; second-to-last
         (o0 (- (+ d 3) d0))
         (o1 (- (+ d 3) d1)))
    (declare (type fixnum i d0 d1 o0 o1))
    (cond ((= d d1) (values 1 0 0))
          ((and (<= 0 o0) (< o0 7) (/= o0 3))
           ;; last-3..last+3 -> 8 6 4 . 5 7 9
           (values (logand (ash #x9750468 (- (* 4 o0))) #xF) 0 0))
          ((and (<= 0 o1) (< o1 7))
           ;; second-3..second+3 -> 14 12 10 1 11 13 15
           (values (logand (ash #xFDB1ACE (- (* 4 o1))) #xF) 0 0))
          ((= d (aref rb (logand (+ i 1) 3))) (values 2 0 0))
          ((= d (aref rb (logand i 3))) (values 3 0 0))
          (t (values nil 0 0)))))

;;; ---- static dictionary index (base words, no transforms) ---------------

;; Flat dictionary index (counting-sort, like C's contiguous
;; dict_words): one packed fixnum per base word - (len << 10) |
;; word-index - in a single array, with bucket start offsets.  The old
;; cons-per-word hash buckets made every probe chase scattered cons
;; cells (~8% of html q10 in sb-sprof).
;; The whole dictionary index is ONE global word: a (flat . bstart)
;; cons cell published with a single SETF.  Readers therefore can never
;; observe one half without the other (the old *DICT-FLAT* +
;; *DICT-BSTART* pair was two separate stores, so a first concurrent
;; use could tear), and two racing builders each publish their own
;; self-consistent pair - the contents are deterministic, so which
;; pair a reader gets is irrelevant.  The dictionary VECTOR and its SAP
;; are not globals at all: they are snapshotted once per LZ77 run and
;; passed down as arguments (see LZ77).
(declaim (type (or null (cons (simple-array fixnum (*))
                              (simple-array fixnum (65537))))
               *dict-index*))
(defvar *dict-index* nil)

(declaim (inline dict-key4))
(defun dict-key4 (vec pos)
  (declare (type (simple-array (unsigned-byte 8) (*)) vec)
           (type fixnum pos)
           (optimize (speed 3) (safety 0)))
  (logior (aref vec pos) (ash (aref vec (1+ pos)) 8)
          (ash (aref vec (+ pos 2)) 16) (ash (aref vec (+ pos 3)) 24)))

(declaim (inline dict-bucket))
(defun dict-bucket (key)
  "2^16 bucket of KEY (C dictionary->buckets[Hash15(..)] style).  Bucket
collisions are safe: dict-match-at verifies the full word against input."
  (declare (type fixnum key) (optimize (speed 3) (safety 0)))
  (logand (logxor key (ash key -16)) #xFFFF))

(defun dict-index ()
  "Ensure the flat dictionary index is built; returns the whole index
as one self-consistent (flat . bstart) snapshot - a single cons cell
published with one SETF, so any reader (including one racing the very
first build) always sees a complete pair.  Words are scattered in
(len, idx) ascending order - the old builder's push order - and each
bucket range is read back reversed, so first-match-wins picks stay
identical to the cons-list version."
  (or *dict-index*
      (let* ((dict (load-dict))
             (counts (make-array 65537 :element-type 'fixnum
                                            :initial-element 0))
             (total 0))
        (declare (type (simple-array fixnum (65537)) counts)
                 (type fixnum total))
        (loop for len of-type fixnum from 4 to 24 do
          (let ((nw (nwords len)) (base (aref +doffset+ len)))
            (declare (type fixnum nw base))
            (loop for idx of-type fixnum below nw do
              (incf (aref counts (dict-bucket
                                  (dict-key4 dict (+ base (* idx len))))))
              (incf total))))
        ;; exclusive prefix: counts[b] = start of bucket b;
        ;; counts[65536] = total (end sentinel, bucket keys are 0..65535)
        (let ((acc 0))
          (declare (type fixnum acc))
          (dotimes (b 65537)
            (let ((c (aref counts b)))
              (declare (type fixnum c))
              (setf (aref counts b) acc)
              (incf acc c))))
        (let ((flat (make-array total :element-type 'fixnum))
              (cur (make-array 65537 :element-type 'fixnum)))
          (declare (type (simple-array fixnum (*)) flat)
                   (type (simple-array fixnum (65537)) cur))
          (replace cur counts)
          (loop for len of-type fixnum from 4 to 24 do
            (let ((nw (nwords len)) (base (aref +doffset+ len)))
              (declare (type fixnum nw base))
              (loop for idx of-type fixnum below nw do
                (let* ((b (dict-bucket (dict-key4 dict
                                                   (+ base (* idx len)))))
                       (at (aref cur b)))
                  (declare (type fixnum b at))
                  (setf (aref flat at) (logior (ash len 11) idx)
                        (aref cur b) (1+ at))))))
          ;; One word, one store: publish the pair atomically so a
          ;; concurrent reader never sees a half-built index.
          (setf *dict-index* (cons flat counts))))))

(deftable +dict-transforms+
  (loop for tid from 0 below (length +transforms+)
        for tr = (aref +transforms+ tid)
        when (and (zerop (length (first tr)))
                  (member (second tr) '(:identity :upper-first :upper-all))
                  (zerop (length (third tr))))
          collect tid)
  "Dictionary transforms that preserve word length (identity and uppercase).")

(deftable +dict-tid0+
  (or (car (rassoc 0 (loop for tid in +dict-transforms+
                           for tr = (aref +transforms+ tid)
                           when (and (zerop (length (first tr)))
                                     (member (second tr)
                                             '(:identity :upper-first :upper-all))
                                     (zerop (length (third tr))))
                             collect (cons tid (case (second tr)
                                                 (:identity 0)
                                                 (:upper-first 1)
                                                 (t 2))))
                       :test #'=))
      0)
  "Transform id of KIND 0 (identity).")
(deftable +dict-transform-kinds+
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
KIND (0 identity, 1 upper-first, 2 upper-all).  Returns (values MATCH
FAIL-POS); for KIND 0 FAIL-POS is the first mismatching byte (>= LEN on
match), which lets the caller skip KIND 1 when identity already failed
beyond the bytes that transform can change.  No temporary vectors."
  (declare (type (simple-array (unsigned-byte 8) (*)) data dict)
           (type fixnum p off len kind)
           (optimize (speed 3) (safety 0)))
  (case kind
    (0
     (let ((i 0))
       (declare (type fixnum i))
       (loop while (and (< i len)
                        (= (aref data (+ p i)) (aref dict (+ off i))))
             do (incf i))
       (values (>= i len) i)))
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

;; Top-level inline: this is a ~15-instruction helper called per
;; dictionary candidate; without the declaim every kind0 compare was a
;; static-fn call.
(declaim (inline %dict-match0-sap))
(defun %dict-match0-sap (data-sap dict-sap p off len)
  "Word-at-a-time identity compare of DATA[P..P+LEN) against
DICT[OFF..OFF+LEN) across the two pinned arrays; returns the first
mismatching byte position (LEN when they are equal).  Same TZCNT trick
as %MATCH-LEN-SAP, but across two different arrays."
  (declare (type ptr data-sap dict-sap)
           (type fixnum p off len)
           (optimize (speed 3) (safety 0)))
  (let ((i 0))
    (declare (type fixnum i))
    (loop while (<= (+ i 8) len) do
      (let ((x (logxor (ptr-u64 data-sap (+ p i))
                       (ptr-u64 dict-sap (+ off i)))))
        (declare (type (unsigned-byte 64) x))
        (unless (zerop x)
          (return-from %dict-match0-sap
            (+ i (ash (%trailing-zeros x) -3)))))
      (incf i 8))
    (loop while (and (< i len)
                     (= (ptr-u8 data-sap (+ p i))
                        (ptr-u8 dict-sap (+ off i))))
          do (incf i))
    i))

(defun dict-match-at (data p n min-len idx dict)
  "Longest dictionary word starting at DATA[P] with length >= MIN-CLOP,
as \(values length index transform-id).  Only length-preserving transforms
are considered so command copy lengths remain the base-word lengths.
IDX is a self-consistent index snapshot from DICT-INDEX (car = packed
word array, cdr = bucket starts) and DICT the dictionary vector; both
come from the caller's one-per-run snapshot, so this function reads no
global state at all."
  (declare (type fixnum p n min-len)
           (type (cons (simple-array fixnum (*))
                       (simple-array fixnum (65537))) idx)
           (type (simple-array (unsigned-byte 8) (*)) dict))
  (let* ((doff +doffset+) (tkinds +dict-transform-kinds+)
         (bucket (dict-bucket (dict-key4 data p)))
         (flat (car idx))
         (starts (cdr idx))
         (best-len 0) (best-idx 0) (best-tid 0))
    (declare (type (simple-array fixnum (*)) flat)
             (type (simple-array fixnum (65537)) starts))
    (loop for k of-type fixnum
          from (1- (aref starts (1+ bucket)))
          downto (aref starts bucket)
          do (let* ((e (aref flat k))
                    (len (ash e -11))
                    (idx (logand e #x7FF)))
               (declare (type (integer 0 #x7FFFFF) e)
                        (type (integer 0 31) len)
                        (type (integer 0 2047) idx))
               (when (and (<= len (- n p)) (>= len min-len)
                          (> len best-len))
                 (let ((off (+ (aref doff len) (* idx len))))
                   (dolist (tk tkinds)
                     (when (%dict-word-match-p data p dict off len (cdr tk))
                       (setf best-len len best-idx idx best-tid (car tk))
                       (return)))))))
    (values best-len best-idx best-tid)))

(defun dict-matches-at (sap data p n min-len dist-base dists stamp
                        idx dict dsap)
  "C BrotliFindAllStaticDictionaryMatches (length-preserving transforms
only): for every dictionary word of length LEN in [MIN-LEN, 24] that
matches DATA[P..), set DISTS[LEN] to its backward distance and return the
number of lengths filled.  DIST-BASE = min(window, position), so every
distance lands just above the decoder's max-distance and is therefore read
as a dictionary reference.  IDX (index snapshot from DICT-INDEX), DICT
(the dictionary vector) and DSAP (its SAP, or NIL) are the caller's
one-per-run snapshot - no globals are read here."
  (declare (type ptr sap)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum p n min-len)
           (type (integer 0 #x1FFFFFF) dist-base)
           (type (simple-array fixnum (25)) dists)
           (type (integer 0 #x7FFFFF) stamp)
           (type (cons (simple-array fixnum (*))
                       (simple-array fixnum (65537))) idx)
           (type (simple-array (unsigned-byte 8) (*)) dict)
           (type (or null ptr) dsap)
           (optimize (speed 3) (safety 0)))
  (let* ((key (if (and sap (<= (+ p 4) n))
                  (ptr-u32 sap p)
                  (dict-key4 data p)))
         ;; lexicals: as literal refs each table went through symbol
         ;; indirection on every candidate/probe
         (doff +doffset+) (tid0 +dict-tid0+)
         (tkinds +dict-transform-kinds+)
         (bucket (dict-bucket key))
         (flat (car idx))
         (starts (cdr idx))
         (count 0))
    (declare (type (simple-array fixnum (*)) flat)
             (type (simple-array fixnum (65537)) starts)
             (type (or null ptr) dsap)
             (type fixnum count))
    (loop for k of-type fixnum
          from (1- (aref starts (1+ bucket)))
          downto (aref starts bucket)
          do (let* ((e (aref flat k))
                    (len (ash e -11))
                    (idx (logand e #x7FF)))
        (declare (type (integer 0 #x7FFFFF) e)
                 (type (integer 0 31) len)
                 (type (integer 0 2047) idx))
        (when (and (<= len (- n p)) (>= len min-len)
                   ;; not yet filled by THIS call (stamps replace the
                   ;; per-call clear the old zero-test relied on)
                   (/= (ash (aref dists len) -26) stamp))
          (let ((off (+ (aref doff len) (* idx len)))
                (skip1 nil))
            (declare (type boolean skip1))
            ;; KIND 0 (identity): word-at-a-time compare across the two
            ;; pinned arrays - it covers the common exact-match case and
            ;; yields the failure position for the kind-1 skip.
            (let ((fpos (if dsap
                            (%dict-match0-sap sap dsap p off len)
                            (nth-value 1
                                       (%dict-word-match-p data p dict
                                                            off len 0)))))
              (declare (type fixnum fpos))
              (cond
                ((>= fpos len)
                 (setf (aref dists len)
                       (logior (ash stamp 26)
                               (+ dist-base 1 idx
                                  (* (the (integer 0 127) tid0)
                                     (the (integer 0 2048) (nwords len))))))
                 (incf count))
                (t
                 ;; KIND 1 (upper-first) only changes the first UTF-8
                 ;; character: if identity failed at or beyond that
                 ;; character's width, KIND 1 fails at the same byte.
                 (when (>= fpos (let ((c (aref dict off)))
                                  (if (< c 192) 1
                                      (if (< c 224) 2 3))))
                   (setf skip1 t))
                 (dolist (tk tkinds)
                   (let ((kd (cdr tk)))
                     (declare (type fixnum kd))
                     (when (and (/= kd 0)
                                (not (and skip1 (= kd 1))))
                       (when (%dict-word-match-p data p dict off len kd)
                         (setf (aref dists len)
                               (logior (ash stamp 26)
                                       (+ dist-base 1 idx
                                          (* (the (integer 0 127) (car tk))
                                             (the (integer 0 2048) (nwords len))))))
                         (incf count)
                         (return))))))))))))
        count))

;;; ---- C's encoder dictionary hash (enc/dictionary_hash.c) ---------------
;;; The q2-q9 hashers (C H2, H4, H5, H6) probe the static dictionary through
;;; a 2^15-entry table indexed by (Hash14 << 1) + slot, where slot 1 holds a
;;; word shorter than 8 bytes.  BrotliEncoderInitDictionaryHash fills it
;;; longest words first, highest index first; a word takes its slot unless
;;; an earlier "frozen" word holds it.  The frozen bit set (one bit per
;;; dictionary word, 1688 bytes) is C's own, so this table - and every
;;; dictionary match the hashers find - is C's.  Entry: len | word << 5
;;; (0 = empty).

(deftable +c-dict-frozen-hex+
  (concatenate 'string
   "000008A420381FBF24048051448491810000001C00080101400301000000000004400102"
   "800084310000000000000000110000000100249800000000800800008000000800004000"
   "000000000000000008000000010040850020000080010000000004040420108200800800"
   "0000000040004000A0009435000000000080008200000008000000000030000000000000"
   "20012081000C000100000000000000100000001020000000000000000001000008000002"
   "00000000002000000002428000001000000000400106800800C0182000000804808002A0"
   "00A000400000020000000000000000002001000040000000000000200042000200040008"
   "000200002108000000080080A2048000022100A00008004000A000810400002000002000"
   "02000000000000800000000000400A000000002040000000000010001010000050020000"
   "000008000010000800000008408000000008D00000000000000020000000000000200008"
   "00800000000100000010080188000024004009000120080040408310E02004000405A000"
   "830004600000B8C000B1CD60000000000200200000000000000000400000800000080000"
   "000001040001000000040000000000000400004045000008024220400000000000010080"
   "11000000000000000000000C001000000480400000000000000000E00008000082104080"
   "02400000008002C040004100000010000000200402024C000000044834832C4C00000000"
   "400110940400100A40000200010080404400000000004090000800020000000000000340"
   "0000000001800000204200000028001200000000002100002000002000800440918C0000"
   "008000020000140050260000200020400404000400000081040000901120821084188600"
   "004002053208C221014475010820A1360082220000004080000002000000002001000000"
   "030E00000000001004000000000000000060011812000180180040000400108000400000"
   "004000080000000000428000000000000000000000000000000010004002000000000600"
   "0808020040000000008002020C400040000800802000000A000020008020210888006040"
   "000000000040041004080000001000020000018000401000000000000000000800000200"
   "100004000800000000001400000000010000000000000000000000088800000000000800"
   "000000000200000040000001000200000000000000000080000000000400000000410000"
   "000000000000000004000000000000000000000002800000000802000080001002000004"
   "00200000010440400004000100100020440404410A001425120194002080030800400000"
   "0000000004001001800000008010000000000180000080408040008200A4080000014080"
   "00120002960008000040005100001080020824208104900D000003080100020000400005"
   "0001220120021080808000000002000412080C2220C00640E02100008948400018088080"
   "0010002080808408000010004000000400001000048040000001000440209082028000C0"
   "00405240012080800200540020002C184850201000002C106040014883000000100000A5"
   "008102313040400C40B0405408801440D5886801290F53AA00002901404000C140400800"
   "800000400840080110000800000201801C548D6100004400008108001008200040000000"
   "18000000C000088000000000004000010000000028018040000402200000000000000000"
   "000000008020080020000000101100020400002180020000000081000200000024002002"
   "000000000000200000000004000000000000000420400000000000002000002080000000"
   "00000000000000801000000000000000010088000018C080030011120200420004180009"
   "D0A70090144000824000021088084A2000A8004120080C01030140B40300400008000020"
   "4100041004104420402420182101800000080020405100010A1308000004059000000880"
   "000004000000000000010000000800000000005001000021002042040200012B02000004"
   "20100040000320000240407400413440001140C060080A08020400114000040000048000"
   "00090000820200C000308040006000400001102000012006800220000C00003020080000"
   "80001200001C182910052000000000000000100000000000000000000000000000010000"
   "001000000000400000000008000000001080000000100000000000000800000000000000"
   "000000000000210000000000000000000000000000100000000000000000000000000000"
   "0000000000000000000000000000000000000000000000000000000000000000"))

(declaim (type (or null (simple-array (unsigned-byte 16) (32768))) *c-dict-hash*))
(defvar *c-dict-hash* nil)

(declaim (inline c-hash14))
(defun c-hash14 (b0 b1 b2 b3)
  "C Hash14 of the four bytes B0..B3 (little-endian u32 * kHashMul32 >> 18)."
  (declare (type (unsigned-byte 8) b0 b1 b2 b3) (optimize (speed 3) (safety 0)))
  (ash (logand (* (logior b0 (ash b1 8) (ash b2 16) (ash b3 24)) #x1E35A7BD)
               #xFFFFFFFF)
       -18))

(defun c-dict-hash ()
  "C's kStaticDictionaryHashWords/Lengths as one u16 table, built once."
  (or *c-dict-hash*
      (let* ((dict (load-dict))
             (hex +c-dict-frozen-hex+)
             (frozen (let ((v (make-array 1688 :element-type '(unsigned-byte 8))))
                       (dotimes (i 1688 v)
                         (setf (aref v i)
                               (parse-integer hex :start (* 2 i) :end (+ 2 (* 2 i))
                                                  :radix 16)))))
             (lens (make-array 32768 :element-type '(unsigned-byte 8) :initial-element 0))
             (words (make-array 32768 :element-type '(unsigned-byte 16) :initial-element 0))
             (tab (make-array 32768 :element-type '(unsigned-byte 16) :initial-element 0))
             (g 0))
        (declare (type fixnum g))
        (loop for len of-type fixnum from 24 downto 4 do
          (let ((nw (nwords len)) (base (aref +doffset+ len)))
            (declare (type fixnum nw base))
            (dotimes (i nw)
              (let* ((j (- nw 1 i))
                     (w (+ base (* len j)))
                     (idx (+ (ash (c-hash14 (aref dict w) (aref dict (+ w 1))
                                            (aref dict (+ w 2)) (aref dict (+ w 3)))
                                  1)
                             (if (< len 8) 1 0))))
                (when (zerop (logand (aref lens idx) #x80))
                  (setf (aref words idx) j
                        (aref lens idx) (+ len (if (logbitp (mod g 8) (aref frozen (floor g 8)))
                                                   #x80 0))))
                (incf g)))))
        (dotimes (i 32768)
          (let ((l (logand (aref lens i) #x7F)))
            (unless (zerop l)
              (setf (aref tab i) (logior l (ash (aref words i) 5))))))
        (setf *c-dict-hash* tab))))

(deftable +c-cut-tid+
  ;; C kCutoffTransforms: transform id of "omit last CUT" for CUT 0..9
  (make-array 10 :element-type 'fixnum
                 :initial-contents '(0 12 27 23 42 63 56 48 59 64)))
(declaim (type (simple-array fixnum (10)) +c-cut-tid+))

(defmacro c-dict-search ((data cur max-length maxb tab dict lookups matches shallow)
                         score &body on-match)
  "C SearchInStaticDictionary at DATA[CUR] (call it only when the hasher
found nothing better than the minimum score SCORE, a place).  LOOKUPS and
MATCHES are the hasher's counters (places).  For each accepted item BODY
runs with LEN (output bytes), LCD (1 + bytes cut from the word: the
command's DICTP) and DIST bound, after SCORE was raised to its score.
SHALLOW probes one slot (H2/H4), otherwise two (H5/H6)."
  (let ((key (gensym "KEY")) (slot (gensym "SLOT")) (e (gensym "E"))
        (wl (gensym "WL")) (word (gensym "WORD")) (off (gensym "OFF"))
        (ml (gensym "ML")) (cut (gensym "CUT")) (sc (gensym "SC")) (i (gensym "I")))
    `(unless (< ,matches (ash ,lookups -7))
       (let ((,key (ash (c-hash14 (aref ,data ,cur) (aref ,data (+ ,cur 1))
                                  (aref ,data (+ ,cur 2)) (aref ,data (+ ,cur 3)))
                        1)))
         (declare (type fixnum ,key))
         (dotimes (,slot ,(if shallow 1 2))
           (incf ,lookups)
           (let ((,e (aref ,tab (+ ,key ,slot))))
             (declare (type fixnum ,e))
             (unless (zerop ,e)
               (let ((,wl (logand ,e 31)) (,word (ash ,e -5)))
                 (declare (type fixnum ,wl ,word))
                 (when (<= ,wl ,max-length)
                   (let* ((,off (+ (aref +doffset+ ,wl) (* ,wl ,word)))
                          (,ml (let ((,i 0))
                                 (declare (type fixnum ,i))
                                 (loop while (and (< ,i ,wl)
                                                  (= (aref ,data (+ ,cur ,i))
                                                     (aref ,dict (+ ,off ,i))))
                                       do (incf ,i))
                                 ,i)))
                     (declare (type fixnum ,off ,ml))
                     (unless (or (zerop ,ml) (<= (+ ,ml 10) ,wl))
                       (let* ((,cut (- ,wl ,ml))
                              (dist (+ ,maxb 1 ,word
                                       (ash (aref +c-cut-tid+ ,cut) (aref +ndbits+ ,wl))))
                              (,sc (- (+ 1920 (* 135 ,ml))
                                      (* 30 (1- (integer-length dist))))))
                         (declare (type fixnum ,cut dist ,sc))
                         (unless (< ,sc ,score)
                           (setf ,score ,sc)
                           (incf ,matches)
                           (let ((len ,ml) (lcd (1+ ,cut)))
                             (declare (type fixnum len lcd) (ignorable len lcd dist))
                             ,@on-match))))))))))))))

;; per word length: C offsets_by_length | size_bits_by_length << 24 (for the
;; assembly dictionary probe)
(deftable +c-dict-len-info+
  (let ((v (make-array 25 :element-type '(unsigned-byte 32) :initial-element 0)))
    (loop for len from 4 to 24
          do (setf (aref v len) (logior (aref +doffset+ len) (ash (aref +ndbits+ len) 24))))
    v))

(declaim (inline copy-code-len))
(defun copy-code-len (cpy dictp)
  "The copy length a command's length code encodes: CPY, or for a static-
dictionary reference (DICTP = 1 + bytes cut) the dictionary word's length."
  (declare (type fixnum cpy dictp))
  (if (> dictp 1) (+ cpy dictp -1) cpy))

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


;;; ---- Zopfli cost-model DP (q10/11; C backward_references_hq + literal_cost)


(deftable +zdc-jo+
  ;; C kDistanceCacheIndex/kDistanceCacheOffset packed into one byte:
  ;; (slot << 4) | (offset + 8), offsets are -3..3.  One table read per
  ;; short candidate instead of two.
  (make-array 16 :element-type '(unsigned-byte 8)
                  :initial-contents '(#x08 #x18 #x28 #x38 #x07 #x09 #x06 #x0A #x05 #x0B #x17 #x19 #x16 #x1A #x15 #x1B))
  "Packed short-distance cache slot + offset per short code 0..15.")
(declaim (type (simple-array (unsigned-byte 8) (16)) +zdc-jo+))
(defconstant +z-infinity+ (float 1.7d38 1.0f0))

;;; ZopfliNode as parallel arrays: cost (single-float), and packed
;;; fixnums mirroring C's bitfields.
;;;   ZLEN[i]  = copy-len | ((copy-len + 9 - len-code) << 25)
;;;   ZINS[i]  = (short-code << 27) | insert-len
;;;   ZDICT[i] = 1 when the copy is a static-dictionary reference (C
;;;              derives this from the distance at command creation; our
;;;              emission re-derives shorts from the ring, so we keep the
;;;              flag explicitly).
(defstruct (zmodel (:constructor make-zmodel (cost-cmd cost-dist lit-prefix
                                              min-cost-cmd)))
  (cost-cmd nil :type (simple-array single-float (*)))
  (cost-dist nil :type (simple-array single-float (*)))
  (lit-prefix nil :type (simple-array single-float (*)))
  (min-cost-cmd 1.0f0 :type single-float))

;;; StartPosQueue: 8-slot ring kept sorted by costdiff (C's PosData queue).
(defstruct (zpq (:constructor make-zpq ()))
  (pos (make-array 8 :element-type 'fixnum :initial-element 0)
       :type (simple-array fixnum (8)))
  (cost (make-array 8 :element-type 'single-float
                       :initial-element +z-infinity+)
        :type (simple-array single-float (8)))
  (costdiff (make-array 8 :element-type 'single-float
                          :initial-element +z-infinity+)
            :type (simple-array single-float (8)))
  ;; 4 distances per slot, flattened slot-major
  (dc (make-array 32 :element-type 'fixnum :initial-element 0)
      :type (simple-array fixnum (32)))
  (idx 0 :type fixnum))

(declaim (inline zq-size))
(defun zq-size (q)
  (declare (type zpq q) (optimize (speed 3) (safety 0)))
  (min (the fixnum (zpq-idx q)) 8))

;; Top-level: the labels-scoped (DECLARE (INLINE ZQ-PUSH)) inside %LZ77
;; sits after the label definitions that call it, so Z-EVAL's body never
;; saw it and every queue push was a full static-fn call.
(declaim (inline zq-push))
(defun zq-push (q pos cost costdiff dc0 dc1 dc2 dc3)
  "C StartPosQueuePush: insert at the ring offset and bubble into sorted
costdiff order."
  (declare (type zpq q) (type fixnum pos dc0 dc1 dc2 dc3)
           (type single-float cost costdiff)
           (optimize (speed 3) (safety 0)))
  (let* ((old-idx (zpq-idx q))
         ;; C: offset = ~(self->idx_++) & 7 -- uses the OLD index.
         (offset (logand (lognot old-idx) 7))
         (_u1 (setf (zpq-idx q) (1+ old-idx)))
         (len (zq-size q))
         (pos-a (zpq-pos q)) (cost-a (zpq-cost q))
         (cd-a (zpq-costdiff q)) (dc (zpq-dc q)))
    (declare (type fixnum offset len old-idx) (ignore _u1))
    (setf (aref pos-a offset) pos
          (aref cost-a offset) cost
          (aref cd-a offset) costdiff)
    (let ((base (* 4 offset)))
      (declare (type fixnum base))
      (setf (aref dc base) dc0
            (aref dc (+ base 1)) dc1
            (aref dc (+ base 2)) dc2
            (aref dc (+ base 3)) dc3))
    ;; The other entries are already sorted, so the first comparison that
    ;; does not swap ends C's fixed LEN - 1 passes early (same result).
    (loop for i of-type fixnum from 1 below len do
      (let ((a offset) (b (logand (1+ offset) 7)))
        (declare (type fixnum a b))
        (unless (> (aref cd-a a) (aref cd-a b)) (return))
        (progn
          (rotatef (aref pos-a a) (aref pos-a b))
          (rotatef (aref cost-a a) (aref cost-a b))
          (rotatef (aref cd-a a) (aref cd-a b))
          ;; unrolled: the loop re-multiplied (* 4 a)/(* 4 b) per slot
          (let ((ba (ash a 2)) (bb (ash b 2)))
            (declare (type fixnum ba bb))
            (rotatef (aref dc ba) (aref dc bb))
            (rotatef (aref dc (+ ba 1)) (aref dc (+ bb 1)))
            (rotatef (aref dc (+ ba 2)) (aref dc (+ bb 2)))
            (rotatef (aref dc (+ ba 3)) (aref dc (+ bb 3)))))
        (setf offset b)))))

;; The long-copy tail of C ZopfliComputeShortestPath: EvaluateNode for the
;; SKIP - 1 positions after I (each: ComputeDistanceShortcut, and when the
;; node beats pure literals ComputeDistanceCache + StartPosQueuePush).  On
;; repetitive input this runs for almost every position; out of the big
;; Z-ITERATE closure every array stays in a register.  The distance cache
;; is written straight into the queue slot it lands in.  Returns
;; (values I OFF) as the inline loop left them.
(defun z-skip-run (i skip n hq off z-nm zcostf prefix zsc zlen zins z-sdc q)
  (declare (type fixnum i skip n off)
           (type boolean hq)
           (type (simple-array (unsigned-byte 32) (*)) z-nm zsc zins)
           (type (simple-array single-float (*)) zcostf prefix)
           (type (simple-array fixnum (*)) zlen)
           (type (simple-array fixnum (4)) z-sdc)
           (type zpq q)
           (optimize (speed 3) (safety 0)))
  (let ((pos-a (zpq-pos q)) (cost-a (zpq-cost q))
        (cd-a (zpq-costdiff q)) (dc (zpq-dc q))
        (qidx (zpq-idx q)))
    (declare (type fixnum qidx))
    (decf skip)
    (loop while (plusp skip) do
      (incf i)
      (when (>= (+ i 3) n) (return))
      (let* ((pos i)
             (zv (aref zlen pos))
             (clen (logand zv #xFFFFFF))
             (sc (if (= clen 1)
                     pos
                     (let* ((zi (aref zins pos))
                            (ins (logand zi #x7FFFFFF)))
                       (declare (type (unsigned-byte 32) zi))
                       (if (and (zerop (logand zv #x1000000))
                                (/= (ash zi -27) 1))
                           pos
                           (aref zsc (- pos clen ins))))))
             (cost (aref zcostf pos))
             (pref (aref prefix pos)))
        (declare (type fixnum pos zv clen sc) (type single-float cost pref))
        (setf (aref zsc pos) sc)
        (when (<= cost pref)
          (let* ((offset (logand (lognot qidx) 7))
                 (base (ash offset 2))
                 (k 0) (p sc))
            (declare (type fixnum offset base k p))
            (incf qidx)
            ;; ComputeDistanceCache into the slot
            (loop while (and (< k 4) (> p 0)) do
              (let* ((zv (aref zlen p))
                     (clen (logand zv #xFFFFFF)))
                (declare (type fixnum zv clen))
                (if (= clen 1)
                    (setf (aref dc (+ base k)) 0
                          p (aref zsc (1- p)))
                    (setf (aref dc (+ base k)) (ash zv -25)
                          p (aref zsc (- p clen (logand (aref zins p) #x7FFFFFF)))))
                (incf k)))
            (loop while (< k 4) do
              (setf (aref dc (+ base k)) (aref z-sdc k))
              (incf k))
            (setf (aref pos-a offset) pos
                  (aref cost-a offset) cost
                  (aref cd-a offset) (- cost pref))
            ;; restore the sorted order (C StartPosQueuePush)
            (let ((len (min qidx 8)))
              (declare (type fixnum len))
              ;; sorted remainder: stop at the first non-swap
              (loop for j of-type fixnum from 1 below len do
                (let ((a offset) (b (logand (1+ offset) 7)))
                  (declare (type fixnum a b))
                  (unless (> (aref cd-a a) (aref cd-a b)) (return))
                  (progn
                    (rotatef (aref pos-a a) (aref pos-a b))
                    (rotatef (aref cost-a a) (aref cost-a b))
                    (rotatef (aref cd-a a) (aref cd-a b))
                    (let ((ba (ash a 2)) (bb (ash b 2)))
                      (declare (type fixnum ba bb))
                      (rotatef (aref dc ba) (aref dc bb))
                      (rotatef (aref dc (+ ba 1)) (aref dc (+ bb 1)))
                      (rotatef (aref dc (+ ba 2)) (aref dc (+ bb 2)))
                      (rotatef (aref dc (+ ba 3)) (aref dc (+ bb 3)))))
                  (setf offset b)))))))
      (when hq (incf off (aref z-nm i)))
      (decf skip))
    (setf (zpq-idx q) qidx)
    (values i off)))

(declaim (inline zq-at))
(defun zq-at (q k)
  "C StartPosQueueAt: k-th smallest-costdiff entry (k=0 is the best)."
  (declare (type zpq q) (type fixnum k) (optimize (speed 3) (safety 0)))
  (logand (- k (zpq-idx q)) 7))

;;; ---- literal bit-cost estimator (C literal_cost.c) --------------------

(declaim (inline utf8-position parse-as-utf8))
(defun parse-as-utf8 (in start end)
  "C BrotliParseAsUTF8: returns (values codepoint bytes-consumed);
codepoint is -1 for invalid sequences (which count as one byte)."
  (declare (type (simple-array (unsigned-byte 8) (*)) in)
           (type fixnum start end) (optimize (speed 3) (safety 0)))
  (let ((b0 (aref in start)))
    (cond
      ((< b0 128) (values b0 1))
      ((< b0 192) (values #x110000 1))
      ((< b0 224)
       (if (and (< (1+ start) end)
                (<= 128 (aref in (1+ start)) 191))
           (values (logior (ash (logand b0 31) 6)
                           (logand (aref in (1+ start)) 63))
                   2)
           (values #x110000 1)))
      ((< b0 240)
       (if (and (< (+ start 2) end)   ; C: size > 2
                (<= 128 (aref in (1+ start)) 191)
                (<= 128 (aref in (+ start 2)) 191))
           (let ((cp (logior (ash (logand b0 15) 12)
                             (ash (logand (aref in (1+ start)) 63) 6)
                             (logand (aref in (+ start 2)) 63))))
             (if (and (>= cp #x800) (not (<= #xD800 cp #xDFFF)))
                 (values cp 3)
                 (values #x110000 1)))
           (values #x110000 1)))
      ((< b0 245)
       (if (and (< (+ start 3) end)   ; C: size > 3
                (<= 128 (aref in (1+ start)) 191)
                (<= 128 (aref in (+ start 2)) 191)
                (<= 128 (aref in (+ start 3)) 191))
           (let ((cp (logior (ash (logand b0 7) 18)
                             (ash (logand (aref in (1+ start)) 63) 12)
                             (ash (logand (aref in (+ start 2)) 63) 6)
                             (logand (aref in (+ start 3)) 63))))
             (if (and (>= cp #x10000) (<= cp #x10FFFF))
                 (values cp 4)
                 (values #x110000 1)))
           (values #x110000 1)))
      (t (values #x110000 1)))))

(deftable +fast-log2-table+
  (let ((v (make-array 2048 :element-type 'double-float
                             :initial-element 0.0d0)))
    (dotimes (i 2048 v)
      (unless (zerop i)
        (setf (aref v i) (log (float i 1.0d0) 2.0d0)))))
  "log2 of small integers (log2(0) = 0). 2048 covers every histogram /
window count the literal estimator sees, so the per-byte estimate loop
never calls libm (C's FastLog2 only tables below 256 and pays log2 for
the rest - our table values agree with libm to within an ULP, the same
rounding class as C's own float casts).")
(declaim (type (simple-array double-float (2048)) +fast-log2-table+)
         (inline fast-log2))
(defun fast-log2 (v)
  "Table lookup below 2048, libm log2 above."
  (declare (type fixnum v) (optimize (speed 3) (safety 0)))
  (if (< v 2048)
      (aref +fast-log2-table+ v)
      (log (float v 1.0d0) 2.0d0)))

(defun mostly-utf8-p (data start end)
  "C BrotliIsMostlyUTF8 with kMinUTF8Ratio = 0.75."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum start end) (optimize (speed 3) (safety 0)))
  (let ((size-utf8 0) (i start))
    (declare (type fixnum size-utf8 i))
    (loop while (< i end) do
      (multiple-value-bind (cp bytes) (parse-as-utf8 data i end)
        (when (< cp #x110000) (incf size-utf8 bytes))
        (incf i bytes)))
    (> (/ (float size-utf8 1.0d0) (- end start)) 0.75d0)))

(defun utf8-stats (data start end)
  "C's BrotliIsMostlyUTF8 and DecideMultiByteStatsLevel fused into one
pass: returns (values MOSTLY C1 C2) where C1 counts bytes >= 192, C2
counts continuation bytes whose predecessor was >= 224, exactly as the
two separate C loops compute them (every byte is visited once, in
order)."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum start end)
           (optimize (speed 3) (safety 0)))
  (let ((size-utf8 0) (i start) (c1 0) (c2 0) (last 0))
    (declare (type fixnum size-utf8 i c1 c2 last))
    (loop while (< i end) do
      (multiple-value-bind (cp bytes) (parse-as-utf8 data i end)
        (declare (ignore cp))
        (dotimes (b bytes)
          (let ((c (aref data (+ i b))))
            (declare (type fixnum c))
            (cond ((< c 128) nil)
                  ((>= c 192) (incf c1))
                  (t (when (>= last #xE0) (incf c2))))
            (setf last c)))
        (when (< cp #x110000) (incf size-utf8 bytes))
        (incf i bytes)))
    (values (> (/ (float size-utf8 1.0d0) (- end start)) 0.75d0)
            c1 c2)))

(defun utf8-position (last c clamp)
  "C UTF8Position."
  (declare (type fixnum last c clamp))
  (cond ((< c 128) 0)
        ((>= c 192) (min 1 clamp))
        (t (if (< last #xE0) 0 (min 2 clamp)))))

(defmacro lit-prefix-step (prefix i x carry)
  "C's compensated literal-cost prefix sum (ZopfliCostModelSetFromLiteral-
Costs / SetFromCommands): CARRY keeps the float rounding residual across the
whole array, so PREFIX[I+1] - PREFIX[J] stays accurate for runs deep into a
block (a plain float sum drifts by bits after a few thousand bytes, enough
to flip copy-vs-literal decisions on cheap literals)."
  (let ((nv (gensym "NV")))
    `(progn
       (incf ,carry ,x)
       (let ((,nv (+ (aref ,prefix ,i) ,carry)))
         (declare (type single-float ,nv))
         (setf (aref ,prefix (1+ ,i)) ,nv)
         (decf ,carry (- ,nv (aref ,prefix ,i)))))))

(defun estimate-literal-costs (data start end costs)
  "C BrotliEstimateBitCostsForLiterals -> COSTS, C's literal_costs
convention: raw costs land at indices 1..END-START (index 0 is the
caller's zero prefix), so COSTS needs END-START+1 entries.  Split into
C's paths: plain ASCII (window 2000, no
bump), mostly-UTF8 with sparse multibyte stats (window 495, single
histogram row, prologue bump), and the general 3x256 position-histogram
UTF8 path.  The single-row case is a fast path, not an approximation:
UTF8Position(.., clamp=0) is identically 0, so the general loop without
position classification computes exactly the same values."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum start end)
           (type (simple-array single-float (*)) costs)
           (optimize (speed 3) (safety 0)))
  (let* ((len (- end start))
         ;; lexical table: the inlined FAST-LOG2 body re-loaded
         ;; +FAST-LOG2-TABLE+ through symbol indirection on every byte
         ;; (Rev 136/137 lesson) - a frame slot here instead
         (fl2tab +fast-log2-table+)
         (c1 0) (c2 0)
         (mostly nil)
         (max-utf8 0)
         (carry 0.0f0))
    (declare (type fixnum len c1 c2 max-utf8) (type boolean mostly)
             (type single-float carry))
    (multiple-value-setq (mostly c1 c2) (utf8-stats data start end))
    ;; C keeps max_utf8 at 1 even with >=500 three-byte stats ("should be
    ;; 2, but 1 compresses better"); only the sparse-multibyte case drops
    ;; to 0 (and non-UTF8 data never takes this path).
    (when mostly
      (setf max-utf8 (if (and (< c2 500) (< (+ c1 c2) 25)) 0 1)))
    (cond
      ((not mostly)
       ;; C's plain path: window 2000, one histogram, no prologue bump.
       (let* ((window 2000)
              (in-window (min window len))
              (hist (make-array 256 :element-type 'fixnum
                                     :initial-element 0))
              ;; log2(in-window) hoisted out of the byte loop: it only
              ;; changes at the window edges (both blocks fire in the
              ;; middle and net to zero).
              (iw-last (min window len))
              (liw (fast-log2 (min window len))))
         (declare (type fixnum window in-window iw-last)
                  (type double-float liw))
         (loop for i of-type fixnum from start below (+ start in-window)
               do (incf (aref hist (aref data i))))
         (loop for i of-type fixnum from 0 below len do
           (let ((p (+ start i)))
             (declare (type fixnum p))
             (when (>= i window)
               (decf (aref hist (aref data (- p window))))
               (decf in-window))
             (when (< (+ i window) len)
               (incf (aref hist (aref data (+ p window))))
               (incf in-window))
             (when (/= in-window iw-last)
               (setf iw-last in-window
                     liw (fast-log2 in-window)))
             (let* ((h (max 1 (aref hist (aref data p))))
                    (cost (+ (- liw (if (< h 2048) (aref fl2tab h) (log (float h 1.0d0) 2.0d0)))
                             0.029d0)))
               (declare (type double-float cost))
               (when (< cost 1.0d0)
                 (setf cost (+ (* 0.5d0 cost) 0.5d0)))
               (lit-prefix-step costs i (float cost 1.0f0) carry))))))
      ((zerop max-utf8)
       ;; Single-row fast path (window 495 + prologue bump): byte-identical
       ;; to the general UTF8 loop because UTF8Position(.., 0) == 0 always.
       (let* ((window 495)
              (in-window (min window len))
              (hist (make-array 256 :element-type 'fixnum
                                     :initial-element 0))
              ;; log2(in-window) hoisted out of the byte loop: it only
              ;; changes at the window edges (both blocks fire in the
              ;; middle and net to zero).
              (iw-last (min window len))
              (liw (fast-log2 (min window len))))
         (declare (type fixnum window in-window iw-last)
                  (type double-float liw))
         (loop for i of-type fixnum from start below (+ start in-window)
               do (incf (aref hist (aref data i))))
                  ;; Three-region split (byte-identical): the steady region from
         ;; R1 to R2 is 99.9% of bytes for 1 MiB inputs; there remove and
         ;; add are unconditional and in-window - hence liw - is constant.
         (let ((r1 (min window len))
               (r2 (max (min window len) (- len window))))
           (declare (type fixnum r1 r2))
           (loop for i of-type fixnum from 0 below r1 do
           (let ((p (+ start i)))
             (declare (type fixnum p))
             (when (>= i window)
               (decf (aref hist (aref data (- p window))))
               (decf in-window))
             (when (< (+ i window) len)
               (incf (aref hist (aref data (+ p window))))
               (incf in-window))
             (when (/= in-window iw-last)
               (setf iw-last in-window
                     liw (fast-log2 in-window)))
             (let* ((h (max 1 (aref hist (aref data p))))
                    (cost (+ (- liw (if (< h 2048) (aref fl2tab h) (log (float h 1.0d0) 2.0d0)))
                             0.029d0)))
               (declare (type double-float cost))
               (when (< cost 1.0d0)
                 (setf cost (+ (* 0.5d0 cost) 0.5d0)))
               (when (< i 2000)
                 (incf cost (+ 0.35d0 (* 0.000175d0 i))))
               (lit-prefix-step costs i (float cost 1.0f0) carry))))
           (loop for i of-type fixnum from r1 below r2 do
           (let ((p (+ start i)))
             (declare (type fixnum p))
             ;; steady window: remove/add conditions are exactly
             ;; (i >= r1)/(i < r2) - both ALWAYS true here - and
             ;; in-window is constant, so no refresh (byte-identical)
             (decf (aref hist (aref data (- p window))))
             (incf (aref hist (aref data (+ p window))))
             (let* ((h (max 1 (aref hist (aref data p))))
                    (cost (+ (- liw (if (< h 2048) (aref fl2tab h) (log (float h 1.0d0) 2.0d0)))
                             0.029d0)))
               (declare (type double-float cost))
               (when (< cost 1.0d0)
                 (setf cost (+ (* 0.5d0 cost) 0.5d0)))
               (when (< i 2000)
                 (incf cost (+ 0.35d0 (* 0.000175d0 i))))
               (lit-prefix-step costs i (float cost 1.0f0) carry))))
           (loop for i of-type fixnum from r2 below len do
           (let ((p (+ start i)))
             (declare (type fixnum p))
             (when (>= i window)
               (decf (aref hist (aref data (- p window))))
               (decf in-window))
             (when (< (+ i window) len)
               (incf (aref hist (aref data (+ p window))))
               (incf in-window))
             (when (/= in-window iw-last)
               (setf iw-last in-window
                     liw (fast-log2 in-window)))
             (let* ((h (max 1 (aref hist (aref data p))))
                    (cost (+ (- liw (if (< h 2048) (aref fl2tab h) (log (float h 1.0d0) 2.0d0)))
                             0.029d0)))
               (declare (type double-float cost))
               (when (< cost 1.0d0)
                 (setf cost (+ (* 0.5d0 cost) 0.5d0)))
               (when (< i 2000)
                 (incf cost (+ 0.35d0 (* 0.000175d0 i))))
               (lit-prefix-step costs i (float cost 1.0f0) carry)))))))
      (t
       ;; General UTF8 path: 3x256 position histograms, window 495.
       (let* ((window 495)
              (in-window (min window len))
              (hist (make-array (* 3 256) :element-type 'fixnum
                                          :initial-element 0))
              (in-u (make-array 3 :element-type 'fixnum
                                    :initial-element 0)))
         (declare (type fixnum window in-window))
         (let ((last 0) (upos 0))
           (declare (type fixnum last upos))
           (loop for i of-type fixnum from start below (+ start in-window) do
             (let ((c (aref data i)))
               (incf (aref hist (+ (* 256 upos) c)))
               (incf (aref in-u upos))
               (setf upos (utf8-position last c max-utf8)
                     last c))))
         (loop for i of-type fixnum from 0 below len do
           (let ((p (+ start i)))
             (declare (type fixnum p))
             (when (>= i window)
               (let* ((c (if (< i (1+ window)) 0
                             (aref data (- p window 1))))
                      (lc (if (< i (+ window 2)) 0
                              (aref data (- p window 2))))
                      (upos (utf8-position lc c max-utf8)))
                 (declare (type fixnum c lc upos))
                 (decf (aref hist (+ (* 256 upos)
                                     (aref data (- p window)))))
                 (decf (aref in-u upos))))
             (when (< (+ i window) len)
               (let* ((c (aref data (+ p window -1)))
                      (lc (aref data (+ p window -2)))
                      (upos (utf8-position lc c max-utf8)))
                 (declare (type fixnum c lc upos))
                 (incf (aref hist (+ (* 256 upos)
                                     (aref data (+ p window)))))
                 (incf (aref in-u upos))))
             (let* ((c (if (< i 1) 0 (aref data (1- p))))
                    (lc (if (< i 2) 0 (aref data (- p 2))))
                    (upos (utf8-position lc c max-utf8))
                    (h (max 1 (aref hist (+ (* 256 upos) (aref data p)))))
                    (cost (+ (- (let ((u (aref in-u upos))) (if (< u 2048) (aref fl2tab u) (log (float u 1.0d0) 2.0d0)))
                                (if (< h 2048) (aref fl2tab h) (log (float h 1.0d0) 2.0d0)))
                             0.029d0)))
               (declare (type fixnum upos) (type double-float cost))
               (when (< cost 1.0d0)
                 (setf cost (+ (* 0.5d0 cost) 0.5d0)))
               (when (< i 2000)
                 (incf cost (+ 0.35d0 (* 0.000175d0 i))))
               (lit-prefix-step costs i (float cost 1.0f0) carry)))))))
    costs))

;;;; ---- per-compressor scratch pool for the big z-state arrays ----
;;;;
;;;; The z-state arrays are ~72 bytes per input byte (~73 MB at 1 MiB).
;;;; Allocating them per compress made every call drop ~73 MB of
;;;; large-object garbage - roughly one SBCL GC per compress (~3 ms of
;;;; GC tax that C's plain malloc never pays - it was the last remaining
;;;; gap on text q11).  For a given input length the shapes are fixed,
;;;; so a pool reuses them across calls.  The pool is a hash table
;;;; CAPTURED IN A CLOSURE (see MAKE-COMPRESSOR) and bound to the
;;;; dynamic variable *SCRATCH-POOL* around each call: dynamic bindings
;;;; are thread-local in every Common Lisp, so each compressor's pool
;;;; is private to the thread currently inside that closure.  No locks,
;;;; no shared mutable state, no implementation-specific threading
;;;; primitives - concurrent COMPRESS calls remain fully independent
;;;; with no serialization of the work itself.  Entries are capped
;;;; (+SCRATCH-MAX-ENTRIES+ per pool, +SCRATCH-MAX-BYTES+ per entry)
;;;; so retention is bounded and a one-off huge input is never pinned.
;;;; Fresh arrays behave exactly like unpooled ones; pooled arrays are
;;;; proven safe because every read path is either filled per call
;;;; (buckets, znm, zcostf, zlen) or strictly read-after-write
;;;; (forest, zins/zsc/znext via the zlen fill, prefix via the
;;;; in-place estimate), making outputs byte-identical.

(defstruct (cl-brotli-scratch (:conc-name scr-))
  "Pooled per-compress arrays; see ACQUIRE-SCRATCH."
  (zlen nil :type (or null (simple-array fixnum (*))))
  (zins nil :type (or null (simple-array (unsigned-byte 32) (*))))
  (zsc nil :type (or null (simple-array (unsigned-byte 32) (*))))
  (znext nil :type (or null (simple-array (unsigned-byte 32) (*))))
  (zcostf nil :type (or null (simple-array single-float (*))))
  (bt-buckets nil :type (or null (simple-array (unsigned-byte 32) (*))))
  (bt-forest nil :type (or null (simple-array (unsigned-byte 32) (*))))
  (prefix nil :type (or null (simple-array single-float (*))))
  (z-nm nil :type (or null (simple-array (unsigned-byte 32) (*))))
  (z-flat nil :type (or null (simple-array fixnum (*)))))

;; Retention caps: how many distinct input lengths one pool keeps, and
;; the largest entry worth pinning (72 bytes/input-byte + buckets).
;; Constants, not parameters: they bound a cache, they are not tuning
;; knobs for callers.
(defconstant +scratch-max-entries+ 2)
(defconstant +scratch-max-bytes+ (* 192 1048576))

(defvar *scratch-pool* nil
  "Per-compressor scratch pool: a hash table mapping input length N to
a reusable CL-BROTLI-SCRATCH entry, or NIL for no pooling (fresh
arrays every call - what plain COMPRESS does).  This variable is only
ever let-bound around a single call by a MAKE-COMPRESSOR closure;
dynamic bindings are thread-local in every Common Lisp, so a pool is
private to the thread running that closure.  Never set it globally and
never share one pool between threads.")

(defun scratch-estimate-bytes (n)
  "Approximate retained bytes for an N-sized entry (72/byte + buckets)."
  (declare (type fixnum n))
  (+ (* 72 n) 524288))

(defun make-scratch-arrays (n)
  (declare (type fixnum n))
  (make-cl-brotli-scratch
   :zlen (make-array (1+ n) :element-type 'fixnum)
   :zins (make-array (1+ n) :element-type '(unsigned-byte 32))
   :zsc (make-array (1+ n) :element-type '(unsigned-byte 32))
   :znext (make-array (1+ n) :element-type '(unsigned-byte 32))
   :zcostf (make-array (+ n 64) :element-type 'single-float)
   :bt-buckets (make-array 131072 :element-type '(unsigned-byte 32))
   :bt-forest (make-array (* 2 (+ n 8)) :element-type '(unsigned-byte 32))
   :prefix (make-array (+ n 2) :element-type 'single-float)))

(defun ensure-scratch-z-nm (scratch n)
  "Lazily add the HQ-only entry-count array (q10 never needs it)."
  (declare (type cl-brotli-scratch scratch) (type fixnum n))
  (or (scr-z-nm scratch)
      (setf (scr-z-nm scratch)
            (make-array (1+ n) :element-type '(unsigned-byte 32)
                                   :initial-element 0))))

(defun ensure-scratch-z-flat (scratch n)
  "Lazily add the HQ-only prepass record array."
  (declare (type cl-brotli-scratch scratch) (type fixnum n))
  (or (scr-z-flat scratch)
      (setf (scr-z-flat scratch)
            (make-array (* 4 n) :element-type 'fixnum))))

(defun acquire-scratch (n)
  "Scratch arrays for an input of length N.  When *SCRATCH-POOL* is
bound (a MAKE-COMPRESSOR closure) the arrays come from that pool and
are reused across calls; without a pool, or for oversized N, fresh
arrays are returned and never retained - identical to the unpooled
behavior.  Because a pool belongs to exactly one closure, callers never
share it, so no locking is needed and concurrent compresses cannot see
each other's buffers.  The pool holds at most +SCRATCH-MAX-ENTRIES+
entries of at most +SCRATCH-MAX-BYTES+ each (once full it is cleared
rather than grown), so retention is bounded per compressor."
  (declare (type fixnum n))
  (let ((pool *scratch-pool*))
    (if (null pool)
        (make-scratch-arrays n)
        (or (gethash n pool)
            (when (<= (scratch-estimate-bytes n) +scratch-max-bytes+)
              ;; bounded retention: this pool is private to one
              ;; compressor, so dropping it wholesale is safe (the
              ;; arrays are only ever referenced from here)
              (when (>= (hash-table-count pool) +scratch-max-entries+)
                (clrhash pool))
              (setf (gethash n pool) (make-scratch-arrays n)))
            (make-scratch-arrays n)))))

(defun acquire-bwr (n)
  "Pooled output writer: C's GetBrotliStorage reuses the encoder context's
storage_ buffer across every metablock and call - ours reuses one BWR per
compressor, its OUT buffer kept at the high-water mark, so the 64KiB ->
output-size growth (alloc + copy of the old buffer) happens once per
compressor instead of once per compress.  POS/ACC/NBITS are reset on every
acquisition; the stale OUT bytes are overwritten from position zero.
Without a pool (plain COMPRESS) a fresh writer is returned, exactly as
before.  Thread-safety mirrors ACQUIRE-SCRATCH: the pool belongs to one
MAKE-COMPRESSOR closure, and the MT suite runs one compressor per thread."
  (declare (type fixnum n))
  (let ((pool *scratch-pool*))
    (if (null pool)
        (b:make-bwr (min (+ n 1024) 65536))
        (or (let ((w (gethash :bwr pool)))
              (when w
                (setf (b::bwr-pos w) 0
                      (b::bwr-acc w) 0
                      (b::bwr-nbits w) 0)
                w))
            (progn
              (when (>= (hash-table-count pool) +scratch-max-entries+)
                (clrhash pool))
              (setf (gethash :bwr pool)
                    (b:make-bwr (min (+ n 1024) 65536))))))))

(defun acquire-headprev (n chained hbits)
  "Pooled hash-chain tables for %LZ77 - C's ownership model: the hasher's
arrays live in the encoder context (HashMemAllocInBytes, allocated once),
not per metablock.  HEAD (2^HBITS u32) is reset to the #xFFFFFFFF
sentinel on every acquisition: a stale position from another input would
otherwise be read as a candidate (and could index past the current data).
PREV (N u32) is never reset - it is only ever read at positions this
input's INS wrote.  Returns (cons HEAD . PREV); PREV is an empty array
when CHAINED is false (nothing walks it).  Without a pool, fresh arrays
exactly as before."
  (declare (type fixnum n hbits) (type boolean chained)
           (optimize (speed 3) (safety 0)))
  (let ((pool *scratch-pool*))
    (flet ((make-it ()
             (cons (make-array (ash 1 hbits)
                               :element-type '(unsigned-byte 32)
                               :initial-element #xFFFFFFFF)
                   (if chained
                       (make-array n :element-type '(unsigned-byte 32))
                       (make-array 0 :element-type '(unsigned-byte 32))))))
      (if (null pool)
          (make-it)
          (let ((key (- n)))
            (or (let ((entry (gethash key pool)))
                  (when entry
                    (fill (car entry) #xFFFFFFFF)
                    entry))
                (progn
                  (when (>= (hash-table-count pool) +scratch-max-entries+)
                    (clrhash pool))
                  (setf (gethash key pool) (make-it)))))))))

(defun zopfli-analytic-model (data n scratch)
  "C ZopfliCostModelSetFromLiteralCosts: estimated literal costs as a
prefix sum + analytic command/distance costs (log2(11+i)/log2(20+i))."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum n) (optimize (speed 3) (safety 0)))
  (declare (type cl-brotli-scratch scratch))
  (let* (;; pooled: [0] is setf'd, [1..n] written by the in-place
         ;; estimate, and the fused fold only reads [0..n] - no fill
         ;; needed, stale contents never survive the writes
         (prefix (scr-prefix scratch))
         (cc (make-array 704 :element-type 'single-float
                             :initial-element 0.0f0))
         (cd (make-array 64 :element-type 'single-float
                            :initial-element 0.0f0)))
    (declare (type (simple-array single-float (*)) prefix cc cd))
    ;; C writes the raw estimate straight into literal_costs[1..n] and
    ;; folds the prefix sum in place - no separate raw array (saves a
    ;; full n-slot alloc + fill per compress).
    (setf (aref prefix 0) 0.0f0)
    (when (plusp n) (estimate-literal-costs data 0 n prefix))
    ;; fold FUSED into ESTIMATE-LITERAL-COSTS' writes (prefix[i+1] =
    ;; prefix[i] + raw[i], identical arithmetic, saves a 1M-pass)
    (dotimes (i 704)
      (setf (aref cc i) (float (log (float (+ 11 i) 1.0d0) 2.0d0) 1.0f0)))
    (dotimes (i 64)
      (setf (aref cd i) (float (log (float (+ 20 i) 1.0d0) 2.0d0) 1.0f0)))
    (make-zmodel cc cd prefix (float (log 11.0d0 2.0d0) 1.0f0))))

(declaim (inline encode-postfix postfix-extra))
(defun encode-postfix (d np nd)
  "Distance D (>=1) -> distance code under NPOSTFIX=NP NDIRECT=ND; inverse
of decompress.lisp's decode branches (RFC 7932 sect. 4).  For (0, 0) this
is byte-for-byte ENCODE-DISTANCE."
  (declare (type fixnum d np nd))
  (if (<= d nd)
      (+ d 15)
      (let* ((x (- d nd 1))
             (mask (1- (ash 1 np)))
             (lcode (logand x mask))
             (y (ash x (- np)))
             (n (if (= y 0) 1 (- (integer-length (+ y 4)) 2)))
             (b (if (>= y (- (* 3 (ash 1 n)) 4)) 1 0)))
        (declare (type fixnum x mask lcode y n b))
        (+ 16 nd (ash (+ (* 2 (1- n)) b) np) lcode))))

(defun postfix-extra (d np nd)
  "Number of extra distance bits for D under (NP, ND)."
  (declare (type fixnum d np nd))
  (if (<= d nd)
      0
      (let* ((x (- d nd 1))
             (y (ash x (- np))))
        (declare (type fixnum x y))
        (if (= y 0) 1 (- (integer-length (+ y 4)) 2)))))

(defun zopfli-set-cost (histo size literal-p costs)
  "C SetCost: Shannon costs from a histogram; zero-count symbols get
log2(sum+missing)+2 (missing-symbol accounting only for non-literal
histograms)."
  (declare (type (simple-array fixnum (*)) histo)
           (type (simple-array single-float (*)) costs)
           (type fixnum size) (type boolean literal-p)
           (optimize (speed 3) (safety 0)))
  (let ((sum 0))
    (declare (type fixnum sum))
    (dotimes (i size) (incf sum (aref histo i)))
    (let* ((log2sum (fast-log2 sum))
           (missing sum)
           (mcost 0.0d0))
      (declare (type double-float log2sum mcost)
               (type fixnum missing))
      (unless literal-p
        (dotimes (i size) (when (zerop (aref histo i)) (incf missing))))
      (setf mcost (+ (fast-log2 missing) 2.0d0))
      (dotimes (i size)
        (let ((h (aref histo i)))
          (setf (aref costs i)
                (if (zerop h)
                    (float mcost 1.0f0)
                    (float (max 1.0d0 (- log2sum (fast-log2 h)))
                           1.0f0))))))
    costs))

(defun zopfli-set-from-commands (model data n commands)
  "C ZopfliCostModelSetFromCommands: replay COMMANDS to tally the literal,
command, and distance histograms, then refine MODEL's cost tables in
place (Shannon costs via SetCost) and rebuild the literal-cost prefix.
The final insert-only trailing command is not part of C's command stream
(C keeps it in last_insert_len) and is skipped."
  (declare (type zmodel model)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum n) (type list commands)
           (optimize (speed 3) (safety 0)))
  (let ((ins-c +ins-code+) (ins-n (length +ins-code+)) (ins-bs +ins-base+)
        (cpy-c +cpy-code+) (cpy-n (length +cpy-code+)) (cpy-bs +cpy-base+)
        (hl (make-array 256 :element-type 'fixnum :initial-element 0))
        (hc (make-array 704 :element-type 'fixnum :initial-element 0))
        (hd (make-array 64 :element-type 'fixnum :initial-element 0))
        (ct (make-array 256 :element-type 'single-float
                            :initial-element 0.0f0))
        (rb (make-array 5 :element-type 'fixnum
                           :initial-contents '(16 15 11 4 4))))
    (declare (type (simple-array fixnum (*)) hl hc hd rb)
             (type (simple-array single-float (*)) ct))
    (dolist (c commands)
      (let ((ins (car c)) (ls (cadr c)) (cpy (caddr c))
            (dist (cadddr c)) (dictp (car (cddddr c))))
        (declare (type fixnum ins ls cpy dist))
        (when (plusp cpy)
          (let ((icode (length-code1 ins ins-c ins-n ins-bs)))
            (let ((ccode (length-code1 cpy cpy-c cpy-n cpy-bs)))
              (let* ((ring-pos (aref rb 4))
                     (repeat (and (not dictp)
                                  (= dist (aref rb (logand (+ ring-pos 3) 3)))))
                     (dist0 (and repeat (<= icode 7) (< ccode 16)))
                     (csym (if dist0 (cmd-symbol-dist0 icode ccode)
                               (cmd-symbol icode ccode)))
                     (dcode -1))
                (declare (type fixnum ring-pos icode ccode csym dcode)
                         (type boolean repeat dist0))
                (incf (aref hc csym))
                (unless dist0
                  (if repeat
                      (setf dcode 0)
                      (multiple-value-bind (scode sxv sxb)
                          (special-distance-code rb dist)
                        (declare (ignore sxv sxb))
                        (if scode
                            (setf dcode scode)
                            (setf dcode (encode-distance dist)))))
                  (when (>= csym 128) (incf (aref hd dcode)))
                  ;; Distance symbol 0 reuses the last distance without
                  ;; pushing; dictionary references are not pushed either.
                  (unless (or dictp (= dcode 0))
                    (setf (aref rb (logand ring-pos 3)) dist
                          (aref rb 4) (1+ ring-pos))))
                (loop for i of-type fixnum from ls below (+ ls ins)
                      do (incf (aref hl (aref data i))))))))))
    ;; C SetCost on all three histograms, then min-cost-cmd.
    (zopfli-set-cost hl 256 t ct)
    (zopfli-set-cost hc 704 nil (zmodel-cost-cmd model))
    (zopfli-set-cost hd 64 nil (zmodel-cost-dist model))
    (let ((mc +z-infinity+))
      (declare (type single-float mc))
      (dotimes (i 704)
        (let ((v (aref (zmodel-cost-cmd model) i)))
          (declare (type single-float v))
          (when (< v mc) (setf mc v))))
      (setf (zmodel-min-cost-cmd model) mc))
    ;; Literal costs: C's compensated prefix of cost_literal[data[i]]
    (let ((prefix (zmodel-lit-prefix model)) (carry 0.0f0))
      (declare (type (simple-array single-float (*)) prefix)
               (type single-float carry))
      (setf (aref prefix 0) 0.0f0)
      (dotimes (i n)
        (lit-prefix-step prefix i (aref ct (aref data i)) carry)))
    model))
(defun %chain-store-range (sap head prev start end shift hmask chained)
  "C StoreRange for %LZ77's hash chains (H5/H6-like): insert START..END.
Its own function so the per-position loop gets the registers; inside the
matcher's frame it reloaded its operands from stack slots."
  (declare (type ptr sap)
           (type (simple-array (unsigned-byte 32) (*)) head prev)
           (type fixnum start end hmask)
           (type (integer -63 -1) shift)
           (type boolean chained)
           (optimize (speed 3) (safety 0)))
  (if chained
      (loop for q of-type fixnum from start below end do
        (let* ((h (%hash4-sap sap q shift hmask)) (old (aref head h)))
          (declare (type fixnum h old))
          (setf (aref head h) q (aref prev q) old)))
      (loop for q of-type fixnum from start below end do
        (setf (aref head (%hash4-sap sap q shift hmask)) q))))
(declaim (notinline %chain-store-range))

(defun %lz77 (data sap dictv dictsap window use-dict dict-limit base-pos
              max-chain lazy skip-match insert-interior
              &optional (score-p nil) (checks 1)
              (bt nil))
  "Implementation of LZ77.  SAP is a system-area pointer for DATA on SBCL,
or NIL on other implementations.  DICTV is the dictionary vector (NIL when
the dictionary is off) and DICTSAP its SAP: one snapshot taken by LZ77
inside its pinned region and passed down as arguments, so concurrent runs
share no dictionary state.  With SCORE-P (q5+), match selection uses
C's BackwardReferenceScore over the CHECKS-entry prepared distance cache
(4/10/16); otherwise the legacy length-maximizing search runs byte-exact."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type (or null (simple-array (unsigned-byte 8) (*))) dictv)
           (type fixnum window base-pos max-chain checks)
           (type boolean score-p)
           (optimize (speed 3) (safety 0)))
  (declare (type ptr sap) (type (or null ptr) dictsap))
  (let* ((n (length data)) (min-match 4)
         ;; Zopfli DP node arrays are whole-input sized (~52 bytes/byte of
         ;; input): cap BT/DP activation so 16 MiB chunks fall back to the
         ;; score path (C runs the DP per ~128 KiB metablock; per-chunk DP
         ;; partitioning is future work).
         (bt (if (and bt (<= n #.(ash 1 23))) bt nil)))
    (if (< n min-match)
        ;; Tiny input: one insert-only command, in the same flat 5-fixnum
        ;; vector shape the rest of this function returns.
        (if (zerop n)
            (make-array 0 :element-type 'fixnum)
            (make-array 5 :element-type 'fixnum
                         :initial-contents (list n 0 0 0 0)))
        (let* ((hbits 17) (hmask (1- (ash 1 hbits)))
               (chained (and (not bt) (> max-chain 1)))
               ;; H10 binary-tree matcher (q10/11, C hash_to_binary_tree):
               ;; 17-bit buckets, two forest slots per position, insertion
               ;; watermark (positions below BT-NEXT are already stored),
               ;; 128-entry match scratch.  BT is the short-back scan size.
               (bt-short (if (integerp bt) bt 16))
               ;; pooled big arrays (see ACQUIRE-SCRATCH); NIL for the
               ;; score path (BT inactive) - the z-labels never run then
               (scratch (and bt (acquire-scratch n)))
               (bt-buckets (and scratch (scr-bt-buckets scratch)))
               ;; No initial fill: like C (Prepare clears buckets only),
               ;; every forest read is preceded by a write - the bucket
               ;; root and every chained prev were written on all of
               ;; their insert's exit paths, and the current node's slots
               ;; are only ever written (termination, >=comp, or branch).
               ;; Saves an 8 MB memset per compress.
               (bt-forest (and scratch (scr-bt-forest scratch)))
               (bt-next 0) (bt-cnt 0) (bt-cpos -1) (bt-cbest 0)
               (bt-md (and bt (make-array 128 :element-type 'fixnum)))
               (bt-ml (and bt (make-array 128 :element-type 'fixnum)))
               ;; Zopfli DP state (only when BT is active)
               (zmodel (if bt (zopfli-analytic-model data n scratch)
                           (load-time-value (make-zmodel (load-time-value (make-array 0 :element-type 'single-float) t) (load-time-value (make-array 0 :element-type 'single-float) t) (load-time-value (make-array 0 :element-type 'single-float) t) 1.0f0) t)))
               ;; 64 cells of padding beyond N: ComputeMinimumCopyLength's
               ;; scan then needs no num_bytes bound check - the +infinity
               ;; padding stops it at exactly the length C's bound would
               ;; (nodes[N+1..] are never real nodes for the other users,
               ;; which all stay <= N).
               (zcostf (if scratch (scr-zcostf scratch) (load-time-value (make-array 0 :element-type 'single-float) t)))
               ;; No :initial-element on the big arrays: z-iterate FILLs
               ;; them before any read (the initial-element form consed a
               ;; second full-array fill per compress).
               (zlen (if scratch (scr-zlen scratch) (load-time-value (make-array 0 :element-type 'fixnum) t)))
               ;; u32: ZINS = (short<<27)|insert fits EXACTLY 32 bits
               ;; (short<=31, insert<2^23), ZSC values < 2^23 - halves
               ;; 16 MB of per-compress allocation and doubles cache
               ;; density for two arrays read on every DP position.
               ;; All reads mask/shift as before (u32 arefs yield the
               ;; same fixnums); stores truncate identically (values
               ;; provably fit).
               (zins (if scratch (scr-zins scratch) (load-time-value (make-array 0 :element-type '(unsigned-byte 32)) t)))
               (zsc (if scratch (scr-zsc scratch) (load-time-value (make-array 0 :element-type '(unsigned-byte 32)) t)))
               ;; u32: command lengths (< 2^23) + the reconstruction
               ;; sentinel (#xFFFFFFFF) - halves another 8 MB; the walk
               ;; compares the sentinel explicitly.
               (znext (if scratch (scr-znext scratch) (load-time-value (make-array 0 :element-type '(unsigned-byte 32)) t)))
               (zq (if bt (make-zpq) (load-time-value (make-zpq) t)))
               (z-sdc (make-array 4 :element-type 'fixnum
                                     :initial-contents '(4 11 15 16)))
               (z-dc (make-array 4 :element-type 'fixnum))
               ;; Dictionary distances are packed (STAMP << 26 | DIST):
               ;; the consumer tests the stamp instead of zero-testing, so
               ;; the per-probe 25-element clear disappears.  -1 can never
               ;; equal a position stamp (and keeps first-use deterministic).
               (z-dmatch (if bt (make-array 25 :element-type 'fixnum
                                            :initial-element -1)
                             (load-time-value (make-array 25 :element-type 'fixnum
                                                             :initial-element -1)
                                              t)))
               ;; HQ (q11) pre-collected match storage: one packed entry per
               ;; match, (dist << 25) | (dict-flag << 24) | len.
               (z-nm (if (and scratch (>= bt 64))
                         (ensure-scratch-z-nm scratch n)
                         (load-time-value (make-array 0 :element-type '(unsigned-byte 32)) t)))
               ;; C allocates 4 * num_bytes matches; we clamp at the same
               ;; (4 * n) capacity (measured corpora peak at 3.77/byte).
               (z-flat (if (and scratch (>= bt 64))
                           (ensure-scratch-z-flat scratch n)
                           (load-time-value (make-array 0 :element-type 'fixnum) t)))
               (z-cands (if (and bt (>= bt 64)) 2 1))
               (z-maxlen (if (and bt (>= bt 64)) 325 150))
               ;; Loop invariants for the DP l-loops, bound once: the
               ;; table length was re-read (symbol + array header) and
               ;; cmd-symbol re-multiplied (icode * 24) on every one of
               ;; the 25-50M length iterations per MiB.
               (cpy-n (length +cpy-code+))
               (ins-n (length +ins-code+))
               (cmd-tab +cmd-symbol-table+)
               ;; The l-loops' length-code tables: bound as LEXICALS so
               ;; the inlined LENGTH-CODE-F body reads frame slots.  As
               ;; literal defparameter refs each table went through
               ;; symbol+value indirection ON EVERY l-iteration (~6
               ;; instructions x 4 tables - the disassembly's loop head
               ;; re-loaded +CPY-CODE+/+CPY-XBITS-F+/+CPY-BASE+/+CPY-BITS+
               ;; through the symbol each pass; SBCL never hoists
               ;; symbol-value loads out of loops).
               (cpy-c +cpy-code+) (cpy-xf +cpy-xbits-f+)
               (cpy-bs +cpy-base+) (cpy-bt +cpy-bits+)
               (ins-c +ins-code+) (ins-xf +ins-xbits-f+)
               (ins-bs +ins-base+) (ins-bt +ins-bits+)
               ;; same symbol-indirection reason: the short loop reads
               ;; this table 16x per position
               (zdc-jo +zdc-jo+)
               ;; C owns its hasher arrays for the encoder's lifetime
               ;; (HashMemAllocInBytes); pooled they are allocated once per
               ;; compressor instead of fresh per call (head 512KiB + prev
               ;; Nx4 = 4.5MiB at 1MiB inputs - the Rev 164 allocation
               ;; cost, paid every call).  HEAD is re-sentinel'd on every
               ;; acquisition; PREV carries no invariant (it is only read
               ;; at positions this input's INS wrote).  BT mode walks
               ;; neither - empty arrays keep the type declares honest.
               (hp (if bt
                       (cons (make-array 0 :element-type
                                            '(unsigned-byte 32))
                             (make-array 0 :element-type
                                            '(unsigned-byte 32)))
                       (acquire-headprev n chained hbits)))
               ;; THE at the bindings: the (IF BT ... ACQUIRE-HEADPREV)
               ;; initializer's type is unknown, which defeated the
               ;; declarations below - every head/prev aref compiled to an
               ;; outlined accessor call (26% of source q7 in VECTOR-HAIRY/
               ;; OPTIMIZED-DATA-VECTOR-REF/SET).  Asserting the type where
               ;; it is bound restores the inlined open-coded access.
               (head (the (simple-array (unsigned-byte 32) (*))
                          (car hp)))
               (prev (the (simple-array (unsigned-byte 32) (*))
                          (cdr hp)))
               ;; Initial capacity mirrors the fragment's PUSH-CMD policy
               ;; (n/32 commands, floor 4096 = 160KiB at 1MiB): sizing it
               ;; at n/8 cost 5.2MiB upfront on EVERY call, which dominated
               ;; command-sparse corpora (TEXT q2 -34% in the r163 sweep -
               ;; fixed cost, not per-command work).  Growth doubles from
               ;; here; the exact-size SUBSEQ at return is proportional to
               ;; the real command count.
               ;; Pooled per compressor (high-water mark) and returned
               ;; untrimmed with its used length, like the quick/H6
               ;; matchers' vectors: the old exact-size SUBSEQ plus the
               ;; doubling made ~6 MB of garbage per MiB of text at q7.
               (cmds (pooled-fixnums :lz77-cmds (* 5 (max 4096 (ash n -5)))))
               (ncmd 0) (lit-start 0) (p 0) (last (- n min-match))
               (skip 32) (dict-used 0) (last-dist 0)
               ;; NIL dict-limit means "no limit": folding it into one
               ;; fixnum local keeps every gate a fixnum compare (the
               ;; (OR NULL FIXNUM) parameter made SBCL emit GENERIC-<
               ;; at all three probe gates).
               (dlim (the fixnum (or dict-limit most-positive-fixnum)))
               ;; One dictionary-index snapshot for the whole run (NIL
               ;; when the dictionary is off): read once here, passed
               ;; down as an argument - the hot paths never touch a
               ;; global.
               (dictidx (and use-dict (dict-index)))
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
               (min-cop (if score-p 2 min-match))
               ;; Legacy lazy shape: the FIND-MATCH result for P+1 that
               ;; made the parser step forward, reused at the next
               ;; iteration instead of searching P+1 a second time (the
               ;; tables are unchanged in between).  CARRY-LEN < 0 = none.
               (carry-len -1) (carry-dist 0))
          (declare (type (cons (simple-array (unsigned-byte 32) (*))
                                (simple-array (unsigned-byte 32) (*)))
                         hp)
                   (type (simple-array (unsigned-byte 32) (*)) head)
                   (type (or null (simple-array (unsigned-byte 32) (*)))
                         bt-buckets bt-forest)
                   (type (or null (simple-array fixnum (128))) bt-md bt-ml)
                   (type fixnum bt-short bt-next bt-cnt bt-cpos bt-cbest)
                   ;; NIL when the dictionary is off; the two dict probe
                   ;; sites only run under USE-DICT, i.e. with a pair.
                   (type (or null (cons (simple-array fixnum (*))
                                        (simple-array fixnum (65537))))
                         dictidx)
                   ;; Plain (non-null) types: the z-state is only ever
                   ;; touched from the z-labels, which run iff BT is active;
                   ;; the (or null ...) form forced a hairy type check on
                   ;; every aref.
                   (type zmodel zmodel)
                   (type (simple-array single-float (*)) zcostf)
                   (type (simple-array fixnum (*))
                         zlen)
                         (type (simple-array (unsigned-byte 32) (*)) zins zsc)
                   (type (simple-array fixnum (25)) z-dmatch)
                   (type (simple-array fixnum (4)) z-sdc)
                   (type (simple-array fixnum (*)) z-flat)
                   (type (simple-array (unsigned-byte 32) (*)) z-nm znext)
                   (type zpq zq)
                   (type (simple-array fixnum (4)) z-dc)
                   (type fixnum z-cands z-maxlen)
                   (type (or null (simple-array fixnum (*))) dc)
                   (type fixnum carry-len carry-dist)
                   (type (integer 0 #.(ash 1 40)) ncmd)
                   (type fixnum p lit-start last skip dict-used last-dist
                            min-cop)
                   ;; SHIFT = hbits - 64 is always in -63..-1 (hbits 1..63),
                   ;; so ASH compiles to ONE sar/shr by CL instead of the
                   ;; generic sign-check + clamp + branch dance that ran on
                   ;; EVERY hash (trawl iterations + interior stores)
                   (type (integer -63 -1) shift))
          ;; Pooled arrays: the clears that used to ride along with
          ;; :INITIAL-ELEMENT now run here, before any bt-do/prepass
          ;; read (z-costf/zlen are filled per pass in Z-ITERATE as
          ;; before; forest/zins/zsc/znext/prefix/zflat are strictly
          ;; read-after-write).
          (when scratch
            (fill (scr-bt-buckets scratch) #xFFFFFFFF)
            (when (>= bt 64)
              (fill (scr-z-nm scratch) 0)))
          (labels ((hash (i)
                     ;; the 8-byte load in %hash4-sap needs the tail branch
                     ;; for i within 3 bytes of the end
                     (if (<= (+ i 8) n)
                         (%hash4-sap sap i shift hmask)
                         (%hash4-tail data i shift hmask)))
                   (mlen (a b) (%match-len-sap sap a b n))
                   (mlen2 (a b e) (%match-len-sap sap a b e))
                   (ins (q h)
                     (declare (type fixnum q h))
                     (if bt
                         (when (>= q bt-next)
                           (bt-do q nil))
                         (let ((old (aref head h)))
                           (declare (type fixnum old))
                           (setf (aref head h) q)
                           (when chained (setf (aref prev q) old)))))
                   (probe-ok (cand best-len psap maxl)
                     ;; PSAP = SAP+POS and MAXL = N-POS are hoisted once per
                     ;; search by each caller (loop invariants), so the probe
                     ;; no longer re-untags POS or recomputes N-POS per candidate.
                     (declare (type fixnum best-len maxl)
                              (type ptr-off psap))
                     ;; C's filter (FindLongestMatch): a match LONGER than
                     ;; BEST-LEN needs every byte of [0..BEST-LEN] equal, so
                     ;; testing only the byte at BEST-LEN is a necessary
                     ;; condition - weaker than the old 4/8-byte window but
                     ;; OUTCOME-IDENTICAL: a candidate that fails the old
                     ;; window has MLEN <= BEST-LEN anyway, so it could never
                     ;; update.  Weaker means more MLEN calls, which is cheap
                     ;; now that MLEN is the 16-byte SSE2 scan; in return this
                     ;; drops ~10 instructions and the (- N POS) spill reload
                     ;; from every probe.  CAND < POS at all five call sites
                     ;; (chain stores are jumped past), so the POS bounds
                     ;; check covers the CAND read too.
                     (if (>= best-len 3)
                         ;; (< best-len maxl)  ==  (<= (+ pos best-len 1) n)
                         (if (< best-len maxl)
                             (= (off-u8 sap psap best-len)
                                (ptr-u8 sap (+ cand best-len)))
                             t)
                         ;; BEST-LEN < 3 keeps the exact old 4-byte window at
                         ;; offset 0: a byte-3-only test would be too weak
                         ;; here, because MLEN could return 1..3 and UPDATE a
                         ;; short BEST-LEN that the old window suppressed.
                         ;; (>= maxl 4)  ==  (<= (+ pos 4) n)
                         (if (>= maxl 4)
                             (= (off-u32 sap psap 0)
                                (ptr-u32 sap cand))
                             t)))
                   (bt-hash (i)
                     "C H10 HashBytes: the low 32 bits of load32(I) *
kHashMul32 shifted down by 15 (17-bit bucket)."
                     (declare (type fixnum i))
                     (let ((w (if (<= (+ i 4) n)
                                  (ptr-u32 sap i)
                                  (logior (aref data i)
                                          (ash (aref data (1+ i)) 8)
                                          (ash (aref data (+ i 2)) 16)
                                          (ash (aref data (+ i 3)) 24)))))
                       (declare (type (unsigned-byte 32) w))
                       (logand (ash (logand (* w #x1E35A7BD) #xFFFFFFFF) -15)
                               #x1FFFF)))
                   (cache-scan (pos bl bd bs)
                     "C FindLongestMatch's distance-cache candidate loop
(the CHECKS-entry cache with PrepareDistanceCache cascade).  Returns the
improved (values len dist score)."
                     (declare (type fixnum pos bl bd bs))
                     (let ((best-len bl) (best-dist bd) (best-score bs)
                           (i 0))
                       (declare (type fixnum best-len best-dist best-score i))
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
                                 (let ((score (- (+ 1935 (* 135 (the (integer 0 #.(ash 1 40)) ml)))
                                                 (if (plusp i)
                                                     (penalty i) 0))))
                                   (declare (type fixnum score))
                                   (when (> score best-score)
                                     (setf best-score score
                                           best-len ml best-dist dist)))))))
                         (incf i))
                       (values best-len best-dist best-score)))
                   ;; ---- H10 binary-tree matcher (q10/11), C
                   ;; ---- hash_to_binary_tree_inc.h ------------------------
                   (bt-do (pos collect)
                     "C FindAllMatches: the short-backward scan (COLLECT
only) then StoreAndFindMatches, which inserts POS into its bucket's BST.
Fills BT-MD/BT-ML[0..BT-CNT) with matches of strictly increasing length and
returns the best length.  Positions below the BT-NEXT watermark are already
stored; a re-dispatch at the position just searched (the legacy lazy gate)
returns the cached result."
                     (declare (type fixnum pos) (type boolean collect))
                     (cond
                       ((= pos bt-cpos) bt-cbest)
                       ((< pos bt-next) 0)
                       (t
                        (setf bt-cnt 0 bt-cpos pos)
                        (setf bt-next (1+ pos))
                        (let ((best 1) (cnt 0)
                              ;; C: FindAllMatches scans up to the block
                              ;; remainder, but Store/StoreRange pass
                              ;; MAX_TREE_COMP_LENGTH (128) - interior store
                              ;; scans are capped the same way (unbounded
                              ;; store scans were the text/source blowup).
                              (max-len (if collect (- n pos)
                                           (min 128 (- n pos)))))
                          (declare (type fixnum best cnt max-len))
                          (when collect
                            ;; C's short-backward scan: catches short matches
                            ;; whose 4-byte hashes differ.
                            (let ((stop (max 0 (- pos bt-short))))
                              (declare (type fixnum stop))
                              ;; BT-SHORT is at most 64 (bt is nil/16/64)
                              ;; and every brotli window is >= 1008, so the
                              ;; backward distance here (<= 63) can never
                              ;; exceed the window - C's per-iteration
                              ;; max_backward break is dead code we drop.
                              ;; POS1/DB0/DB1 are loop-invariant: gcc LICMs
                              ;; these loads, SBCL does not - hoisting saves
                              ;; two frame reloads + address computes on each
                              ;; of the 15.6M scan iterations per MiB.
                              (let ((pos1 (1+ pos))
                                    (db0 (aref data pos))
                                    (db1 (aref data (1+ pos))))
                                (declare (type fixnum pos1)
                                         (type (unsigned-byte 8) db0 db1))
                                (loop for i of-type fixnum
                                        from (1- pos) downto (1+ stop)
                                      while (<= best 2) do
                                  (when (and (= db0 (aref data i))
                                             (= db1 (aref data (1+ i))))
                                  (let ((len (mlen i pos)))
                                    (declare (type fixnum len))
                                    (when (> len best)
                                      (setf best len)
                                      (setf (aref bt-md cnt) (- pos i)
                                            (aref bt-ml cnt) len)
                                      (incf cnt))))))))
                          (when (< best max-len)
                            (let* ((comp (min max-len 128))
                                   (reroot (>= max-len 128))
                                   (key (bt-hash pos))
                                   (prev (aref bt-buckets key))
                                   (node-left (* 2 pos))
                                   (node-right (1+ node-left))
                                   (bl-left 0) (bl-right 0)
                                   (depth 64)
                                   ;; both loop invariants: the mlen2 scan
                                   ;; end and the window bound (POS - WINDOW)
                                   ;; were recomputed on every tree step
                                   (mend (+ pos max-len))
                                   (min-prev (- pos window)))
                              (declare (type fixnum comp key prev node-left
                                             node-right bl-left bl-right depth
                                             mend min-prev)
                                       (type boolean reroot))
                              (when reroot (setf (aref bt-buckets key) pos))
                              (loop
                                ;; PREV >= POS covers the sentinel
                                ;; (#xFFFFFFFF read as a fixnum) and
                                ;; PREV = POS; PREV < POS - WINDOW is the
                                ;; old (> BACKWARD WINDOW) - both compare-
                                ;; only, no per-step subtraction.
                                (when (or (<= pos prev)
                                          (< prev min-prev)
                                          (<= depth 0))
                                    (when reroot
                                      (setf (aref bt-forest node-left)
                                            #xFFFFFFFF
                                            (aref bt-forest node-right)
                                            #xFFFFFFFF))
                                    (return))
                                (decf depth)
                                (let* ((clen (min bl-left bl-right))
                                       (len (+ clen
                                               ;; A < B contract: candidate
                                               ;; side first; scan end
                                               ;; POS+MAX-LEN = C's
                                               ;; max_length - cur_len limit
                                               ;; (128 for store scans).
(mlen2 (+ prev clen)
                                                      (+ pos clen)
                                                      mend))))
                                  (declare (type fixnum clen len))
                                  (when (and collect (> len best))
                                    (setf best len)
                                    (setf (aref bt-md cnt) (- pos prev)
                                          (aref bt-ml cnt) len)
                                    (incf cnt))
                                  (when (>= len comp)
                                    (when reroot
                                      (setf (aref bt-forest node-left)
                                            (aref bt-forest (* 2 prev))
                                            (aref bt-forest node-right)
                                            (aref bt-forest (1+ (* 2 prev)))))
                                    (return))
                                  (if (> (aref data (+ pos len))
                                         (aref data (+ prev len)))
                                      (progn
                                        (setf bl-left len)
                                        (when reroot
                                          (setf (aref bt-forest node-left)
                                                prev))
                                        (setf node-left (1+ (* 2 prev))
                                              prev (aref bt-forest node-left)))
                                      (progn
                                        (setf bl-right len)
                                        (when reroot
                                          (setf (aref bt-forest node-right)
                                                prev))
                                        (setf node-right (* 2 prev)
                                              prev (aref bt-forest
                                                         node-right))))))))
                          (setf bt-cnt cnt bt-cbest best)
                          best))))
                   (bt-longest (pos)
                     "Longest match at POS from the tree (legacy shape)."
                     (declare (type fixnum pos))
                     (let ((best-len 0) (best-dist 0))
                       (declare (type fixnum best-len best-dist))
                       (bt-do pos t)
                       (dotimes (i bt-cnt)
                         (declare (type fixnum i))
                         (when (>= (aref bt-ml i) best-len)
                           (setf best-len (aref bt-ml i)
                                 best-dist (aref bt-md i))))
                       (values best-len best-dist 0)))
                   (bt-score (pos)
                     "Cache candidates (C FindLongestMatch's first half) plus
tree candidates scored with the same 1920+135*len-30*ilog2 formula the
chain walk uses."
                     (declare (type fixnum pos))
                     (multiple-value-bind (best-len best-dist best-score)
                         (cache-scan pos 0 0 2020)
                       (declare (type fixnum best-len best-dist best-score))
                       (bt-do pos t)
                       (dotimes (i bt-cnt)
                         (declare (type fixnum i))
                         (let* ((d (aref bt-md i))
                                (ml (aref bt-ml i)))
                           (declare (type fixnum d ml))
                           ;; same >=4 floor as the chain walk: the short
                           ;; backward scan's 2-3 byte copies lost ratio
                           ;; where the chain would have offered nothing.
                           (when (>= ml 4)
                             (let ((score (+ 1920 (* 135 (the (integer 0 #.(ash 1 40)) ml))
                                             (- (* 30 (1- (integer-length d)))))))
                               (declare (type fixnum score))
                               (when (> score best-score)
                                 (setf best-score score
                                       best-len ml best-dist d))))))
                       (values best-len best-dist best-score)))
                   ;; ---- Zopfli DP core (C backward_references_hq) --------
                   (z-cache (pos)
                     "C ComputeDistanceCache: the four last distances at POS
following the shortcut chain, then the stream-starting cache."
                     (declare (type fixnum pos))
                     (let ((idx 0) (p (aref zsc pos)))
                       (declare (type fixnum idx p))
                       (loop while (and (< idx 4) (> p 0)) do
                         (let* ((zv (aref zlen p))
                                (clen (logand zv #xFFFFFF)))
                           (declare (type fixnum zv clen))
                           (if (= clen 1)
                               ;; stub: C's initialized distance is 0 and
                               ;; its shortcut chain steps to p - 1.
                               (progn
                                 (setf (aref z-dc idx) 0)
                                 (incf idx)
                                 (setf p (aref zsc (1- p))))
                               (let ((ins (logand (aref zins p) #x7FFFFFF)))
                                 (declare (type fixnum ins))
                                 ;; distance packed into ZLEN bits 25..50
                                 (setf (aref z-dc idx) (ash zv -25))
                                 (incf idx)
                                 (setf p (aref zsc (- p clen ins)))))))
                       (loop for i of-type fixnum from idx below 4 do
                         (setf (aref z-dc i) (aref z-sdc i))))
                     z-dc)
                   (z-shortcut (pos)
                     "C ComputeDistanceShortcut: POS when its command pushes
the ring (non-dictionary, not short code 1), else the predecessor's
shortcut."
                     (declare (type fixnum pos))
                     (if (zerop pos)
                         0
                         (let* ((zv (aref zlen pos))
                                (clen (logand zv #xFFFFFF)))
                           (declare (type fixnum zv clen))
                           (if (= clen 1)
                               ;; stub / unwritten: zins = 0, dictp bit clear
                               pos
                               (let* ((ins (logand (aref zins pos) #x7FFFFFF))
                                      (short (ash (aref zins pos) -27)))
                                 (declare (type fixnum ins short))
                                 ;; C ComputeDistanceShortcut: shortcut = POS
                                 ;; iff the copy updates the last distances:
                                 ;; not a dictionary reference and distance
                                 ;; code > 0.  Code 0 is short code 1 (repeat
                                 ;; last); codes 1..15 (our short 2..16) DO
                                 ;; push and must land on POS, not on the
                                 ;; predecessor.
                                 (if (and (zerop (logand zv #x1000000))
                                          (/= short 1))
                                     pos
                                     (aref zsc (- pos clen ins))))))))
                   (z-update-node (pos start len dist short dictp cost)
                     "C UpdateZopfliNode plus our dictionary flag packed
into ZLEN bit 24 (our length code always equals the copy length - the
length-preserving transforms - so C's packed len_code modifier at bits
25+ was write-only dead weight, and the separate ZDICT array is gone:
both readers already had ZLEN in hand)."
                     ;; Tight ranges: the DP only runs for inputs <= 2^23
                     ;; bytes, distances < 2^26 and SHORT/DICTP are 5/1-bit
                     ;; fields - so the packed writes provably fit a fixnum
                     ;; and compile to plain shifts/logior (loose FIXNUM
                     ;; declarations made every node write take the
                     ;; overflow-checked path with ALLOC-SIGNED-BIGNUM).
                     (declare (type (integer 0 #x7FFFFF) pos start)
                              (type (integer 0 #xFFFFFF) len)
                              (type (integer 0 #x3FFFFFF) dist)
                              (type (integer 0 31) short)
                              (type (integer 0 1) dictp)
                              (type single-float cost)
                              (optimize (speed 3) (safety 0)))
                     (let ((q (+ pos len)))
                       (declare (type fixnum q))
                       ;; DIST packs into ZLEN bits 25..50 (dist < 2^26):
                     ;; both zdist readers (z-cache, path reconstruction)
                     ;; already had ZLEN in hand, so the separate 8 MB
                     ;; array and its per-node store are gone.
                     (setf (aref zlen q) (logior len (ash dictp 24)
                                                  (ash dist 25))
                             (aref zins q) (logior (ash short 27)
                                                   (- pos start))
                             (aref zcostf q) cost)))
                   (z-eval (pos)
                     "C EvaluateNode: record the shortcut, and queue POS
when the command path is cheaper than pure literals."
                     (declare (type fixnum pos))
                     (let ((cost (aref zcostf pos))
                           (prefix (zmodel-lit-prefix zmodel)))
                       (declare (type single-float cost)
                                (type (simple-array single-float (*)) prefix))
                       (setf (aref zsc pos) (z-shortcut pos))
                       (when (<= cost (aref prefix pos))
                         (z-cache pos)
                         (zq-push zq pos cost (- cost (aref prefix pos))
                                  (aref z-dc 0) (aref z-dc 1)
                                  (aref z-dc 2) (aref z-dc 3)))))
                   (z-minlen (start-cost pos)
                     "C ComputeMinimumCopyLength.  A walking index keeps
the array address in one register instead of recomputing (+ POS LEN)
twice per iteration (C's loop keeps it in one register too)."
                     (declare (type fixnum pos) (type single-float start-cost))
                     (let ((min-cost start-cost) (len 2)
                           (bucket 4) (offset 10)
                           (idx (+ pos 2))
                           (stop (+ pos 10)))
                       (declare (type single-float min-cost)
                                (type fixnum len bucket offset idx stop))
                       (loop while (<= (aref zcostf idx) min-cost)
                             do (incf len)
                                (incf idx)
                                (when (= idx stop)
                                  (incf min-cost 1.0f0)
                                  (incf stop bucket)
                                  (setf bucket (ash bucket 1))))
                       len))
                   (z-update (pos dict-p)
                     "C UpdateNodes: evaluate POS, then try short-code,
match, and (when DICT-P) dictionary candidates from every queued start
position.  Returns the longest newly-reached copy length."
                     (declare (type fixnum pos) (type boolean dict-p))
                     (let ((max-len (- n pos)) (result 0))
                       (declare (type fixnum max-len result))
                       (z-eval pos)
                       (let* ((pos-a (zpq-pos zq))
                              (cost-a (zpq-cost zq))
                              (cd-a (zpq-costdiff zq))
                              (dc-a (zpq-dc zq))
                              (cmd-a (zmodel-cost-cmd zmodel))
                              (dst-a (zmodel-cost-dist zmodel))
                              (k0 (zq-at zq 0))
                              (prefix (zmodel-lit-prefix zmodel))
                              (min-cost
                                (+ (aref cost-a k0)
                                   (zmodel-min-cost-cmd zmodel)
                                   (- (aref prefix pos)
                                      (aref prefix (aref pos-a k0)))))
                              (min-len (z-minlen min-cost pos)))
                         (declare (type fixnum k0 min-len)
                                  (type (simple-array single-float (*)) prefix)
                                  (type single-float min-cost))
                         (loop for k of-type fixnum
                                 below (min z-cands (zq-size zq)) do
                           (let* ((ki (zq-at zq k))
                                  (start (aref pos-a ki)))
                             (declare (type fixnum ki start))
                             (multiple-value-bind (icode ixbf)
                                 (length-code-f (- pos start) ins-c ins-n
                                              ins-xf ins-bs ins-bt)
                               (let ((base (+ (aref cd-a ki)
                                              ixbf
                                              (aref prefix pos)))
                                       (cmd-base (* icode 24))
                                       (icode8 (* icode 8)))
                                 ;; insert codes are 0..23 (+ins-code+ is
                                 ;; a 24-row table), so the derived indices
                                 ;; have tiny provable ranges - this keeps
                                 ;; the dist0 cmdc arithmetic in fixnum
                                 ;; registers (it was compiling to the
                                 ;; generic/bignum path per l-iteration).
                                 (declare (type (integer 0 23) icode)
                                          (type (integer 0 552) cmd-base)
                                          (type (integer 0 184) icode8)
                                          (type single-float base))
                                 ;; --- 16 short-distance candidates ---
                                 (let ((best (1- min-len)) (j 0)
                                       (dc0 (* 4 ki))
                                       ;; pos+best and its byte are invariant
                                       ;; across j until a longer match lands
                                       (pb (+ pos (1- min-len)))
                                       ;; (only read when the loop runs:
                                       ;; near the end PB can be = N)
                                       (left (let ((i (+ pos (1- min-len))))
                                               (if (< i (length data))
                                                   (aref data i)
                                                   0))))
                                   (declare (type fixnum best j dc0 pb)
                                            (type (unsigned-byte 8) left))
                                   (loop while (and (< j 16) (< best max-len))
                                         do
                                     (let* ((jo (aref zdc-jo j))
                                            (back (+ (aref dc-a
                                                       (+ dc0 (ash jo -4)))
                                                     (- (logand jo #xF) 8))))
                                       (declare (type (unsigned-byte 8) jo)
                                                (type fixnum back))
                                       (incf j)
                                       ;; C: max_distance = min(pos, window),
                                       ;; prev_ix >= cur_ix => continue, and
                                       ;; the continuation-byte prefilter.
                                       (when (and (>= back 1) (<= back pos)
                                                  (<= back window)
                                                  (< pb n)
                                                  (= left
                                                     (aref data (- pb back))))
                                         (let ((len (mlen (- pos back) pos)))
                                           (declare (type fixnum len))
                                           (when (> len best)
                                             (let ((l (1+ best))
                                                   (dist-add
                                                     (aref dst-a (1- j)))
                                                   ;; invariant across the
                                                   ;; l-loop (j and icode fixed)
                                                   (dist0 (and (= j 1)
                                                               (< icode 8))))
                                               (declare (type fixnum l)
                                                        (type single-float
                                                               dist-add)
                                                        (type boolean dist0))
                                               (loop while (<= l len) do
                                                 (progn
                                                 (multiple-value-bind (cc cxbf)
                                                     (length-code-f l cpy-c cpy-n cpy-xf
                                                                    cpy-bs cpy-bt)
                                                   (let* ((cmdc
                                                            (if (and dist0
                                                                     (< cc 16))
                                                                (+ (* (ash cc -3) 64)
                                                                   icode8
                                                                   (logand cc 7))
                                                                (aref cmd-tab
                                                                      (+ cmd-base cc))))
                                                     (cost
                                                       (+ (if (< cmdc 128)
                                                              base
                                                              (+ base dist-add))
                                                          cxbf
                                                          (aref cmd-a cmdc))))
                                                     ;; copy codes are 0..23
                                                     (declare (type (integer 0 23) cc)
                                                              (type fixnum cmdc)
                                                              (type single-float cost))
                                                     (when (< cost (aref zcostf (+ pos l)))
                                                       (z-update-node pos start l back j 0 cost)
                                                       (when (> l result)
                                                         (setf result l)))))
                                             (setf best l)
                                             (incf l))))
                                   (setf pb (+ pos best))
                                   (when (< pb n)
                                     (setf left (aref data pb)))))))))
                                 ;; --- BT + dictionary match candidates ---
                                 ;; C keeps `len` across the match loop: each
                                 ;; copy length is tried with the first match
                                 ;; that reaches it (O(total lengths), not
                                 ;; O(matches x lengths)), and computes the
                                 ;; distance cost once per match.
                                 (unless (>= k 2)
                                   ;; C's matches[] = BT matches followed by
                                   ;; one dictionary match per length (the
                                   ;; dict matches carry their own length),
                                   ;; with `len` carried across the loop.
                                   (let ((mi 0) (dl 4) (len min-len))
                                     (declare (type fixnum mi dl len))
                                     (loop
                                       (let ((dist 0) (max-m 0) (isdict 0))
                                         (declare (type fixnum dist max-m isdict))
                                         (cond
                                           ((< mi bt-cnt)
                                            (setf dist (aref bt-md mi)
                                                  max-m (aref bt-ml mi))
                                            (incf mi))
                                           ((and dict-p (<= dl 24))
                                            (loop while (and (<= dl 24)
                                                             (/= (ash (aref z-dmatch dl) -26)
                                                                 pos))
                                                  do (incf dl))
                                            (when (> dl 24)
                                              (return))
                                            (setf dist (logand (aref z-dmatch dl)
                                                               #x3FFFFFF)
                                                  max-m dl
                                                  isdict 1)
                                            (incf dl))
                                           (t (return)))
                                         (when (and (< len max-m)
                                                    (or (plusp isdict)
                                                        (> max-m z-maxlen)))
                                           (setf len max-m))
                                         (multiple-value-bind (dcode dxv)
                                             (encode-postfix dist 0 0)
                                           (declare (ignore dxv))
                                           (let ((dist-cost
                                                   (+ base
                                                      (float (postfix-extra
                                                              dist 0 0) 1.0f0)
                                                      (aref dst-a dcode))))
                                             (declare (type fixnum dcode)
                                                      (type single-float
                                                             dist-cost))
                                             (loop while (<= len max-m) do
                                               (multiple-value-bind (cc cxbf)
                                                   (length-code-f len cpy-c cpy-n cpy-xf
                                                                  cpy-bs cpy-bt)
                                                 (let* ((cmdc (aref cmd-tab
                                                                    (+ cmd-base cc)))
                                                        (cost (+ dist-cost
                                                                 cxbf
                                                                 (aref cmd-a cmdc))))
                                                   (declare (type (integer 0 23) cc)
                                                            (type fixnum cmdc)
                                                            (type single-float
                                                                   cost))
                                                   (when (< cost (aref zcostf (+ pos len)))
                                                     (z-update-node pos start len dist 0 isdict cost)
                                                     (when (> len result)
                                                       (setf result len)))))
                                               (incf len))))))))))))
                       result)))
                   (z-iterate (hq)
                     "C BrotliZopfliComputeShortestPath: per position BT+dict
candidates into the DP (analytic cost model), long-copy skip logic, then
the shortest path becomes our command list.  HQ (the q11 second
iteration) loads the matches pre-collected by Z-PREPASS instead of
probing and storing here."
                     (declare (type boolean hq))
                     (fill zcostf +z-infinity+)
                     (fill zlen 1)
                     ;; No fill for zins/zsc/znext: an
                     ;; unwritten node is exactly ZLEN = 1 (written nodes
                     ;; have copy length >= 2, node 0 has 0), and every
                     ;; reader tests ZLEN first (z-shortcut/z-cache stub
                     ;; branches behave like C's zero-initialized stub:
                     ;; distance 0, insert 0, dictionary false).
                     ;; C re-Inits the queue for every ZopfliIterate run.
                     (setf (zpq-idx zq) 0)
                     (setf (aref zlen 0) 0
                           (aref zcostf 0) 0.0f0)
                     (let ((i 0) (off 0))
                       (declare (type fixnum i off))
                       (loop while (< (+ i 3) n) do
                         (let* ((cnt (if hq (aref z-nm i)
                                             (progn (bt-do i t) bt-cnt)))
                                (dok nil))
                           (declare (type fixnum cnt) (type boolean dok))
                           (if hq
                               ;; Load this position's recorded matches:
                               ;; BT entries into bt-md/bt-ml, dictionary
                               ;; entries into z-dmatch (length-keyed).
                               (progn
                                 (let ((mi 0))
                                   (declare (type fixnum mi))
                                   (loop for k of-type fixnum below cnt do
                                     (let ((e (aref z-flat (+ off k))))
                                       (declare (type fixnum e))
                                       (if (logbitp 24 e)
                                           (progn
                                             ;; stamp-packed: the consumer
                                             ;; tests STAMP == position, so
                                             ;; no per-position clear
                                             (setf (aref z-dmatch
                                                         (logand e #xFFFFFF))
                                                   (logior (ash (the (integer 0 #.(ash 1 33)) i) 26)
                                                           (ash e -25))
                                                   dok t))
                                           (progn
                                             (setf (aref bt-md mi)
                                                   (ash e -25)
                                                   (aref bt-ml mi)
                                                   (logand e #xFFFFFF))
                                             (incf mi)))))
                                   (setf bt-cnt mi))
                                 (incf off cnt))
                               (progn
                                 ;; C FindAllMatches consults the dictionary
                                 ;; for every word length >= max(4, best_len
                                 ;; + 1); with best >= 24 no word can
                                 ;; contribute.  Each length gets its own
                                 ;; candidate (C appends one match per length).
                                 (when (and use-dict
                                            (< (if (plusp cnt) bt-cbest 0) 24)
                                            (< dict-used dlim))
                                   (dict-matches-at sap data i n
                                                    (max 4 (1+
                                                            (if (plusp cnt)
                                                                bt-cbest 0)))
                                                    (min window (+ base-pos i))
                                                    z-dmatch i
                                                    dictidx dictv dictsap)
                                   (setf dok t))
                                 ;; C: only the longest match survives when
                                 ;; it exceeds MaxZopfliLen.
                                 (when (and (> cnt 0)
                                            (> (aref bt-ml (1- cnt)) z-maxlen))
                                   (setf (aref bt-md 0) (aref bt-md (1- cnt))
                                         (aref bt-ml 0) (aref bt-ml (1- cnt))
                                         cnt 1))))
                           (let ((skip (z-update i dok)))
                             (declare (type fixnum skip))
                             (when (< skip 16384) (setf skip 0))
                             ;; (PLUSP BT-CNT): in HQ mode CNT counts
                             ;; dictionary entries too, and a lone
                             ;; dictionary entry must not test bt-ml[0].
                             (when (and (= cnt 1) (plusp bt-cnt)
                                        (> (aref bt-ml 0) z-maxlen))
                               (setf skip (max (aref bt-ml 0) skip)))
                             (when (> skip 1)
                               (let ((beg (1+ i))
                                     (end (min (+ i skip) (- n 127))))
                                 (declare (type fixnum beg end))
                                 ;; C StoreRangeH10 for the copy tail (both
                                 ;; q10 and q11: the q11 pre-pass also skips
                                 ;; long-copy interiors with StoreRange): the
                                 ;; bulk at stride 8, the last 63 positions
                                 ;; individually, and the 64..574 window's
                                 ;; bulk is skipped.
                                 (unless hq (let ((ii beg) (jj beg))
                                   (declare (type fixnum ii jj))
                                   (when (<= (+ beg 63) end)
                                     (setf ii (- end 63)))
                                   (when (<= (+ beg 512) ii)
                                     (loop while (< jj ii) do
                                       (bt-do jj nil)
                                       (incf jj 8)))
                                   (loop while (< ii end) do
                                     (bt-do ii nil)
                                     (incf ii)))))
                               ;; EvaluateNode over the copy; HQ: the
                               ;; skipped positions were recorded by the
                               ;; pre-pass, so the flat cursor steps past
                               ;; their entries.
                               (multiple-value-setq (i off)
                                 (z-skip-run i skip n hq off z-nm zcostf
                                             (zmodel-lit-prefix zmodel)
                                             zsc zlen zins z-sdc zq)))
                             (incf i)))))
                     ;; C ComputeShortestPathFromNodes -> backward links
                     (let ((index n))
                       (declare (type fixnum index))
                       ;; Unwritten <=> ZLEN = 1 (fills are gone; written
                       ;; copy lengths are >= 2), so the zins half of C's
                       ;; stub test is redundant.
                       (loop while (= (aref zlen index) 1)
                             do (decf index))
                       (setf (aref znext index) #xFFFFFFFF)
                       (loop while (/= index 0) do
                         (let ((len (+ (logand (aref zlen index) #xFFFFFF)
                                       (logand (aref zins index) #x7FFFFFF))))
                           (declare (type fixnum len))
                           (decf index len)
                           (setf (aref znext index) len))))
                     ;; C BrotliZopfliCreateCommands -> our command list
                     ;; A fresh list per iteration: C restores
                     ;; num_commands/last_insert_len before each run.
                     (let ((pos 0) (off (aref znext 0)) (out nil))
                       (declare (type fixnum pos off) (type list out))
                       (loop while (/= off #xFFFFFFFF) do
                         (let* ((q (+ pos off))
                                (zv (aref zlen q))
                                (cpy (logand zv #xFFFFFF))
                                (ins (logand (aref zins q) #x7FFFFFF))
                                (dist (ash zv -25))
                                (dictp (if (logbitp 24 zv) 1 0))
                                (lit-start pos))
                           (declare (type fixnum q zv cpy ins dist dictp
                                          lit-start))
                           (incf pos ins)
                           (when (plusp dictp) (incf dict-used))
                           ;; DICTP must be a boolean: downstream consumers
                           ;; (plan-commands ring push, split-command-at)
                           ;; test it with (or dictp ...) where 0 is truthy.
                           (push (list ins lit-start cpy dist
                                       (and (plusp dictp) t))
                                 out)
                           ;; C: offset = next->u.next = the node's own slot.
                           (setf off (aref znext q))
                           (incf pos cpy)))
                       (let ((trail (- n pos)))
                         (declare (type fixnum trail))
                         (when (plusp trail)
                           (push (list trail pos 0 0 nil) out)))
                       (nreverse out)))
                   (z-prepass ()
                     "C BrotliCreateHqZopfliBackwardReferences pre-pass:
FindAllMatches at every position (with the long-copy StoreRangeH10 skip)
recorded into Z-FLAT, packed as (dist << 25) | (dict << 24) | len;
Z-NM[i] counts position I's entries (skip interiors stay 0)."
                     (let ((i 0) (total 0))
                       (declare (type fixnum i total))
                       (labels ((record (dist len dict)
                                  ;; dist < 2^26 (window + dictionary distance),
                                  ;; len <= 2^25, dict is a flag: the packed
                                  ;; (dist<<25 | dict<<24 | len) word fits a
                                  ;; fixnum provably -> no overflow check.
                                  (declare (type (integer 0 #x3FFFFFF) dist)
                                           (type (integer 0 #x1FFFFFF) len)
                                           (type (integer 0 1) dict))
                                  (when (< total (* 4 n))
                                    (setf (aref z-flat total)
                                          (logior (ash dist 25)
                                                  (ash dict 24) len))
                                    (incf total)
                                    (incf (aref z-nm i)))))
                         (loop while (< (+ i 3) n) do
                           (bt-do i t)
                           (let ((cnt bt-cnt) (longp nil))
                             (declare (type fixnum cnt)
                                      (type boolean longp))
                             ;; C: last match > MaxZopfliLen -> keep only it
                             ;; and skip the copy's interior.
                             (when (and (> cnt 0)
                                        (> (aref bt-ml (1- cnt)) z-maxlen))
                               (setf longp t
                                     (aref bt-md 0) (aref bt-md (1- cnt))
                                     (aref bt-ml 0) (aref bt-ml (1- cnt))
                                     cnt 1))
                             ;; Dictionary (C appends these inside
                             ;; FindAllMatches; the gate is false exactly
                             ;; when C's minlen would exceed 24).
                             (when (and use-dict
                                        (< bt-cbest 24)
                                        (< dict-used dlim))
                               (dict-matches-at sap data i n
                                                (max 4 (1+ bt-cbest))
                                                (min window (+ base-pos i))
                                                z-dmatch i
                                                dictidx dictv dictsap)
                               (loop for l of-type fixnum from 4 to 24 do
                                 (let ((d (aref z-dmatch l)))
                                   (declare (type fixnum d))
                                   (when (= (ash d -26) i)
                                     (record (logand d #x3FFFFFF) l 1)))))
                             (loop for k of-type fixnum below cnt do
                               (record (aref bt-md k) (aref bt-ml k) 0))
                             (if longp
                                 (let ((mlen (aref bt-ml 0)))
                                   (declare (type fixnum mlen))
                                   ;; StoreRangeH10(pos+1,
                                   ;; min(pos+mlen, store_end)) - but only
                                   ;; when a FUTURE full walk can read the
                                   ;; tree entries: if the skip jumps past
                                   ;; the last FindAll position (n-4), the
                                   ;; insertions are provably dead (C never
                                   ;; sees this case - its 256 KiB chunking
                                   ;; caps skips inside the chunk; our one
                                   ;; 1 MiB chunk produced 126,718 dead
                                   ;; store-walks on text vs C's 28,795).
                                   (when (<= (+ i mlen) (- n 4))
                                   (let ((beg (1+ i))
                                         (end (min (+ i mlen) (- n 127))))
                                     (declare (type fixnum beg end))
                                     (let ((ii beg) (jj beg))
                                       (declare (type fixnum ii jj))
                                       (when (<= (+ beg 63) end)
                                         (setf ii (- end 63)))
                                       (when (<= (+ beg 512) ii)
                                         (loop while (< jj ii) do
                                           (bt-do jj nil)
                                           (incf jj 8)))
                                       (loop while (< ii end) do
                                         (bt-do ii nil)
                                         (incf ii)))))
                                   (incf i (1- mlen)))
                                 (incf i)))))
                     total))
                   (z-iterate-hq ()
                     "C BrotliCreateHqZopfliBackwardReferences (q11): one
match-collection pass, then the DP twice - analytic costs, then exact
costs from the first iteration's commands
\(ZopfliCostModelSetFromCommands)."
                     (z-prepass)
                     (let ((base dict-used))
                       (declare (type fixnum base))
                       (let ((first-pass (z-iterate t))
                             (saved z-cands))
                         (setf dict-used base)
                         (zopfli-set-from-commands zmodel data n first-pass)
                         ;; C re-runs the full candidate set; with exact
                         ;; costs in hand one queue entry keeps most of the
                         ;; ratio at measurably less pass-2 time.
                         (setf z-cands 1)
                         (prog1 (z-iterate t)
                           (setf z-cands saved)))))
                   (find-match (pos h)
                     (declare (type fixnum pos h))
                     (let ((psap (ptr+ sap pos))   ; probe invariants
                           (maxl (- n pos))
                           (cand (aref head h)) (best-len 0) (best-dist 0))
                       (declare (type fixnum cand best-len best-dist))
                       ;; C checks the last distance before walking the
                       ;; chain.  A good hit also raises BEST-LEN, which
                       ;; makes PROBE-OK reject more chain candidates.
                       (when (plusp last-dist)
                         (let ((prev (- pos last-dist)))
                           (declare (type fixnum prev))
                           (when (and (>= prev 0) (<= last-dist window)
                                      (probe-ok prev best-len psap maxl))
                             (let ((ml (mlen prev pos)))
                               (declare (type fixnum ml))
                               (when (> ml best-len)
                                 (setf best-len ml best-dist last-dist))))))
                       (if chained
                           (let ((chain max-chain))
                             (declare (type fixnum chain))
                             (loop while (and (/= cand #xFFFFFFFF) (> chain 0)) do
                               (when (> (- pos cand) window) (return))
                               (when (probe-ok cand best-len psap maxl)
                                 (let ((ml (mlen cand pos)))
                                   (declare (type fixnum ml))
                                   (when (> ml best-len)
                                     (setf best-len ml best-dist (- pos cand)))))
                               (setf cand (the fixnum (aref prev cand))) (decf chain)))
                           (when (and (/= cand #xFFFFFFFF) (<= (- pos cand) window))
                             (when (probe-ok cand best-len psap maxl)
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

                     (let ((psap (ptr+ sap pos))   ; probe invariants
                           (maxl (- n pos))
                           (cand (aref head h)) (best-len 0) (best-dist 0)
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
                                        (< best-len (- n pos))
                                        (< best-len (- n prev))
                                        (= (aref data (+ pos best-len))
                                           (aref data (+ prev best-len))))
                               (let ((ml (mlen prev pos)))
                                 (declare (type fixnum ml))
                                 (when (or (>= ml 3) (and (= ml 2) (< i 2)))
                                   (let ((score (- (+ 1935 (* 135 (the (integer 0 #.(ash 1 40)) ml)))
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
                                 (when (probe-ok cand best-len psap maxl)
                                   (let ((ml (mlen cand pos)))
                                     (declare (type fixnum ml))
                                     (when (>= ml 4)
                                       ;; SCORE = 1920 + 135*len
                                       ;;             - 30*floor(log2(dist))
                                       (let ((score (+ 1920 (* 135 (the (integer 0 #.(ash 1 40)) ml))
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
                             (when (probe-ok cand best-len psap maxl)
                               (let ((ml (mlen cand pos)))
                                 (declare (type fixnum ml))
                                 (when (>= ml 4)
                                   (let ((score (+ 1920 (* 135 (the (integer 0 #.(ash 1 40)) ml))
                                                   (- (* 30 (1- (integer-length (- pos cand))))))))
                                     (declare (type fixnum score))
                                     (when (> score best-score)
                                       (setf best-score score
                                             best-len ml
                                             best-dist (- pos cand)))))))))
                       (values best-len best-dist best-score)))
                   (push-cmd (ins ls cpy dist dictp)
                     ;; Append one 5-fixnum command record (INS LIT-START
                     ;; CPY DIST DICTP) to CMDS, growing it geometrically.
                     ;; DICTP is 0/1, not nil/t: the consumers test it with
                     ;; ZEROP/PLUSP.  (A comment, not a docstring: ECL
                     ;; rejects a DECLARE after a LABELS docstring.)
                     (declare (type fixnum ins ls cpy dist dictp))
                     (when (>= (* 5 (1+ ncmd)) (length cmds))
                       (let ((new (make-array (* 2 (length cmds))
                                              :element-type 'fixnum)))
                         (replace new cmds :end2 (* 5 ncmd))
                         (when *scratch-pool*
                           (setf (gethash :lz77-cmds *scratch-pool*) new))
                         (setf cmds new)))
                     (let ((vb (* 5 ncmd)))
                       (declare (type fixnum vb))
                       (setf (aref cmds vb) ins
                             (aref cmds (+ vb 1)) ls
                             (aref cmds (+ vb 2)) cpy
                             (aref cmds (+ vb 3)) dist
                             (aref cmds (+ vb 4)) dictp))
                     (incf ncmd))
                   (emit-normal (best-len best-dist inserted h)
                     (declare (type fixnum best-len best-dist h))
                     (unless inserted (ins p h))
                     (if (>= best-len min-cop)
                         (progn
                           (push-cmd (- p lit-start) lit-start best-len
                                     best-dist 0)
                           (setf last-dist best-dist)
                           (when (and dc (/= best-dist (aref dc 0)))
                             ;; C rotates the cache for every copy except a
                             ;; repeat of dc[0] (distance short code 0).
                             (setf (aref dc 3) (aref dc 2)
                                   (aref dc 2) (aref dc 1)
                                   (aref dc 1) (aref dc 0)
                                   (aref dc 0) best-dist)
                             (prepare-dc))
                           (when (or bt (and chained insert-interior))
                             ;; C's StoreRange: for a short distance relative
                             ;; to the match, only store the tail positions to
                             ;; avoid poisoning the chain on RLE-like data.
                             (let* ((range-end (min (+ p best-len) (1+ last)))
                                    (range-start (1+ p)))
                               (declare (type fixnum range-end range-start))
                               (when (< best-dist (ash (- range-end p) -2))
                                 (setf range-start
                                       (max range-start
                                            (- range-end (ash (the (integer 0 #.(ash 1 40)) best-dist) 2)))))
                               (when (< range-start range-end)
                                     ;; StoreRange runs 15-51x per command, so every
                                     ;; per-iteration decision is hoisted: BT and the
                                     ;; SAP-hash bounds test are loop invariant, and
                                     ;; INS is inlined (its body is exactly head/prev
                                     ;; maintenance).  The two hashes are
                                     ;; interchangeable: %HASH4-SAP uses the low 40
                                     ;; bits of its 8-byte load (bytes i..i+4), which
                                     ;; %HASH4-TAIL rebuilds from five byte loads -
                                     ;; same value, so the whole-range choice cannot
                                     ;; change output.
                                     (cond
                                       (bt
                                        (loop for q of-type fixnum
                                              from range-start below range-end
                                              do (bt-do q nil)))
                                       ((and sap (<= (+ range-end 8) n))
                                        ;; out of line: in this function the
                                        ;; loop had no free registers
                                        (%chain-store-range sap head prev range-start
                                                            range-end shift hmask chained))
                                       (t
                                        (loop for q of-type fixnum
                                              from range-start below range-end
                                              do (let* ((h (%hash4-tail data q shift hmask))
                                                        (old (aref head h)))
                                                   (declare (type fixnum h old))
                                                   (setf (aref head h) q)
                                                   (when chained
                                                     (setf (aref prev q) old)))))))))
                           (setf skip 32)
                           (incf p best-len)
                           (setf lit-start p))
                         (if skip-match
                             (let ((step (max 1 (ash skip -5))))
                               (incf p step)
                               (incf skip))
                             (incf p)))))
            (declare (inline hash ins mlen mlen2 probe-ok penalty
                             zq-push z-minlen bt-hash z-update-node
                             z-shortcut z-eval z-cache push-cmd))
            (if bt
                ;; Z-ITERATE builds 5-element lists (boolean DICTP); the
                ;; consumers below expect the flat 5-fixnum vector, so
                ;; convert at this boundary (same as BLOCK->CMDS).
                (if (>= bt 64)
                    (block->cmds (z-iterate-hq))
                    (block->cmds (z-iterate nil)))
                (progn
                  (loop while (<= p last) do
              (let* ((ph (hash p)))
                (multiple-value-bind (best-len best-dist best-score)
                    (cond (bt (if score-p (bt-score p) (bt-longest p)))
                          (score-p (find-match-score p ph))
                          ((>= carry-len 0)
                           (multiple-value-prog1 (values carry-len carry-dist 0)
                             (setf carry-len -1)))
                          (t (find-match p ph)))

                  (declare (type fixnum best-len best-dist best-score))
                  (let ((dict-p nil))
                    (when (and use-dict
                               (< dict-used dlim))
                      (multiple-value-bind (dict-len dict-idx dict-tid)
                          ;; min-len = best-len + 1 reproduces the outer
                          ;; (> dict-len best-len) guard while pruning the
                          ;; candidate scan (C: minlen = max(4, best_len+1)).
                          (dict-match-at data p n (1+ best-len)
                                         dictidx dictv)
                        ;; DICT-IDX is NIL only when no word matched, which
                        ;; the DICT-LEN >= 9 guard excludes; typing the three
                        ;; keeps the compares/arith in fixnum registers.
                        (declare (type fixnum dict-len dict-idx dict-tid))
                        (when (and (>= dict-len 9) (> dict-len best-len))
                          (setf dict-p t)
                          (let ((dist (+ (the (integer 0 #x1FFFFFF)
                                             (min window (+ base-pos p)))
                                       1
                                       (the (integer 0 2047) dict-idx)
                                       (* (the (integer 0 127) dict-tid)
                                          (nwords dict-len)))))
                            (push-cmd (- p lit-start) lit-start dict-len dist 1)
                            (incf dict-used)
                            (ins p ph)
                            (when (or bt (and chained insert-interior))
                              (loop for q from (1+ p)
                                    below (min (+ p dict-len) (1+ last))
                                    do (if bt (bt-do q nil)
                                           (ins q (hash q)))))
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
                                    (if bt (bt-longest (1+ p))
                                        (find-match (1+ p) (hash (1+ p))))
                                  (declare (type fixnum next-len next-dist))
                                  (if (and (>= next-len min-match)
                                           (> next-len best-len))
                                      (progn
                                        (unless bt
                                          (setf carry-len next-len
                                                carry-dist next-dist))
                                        (incf p))
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
                                           (if bt (bt-score (1+ p))
                                               (find-match-score (1+ p) h2))
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
                    (push-cmd (- n lit-start) lit-start 0 0 0))
                  (values cmds (* 5 ncmd)))))))))

;;; ---- C Brotli's q2-q4 matcher: CreateBackwardReferences over the
;;; HashLongestMatchQuickly family (H2 / H3 / H4 / H54) ---------------------

(defun pooled-fixnums (key size)
  "A fixnum vector of at least SIZE from the compressor's pool under KEY
\(fresh when there is no pool).  Contents are stale: the caller writes
before it reads and never uses the vector's length."
  (declare (type fixnum size) (optimize (speed 3) (safety 0)))
  (let* ((pool *scratch-pool*)
         (v (and pool (gethash key pool))))
    (if (and v (>= (length (the (simple-array fixnum (*)) v)) size))
        v
        (let ((new (make-array size :element-type 'fixnum)))
          (when pool (setf (gethash key pool) new))
          new))))

(defun pooled-u16 (key size)
  "A zeroed (unsigned-byte 16) vector of SIZE from the compressor's pool
under KEY (fresh when there is no pool)."
  (declare (type fixnum size) (optimize (speed 3) (safety 0)))
  (let* ((pool *scratch-pool*)
         (v (and pool (gethash key pool))))
    (if (and v (= (length (the (simple-array (unsigned-byte 16) (*)) v)) size))
        (fill (the (simple-array (unsigned-byte 16) (*)) v) 0)
        (let ((new (make-array size :element-type '(unsigned-byte 16)
                                    :initial-element 0)))
          (when pool (setf (gethash key pool) new))
          new))))

(defun pooled-u32 (key size fill)
  "A u32 vector of at least SIZE from the compressor's pool under KEY
\(fresh when there is no pool).  When FILL is a number the first SIZE
entries are set to it; otherwise contents are stale and the caller must
not read what it has not written."
  (declare (type fixnum size) (optimize (speed 3) (safety 0)))
  (let* ((pool *scratch-pool*)
         (v (and pool (gethash key pool))))
    (if (and v (>= (length (the (simple-array (unsigned-byte 32) (*)) v)) size))
        (progn (when fill (fill (the (simple-array (unsigned-byte 32) (*)) v)
                                fill :end size))
               v)
        (let ((new (if fill
                       (make-array size :element-type '(unsigned-byte 32)
                                        :initial-element fill)
                       (make-array size :element-type '(unsigned-byte 32)))))
          (when pool (setf (gethash key pool) new))
          new))))

(defun %quick-partial-clear (buckets data bits sweep hash-len)
  "C's partial Prepare: zero only the buckets DATA's positions hash to (the
sweep slots included).  The matchers read only keys of positions <= n - 9,
so the result reads exactly like a fully zeroed table."
  (declare (type (simple-array (unsigned-byte 32) (*)) buckets)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type (integer 1 24) bits) (type (integer 1 4) sweep)
           (type (integer 5 8) hash-len)
           (optimize (speed 3) (safety 0)))
  (let ((n (length data)) (mask (1- (ash 1 bits))) (shift (- bits 64)))
    (declare (type fixnum n mask) (type (integer -63 -40) shift))
    (with-ptrs ((sap data))
      (loop for i of-type fixnum from 0 to (- n 8) do
        (let* ((w (ptr-u64 sap i))
               (x (if (= hash-len 5)
                      (logand (ash w 24) #xFFFFFFFFFFFFFFFF)
                      (logand (ash w 8) #xFFFFFFFFFFFFFFFF)))
               (key (ash (logand (* x #x1FE35A7BD3579BD3) #xFFFFFFFFFFFFFFFF) shift)))
          (declare (type (unsigned-byte 64) w x) (type fixnum key))
          (dotimes (j sweep)
            (setf (aref buckets (logand (+ key (ash j 3)) mask)) 0)))))))

(defun acquire-quick-buckets (bits sweep &optional data (hash-len 5))
  "Zeroed bucket table for %LZ77-QUICK (2^BITS + SWEEP u32; C zeroes its
buckets in Prepare and treats 0 as a real position).  Pooled per
compressor like ACQUIRE-HEADPREV.  With DATA small next to the table (C:
input <= 2^BITS / 32), a pooled table is cleared only where DATA hashes."
  (declare (type (integer 1 24) bits) (type (integer 1 4) sweep))
  (let ((pool *scratch-pool*) (size (+ (ash 1 bits) sweep)))
    (flet ((make-it () (make-array size :element-type '(unsigned-byte 32)
                                        :initial-element 0)))
      (if (null pool)
          (make-it)
          (let* ((key (case bits (16 :quick16) (17 :quick17) (t :quick20)))
                 (entry (gethash key pool)))
            (if (and entry (= (length (the (simple-array (unsigned-byte 32) (*)) entry))
                              size))
                (if (and data (<= (length (the (simple-array (unsigned-byte 8) (*)) data))
                                  (ash 1 (- bits 5))))
                    (progn (%quick-partial-clear entry data bits sweep hash-len)
                           entry)
                    (fill (the (simple-array (unsigned-byte 32) (*)) entry) 0))
                (progn
                  (when (>= (hash-table-count pool) +scratch-max-entries+)
                    (clrhash pool))
                  (setf (gethash key pool) (make-it)))))))))

;; One specialized matcher per C hasher: BUCKET_BITS / BUCKET_SWEEP /
;; HASH_LEN are compile-time constants in C, and as runtime arguments here
;; every store reloaded them from stack slots and branched on them.
(defmacro define-quick-matcher (name bits sweep hash-len &optional use-dict)
  (let ((sr (intern (format nil "~A-STORE-RANGE" (symbol-name name)))))
    `(progn
       ;; C StoreRange as its own function: inside the matcher it ran out of
       ;; registers (SAP and BUCKETS reloaded from the stack per position,
       ;; 13 instructions, ~half of q2's matcher time); here the loop has
       ;; them all.  One call per match.
       (defun ,sr (sap buckets start end)
         (declare (type ptr sap)
                  (type (simple-array (unsigned-byte 32) (*)) buckets)
                  (type fixnum start end)
                  (optimize (speed 3) (safety 0)))
         (loop for i of-type fixnum from start below end do
           (let* ((w (ptr-u64 sap i))
                  (x ,(if (= hash-len 5)
                          '(logand (ash w 24) #xFFFFFFFFFFFFFFFF)
                          '(logand (ash w 8) #xFFFFFFFFFFFFFFFF)))
                  (key (ash (logand (* x #x1FE35A7BD3579BD3) #xFFFFFFFFFFFFFFFF)
                            ,(- bits 64))))
             (declare (type (unsigned-byte 64) w x) (type fixnum key))
             (setf (aref buckets ,(if (= sweep 1)
                                      'key
                                      ;; C 1.2.0: slot (key + (j << 3)) & mask
                                      `(logand (+ key (logand i ,(ash (1- sweep) 3)))
                                               ,(1- (ash 1 bits)))))
                   i))))
       (declaim (notinline ,sr))
       (defun ,name (data sap window)
         (declare (type (simple-array (unsigned-byte 8) (*)) data)
                  (type ptr sap)
                  (type fixnum window)
                  (optimize (speed 3) (safety 0)))
         #+cl-brotli-x86-64
         (progn sap
           (%asm-quick-drive data window ,bits ,sweep
                             (lambda (st ctx)
                               (,(intern (format nil "%ASM-QUICK-~A"
                                                 (subseq (symbol-name name)
                                                         (length "%LZ77-QUICK-")))
                                         "CL-BROTLI.LISP")
                                st ctx))
                             ,hash-len))
         #-cl-brotli-x86-64
         (symbol-macrolet ((bits ,bits) (sweep ,sweep) (hash-len ,hash-len)
                           (use-dict ,use-dict))
           (macrolet ((%store-range (sap buckets start end)
                        (list ',sr sap buckets start end)))
             (%lz77-quick-body)))))))

#+cl-brotli-x86-64
(defun %asm-h6-drive (data window block-bits buckets run htl)
  "DEFINE-H6-MATCHER's matcher through the assembly RUN (src/evops.lisp),
like %ASM-QUICK-DRIVE.  HTL is the hasher's HashTypeLength = StoreLookahead
\(8 for H6, 4 for H5)."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type (simple-array (unsigned-byte 32) (*)) buckets)
           (type fixnum window block-bits htl) (type function run)
           (optimize (speed 3) (safety 0)))
  (let* ((n (length data))
         ;; u16 like C's num_ (the counters wrap at 2^16): half the cache
         ;; footprint of the u32 array the Lisp matcher uses
         (num (pooled-u16 :h6-num16 32768))
         (cmds (let ((pool *scratch-pool*) (want (* 5 (max 4096 (ash n -5)))))
                 (or (and pool
                          (let ((v (gethash :quick-cmds pool)))
                            (and v (>= (length (the (simple-array fixnum (*)) v)) want) v)))
                     (let ((v (make-array want :element-type 'fixnum)))
                       (when pool (setf (gethash :quick-cmds pool) v))
                       v))))
         (rh-window (if (< block-bits 8) 64 512))
         (st (arena-u64s +q0-st-size+))
         (ctx (arena-svec +q0-ctx-size+)))
    (declare (type (simple-array fixnum (*)) cmds)
             (type (simple-array (unsigned-byte 64) (*)) st) (type simple-vector ctx))
    (setf (svref ctx +q0c-data+) data (svref ctx +q0c-buckets+) buckets
          (svref ctx +q0c-num+) num
          (svref ctx +q0c-dict+) (load-dict) (svref ctx +q0c-dhash+) (c-dict-hash)
          (svref ctx +q0c-dlen+) +c-dict-len-info+)
    ;; C's limits: loop while pos + HashTypeLength < n, store_end =
    ;; n - StoreLookahead + 1, random-heuristics jumps stop at
    ;; n - max(lookahead - 1, 4) / n - max(lookahead - 1, 2)
    (setf (aref st +q0-pos+) 0 (aref st +q0-lit-start+) 0 (aref st +q0-ncmd+) 0
          (aref st +q0-apply-rh+) rh-window (aref st +q0-rhwin+) rh-window
          (aref st +q0-n+) n (aref st +q0-window+) window
          (aref st +q0-store-end+) (if (>= n htl) (- n (1- htl)) 0)
          (aref st +q0-n9+) (ldb (byte 64 0) (- n (1+ htl)))
          (aref st +q0-n7+) (ldb (byte 64 0) (- n (max (1- htl) 4)))
          (aref st +q0-n7b+) (ldb (byte 64 0) (- n (max (1- htl) 2)))
          (aref st +q0-olcd+) 0 (aref st +q0-lcd+) 0
          (aref st +q0-dlookups+) 0 (aref st +q0-dmatches+) 0
          (aref st +q0-mulc+) #x1FE35A7BD3579BD3)
    ;; C's initial distance cache and its derived candidates
    (let ((dc '(4 11 15 16)))
      (loop for d in dc for k from 0 do (setf (aref st (+ +q0-dc0+ k)) d))
      (loop for off in '(-1 1 -2 2 -3 3) for k from 4
            do (setf (aref st (+ +q0-dc0+ k)) (ldb (byte 64 0) (+ 4 off))
                     (aref st (+ +q0-dc0+ k 6)) (ldb (byte 64 0) (+ 11 off)))))
    (when (< htl n)
      ;; pinned: the matcher walks a key's ring through a raw pointer
      (sb-sys:with-pinned-objects (buckets)
        (loop
          (setf (svref ctx +q0c-cmds+) cmds (aref st +q0-cmdcap+) (length cmds))
          (funcall run st ctx)
          (when (zerop (aref st +q0-exit+)) (return))
          (let ((new (make-array (* 2 (length cmds)) :element-type 'fixnum)))
            (replace new cmds :end2 (* 5 (aref st +q0-ncmd+)))
            (when *scratch-pool* (setf (gethash :quick-cmds *scratch-pool*) new))
            (setf cmds new)))))
    (let* ((ncmd (aref st +q0-ncmd+))
           (insert (- n (aref st +q0-lit-start+))))
      (declare (type fixnum ncmd insert))
      (when (plusp insert)
        (when (> (* 5 (1+ ncmd)) (length cmds))
          (let ((new (make-array (+ 5 (* 2 (length cmds))) :element-type 'fixnum)))
            (replace new cmds :end2 (* 5 ncmd))
            (when *scratch-pool* (setf (gethash :quick-cmds *scratch-pool*) new))
            (setf cmds new)))
        (let ((b (* 5 ncmd)))
          (setf (aref cmds b) insert (aref cmds (+ b 1)) (- n insert)
                (aref cmds (+ b 2)) 0 (aref cmds (+ b 3)) 0 (aref cmds (+ b 4)) 0))
        (incf ncmd))
      (values cmds (* 5 ncmd)))))

#+cl-brotli-x86-64
(defun %asm-quick-drive (data window bits sweep run &optional (hash-len 5))
  "%LZ77-QUICK-BODY through the assembly matcher RUN (src/evops.lisp),
growing the command vector between runs; the tail (the last 8 bytes'
insert) is added here.  Same commands, same (values CMDS USED)."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum window bits sweep) (type function run)
           (optimize (speed 3) (safety 0)))
  (let* ((n (length data))
         (buckets (acquire-quick-buckets bits sweep data hash-len))
         (cmds (let ((pool *scratch-pool*) (want (* 5 (max 4096 (ash n -5)))))
                 (or (and pool
                          (let ((v (gethash :quick-cmds pool)))
                            (and v (>= (length (the (simple-array fixnum (*)) v)) want) v)))
                     (let ((v (make-array want :element-type 'fixnum)))
                       (when pool (setf (gethash :quick-cmds pool) v))
                       v))))
         (st (arena-u64s +q0-st-size+))
         (ctx (arena-svec +q0-ctx-size+)))
    (declare (type (simple-array fixnum (*)) cmds)
             (type (simple-array (unsigned-byte 64) (*)) st) (type simple-vector ctx))
    (setf (svref ctx +q0c-data+) data (svref ctx +q0c-buckets+) buckets
          (svref ctx +q0c-dict+) (load-dict) (svref ctx +q0c-dhash+) (c-dict-hash)
          (svref ctx +q0c-dlen+) +c-dict-len-info+)
    (setf (aref st +q0-olcd+) 0 (aref st +q0-lcd+) 0
          (aref st +q0-dlookups+) 0 (aref st +q0-dmatches+) 0)
    (setf (aref st +q0-pos+) 0 (aref st +q0-lit-start+) 0 (aref st +q0-ncmd+) 0
          (aref st +q0-c0+) 4 (aref st +q0-c1+) 11 (aref st +q0-c2+) 15 (aref st +q0-c3+) 16
          (aref st +q0-apply-rh+) 64 (aref st +q0-n+) n (aref st +q0-window+) window
          (aref st +q0-store-end+) (if (>= n 8) (- n 7) 0)
          (aref st +q0-n9+) (ldb (byte 64 0) (- n 9))
          (aref st +q0-n7+) (ldb (byte 64 0) (- n 7))
          (aref st +q0-mulc+) #x1FE35A7BD3579BD3)
    (when (< 8 n)
      (loop
        (setf (svref ctx +q0c-cmds+) cmds (aref st +q0-cmdcap+) (length cmds))
        (funcall run st ctx)
        (when (zerop (aref st +q0-exit+)) (return))
        (let ((new (make-array (* 2 (length cmds)) :element-type 'fixnum)))
          (replace new cmds :end2 (* 5 (aref st +q0-ncmd+)))
          (when *scratch-pool* (setf (gethash :quick-cmds *scratch-pool*) new))
          (setf cmds new))))
    (let* ((ncmd (aref st +q0-ncmd+))
           (insert (- n (aref st +q0-lit-start+))))
      (declare (type fixnum ncmd insert))
      (when (plusp insert)
        (when (> (* 5 (1+ ncmd)) (length cmds))
          (let ((new (make-array (+ 5 (* 2 (length cmds))) :element-type 'fixnum)))
            (replace new cmds :end2 (* 5 ncmd))
            (when *scratch-pool* (setf (gethash :quick-cmds *scratch-pool*) new))
            (setf cmds new)))
        (let ((b (* 5 ncmd)))
          (setf (aref cmds b) insert (aref cmds (+ b 1)) (- n insert)
                (aref cmds (+ b 2)) 0 (aref cmds (+ b 3)) 0 (aref cmds (+ b 4)) 0))
        (incf ncmd))
      (values cmds (* 5 ncmd)))))

(defmacro %lz77-quick-body ()
  ;; the body of every DEFINE-QUICK-MATCHER instance; BITS, SWEEP and
  ;; HASH-LEN are symbol macros there (constants)
  '(let* ((n (length data))
         (buckets (acquire-quick-buckets bits sweep data hash-len))
         (hshift (- bits 64))
         ;; Pooled per compressor and returned untrimmed with its used
         ;; length: the doubling growth + final SUBSEQ were ~20% of q2.
         (cmds (let ((pool *scratch-pool*) (want (* 5 (max 4096 (ash n -5)))))
                 (or (and pool
                          (let ((v (gethash :quick-cmds pool)))
                            (and v (>= (length (the (simple-array fixnum (*)) v)) want) v)))
                     (let ((v (make-array want :element-type 'fixnum)))
                       (when pool (setf (gethash :quick-cmds pool) v))
                       v))))
         (ncmd 0)
         (c0 4) (c1 11) (c2 15) (c3 16)          ; C's initial distance cache
         (store-end (if (>= n 8) (- n 7) 0))
         (pos 0) (insert 0)
         (rh-window 64)                          ; LiteralSpreeLengthForSparseSearch, q < 9
         (apply-rh 64)
         (kmin 2020)                             ; BROTLI_SCORE_BASE + 100
         (dict (load-dict)) (dtab (c-dict-hash))
         (dlookups 0) (dmatches 0))
    (declare (type (simple-array (unsigned-byte 32) (*)) buckets)
             (type (integer -63 -40) hshift)
             (type (simple-array fixnum (*)) cmds)
             (type (integer 0 #.(ash 1 40)) ncmd)
             (type fixnum c0 c1 c2 c3 store-end pos insert rh-window apply-rh kmin
                   dlookups dmatches)
             (type (simple-array (unsigned-byte 8) (*)) dict)
             (type (simple-array (unsigned-byte 16) (32768)) dtab)
             (ignorable c1 c2 c3 dict dtab))
    (labels ((hash (i)
               (declare (type fixnum i))
               ;; Constant shifts: a variable ASH of a u64 is not modular
               ;; and consed a bignum per hash.
               (let* ((w (ptr-u64 sap i))
                      (x (if (= hash-len 5)
                             (logand (ash w 24) #xFFFFFFFFFFFFFFFF)
                             (logand (ash w 8) #xFFFFFFFFFFFFFFFF)))
                      (h (logand (* x #x1FE35A7BD3579BD3) #xFFFFFFFFFFFFFFFF)))
                 (declare (type (unsigned-byte 64) x))
                 (declare (type (unsigned-byte 64) w h))
                 (the fixnum (ash h hshift))))
             (store (i)
               (declare (type fixnum i))
               (let ((key (hash i)))
                 (declare (type fixnum key))
                 (setf (aref buckets (if (= sweep 1)
                                         key
                                         ;; C 1.2.0: slot (key + (j << 3)) & mask
                                         (logand (+ key (logand i (ash (1- sweep) 3)))
                                                 (1- (ash 1 bits)))))
                       i)))
             (push-cmd (ins ls cpy dist dictp)
               (declare (type fixnum ins ls cpy dist dictp))
               (when (>= (* 5 (1+ ncmd)) (length cmds))
                 (let ((new (make-array (* 2 (length cmds)) :element-type 'fixnum)))
                   (replace new cmds)
                   (when *scratch-pool* (setf (gethash :quick-cmds *scratch-pool*) new))
                   (setf cmds new)))
               (let ((b (* 5 ncmd)))
                 (declare (type fixnum b))
                 (setf (aref cmds b) ins (aref cmds (+ b 1)) ls
                       (aref cmds (+ b 2)) cpy (aref cmds (+ b 3)) dist
                       (aref cmds (+ b 4)) dictp))
               (incf ncmd))
             (char-at (i)
               ;; C reads past the end into ring-buffer slack; a byte that
               ;; cannot match (-1) is the same outcome here.
               (declare (type fixnum i))
               (if (< i n) (aref data i) -1))
             (find-longest (cur best-len-in)
               ;; C FindLongestMatch: (values len distance score lcd), LCD =
               ;; 1 + cut for a static-dictionary word (USE-DICT hashers).
               (declare (type fixnum cur best-len-in))
               (let* ((maxb (min cur window))
                      (key (hash cur))
                      (best-len best-len-in)
                      (best-score kmin)
                      (out-len 0) (out-dist 0) (out-score kmin) (out-lcd 0)
                      (compare (char-at (+ cur best-len))))
                 (declare (type fixnum maxb key best-len best-score out-len
                                out-dist out-score out-lcd compare))
                 ;; the last distance first
                 (let ((prev (- cur c0)))
                   (declare (type fixnum prev))
                   (when (and (>= prev 0) (< prev cur)
                              (= compare (aref data (+ prev best-len))))
                     (let ((len (%match-len-sap sap prev cur n)))
                       (declare (type fixnum len))  ; not narrower: that drops the VOP
                       (when (>= len 4)
                         (let ((score (+ 1935 (* 135 (the (integer 0 #.(ash 1 40)) len)))))
                           (declare (type fixnum score))
                           (when (< best-score score)
                             (setf out-len len out-dist c0 out-score score)
                             (when (= sweep 1)
                               (setf (aref buckets key) cur)
                               (return-from find-longest
                                 (values out-len out-dist out-score 0)))
                             (setf best-len len best-score score
                                   compare (char-at (+ cur len)))))))))
                 (if (= sweep 1)
                     (let* ((prev (aref buckets key))
                            (backward (- cur prev)))
                       (declare (type fixnum prev backward))
                       (setf (aref buckets key) cur)
                       (when (and (= compare (aref data (+ prev best-len-in)))
                                  (> backward 0) (<= backward maxb))
                         (let ((len (%match-len-sap sap prev cur n)))
                           (declare (type fixnum len))  ; not narrower: that drops the VOP
                           (when (>= len 4)
                             (let ((score (- (+ 1920 (* 135 (the (integer 0 #.(ash 1 40)) len)))
                                             (* 30 (1- (integer-length backward))))))
                               (declare (type fixnum score))
                               (when (< best-score score)
                                 (return-from find-longest
                                   (values len backward score 0)))))
                           ;; C H2 reaches its dictionary probe only here:
                           ;; every other path returned early
                           (when use-dict
                             (c-dict-search (data cur (- n cur) maxb dtab dict
                                                  dlookups dmatches t)
                                 out-score
                               (setf out-len len out-dist dist out-lcd lcd))))))
                     (progn
                       (loop for i of-type fixnum below sweep do
                         (let* ((prev (aref buckets (logand (+ key (ash i 3))
                                                            (1- (ash 1 bits)))))
                                (backward (- cur prev)))
                           (declare (type fixnum prev backward))
                           (when (and (= compare (aref data (+ prev best-len)))
                                      (> backward 0) (<= backward maxb))
                             (let ((len (%match-len-sap sap prev cur n)))
                               (declare (type fixnum len))  ; not narrower: that drops the VOP
                               (when (>= len 4)
                                 (let ((score (- (+ 1920 (* 135 (the (integer 0 #.(ash 1 40)) len)))
                                                 (* 30 (1- (integer-length backward))))))
                                   (declare (type fixnum score))
                                   (when (< best-score score)
                                     (setf best-score score best-len len
                                           out-len len out-dist backward
                                           out-score score
                                           compare (char-at (+ cur len))))))))))
                       (when (and use-dict (= out-score kmin))
                         (c-dict-search (data cur (- n cur) maxb dtab dict
                                              dlookups dmatches t)
                             out-score
                           (setf out-len len out-dist dist out-lcd lcd)))
                       (setf (aref buckets (logand (+ key (logand cur (ash (1- sweep) 3)))
                                                   (1- (ash 1 bits))))
                             cur)))
                 (values out-len out-dist out-score out-lcd))))
      (declare (inline hash store char-at find-longest))
      (loop while (< (+ pos 8) n) do
        (multiple-value-bind (len dist score lcd) (find-longest pos 0)
          (declare (type fixnum len dist score lcd))
          (if (> score kmin)
              (let ((delayed 0))
                (declare (type fixnum delayed))
                ;; C: look for a better match one byte ahead
                (loop
                  (multiple-value-bind (l2 d2 s2 c2)
                      (find-longest (1+ pos) (min (1- len) (- n pos 1)))
                    (declare (type fixnum l2 d2 s2 c2))
                    (if (>= s2 (+ score 175))
                        (progn
                          (incf pos) (incf insert)
                          (setf len l2 dist d2 score s2 lcd c2)
                          (unless (and (< (incf delayed) 4) (< (+ pos 8) n))
                            (return)))
                        (return))))
                (setf apply-rh (+ pos (* 2 len) rh-window))
                ;; ComputeDistanceCode > 0, and not a dictionary word
                (when (and (zerop lcd) (/= dist c0))
                  (setf c3 c2 c2 c1 c1 c0 c0 dist))
                (push-cmd insert (- pos insert) len dist lcd)
                (setf insert 0)
                (let ((rs (+ pos 2)) (re (min (+ pos len) store-end)))
                  (declare (type fixnum rs re))
                  (when (< dist (ash len -2))
                    (setf rs (min re (max rs (- (+ pos len) (ash (the (integer 0 #.(ash 1 40)) dist) 2))))))
                  (when (< rs re) (%store-range sap buckets rs re)))
                (incf pos len))
              (progn
                (incf insert) (incf pos)
                ;; C: no match for a while - store hashes sparsely and jump
                (when (> pos apply-rh)
                  (if (> pos (+ apply-rh (* 4 rh-window)))
                      (let ((jump (min (+ pos 16) (- n 7))))
                        (declare (type fixnum jump))
                        (loop while (< pos jump) do
                          (store pos) (incf insert 4) (incf pos 4)))
                      (let ((jump (min (+ pos 8) (- n 7))))
                        (declare (type fixnum jump))
                        (loop while (< pos jump) do
                          (store pos) (incf insert 2) (incf pos 2)))))))))
      (incf insert (- n pos))
      (when (plusp insert)
        (push-cmd insert (- n insert) 0 0 0))
      ;; (values CMDS USED): only CMDS[0..USED) is this input's commands.
      (values cmds (* 5 ncmd)))))

;; C's H6 (hash_longest_match64_inc.h) for q5-q9 on >= 1 MiB inputs with
;; lgwin >= 19, and H5 (hash_longest_match_inc.h, HASH-BYTES 4) below 1 MiB
;; (ChooseHasher): 2^BUCKET-BITS keys, a ring of 2^BLOCK-BITS candidates
;; per key (BLOCK-BITS = quality - 1), H6's 5-byte 64-bit hash or H5's
;; 4-byte 32-bit one, NDIST distance cache candidates (4 / 10 / 16), and
;; C's static-dictionary probe when nothing scored.  Same driver as
;; DEFINE-QUICK-MATCHER (BrotliCreateBackwardReferences) with q >= 5's lazy
;; search.  Commands carry DICTP = 1 + cut for dictionary words.
(defmacro define-h6-matcher (name block-bits ndist &key (hash-bytes 5) (bucket-bits 15))
  (let* ((sr (intern (format nil "~A-STORE-RANGE" (symbol-name name))))
         (bsize (ash 1 block-bits)) (bmask (1- (ash 1 block-bits)))
         (htl (if (= hash-bytes 5) 8 4))          ; HashTypeLength = StoreLookahead
         (hash-form
           (if (= hash-bytes 5)
               `(ash (logand (* (logand (ptr-u64 sap i) #xFFFFFFFFFF)
                                #x1FE35A7BD3579BD3)
                             #xFFFFFFFFFFFFFFFF)
                     ,(- bucket-bits 64))
               `(ash (logand (* (ptr-u32 sap i) #x1E35A7BD) #xFFFFFFFF)
                     ,(- bucket-bits 32))))
         (tag (format nil "~A-~D" (if (= hash-bytes 5) "H6" "H5") block-bits))
         (bkey (intern (format nil "~A-BUCKETS" tag) :keyword))
         (bcount (ash 1 (+ bucket-bits block-bits)))
         ;; the assembly matcher of this hasher and quality (q = block bits + 1)
         (asm (intern (format nil "%ASM-~A-Q~D" (if (= hash-bytes 5) "H6" "H5")
                              (1+ block-bits))
                      "CL-BROTLI.LISP")))
    `(progn
       (defun ,sr (sap buckets num start end)
         (declare (type ptr sap)
                  (type (simple-array (unsigned-byte 32) (*)) buckets num)
                  (type fixnum start end)
                  (optimize (speed 3) (safety 0)))
         (loop for i of-type fixnum from start below end do
           (let* ((key ,hash-form)
                  (nk (aref num key)))
             (declare (type fixnum key nk))
             (setf (aref buckets (+ (ash key ,block-bits) (logand nk ,bmask))) i
                   (aref num key) (logand (1+ nk) #xFFFF)))))
       (declaim (notinline ,sr))
       (defun ,name (data sap window)
         (declare (type (simple-array (unsigned-byte 8) (*)) data)
                  (type ptr sap)
                  (type fixnum window)
                  (optimize (speed 3) (safety 0)))
         #+cl-brotli-x86-64
         (return-from ,name
           (%asm-h6-drive data window ,block-bits
                          (pooled-u32 ,bkey ,bcount nil)
                          (lambda (st ctx) (,asm st ctx))
                          ,htl))
         (let* ((n (length data))
                (buckets (pooled-u32 ,bkey ,bcount nil))
                (num (pooled-u32 :h6-num 32768 0))
                (cmds (let ((pool *scratch-pool*) (want (* 5 (max 4096 (ash n -5)))))
                        (or (and pool
                                 (let ((v (gethash :quick-cmds pool)))
                                   (and v (>= (length (the (simple-array fixnum (*)) v)) want) v)))
                            (let ((v (make-array want :element-type 'fixnum)))
                              (when pool (setf (gethash :quick-cmds pool) v))
                              v))))
                (ncmd 0)
                (dc (make-array 16 :element-type 'fixnum :initial-element 0))
                (store-end (if (>= n ,htl) (- n ,(1- htl)) 0))
                (pos 0) (insert 0)
                (rh-window ,(if (< block-bits 8) 64 512))  ; q < 9 : 64
                (apply-rh 0)
                (kmin 2020)
                (dict (load-dict)) (dtab (c-dict-hash))
                (dlookups 0) (dmatches 0))
           (declare (type (simple-array (unsigned-byte 32) (*)) buckets num)
                    (type (simple-array fixnum (*)) cmds)
                    (type (simple-array fixnum (16)) dc)
                    (type (integer 0 #.(ash 1 40)) ncmd)
                    (type fixnum store-end pos insert rh-window apply-rh kmin
                          dlookups dmatches)
                    (type (simple-array (unsigned-byte 8) (*)) dict)
                    (type (simple-array (unsigned-byte 16) (32768)) dtab))
           (setf (aref dc 0) 4 (aref dc 1) 11 (aref dc 2) 15 (aref dc 3) 16
                 apply-rh rh-window)
           (labels ((hash (i)
                      (declare (type fixnum i))
                      (the fixnum ,hash-form))
                    (store (i)
                      (declare (type fixnum i))
                      (let* ((key (hash i)) (nk (aref num key)))
                        (declare (type fixnum key nk))
                        (setf (aref buckets (+ (ash key ,block-bits) (logand nk ,bmask))) i
                              (aref num key) (logand (1+ nk) #xFFFF))))
                    (prepare-dc ()
                      ,@(when (> ndist 4)
                          `((let ((d0 (aref dc 0)))
                              (declare (type fixnum d0))
                              (setf (aref dc 4) (- d0 1) (aref dc 5) (+ d0 1)
                                    (aref dc 6) (- d0 2) (aref dc 7) (+ d0 2)
                                    (aref dc 8) (- d0 3) (aref dc 9) (+ d0 3)))))
                      ,@(when (> ndist 10)
                          `((let ((d1 (aref dc 1)))
                              (declare (type fixnum d1))
                              (setf (aref dc 10) (- d1 1) (aref dc 11) (+ d1 1)
                                    (aref dc 12) (- d1 2) (aref dc 13) (+ d1 2)
                                    (aref dc 14) (- d1 3) (aref dc 15) (+ d1 3)))))
                      nil)
                    (push-cmd (ins ls cpy dist dictp)
                      (declare (type fixnum ins ls cpy dist dictp))
                      (when (>= (* 5 (1+ ncmd)) (length cmds))
                        (let ((new (make-array (* 2 (length cmds)) :element-type 'fixnum)))
                          (replace new cmds)
                          (when *scratch-pool* (setf (gethash :quick-cmds *scratch-pool*) new))
                          (setf cmds new)))
                      (let ((b (* 5 ncmd)))
                        (declare (type fixnum b))
                        (setf (aref cmds b) ins (aref cmds (+ b 1)) ls
                              (aref cmds (+ b 2)) cpy (aref cmds (+ b 3)) dist
                              (aref cmds (+ b 4)) dictp))
                      (incf ncmd))
                    (find-longest (cur)
                      ;; C FindLongestMatch (H5/H6): (values len distance
                      ;; score lcd), LCD = 1 + cut for a dictionary word
                      (declare (type fixnum cur))
                      (let ((maxb (min cur window))
                            (best-len 0) (best-score kmin)
                            (out-len 0) (out-dist 0) (out-score kmin) (out-lcd 0))
                        (declare (type fixnum maxb best-len best-score out-len out-dist
                                       out-score out-lcd))
                        ;; distance cache first
                        (loop for i of-type fixnum below ,ndist do
                          (let* ((backward (aref dc i))
                                 (prev (- cur backward)))
                            (declare (type fixnum backward prev))
                            (when (and (> backward 0) (<= backward maxb)
                                       (< (+ cur best-len) n)
                                       (= (aref data (+ cur best-len))
                                          (aref data (+ prev best-len))))
                              (let ((len (%match-len-sap sap prev cur n)))
                                (declare (type fixnum len))   ; not narrower (VOP)
                                (when (or (>= len 3) (and (= len 2) (< i 2)))
                                  (let ((score (+ 1935 (* 135 (the (integer 0 #.(ash 1 40)) len)))))
                                    (declare (type fixnum score))
                                    (when (< best-score score)
                                      (unless (zerop i)
                                        (decf score (+ 39 (logand (ash #x1CA10 (- (logand i #xE))) #xE))))
                                      (when (< best-score score)
                                        (setf best-score score best-len len
                                              out-len len out-dist backward out-score score)))))))))
                        ;; then the bucket ring, newest first
                        (let* ((key (hash cur))
                               (base (ash key ,block-bits))
                               (nk (aref num key))
                               (down (if (> nk ,bsize) (- nk ,bsize) 0))
                               (first4 (ptr-u32 sap cur))
                               (i nk))
                          (declare (type fixnum key base nk down i)
                                   (type (unsigned-byte 32) first4))
                          (loop while (> i down) do
                            (decf i)
                            (let* ((prev (aref buckets (+ base (logand i ,bmask))))
                                   (backward (- cur prev)))
                              (declare (type fixnum prev backward))
                              ;; (also stops on a stale entry from an earlier
                              ;; input: the pooled buckets are not cleared)
                              (when (or (<= backward 0) (> backward maxb)) (return))
                              (when (and (< (+ cur best-len) n)
                                         (= (aref data (+ cur best-len))
                                            (aref data (+ prev best-len)))
                                         (= first4 (ptr-u32 sap prev)))
                                (let ((len (%match-len-sap sap prev cur n)))
                                  (declare (type fixnum len))
                                  (let ((score (- (+ 1920 (* 135 (the (integer 0 #.(ash 1 40)) len)))
                                                  (* 30 (1- (integer-length backward))))))
                                    (declare (type fixnum score))
                                    (when (< best-score score)
                                      (setf best-score score best-len len
                                            out-len len out-dist backward out-score score)))))))
                          (setf (aref buckets (+ base (logand nk ,bmask))) cur
                                (aref num key) (logand (1+ nk) #xFFFF)))
                        ;; C SearchInStaticDictionary (shallow = false)
                        (when (= out-score kmin)
                          (c-dict-search (data cur (- n cur) maxb dtab dict
                                               dlookups dmatches nil)
                              out-score
                            (setf out-len len out-dist dist out-lcd lcd)))
                        (values out-len out-dist out-score out-lcd))))
             (declare (inline hash store prepare-dc find-longest))
             (prepare-dc)
             (loop while (< (+ pos ,htl) n) do
               (multiple-value-bind (len dist score lcd) (find-longest pos)
                 (declare (type fixnum len dist score lcd))
                 (if (> score kmin)
                     (let ((delayed 0))
                       (declare (type fixnum delayed))
                       (loop
                         (multiple-value-bind (l2 d2 s2 c2) (find-longest (1+ pos))
                           (declare (type fixnum l2 d2 s2 c2))
                           (if (>= s2 (+ score 175))
                               (progn
                                 (incf pos) (incf insert)
                                 (setf len l2 dist d2 score s2 lcd c2)
                                 (unless (and (< (incf delayed) 4) (< (+ pos ,htl) n))
                                   (return)))
                               (return))))
                       (setf apply-rh (+ pos (* 2 len) rh-window))
                       ;; a dictionary word's distance is not pushed
                       (when (and (zerop lcd) (/= dist (aref dc 0)))
                         (setf (aref dc 3) (aref dc 2) (aref dc 2) (aref dc 1)
                               (aref dc 1) (aref dc 0) (aref dc 0) dist)
                         (prepare-dc))
                       (push-cmd insert (- pos insert) len dist lcd)
                       (setf insert 0)
                       (let ((rs (+ pos 2)) (re (min (+ pos len) store-end)))
                         (declare (type fixnum rs re))
                         (when (< dist (ash len -2))
                           (setf rs (min re (max rs (- (+ pos len) (ash (the (integer 0 #.(ash 1 40)) dist) 2))))))
                         (when (< rs re) (,sr sap buckets num rs re)))
                       (incf pos len))
                     (progn
                       (incf insert) (incf pos)
                       (when (> pos apply-rh)
                         (if (> pos (+ apply-rh (* 4 rh-window)))
                             (let ((jump (min (+ pos 16) (- n ,(max (1- htl) 4)))))
                               (declare (type fixnum jump))
                               (loop while (< pos jump) do
                                 (store pos) (incf insert 4) (incf pos 4)))
                             (let ((jump (min (+ pos 8) (- n ,(max (1- htl) 2)))))
                               (declare (type fixnum jump))
                               (loop while (< pos jump) do
                                 (store pos) (incf insert 2) (incf pos 2)))))))))
             (incf insert (- n pos))
             (when (plusp insert)
               (push-cmd insert (- n insert) 0 0 0))
             (values cmds (* 5 ncmd))))))))

(define-h6-matcher %lz77-h6-q5 4 4)
(define-h6-matcher %lz77-h6-q6 5 4)
(define-h6-matcher %lz77-h6-q7 6 10)
(define-h6-matcher %lz77-h6-q8 7 10)
(define-h6-matcher %lz77-h6-q9 8 16)
(define-h6-matcher %lz77-h6-q5-h5 4 4 :hash-bytes 4 :bucket-bits 14)
(define-h6-matcher %lz77-h6-q6-h5 5 4 :hash-bytes 4 :bucket-bits 14)
(define-h6-matcher %lz77-h6-q7-h5 6 10 :hash-bytes 4 :bucket-bits 15)
(define-h6-matcher %lz77-h6-q8-h5 7 10 :hash-bytes 4 :bucket-bits 15)
(define-h6-matcher %lz77-h6-q9-h5 8 16 :hash-bytes 4 :bucket-bits 15)

(define-quick-matcher %lz77-quick-h2 16 1 5 t)
(define-quick-matcher %lz77-quick-h3 16 2 5)
(define-quick-matcher %lz77-quick-h4 17 4 5 t)
(define-quick-matcher %lz77-quick-h54 20 4 7)

(defun %lz77-h6 (data sap window quality)
  "C's q5-q9 hasher: H6 from 1 MiB (ChooseHasher's size hint), H5 below."
  (if (>= (length data) #.(ash 1 20))
      (case quality
        (5 (%lz77-h6-q5 data sap window)) (6 (%lz77-h6-q6 data sap window))
        (7 (%lz77-h6-q7 data sap window)) (8 (%lz77-h6-q8 data sap window))
        (t (%lz77-h6-q9 data sap window)))
      (case quality
        (5 (%lz77-h6-q5-h5 data sap window)) (6 (%lz77-h6-q6-h5 data sap window))
        (7 (%lz77-h6-q7-h5 data sap window)) (8 (%lz77-h6-q8-h5 data sap window))
        (t (%lz77-h6-q9-h5 data sap window)))))

(defun %lz77-quick (data sap window bits sweep hash-len)
  "C BrotliCreateBackwardReferences with HashLongestMatchQuickly
\(BUCKET_BITS = BITS, BUCKET_SWEEP = SWEEP, HASH_LEN = HASH-LEN): one or a
few u32 slots per bucket, the last distance probed first, candidates ranked
by BackwardReferenceScore, the lazy one-byte deferral (cost_diff_lazy 175,
at most 4 in a row), StoreRange over copy interiors and the sparse-search
jumps through literal runs.  No static dictionary.  Returns (values CMDS
USED): the flat 5-fixnum command vector (insert lit-start copy distance 0)
like %LZ77's, but possibly longer than USED (it is pooled) - callers must
use only CMDS[0..USED)."
  (cond ((and (= bits 16) (= sweep 1)) (%lz77-quick-h2 data sap window))
        ((= bits 16) (%lz77-quick-h3 data sap window))
        ((= bits 17) (%lz77-quick-h4 data sap window))
        (t (progn hash-len (%lz77-quick-h54 data sap window)))))

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

(deftable +q0-cmd-map+
  (let ((v (make-array 64 :element-type 'fixnum)))
    (dotimes (c 64 v) (setf (aref v c) (q0-cmd-symbol c)))))
;; typed: an untyped DEFPARAMETER made every (AREF +Q0-CMD-MAP+ CC) in the
;; fragment's hot emit loop go through VECTOR-HAIRY-DATA-VECTOR-REF
;; (5.6% of q0 samples); SBCL reads the symbol value at runtime, so the
;; declaration is what lets it open-code the ref.
(declaim (type (simple-array fixnum (64)) +q0-cmd-map+))

;; C's kCmdHistoSeed: a prior that keeps every command code the fast path can
;; emit encodable and avoids degenerate one-symbol command trees.
(deftable +q0-seed-cmd+
  #(0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    0 0 0 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 0 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1))

(deftable +q0-seed-dist+
  #(1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 1 1 1 1 1 1 1 1 1 1 1 0 0 0 0))

;; C's InitCommandPrefixCodes (encode.c): kDefaultCommandDepths, the code
;; BrotliCompressFragmentFast uses for the first meta-block - 64 command
;; symbols (the +Q0-CMD-MAP+ order) then 64 distance symbols.  Tuned on
;; typical data: ~10% fewer command/distance bits than a code built from
;; the flat seed histogram, for a 448-bit header.
(deftable +q0-default-depths+
  (make-array 128 :element-type 'fixnum
                  :initial-contents
                  '(0 4 4 5 6 6 7 7 7 7 7 8 8 8 8 8
                    0 0 0 4 4 4 4 4 5 5 6 6 6 6 7 7
                    7 7 10 10 10 10 10 10 0 4 4 5 5 5 6 6
                    7 8 8 9 10 10 10 10 10 10 10 10 10 10 10 10
                    5 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                    6 6 6 6 6 6 5 5 5 5 5 5 4 4 4 4
                    4 4 4 5 5 5 5 5 5 6 6 7 7 7 8 10
                    12 12 12 12 12 12 12 12 12 12 12 12 0 0 0 0)))
(declaim (type (simple-array fixnum (128)) +q0-default-depths+))

(defvar *q0-default-etrees* nil)
(defun q0-default-etrees ()
  "C's default q0 command (704-symbol) and distance (64-symbol) codes, built
once (constant, shared: never handed to the arena)."
  (let ((c *q0-default-etrees*))
    (if c
        (values (car c) (cdr c))
        (let ((full (make-array 704 :element-type 'fixnum :initial-element 0))
              (dl (make-array 64 :element-type 'fixnum :initial-element 0)))
          (dotimes (c 64)
            (let ((d (aref +q0-default-depths+ c)))
              (when (plusp d) (setf (aref full (aref +q0-cmd-map+ c)) d))))
          (dotimes (c 64) (setf (aref dl c) (aref +q0-default-depths+ (+ 64 c))))
          (let* ((*arena* nil)
                 (cmd (make-fixed-etree full 704))
                 (dist (make-fixed-etree dl 64)))
            (setf *q0-default-etrees* (cons cmd dist))
            (values cmd dist))))))

;; C's kDefaultCommandCode: the two default codes above as stored by
;; BrotliStoreHuffmanTree (448 bits), written verbatim
(deftable +q0-default-code-bytes+
  (make-array 56 :element-type '(unsigned-byte 8)
                 :initial-contents
                 '(#xff #x77 #xd5 #xbf #xe7 #xde #xea #x9e #x51 #x5d #xde #xc6
                   #x70 #x57 #xbc #x58 #x58 #x58 #xd8 #xd8 #x58 #xd5 #xcb #x8c
                   #xea #xe0 #xc3 #x87 #x1f #x83 #xc1 #x60 #x1c #x67 #xb2 #xaa
                   #x06 #x83 #xc1 #x60 #x30 #x18 #xcc #xa1 #xce #x88 #x54 #x94
                   #x46 #xe1 #xb0 #xd0 #x4e #xb2 #xf7 #x04)))
(declaim (type (simple-array (unsigned-byte 8) (56)) +q0-default-code-bytes+))

(defun make-fixed-etree (lengths n)
  (make-etree :lengths lengths :rcodes (canonical-rcodes lengths n)))

(defun fast-cmd-etree (et)
  "Map a 64-symbol fast command etree onto the full 704-symbol alphabet."
  (if (etree-single et)
      (make-etree :single (aref +q0-cmd-map+ (etree-single et)))
      (let ((full (arena-fixnums 704))
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
(defun %sample-lit-histogram (data n)
  "C BuildAndStoreLiteralPrefixCode's histogram over the RAW input (one-pass
builds the literal tree before LZ77 runs, so C approximates the literal
stream): exact below 32 KiB with C's weight-3 adjustment of the first 11
samples, stride-29 sampling plus one-count smoothing above."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum n)
           (optimize (speed 3) (safety 0)))
  (let ((f (arena-fixnums 256)))
    (declare (type (simple-array fixnum (256)) f))
    (if (< n #x8000)
        (let ((lanes (make-array 1024 :element-type '(unsigned-byte 32) :initial-element 0))
              (i 0))
          ;; four interleaved counters (see below)
          (declare (type (simple-array (unsigned-byte 32) (1024)) lanes) (type fixnum i)
                   (dynamic-extent lanes))
          (loop while (<= (+ i 4) n)
                do (incf (aref lanes (aref data i)))
                   (incf (aref lanes (+ 256 (aref data (+ i 1)))))
                   (incf (aref lanes (+ 512 (aref data (+ i 2)))))
                   (incf (aref lanes (+ 768 (aref data (+ i 3)))))
                   (incf i 4))
          (loop while (< i n) do (incf (aref lanes (aref data i))) (incf i))
          (dotimes (b 256)
            (let ((c (+ (aref lanes b) (aref lanes (+ 256 b))
                        (aref lanes (+ 512 b)) (aref lanes (+ 768 b)))))
              (declare (type fixnum c))
              (setf (aref f b) (+ c (* 2 (min c 11)))))))
        (let ((lanes (make-array 1024 :element-type '(unsigned-byte 32) :initial-element 0))
              (i 0))
          ;; four interleaved counters: in a run of one byte value every
          ;; increment of a single counter waited on the previous one
          (declare (type (simple-array (unsigned-byte 32) (1024)) lanes) (type fixnum i)
                   (dynamic-extent lanes))
          (loop while (< (+ i (* 3 29)) n)
                do (incf (aref lanes (aref data i)))
                   (incf (aref lanes (+ 256 (aref data (+ i 29)))))
                   (incf (aref lanes (+ 512 (aref data (+ i 58)))))
                   (incf (aref lanes (+ 768 (aref data (+ i 87)))))
                   (incf i (* 4 29)))
          (loop while (< i n) do (incf (aref lanes (aref data i))) (incf i 29))
          (dotimes (b 256)
            (setf (aref f b) (+ (aref lanes b) (aref lanes (+ 256 b))
                                (aref lanes (+ 512 b)) (aref lanes (+ 768 b)))))
          (dotimes (i 256)
            (declare (type fixnum i))
            (incf (aref f i) (+ 1 (* 2 (min (aref f i) 11)))))))
    f))

;;;; Bit-writer macros that thread ACC/NBITS/POS as LEXICALS instead of
;;;; touching the BWR struct on every write.  See EMIT-ONE: while W
;;;; escapes to the non-inline W-EMIT-RUN, every struct-slot write paid
;;;; 3 stack loads + 3 untags - measured 29 instructions per literal
;;;; against C's 14.  Both macros are exact transcriptions of
;;;; %WBITS-RAW-PM / %WBITS-RAW (same arithmetic, same flush), so the
;;;; bits written cannot change.

(defmacro %wr-flush (w acc nbits pos aa nb)
  "Shared branchless tail of WR-PM / WR-RAW (the %WBITS-BODY shape): store
the whole accumulator at POS, advance POS by the completed bytes."
  (let ((em (gensym)) (pp (gensym)))
    `(let ((,em (ash ,nb -3)) (,pp ,pos))
       (declare (type (integer 0 3) ,em) (type fixnum ,pp))
       #+cl-brotli-sap
       (sb-sys:with-pinned-objects ((b:bwr-out ,w))
         (setf (sb-sys:sap-ref-64 (sb-sys:vector-sap (b:bwr-out ,w)) ,pp)
               ,aa))
       #-cl-brotli-sap
       (loop for i of-type fixnum below ,em
             do (setf (aref (b:bwr-out ,w) (+ ,pp i))
                      (logand (ash ,aa (* -8 i)) #xff)))
       (setf ,pos (+ ,pp ,em)
             ,acc (ash ,aa (- (ash ,em 3)))
             ,nbits (logand ,nb 7)))))

(defmacro wr-pm (w acc nbits pos v n)
  "Pre-masked write over the lexicals ACC/NBITS/POS (V must satisfy
0 <= V < 2^N), mirroring %WBITS-RAW-PM."
  (let ((vv (gensym)) (nn (gensym)) (pr (gensym)) (aa (gensym))
        (nb (gensym)))
    `(let* ((,vv ,v) (,nn ,n) (,pr ,nbits)
            (,aa (logior (the (unsigned-byte 64) ,acc)
                         (the (unsigned-byte 32) (ash ,vv ,pr))))
            (,nb (+ ,pr ,nn)))
       (declare (type fixnum ,vv ,nn ,pr ,nb)
                (type (integer 0 7) ,pr)
                (type (unsigned-byte 64) ,aa))
       (%wr-flush ,w ,acc ,nbits ,pos ,aa ,nb))))

(defmacro wr-raw (w acc nbits pos v n)
  "Masked write over the lexicals ACC/NBITS/POS (V masked to N bits),
mirroring %WBITS-RAW."
  (let ((vv (gensym)) (nn (gensym)) (pr (gensym)) (vb (gensym))
        (aa (gensym)) (nb (gensym)))
    `(let* ((,vv ,v) (,nn ,n) (,pr ,nbits)
            (,vb (the (unsigned-byte 32)
                      (logand ,vv (aref b::+masks+ ,nn))))
            (,aa (logior (the (unsigned-byte 64) ,acc)
                         (the (unsigned-byte 32) (ash ,vb ,pr))))
            (,nb (+ ,pr ,nn)))
       (declare (type fixnum ,vv ,nn ,pr ,nb)
                (type (integer 0 7) ,pr)
                (type (unsigned-byte 64) ,aa))
       (%wr-flush ,w ,acc ,nbits ,pos ,aa ,nb))))

#+cl-brotli-x86-64
(progn
(defvar *q0-luts* nil
  "(KEY . LUTS): the q0 command / length / distance code words for the
assembly scan, built for the code lengths in KEY.  The fast path's command
and distance codes come from fixed seeds, so this is built once.")

(defun %q0-luts (cmd-rc cmd-ln dist-rc dist-ln)
  "Code words (bits << 8 | flag << 7 | length) for %ASM-FRAGMENT-FAST:
command codes 0..63 (flag: the code implies an explicit distance), insert
lengths < 6210 and copy lengths < 2118 / last-distance copies < 2120 with
their extra bits, distance codes 0..63."
  (declare (type (simple-array fixnum (*)) cmd-rc cmd-ln dist-rc dist-ln))
  (let ((cached *q0-luts*))
    (when (and cached
               (or (eq (third (car cached)) cmd-ln)
                   (and (equalp (first (car cached)) cmd-ln)
                        (equalp (second (car cached)) dist-ln))))
      (return-from %q0-luts (cdr cached))))
  (flet ((u64s (n) (make-array n :element-type '(unsigned-byte 64) :initial-element 0)))
    (let ((cmd (u64s 64)) (ins (u64s 6210)) (copy (u64s 2118)) (clast (u64s 2120))
          (dist (u64s 64)))
      (dotimes (c 64)
        (let ((m (aref +q0-cmd-map+ c)))
          (setf (aref cmd c) (logior (ash (aref cmd-rc m) 8) (aref cmd-ln m)
                                     (if (>= m 128) 128 0)))))
      (dotimes (c 64)
        (setf (aref dist c) (logior (ash (aref dist-rc c) 8) (aref dist-ln c))))
      (flet ((combine (cc e nb)
               (let* ((w (aref cmd cc)) (len (logand w 127)))
                 (logior (ash (logior (ash w -8) (ash e len)) 8)
                         (+ len nb) (logand w 128)))))
        (dotimes (i 6210) (multiple-value-call #'(lambda (cc e nb) (setf (aref ins i) (logand (combine cc e nb) (lognot 128)))) (q0-insert-len i)))
        (loop for i from 2 below 2118
              do (multiple-value-call #'(lambda (cc e nb) (setf (aref copy i) (logand (combine cc e nb) (lognot 128)))) (q0-copy-len i)))
        (loop for i from 4 below 2120
              do (multiple-value-call #'(lambda (cc e nb) (setf (aref clast i) (combine cc e nb))) (q0-copy-last-len i))))
      (let ((luts (list cmd ins copy clast dist)))
        ;; the third key: the constant default code's own vector (EQ)
        (setf *q0-luts* (cons (list (copy-seq cmd-ln) (copy-seq dist-ln)
                                    (and (eq cmd-ln (etree-lengths (q0-default-etrees)))
                                         cmd-ln))
                              luts))
        luts))))

(defun %bwr-settle (w)
  "Write W's whole pending bytes so fewer than 8 bits remain: the
assembly writers' entry invariant (they flush without a branch)."
  (declare (type b:bwr w) (optimize (speed 3) (safety 0)))
  (let ((out (b:bwr-out w)) (pos (b:bwr-pos w))
        (acc (b::bwr-acc w)) (nb (b::bwr-nbits w)))
    (declare (type (simple-array (unsigned-byte 8) (*)) out)
             (type fixnum pos nb) (type (unsigned-byte 64) acc))
    (loop while (>= nb 8)
          do (setf (aref out pos) (logand acc 255)
                   acc (ash acc -8) nb (- nb 8))
             (incf pos))
    (setf (b:bwr-pos w) pos (b::bwr-acc w) acc (b::bwr-nbits w) nb)
    w))

(defun %asm-q0-scan (data table w n limit window table-bits k back p next-hash
                     lit-rc lit-ln lit-single cmd-rc cmd-ln dist-rc dist-ln)
  "Run %LZ77-FRAGMENT-FAST's scan with %ASM-FRAGMENT-FAST, growing W between
chunks.  Returns the final LIT-START and LAST-DIST."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type (simple-array (unsigned-byte 32) (*)) table)
           (type b:bwr w) (type fixnum n limit window table-bits k back p next-hash)
           (type (simple-array fixnum (*)) lit-rc lit-ln cmd-rc cmd-ln dist-rc dist-ln)
           (optimize (speed 3) (safety 0)))
  (destructuring-bind (cmd ins copy clast dist) (%q0-luts cmd-rc cmd-ln dist-rc dist-ln)
    (let ((lit (make-array 256 :element-type '(unsigned-byte 64) :initial-element 0))
          (st (arena-u64s +q0-st-size+))
          (ctx (arena-svec +q0-ctx-size+)))
      (declare (type (simple-array (unsigned-byte 64) (*)) lit st) (type simple-vector ctx))
      (unless lit-single
        (dotimes (c 256)
          (setf (aref lit c) (logior (ash (aref lit-rc c) 8) (aref lit-ln c)))))
      (setf (svref ctx +q0c-data+) data (svref ctx +q0c-table+) table
            (svref ctx +q0c-litlut+) lit (svref ctx +q0c-cmdlut+) cmd
            (svref ctx +q0c-inslut+) ins (svref ctx +q0c-copylut+) copy
            (svref ctx +q0c-clastlut+) clast (svref ctx +q0c-distlut+) dist)
      (setf (aref st +q0-p+) p (aref st +q0-lit-start+) 0
            (aref st +q0-last-dist+) (ldb (byte 64 0) -1)
            (aref st +q0-next-hash+) next-hash (aref st +q0-mode+) 0
            (aref st +q0-n+) n (aref st +q0-limit+) limit (aref st +q0-window+) window
            (aref st +q0-shift+) (- 64 table-bits) (aref st +q0-k+) k
            (aref st +q0-back+) back (aref st +q0-n8+) (- n 8))
      (loop
        (let* ((at (if (= (aref st +q0-mode+) 1) (aref st +q0-next-ip+) (aref st +q0-p+)))
               (chunk-end (+ at 65536))
               (lit-start (aref st +q0-lit-start+)))
          (declare (type fixnum at chunk-end lit-start))
          ;; at most 2 bytes per literal and 13 per command (>= k input
          ;; bytes each), 8 bytes past the last store
          (b:w-ensure w (+ 1024 (* 5 (- chunk-end lit-start))))
          (%bwr-settle w)
          (setf (aref st +q0-chunk-end+) chunk-end
                (aref st +q0-wpos+) (b:bwr-pos w)
                (aref st +q0-wacc+) (b::bwr-acc w)
                (aref st +q0-wnbits+) (b::bwr-nbits w)
                (svref ctx +q0c-out+) (b:bwr-out w))
          (if (= table-bits 15)
              (%asm-fragment-fast st ctx)
              (%asm-fragment-fast-v st ctx))
          ;; back to BWR's form: whole bytes out, NBITS < 8
          (let ((out (b:bwr-out w)) (pos (aref st +q0-wpos+))
                (acc (aref st +q0-wacc+)) (nb (aref st +q0-wnbits+)))
            (declare (type (simple-array (unsigned-byte 8) (*)) out)
                     (type fixnum pos nb) (type (unsigned-byte 64) acc))
            (loop while (>= nb 8)
                  do (setf (aref out pos) (logand acc 255)
                           acc (ash acc -8) nb (- nb 8))
                     (incf pos))
            (setf (b:bwr-pos w) pos (b::bwr-acc w) acc (b::bwr-nbits w) nb))
          (when (zerop (aref st +q0-exit+))
            (return (values (the fixnum (aref st +q0-lit-start+))
                            (let ((d (aref st +q0-last-dist+)))
                              (if (logbitp 63 d) (- d (ash 1 64)) d))))))))))
)

#+cl-brotli-x86-64
(progn
(deftable +q1-cc-luts+
  ;; command code numbers for the q1 assembly scan's histograms: insert
  ;; lengths < 6210, copy lengths < 2118, last-distance copy lengths < 2120
  ;; (bit 7: the code implies an explicit distance code 0)
  (let ((ins (make-array 6210 :element-type '(unsigned-byte 8) :initial-element 0))
        (copy (make-array 2118 :element-type '(unsigned-byte 8) :initial-element 0))
        (clast (make-array 2120 :element-type '(unsigned-byte 8) :initial-element 0)))
    (dotimes (i 6210) (setf (aref ins i) (q0-insert-len i)))
    (loop for i from 2 below 2118 do (setf (aref copy i) (q0-copy-len i)))
    (loop for i from 4 below 2120
          do (let ((cc (q0-copy-last-len i)))
               (setf (aref clast i)
                     (logior cc (if (>= (aref +q0-cmd-map+ cc) 128) 128 0)))))
    (list ins copy clast)))

(defun %asm-q1-scan (data table cv start bend limit window table-bits k
                     next-hash litf cmdf distf)
  "C CreateCommands for the q1 block [START, BEND) through the assembly
scan (%ASM-FRAGMENT-RECORD for K 6, -RECORD4 for K 4), growing CV between
chunks.  Returns the final LIT-START and NC (the records) and CV."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type (simple-array (unsigned-byte 32) (*)) table cv)
           (type fixnum start bend limit window table-bits k next-hash)
           (type (simple-array fixnum (*)) litf cmdf distf)
           (optimize (speed 3) (safety 0)))
  (destructuring-bind (inscc copycc clastcc) +q1-cc-luts+
    (let ((st (arena-u64s +q0-st-size+))
          (ctx (arena-svec +q0-ctx-size+))
          (n (length data)))
      (declare (type (simple-array (unsigned-byte 64) (*)) st) (type simple-vector ctx)
               (type fixnum n))
      (setf (svref ctx +q0c-data+) data (svref ctx +q0c-table+) table
            (svref ctx +q0c-litf+) litf (svref ctx +q0c-cmdf+) cmdf
            (svref ctx +q0c-distf+) distf (svref ctx +q0c-inscc+) inscc
            (svref ctx +q0c-copycc+) copycc (svref ctx +q0c-clastcc+) clastcc)
      ;; N bounds the match length (C: ip_end, the block end); N8 the
      ;; 8-byte loads (the whole input)
      (setf (aref st +q0-p+) (1+ start) (aref st +q0-lit-start+) start
            (aref st +q0-last-dist+) (ldb (byte 64 0) -1)
            (aref st +q0-next-hash+) next-hash (aref st +q0-mode+) 0
            (aref st +q0-n+) bend (aref st +q0-limit+) limit (aref st +q0-window+) window
            (aref st +q0-shift+) (- 64 table-bits) (aref st +q0-k+) k
            (aref st +q0-back+) (if (= k 4) 3 5) (aref st +q0-nc+) 0
            (aref st +q0-n8+) (- n 8)
            (aref st +q0-c39flag+) (if (>= (aref +q0-cmd-map+ 39) 128) 128 0))
      (loop
        (let* ((at (if (= (aref st +q0-mode+) 1) (aref st +q0-next-ip+) (aref st +q0-p+)))
               (chunk-end (+ at 65536))
               (need (* 4 (+ (aref st +q0-nc+) 16
                             (floor (- chunk-end (aref st +q0-lit-start+)) k)))))
          (declare (type fixnum at chunk-end need))
          ;; a command consumes >= K input bytes
          (when (> need (length cv))
            (let ((new (make-array (max need (* 2 (length cv)))
                                   :element-type '(unsigned-byte 32))))
              (replace new cv :end2 (* 4 (aref st +q0-nc+)))
              (when *scratch-pool* (setf (gethash :frag2-cv *scratch-pool*) new))
              (setf cv new)))
          (setf (aref st +q0-chunk-end+) chunk-end (svref ctx +q0c-cv+) cv)
          (if (= k 4)
              (%asm-fragment-record4 st ctx)
              (%asm-fragment-record st ctx))
          (when (zerop (aref st +q0-exit+))
            (return (values (the fixnum (aref st +q0-lit-start+))
                            (the fixnum (aref st +q0-nc+))
                            cv))))))))
)

(defun %lz77-fragment-fast (data sap window table-bits w)
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type ptr sap)
           (type fixnum window table-bits)
           (optimize (speed 3) (safety 0)))
  (let* ((n (length data))
         (k (if (<= table-bits 16) 5 6))
         (min-match k)
         (hmask (1- (ash 1 table-bits)))
         ;; C GetHashTable: zeroed (a fresh entry is a candidate at 0)
         (table (let ((v (pooled-u32 :frag1-table #.(ash 1 15) nil)))
                  (fill v 0 :end (ash 1 table-bits))
                  v))
         (litf (%sample-lit-histogram data n))
         (cmdf (make-array 64 :element-type 'fixnum :initial-element 0))
         (distf (make-array 64 :element-type 'fixnum :initial-element 0))
         (lit-start 0) (p 1) (limit (- n k))
         (last-dist -1) (back (if (= k 5) 3 5))
         (shift (the fixnum (- table-bits 64)))
         (slack 0)
         (lit-1p nil) (cmd-1p nil) (dist-1p nil)
         (lit-rc-1p +empty-fixnums+) (lit-ln-1p +empty-fixnums+)
         (lit-1p-single nil)
         (cmd-rc-1p +empty-fixnums+) (cmd-ln-1p +empty-fixnums+)
         (cmd-1p-single nil)
         (dist-rc-1p +empty-fixnums+) (dist-ln-1p +empty-fixnums+)
         (dist-1p-single nil))
    (declare (type fixnum k min-match p lit-start limit last-dist back)
             ;; SHIFT = table-bits - 64 is always in -63..-1 (table-bits
             ;; 1..63), so ASH compiles to ONE sar/shr by CL instead of the
             ;; generic sign-check + clamp + branch dance (~9 instructions
             ;; and 3 branches PER HASH, and hashes run on every trawl
             ;; iteration and every interior store)
             (type (integer -63 -1) shift)
             (type (simple-array (unsigned-byte 32) (*)) table)
             (type (simple-array fixnum (256)) litf)
             (type (simple-array fixnum (64)) cmdf distf)
             (type fixnum slack)
             (type (or null etree) lit-1p cmd-1p dist-1p)
             (type (or null fixnum) lit-1p-single cmd-1p-single
                                     dist-1p-single)
             (type (simple-array fixnum (*))
                   lit-rc-1p lit-ln-1p cmd-rc-1p cmd-ln-1p
                   dist-rc-1p dist-ln-1p))
    (replace cmdf +q0-seed-cmd+)
    (replace distf +q0-seed-dist+)
    ;; C BrotliCompressFragmentFast: trees come from what C fixes up front -
    ;; the sampled RAW-INPUT literal histogram (maxbits 8, like C's
    ;; BuildAndStoreHuffmanTreeFast) and the fixed seed command and distance
    ;; codes - and the header is written before the scan; the scan then emits
    ;; directly into W.
    (progn
      (setf lit-1p (build-etree litf 256 15))
      (multiple-value-setq (cmd-1p dist-1p) (q0-default-etrees))
      (setf lit-rc-1p (or (etree-rcodes lit-1p) +empty-fixnums+)
            lit-ln-1p (or (etree-lengths lit-1p) +empty-fixnums+)
            lit-1p-single (etree-single lit-1p)
            cmd-rc-1p (or (etree-rcodes cmd-1p) +empty-fixnums+)
            cmd-ln-1p (or (etree-lengths cmd-1p) +empty-fixnums+)
            cmd-1p-single (etree-single cmd-1p)
            dist-rc-1p (or (etree-rcodes dist-1p) +empty-fixnums+)
            dist-ln-1p (or (etree-lengths dist-1p) +empty-fixnums+)
            dist-1p-single (etree-single dist-1p))
      ;; header: NBLTYPES 1/1/1, NPOSTFIX, NDIRECT, mode, NTREESL, NTREESD
      ;; + literal, command, distance codes (write-fast-block-body's shape)
      (b:wbits w 0 1) (b:wbits w 0 1) (b:wbits w 0 1)
      (b:wbits w 0 2)
      (b:wbits w 0 4)
      (b:wbits w 0 2)
      (b:wbits w 0 1) (b:wbits w 0 1)
      (write-etree w lit-1p 256)
      (let ((code +q0-default-code-bytes+))
        (dotimes (i 56) (b:wbits w (aref code i) 8))))
    (labels ((hash (i)
               ;; The 8-byte load in %HASHF-SAP reads i..i+7; within 3 bytes
               ;; of the end that crosses the vector boundary (C's matcher
               ;; keeps a 16-byte margin we do not have), so the tail
               ;; positions compute the same hash from a 5-byte u40 build.
               (if (<= (+ i 8) n)
                   (%hashf-sap sap i shift hmask)
                   (%hashf-tail data i shift hmask)))
             (prefix-match (a b)
               (and (= (ptr-u32 sap a)
                       (ptr-u32 sap b))
                    (if (= k 5)
                        (= (ptr-u8 sap (+ a 4))
                           (ptr-u8 sap (+ b 4)))
                        (= (ptr-u16 sap (+ a 4))
                           (ptr-u16 sap (+ b 4))))))
             (mlen (a b) (%match-len-sap sap a b n))
             (emit-one (insert lit-start cpy dist last-dist)
               "Write one fast-path command into W (C's one-pass emit) and
return the updated last-distance.  Mirrors WRITE-FAST-BLOCK-BODY's
decisions; used only when W is non-nil."
               (declare (type fixnum insert lit-start cpy dist last-dist)
                        (optimize (speed 3) (safety 0)))
               ;; Slack check first: W's state is still authoritative here.
               (let ((cost (+ 32 (* 2 insert))))
                 (declare (type fixnum cost))
                 (when (> cost slack)
                   (setf slack (+ 65536 cost))
                   (b:w-ensure w slack))
                 (decf slack cost))
               ;; Thread the writer state as LEXICALS: while W escapes to
               ;; the non-inline W-EMIT-RUN, every bit write reloaded the
               ;; BWR struct slots (3 stack loads + 3 untags per literal =
               ;; 29 instructions/literal vs C's 14).  Locals stay in
               ;; registers; W is written back at the end and around
               ;; W-EMIT-RUN (which reads it on entry).
               (let ((acc (b::bwr-acc w)) (nbits (b::bwr-nbits w)) (pos (b::bwr-pos w)))
                 ;; NBITS is deliberately a plain FIXNUM: it transiently exceeds
                 ;; 7 on every flush, and declaring (INTEGER 0 7) here would
                 ;; let SBCL delete the (LOGAND NBITS 7) mask in WR-PM/WR-RAW;
                 ;; the >7 value would then feed the next shift and corrupt
                 ;; the bit stream.  The 0..7 bound holds only for the ENTRY
                 ;; value, which the macros assert as (THE (INTEGER 0 7) pr).
                 (declare (type (unsigned-byte 64) acc)
                          (type fixnum nbits pos))
                 (flet ((cmd-bits (cc)
                          (unless cmd-1p-single
                            ;; one map lookup, not two
                            (let ((mc (aref +q0-cmd-map+ cc)))
                              (wr-pm w acc nbits pos (aref cmd-rc-1p mc)
                                              (aref cmd-ln-1p mc)))))
                        (dist0-bits ()
                          (unless dist-1p-single
                            (wr-raw w acc nbits pos (aref dist-rc-1p 0)
                                            (aref dist-ln-1p 0))))
                        (lits ()
                          (unless lit-1p-single
                            (if (>= insert 8)
                                (progn
                                  ;; W-EMIT-RUN is not inline: flush the
                                  ;; lexicals into W, call, reload
                                  (setf (b::bwr-acc w) acc (b::bwr-nbits w) nbits
                                        (b::bwr-pos w) pos)
                                  (b:w-emit-run w data lit-start
                                                (+ lit-start insert)
                                                lit-rc-1p lit-ln-1p)
                                  (setf acc (b::bwr-acc w) nbits (b::bwr-nbits w)
                                        pos (b::bwr-pos w)))
                                (loop for i of-type fixnum
                                      from lit-start below (+ lit-start insert)
                                      do (let ((sym (aref data i)))
                                           (wr-pm w acc nbits pos
                                                  (aref lit-rc-1p sym)
                                                  (aref lit-ln-1p sym))))))))
                   ;; these three run per command/literal; without this they
                   ;; stay separate local functions (CMD-BITS 12.0% and LITS
                   ;; 6.4% of q0 samples as their own profile entries)
                   (declare (inline cmd-bits dist0-bits lits))
                   (cond
                     ((and (plusp insert) (plusp cpy))
                      (multiple-value-bind (cc e nb) (q0-insert-len insert)
                        (cmd-bits cc)
                        (when (plusp nb) (wr-raw w acc nbits pos e nb)))
                      (lits)
                      (if (= dist last-dist)
                          (dist0-bits)
                          (progn
                            (multiple-value-bind (cc e nb) (q0-distance dist)
                              (unless dist-1p-single
                                (wr-raw w acc nbits pos
                                        (aref dist-rc-1p (- cc 64))
                                        (aref dist-ln-1p (- cc 64)))
                                (when (plusp nb) (wr-raw w acc nbits pos e nb))))
                            (setf last-dist dist)))
                      (multiple-value-bind (cc e nb) (q0-copy-last-len cpy)
                        (cmd-bits cc)
                        (when (plusp nb) (wr-raw w acc nbits pos e nb))
                        (when (>= (aref +q0-cmd-map+ cc) 128)
                          (dist0-bits))))
                     ((plusp cpy)
                      ;; INSERT is 0 in this clause (clause 1 caught both
                      ;; positive), so LITS would run a zero-iteration
                      ;; loop - skipped entirely.
                      (multiple-value-bind (cc e nb) (q0-copy-len cpy)
                        (cmd-bits cc)
                        (when (plusp nb) (wr-raw w acc nbits pos e nb)))
                      (multiple-value-bind (cc e nb) (q0-distance dist)
                        (unless dist-1p-single
                          (wr-raw w acc nbits pos (aref dist-rc-1p (- cc 64))
                                          (aref dist-ln-1p (- cc 64)))
                          (when (plusp nb) (wr-raw w acc nbits pos e nb))))
                      (setf last-dist dist))
                     (t
                      (multiple-value-bind (cc e nb) (q0-insert-len insert)
                        (cmd-bits cc)
                        (when (plusp nb) (wr-raw w acc nbits pos e nb)))
                      (lits))))
                 ;; write the threaded state back for the next call / flush
                 (setf (b::bwr-acc w) acc (b::bwr-nbits w) nbits (b::bwr-pos w) pos))
               last-dist)
             )
        (declare (inline hash prefix-match))
      ;; x86-64 SBCL: the same scan in assembly (src/evops.lisp); it leaves
      ;; LIT-START / LAST-DIST for the remainder below, bit-identical
      #+cl-brotli-x86-64
      (when (and (> n 8) (= k 5) (not cmd-1p-single) (not dist-1p-single))
        (multiple-value-bind (ls ld)
            (%asm-q0-scan data table w n limit window table-bits k back p (hash p)
                          lit-rc-1p lit-ln-1p (and lit-1p-single t)
                          cmd-rc-1p cmd-ln-1p dist-rc-1p dist-ln-1p)
          (setf lit-start ls last-dist ld slack 0 p n)))
      (when (and (> n k) (< p n))
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
                          (when (prefix-match p ld)
                            (setf (aref table h) p
                                  cand ld)
                            (return-from trawl nil))))
                      (let ((c2 (aref table h)))
                        (setf (aref table h) p)
                        ;; C checks the distance only once, after a
                        ;; prefix-match succeeds; the two guards dropped
                        ;; here are invariants of the table (see GAP 165).
                        (when (and (/= c2 #xFFFFFFFF)
                                   (prefix-match p c2)
                                   (<= (- p c2) window))
                          (setf cand c2)
                          (return-from trawl nil))))))
                ;; Step 2: emit the found match plus the pending literals.
                (let* ((base p)
                       (matched (+ min-match (%match-len-sap-frag sap (+ cand k) (+ p k) n)))
                       (distance (- base cand))
                       (insert (- base lit-start)))
                  (declare (type fixnum matched distance insert))
                  (setf last-dist
                            (emit-one insert lit-start matched distance last-dist))
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
                          (setf last-dist
                                    (emit-one 0 p matched distance last-dist))
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
          (setf last-dist (emit-one insert lit-start 0 0 last-dist))))
      nil)))

;;; q1: C's BrotliCompressFragmentTwoPass.  The input in 128 KiB blocks,
;;; one meta-block each (or an uncompressed one when ShouldCompress says
;;; so), a hash table of HashTableSize(2^17, n) zeroed entries shared by
;;; the blocks, min_match 4 with a 4-byte hash up to 2^15 entries, else 6
;;; and a 6-byte hash.  Per block (CreateCommands): last distance reset,
;;; the scan starts at the block's second byte, copies end at the block
;;; end, and the first byte past the last copy is skipped.  Distances
;;; reach the whole window (C: 2^18 - 16): never larger than C's output.

(declaim (inline q1-hash-4 q1-hash-6))
(defun q1-hash-4 (sap i shift)
  "C two-pass Hash(p, shift, 4): ((load64 << 32) * kHashMul32) >> shift."
  (declare (type ptr sap) (type fixnum i) (type (integer -63 -1) shift)
           (optimize (speed 3) (safety 0)))
  (let* ((w (ptr-u64 sap i))
         (b (logand (ash w 32) #xFFFFFFFFFFFFFFFF))
         (c (logand (* b #x1E35A7BD) #xFFFFFFFFFFFFFFFF)))
    (declare (type (unsigned-byte 64) w b c))
    (the fixnum (ash c shift))))
(defun q1-hash-6 (sap i shift)
  "C two-pass Hash(p, shift, 6): ((load64 << 16) * kHashMul32) >> shift."
  (declare (type ptr sap) (type fixnum i) (type (integer -63 -1) shift)
           (optimize (speed 3) (safety 0)))
  (let* ((w (ptr-u64 sap i))
         (b (logand (ash w 16) #xFFFFFFFFFFFFFFFF))
         (c (logand (* b #x1E35A7BD) #xFFFFFFFFFFFFFFFF)))
    (declare (type (unsigned-byte 64) w b c))
    (the fixnum (ash c shift))))

(defmacro define-q1-scan (name k)
  "C CreateCommands with min_match K (4 or 6) over the block [START, BEND):
records (ins lit-start cpy dist) into CV from NC, histograms via
NOTE-FAST-COMMAND.  Returns (values CV NC)."
  `(defun ,name (data sap window table shift cv nc start bend litf cmdf distf)
     (declare (type (simple-array (unsigned-byte 8) (*)) data)
              (type ptr sap)
              (type fixnum window nc start bend)
              (type (integer -63 -1) shift)
              (type (simple-array (unsigned-byte 32) (*)) table cv)
              (type (simple-array fixnum (256)) litf)
              (type (simple-array fixnum (64)) cmdf distf)
              (optimize (speed 3) (safety 0)))
     (let* ((n (length data))
            (bsize (- bend start))
            (lit-start start) (last-dist -1))
       (declare (type fixnum n bsize lit-start last-dist))
       (labels ((hash (i)
                  (declare (type fixnum i))
                  (,(if (= k 4) 'q1-hash-4 'q1-hash-6) sap i shift))
                (is-match (a b)
                  (declare (type fixnum a b))
                  (and (= (ptr-u32 sap a) (ptr-u32 sap b))
                       ,@(when (= k 6) '((= (ptr-u16 sap (+ a 4)) (ptr-u16 sap (+ b 4)))))))
                (push-cmd (ins ls cpy dist)
                  (declare (type fixnum ins ls cpy dist))
                  (when (>= (* 4 (1+ nc)) (length cv))
                    (let ((new (make-array (* 2 (length cv))
                                           :element-type '(unsigned-byte 32))))
                      (replace new cv)
                      (when *scratch-pool* (setf (gethash :frag2-cv *scratch-pool*) new))
                      (setf cv new)))
                  (let ((b (* 4 nc)))
                    (declare (type fixnum b))
                    (setf (aref cv b) ins (aref cv (+ b 1)) ls
                          (aref cv (+ b 2)) cpy (aref cv (+ b 3)) dist))
                  (incf nc)
                  (setf last-dist (note-fast-command data litf cmdf distf last-dist
                                                     ins ls cpy dist))))
         (declare (inline hash is-match))
         (when (>= bsize 16)                   ; kInputMarginBytes
           (let* ((limit (+ start (min (- bsize ,k) (- n start 16))))
                  (p (1+ start))
                  (next-hash (hash p)))
             (declare (type fixnum limit p next-hash))
             (block scan
               (loop
                 (let ((skip 32) (next-ip p) (cand 0))
                   (declare (type fixnum skip next-ip cand))
                   ;; trawl: C's do-while, re-entered when the candidate is
                   ;; too far (goto trawl keeps SKIP)
                   (loop
                     (let ((h next-hash) (found nil))
                       (declare (type fixnum h))
                       (setf p next-ip
                             next-ip (+ p (ash skip -5)))
                       (incf skip)
                       (when (> next-ip limit) (return-from scan))
                       (setf next-hash (hash next-ip))
                       (let ((c (- p last-dist)))
                         (declare (type fixnum c))
                         (when (and (< c p) (is-match p c))
                           (setf (aref table h) p cand c found t)))
                       (unless found
                         (setf cand (aref table h) (aref table h) p)
                         (setf found (is-match p cand)))
                       (when (and found (<= (- p cand) window))
                         (return))))
                   ;; emit the match with the literals before it
                   (let* ((base p)
                          (matched (+ ,k (%match-len-sap-frag sap (+ cand ,k) (+ p ,k) bend))))
                     (declare (type fixnum base matched))
                     (incf p matched)
                     (push-cmd (- base lit-start) lit-start matched (- base cand))
                     (setf lit-start p))
                   (when (>= p limit) (return-from scan))
                   (let ((cur 0))
                     (declare (type fixnum cur))
                     ,(if (= k 4)
                          ;; C's first-emit update stores p-1 under hash(p-3)
                          '(let ((h3 (hash (- p 3))))
                             (setf (aref table h3) (- p 3)
                                   (aref table (hash (- p 2))) (- p 2)
                                   (aref table h3) (- p 1)))
                          '(loop for q of-type fixnum from (- p 5) below p
                                 do (setf (aref table (hash q)) q)))
                     (setf cur (hash p) cand (aref table cur) (aref table cur) p)
                     ;; back-to-back copies
                     (loop while (and (<= (- p cand) window) (is-match p cand)) do
                       (let* ((base p)
                              (matched (+ ,k (%match-len-sap-frag sap (+ cand ,k) (+ p ,k) bend))))
                         (declare (type fixnum base matched))
                         (incf p matched)
                         (push-cmd 0 base matched (- base cand))
                         (setf lit-start p)
                         (when (>= p limit) (return-from scan))
                         (loop for q of-type fixnum from (- p ,(1- k)) below p
                               do (setf (aref table (hash q)) q))
                         (setf cur (hash p) cand (aref table cur) (aref table cur) p))))
                   (incf p)
                   (setf next-hash (hash p)))))))
         ;; emit_remainder
         (when (< lit-start bend)
           (push-cmd (- bend lit-start) lit-start 0 0))
         (values cv nc)))))

(define-q1-scan %q1-scan-4 4)
(define-q1-scan %q1-scan-6 6)

(defun q1-should-compress (data start bsize num-literals)
  "C ShouldCompress (compress_fragment_two_pass.c): MIN_RATIO 0.98,
SAMPLE_RATE 43."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum start bsize num-literals))
  (or (< num-literals (* 0.98d0 bsize))
      (let ((h (arena-fixnums 256)) (total 0))
        (declare (type (simple-array fixnum (*)) h) (type fixnum total))
        (loop for i of-type fixnum from 0 below bsize by 43
              do (incf (aref h (aref data (+ start i)))) (incf total))
        (< (max (estimate-entropy h 0 256) (float total 1.0d0))
           (/ (* bsize 8 0.98d0) 43)))))

(defun write-uncompressed-metablock (w data start len)
  "A non-last uncompressed meta-block of DATA[START, START + LEN)."
  (let* ((m1 (1- len)) (nib (cond ((<= m1 #xFFFF) 4) ((<= m1 #xFFFFF) 5) (t 6))))
    (b:wbits w 0 1)
    (b:wbits w (- nib 4) 2)
    (b:wbits w m1 (* 4 nib))
    (b:wbits w 1 1)
    (b:w-align w)
    (b:w-bytes-range w data start (+ start len))))

(defun write-q1-stream (w data window)
  "Every meta-block of a q1 stream (C BrotliCompressFragmentTwoPass), after
the window bits."
  (declare (type (simple-array (unsigned-byte 8) (*)) data) (type fixnum window))
  (let* ((n (length data))
         ;; HashTableSize(2^17, n): 256 doubled while below 2^17 and n
         (tbits (max 8 (min 17 (integer-length (max 1 (1- n))))))
         (k (if (<= tbits 15) 4 6))
         (table (pooled-u32 :frag2-table (ash 1 tbits) nil))
         (cv (pooled-u32 :frag2-cv (* 4 (max 4096 (ash (min n 131072) -4))) nil)))
    (declare (type fixnum n tbits k)
             (type (simple-array (unsigned-byte 32) (*)) table cv))
    (fill table 0 :end (ash 1 tbits))       ; C GetHashTable: memset 0
    (with-ptrs ((sap data))
      (loop for start of-type fixnum from 0 below n by 131072 do
        (let* ((bend (min n (+ start 131072)))
               (bsize (- bend start))
               (lastp (= bend n))
               (litf (arena-fixnums 256))
               (cmdf (arena-fixnums 64))
               (distf (arena-fixnums 64))
               (nc 0))
          (declare (type fixnum bend bsize nc)
                   (type (simple-array fixnum (256)) litf)
                   (type (simple-array fixnum (64)) cmdf distf))
          (let ((asm-done nil))
            #+cl-brotli-x86-64
            (when (>= bsize 16)
              (let ((limit (+ start (min (- bsize k) (- n start 16)))))
                (multiple-value-bind (ls c new-cv)
                    (%asm-q1-scan data table cv start bend limit window tbits k
                                  (if (= k 4)
                                      (q1-hash-4 sap (1+ start) (- tbits 64))
                                      (q1-hash-6 sap (1+ start) (- tbits 64)))
                                  litf cmdf distf)
                  (declare (type fixnum ls c))
                  (setf cv new-cv nc c)
                  ;; emit_remainder
                  (when (< ls bend)
                    (let ((insert (- bend ls)))
                      (when (>= (* 4 (1+ nc)) (length cv))
                        (let ((new (make-array (* 2 (length cv)) :element-type '(unsigned-byte 32))))
                          (replace new cv)
                          (when *scratch-pool* (setf (gethash :frag2-cv *scratch-pool*) new))
                          (setf cv new)))
                      (let ((b (* 4 nc)))
                        (setf (aref cv b) insert (aref cv (+ b 1)) ls
                              (aref cv (+ b 2)) 0 (aref cv (+ b 3)) 0))
                      (incf nc)
                      (note-fast-command data litf cmdf distf -1 insert ls 0 0)))
                  (setf asm-done t))))
            (unless asm-done
              (multiple-value-setq (cv nc)
                (if (= k 4)
                    (%q1-scan-4 data sap window table (- tbits 64) cv 0 start bend litf cmdf distf)
                    (%q1-scan-6 data sap window table (- tbits 64) cv 0 start bend litf cmdf distf)))))
          (let ((num-literals (loop for v across litf sum v of-type fixnum)))
            (declare (type fixnum num-literals))
            (cond
              ((q1-should-compress data start bsize num-literals)
               ;; C StoreCommands' seeds
               (incf (aref cmdf 1)) (incf (aref cmdf 2))
               (incf (aref distf 0)) (incf (aref distf 20))
               (write-mlen-header w bsize lastp)
               (write-fast-block-body w data cv nc litf cmdf distf))
              (t
               (write-uncompressed-metablock w data start bsize)
               (when lastp
                 (b:wbits w 1 1) (b:wbits w 1 1)))))))))
  nil)

(defun lz77 (data window &key (use-dict (text-like-data-p data)) dict-limit
                              (base-pos 0) (max-chain 128) (lazy t)
                              (skip-match nil) (insert-interior t)
                              (score-p nil) (checks 1) (one-pass nil)
                              (bt nil) (fast-fragment nil) (quick nil))
  "Return commands (insert-len lit-start copy-len distance dict-p); copy-len 0
marks a trailing insert-only command.  BASE-POS is the number of bytes already
produced before DATA.  Commands come back as a flat fixnum vector with five
entries per command (insert-len lit-start copy-len distance dict-p).; it is needed to encode dictionary distances correctly
when DATA is one chunk of a multi-meta-block stream.  MAX-CHAIN and LAZY trade
compression ratio for encoder throughput."
  ;; One dictionary snapshot per run: the vector, and its SAP taken
  ;; inside the pinned region, travel down as arguments.  No global is
  ;; written or read (the old *DICT-SAP* store is gone), so concurrent
  ;; runs - including two racing the first dictionary build - cannot
  ;; observe each other's state.
  (let ((dictv (and use-dict (load-dict))))
    (with-ptrs ((sap data) (dictsap dictv))
      (cond
        ((and quick (eq (first quick) :h6))
         (%lz77-h6 data sap window (second quick)))
        (quick
         (%lz77-quick data sap window (first quick) (second quick) (third quick)))
        (fast-fragment
          ;; C keeps BrotliCompressFragmentFast (q0, one-pass) and
          ;; BrotliCompressFragmentTwoPass (q1) in separate translation
          ;; units; so do we - the writer decides which variant runs.
          ;; (q1, the two-pass variant, writes its own meta-blocks:
          ;; WRITE-Q1-STREAM)
          (progn
            (assert one-pass () "q1 streams are written by WRITE-Q1-STREAM")
            ;; C HashTableSize(2^15, n), rounded up to odd bits (the only
            ;; shifts C's one-pass compressor supports)
            (let ((tb (max 8 (min 15 (integer-length (max 1 (1- (length data))))))))
              (when (evenp tb) (incf tb))
              (%lz77-fragment-fast data sap window tb one-pass))))
        (t
          (%lz77 data sap dictv dictsap window
                 use-dict dict-limit base-pos max-chain lazy skip-match
                 insert-interior score-p checks bt))))))

;;; A "trivial" entropy path for q2-q4: one literal/command/distance tree,
;;; no context maps, no block splits.  Unlike PLAN-COMMANDS it does not
;;; allocate or write a 10-fixnum record per command; the code values are
;;; recomputed in the emission pass.
#+cl-brotli-x86-64
(progn
(deftable +triv-tables+
  ;; for %ASM-TRIV-PLAN: insert / copy length codes up to 4096 as
  ;; code | xbits << 8 | xval << 16, the 24 bases and extra-bit counts of
  ;; each alphabet, and the command symbol table
  (flet ((lc (code xval xbits)
           (let ((v (make-array (length code) :element-type '(unsigned-byte 32))))
             (dotimes (i (length code) v)
               (setf (aref v i) (logior (aref code i) (ash (aref xbits i) 8)
                                        (ash (aref xval i) 16))))))
         (u64s (sv) (map '(simple-array (unsigned-byte 64) (*)) #'identity sv)))
    (list (lc +ins-code+ +ins-xval+ +ins-xbits+)
          (lc +cpy-code+ +cpy-xval+ +cpy-xbits+)
          (u64s +ins-base+) (u64s +ins-bits+) (u64s +cpy-base+) (u64s +cpy-bits+)
          (map '(simple-array (unsigned-byte 16) (*)) #'identity +cmd-symbol-table+))))

(defun %asm-triv-plan-drive (data cmds nc rb short-dist litf cmdf distf)
  "WRITE-TRIVIAL-BLOCK-BODY's first pass via %ASM-TRIV-PLAN; RB is
advanced as the second pass would advance it."
  (declare (type (simple-array fixnum (*)) cmds rb litf cmdf distf)
           (type fixnum nc) (optimize (speed 3) (safety 0)))
  (destructuring-bind (inslc cpylc insbase insbits cpybase cpybits cmdsym) +triv-tables+
    (let ((st (arena-u64s +q0-st-size+))
          (ctx (arena-svec +q0-ctx-size+))
          (lit4 (make-array 1024 :element-type '(unsigned-byte 64) :initial-element 0)))
      (declare (type (simple-array (unsigned-byte 64) (*)) st lit4) (type simple-vector ctx))
      (setf (svref ctx +q0c-lit4+) lit4)
      (setf (svref ctx +q0c-data+) data (svref ctx +q0c-cmds+) cmds
            (svref ctx +q0c-litf+) litf (svref ctx +q0c-cmdf+) cmdf
            (svref ctx +q0c-distf+) distf (svref ctx +q0c-inslc+) inslc
            (svref ctx +q0c-cpylc+) cpylc (svref ctx +q0c-insbase+) insbase
            (svref ctx +q0c-insbits+) insbits (svref ctx +q0c-cpybase+) cpybase
            (svref ctx +q0c-cpybits+) cpybits (svref ctx +q0c-cmdsym+) cmdsym)
      (setf (aref st +q0-nc+) nc (aref st +q0-short-dist+) (if short-dist 1 0)
            (aref st +q0-ring0+) (aref rb 0) (aref st +q0-ring1+) (aref rb 1)
            (aref st +q0-ring2+) (aref rb 2) (aref st +q0-ring3+) (aref rb 3)
            (aref st +q0-ringidx+) (aref rb 4))
      (%asm-triv-plan st ctx)
      (dotimes (b 256)
        (incf (aref litf b) (the fixnum (+ (aref lit4 b) (aref lit4 (+ 256 b))
                                            (aref lit4 (+ 512 b)) (aref lit4 (+ 768 b))))))
      (setf (aref rb 0) (aref st +q0-ring0+) (aref rb 1) (aref st +q0-ring1+)
            (aref rb 2) (aref st +q0-ring2+) (aref rb 3) (aref st +q0-ring3+)
            (aref rb 4) (aref st +q0-ringidx+)))))

(defun %asm-triv-emit-drive (w data cmds nc lit-rc lit-ln lit-single cmd-rc cmd-ln
                             dist-rc dist-ln)
  "WRITE-TRIVIAL-BLOCK-BODY's second pass via %ASM-TRIV-EMIT."
  (declare (type b:bwr w) (type (simple-array (unsigned-byte 8) (*)) data)
           (type (simple-array fixnum (*)) cmds lit-rc lit-ln cmd-rc cmd-ln dist-rc dist-ln)
           (type fixnum nc) (optimize (speed 3) (safety 0)))
  (flet ((words (rc ln n)
           (declare (type (simple-array fixnum (*)) rc ln) (type fixnum n))
           (let ((v (arena-u64s n)))
             (when (plusp (length ln))
               (dotimes (i n) (setf (aref v i) (logior (ash (aref rc i) 8) (aref ln i)))))
             v)))
    (let ((st (arena-u64s +q0-st-size+))
          (ctx (arena-svec +q0-ctx-size+)))
      (declare (type (simple-array (unsigned-byte 64) (*)) st) (type simple-vector ctx))
      (setf (svref ctx +q0c-data+) data (svref ctx +q0c-cmds+) cmds
            (svref ctx +q0c-litlut+) (if lit-single
                                         (make-array 256 :element-type '(unsigned-byte 64)
                                                         :initial-element 0)
                                         (words lit-rc lit-ln 256))
            (svref ctx +q0c-cmdlut+) (words cmd-rc cmd-ln 704)
            (svref ctx +q0c-distlut+) (words dist-rc dist-ln 64))
      (setf (aref st +q0-ci+) 0 (aref st +q0-nc+) nc)
      (loop
        (let ((ci (aref st +q0-ci+)))
          (declare (type fixnum ci))
          (b:w-ensure w (+ 65536 (if (< ci nc) (* 2 (ash (aref cmds (* 5 ci)) 0)) 0)))
          (setf (aref st +q0-wpos+) (b:bwr-pos w)
                (aref st +q0-wacc+) (b::bwr-acc w)
                (aref st +q0-wnbits+) (b::bwr-nbits w)
                (aref st +q0-wcap+) (- (length (b:bwr-out w)) 16)
                (svref ctx +q0c-out+) (b:bwr-out w))
          (%asm-triv-emit st ctx)
          (let ((out (b:bwr-out w)) (pos (aref st +q0-wpos+))
                (acc (aref st +q0-wacc+)) (nb (aref st +q0-wnbits+)))
            (declare (type (simple-array (unsigned-byte 8) (*)) out)
                     (type fixnum pos nb) (type (unsigned-byte 64) acc))
            (loop while (>= nb 8)
                  do (setf (aref out pos) (logand acc 255)
                           acc (ash acc -8) nb (- nb 8))
                     (incf pos))
            (setf (b:bwr-pos w) pos (b::bwr-acc w) acc (b::bwr-nbits w) nb))
          (when (zerop (aref st +q0-exit+)) (return nil)))))))
)

;; C's q2 (BrotliStoreMetaBlockFast): a meta-block of at most 128 commands
;; uses fixed command and distance codes (kStaticCommandCodeDepth: symbols
;; 0..447 9 bits, 448..703 11 bits; kStaticDistanceCodeDepth: 6 bits),
;; stored as C's constant bit strings - no command or distance tree is
;; built.  Bound true by %COMPRESS-BYTES for q2.
(defvar *q2-static-codes* nil)
(defvar *q2-static-etrees* nil)
(defun q2-static-etrees ()
  (let ((c *q2-static-etrees*))
    (if c
        (values (car c) (cdr c))
        (let ((cl (make-array 704 :element-type 'fixnum :initial-element 9))
              (dl (make-array 64 :element-type 'fixnum :initial-element 6)))
          (fill cl 11 :start 448)
          (let* ((*arena* nil)
                 (cmd (make-fixed-etree cl 704))
                 (dist (make-fixed-etree dl 64)))
            (setf *q2-static-etrees* (cons cmd dist))
            (values cmd dist))))))
(defun write-q2-static-trees (w)
  "C StoreStaticCommandHuffmanTree + StoreStaticDistanceHuffmanTree."
  ;; 56 bits 0x92624416307003, 3 zero bits, then 28 bits 0x0369DC03, in
  ;; writes of at most 24 bits
  (b:wbits w #x307003 24) (b:wbits w #x624416 24) (b:wbits w #x92 8)
  (b:wbits w 0 3)
  (b:wbits w #x69DC03 24) (b:wbits w #x3 4))

(defun write-trivial-block-body (w data cmds rb
                                 &key (short-dist nil)
                                   (max-lit-bits 15)
                                   (n5 (length cmds)))
  (declare (type b:bwr w)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type (simple-array fixnum (*)) rb cmds)
           (type fixnum n5)
           (optimize (speed 3) (safety 0)))
  (let* ((litf (make-array 256 :element-type 'fixnum :initial-element 0))
         (cmdf (make-array 704 :element-type 'fixnum :initial-element 0))
         (distf (make-array 64 :element-type 'fixnum :initial-element 0))
         (probe-rb (copy-seq rb))
         ;; LENGTH-CODE's five table args are DEFPARAMETERS; bound once
         ;; (4 calls per command across the two passes re-read 20 globals
         ;; otherwise).
         (ins-c +ins-code+) (ins-x +ins-xval+) (ins-xb +ins-xbits+)
         (ins-b +ins-base+) (ins-bt +ins-bits+)
         (cpy-c +cpy-code+) (cpy-x +cpy-xval+) (cpy-xb +cpy-xbits+)
         (cpy-b +cpy-base+) (cpy-bt +cpy-bits+))
    (declare (type (simple-array fixnum (256)) litf)
             (type (simple-array fixnum (*)) cmdf distf probe-rb))
    ;; x86-64 SBCL: both passes in assembly (the first computes each
    ;; command's codes once, into the command's slots 2..4, and advances RB
    ;; exactly as the second pass below would)
    #+cl-brotli-x86-64
    (let ((nc (truncate n5 5)))
      (%asm-triv-plan-drive data cmds nc rb short-dist litf cmdf distf)
      (let* ((static (and *q2-static-codes* (<= nc 128)))
             (lit (build-etree litf 256 max-lit-bits))
             (cmd (if static (q2-static-etrees) (build-etree cmdf 704 15)))
             (dist (if static (nth-value 1 (q2-static-etrees)) (build-etree distf 64 15))))
        (b:wbits w 0 1) (b:wbits w 0 1) (b:wbits w 0 1)
        (b:wbits w 0 2) (b:wbits w 0 4) (b:wbits w 0 2)
        (b:wbits w 0 1) (b:wbits w 0 1)
        (write-etree w lit 256)
        (if static
            (write-q2-static-trees w)
            (progn (write-etree w cmd 704)
                   (write-etree w dist 64)))
        (%asm-triv-emit-drive w data cmds nc
                              (or (etree-rcodes lit) +empty-fixnums+)
                              (or (etree-lengths lit) +empty-fixnums+)
                              (and (etree-single lit) t)
                              (or (etree-rcodes cmd) +empty-fixnums+)
                              (or (etree-lengths cmd) +empty-fixnums+)
                              (or (etree-rcodes dist) +empty-fixnums+)
                              (or (etree-lengths dist) +empty-fixnums+))
        (return-from write-trivial-block-body nil)))
    ;; Pass 1: histograms only.  CMDS is a flat 5-fixnum vector; DICTP is 0/1.
    (loop for ci of-type fixnum from 0 below (truncate n5 5) do
      (let* ((vb (* 5 ci))
             (ins (aref cmds vb)) (lit-start (aref cmds (+ vb 1)))
             (cpy (aref cmds (+ vb 2)))
             (dist (aref cmds (+ vb 3))) (dictp (aref cmds (+ vb 4))))
        (declare (type (integer 0 #.(ash 1 40)) ins lit-start cpy dist)
                 (type (integer 0 15) dictp))
        (loop for i from lit-start below (+ lit-start ins)
              do (incf (aref litf (aref data i))))
        (multiple-value-bind (icode ixv ixb)
            (length-code ins ins-c ins-x ins-xb ins-b ins-bt)
          (declare (ignore ixv ixb))
          (multiple-value-bind (ccode cxv cxb)
              (if (plusp cpy)
                  (length-code (copy-code-len cpy dictp) cpy-c cpy-x cpy-xb cpy-b cpy-bt)
                  (values 0 0 0))
            (declare (ignore cxv cxb))
            (let* ((ring-pos (aref probe-rb 4))
                   (repeat (and (plusp cpy) (zerop dictp)
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
                          (if (and short-dist (zerop dictp))
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
                  (unless (or (plusp dictp) (= dcode 0))
                    (setf (aref probe-rb (logand ring-pos 3)) dist)
                    (setf (aref probe-rb 4) (1+ ring-pos))))))))))
    (let* ((static (and *q2-static-codes* (<= (truncate n5 5) 128)))
           (lit (build-etree litf 256 max-lit-bits))
           (cmd (if static (q2-static-etrees) (build-etree cmdf 704 15)))
           (dist (if static (nth-value 1 (q2-static-etrees)) (build-etree distf 64 15)))
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
               (type (integer 0 #.(ash 1 40)) slack))
      (b:wbits w 0 1) (b:wbits w 0 1) (b:wbits w 0 1)
      (b:wbits w 0 2) (b:wbits w 0 4) (b:wbits w 0 2)
      (b:wbits w 0 1) (b:wbits w 0 1)
      (write-etree w lit 256)
      (if static
          (write-q2-static-trees w)
          (progn (write-etree w cmd 704)
                 (write-etree w dist 64)))
      ;; Pass 2: recompute the compact codes and emit.  The writer's
      ;; ACC/NBITS/POS live in locals (WR-PM / WR-RAW) and are synced with
      ;; the BWR only around W-ENSURE and W-EMIT-RUN: through the struct,
      ;; every write was three loads and three stores.
      (let ((acc (b::bwr-acc w)) (nbits (b::bwr-nbits w)) (wpos (b::bwr-pos w)))
        (declare (type (unsigned-byte 64) acc) (type (integer 0 7) nbits)
                 (type fixnum wpos))
        (macrolet ((sync-out () '(setf (b::bwr-acc w) acc (b::bwr-nbits w) nbits (b::bwr-pos w) wpos))
                   (sync-in () '(setf acc (b::bwr-acc w) nbits (b::bwr-nbits w) wpos (b::bwr-pos w))))
      (loop for ci of-type fixnum from 0 below (truncate n5 5) do
        (let* ((vb (* 5 ci))
               (ins (aref cmds vb)) (lit-start (aref cmds (+ vb 1)))
               (cpy (aref cmds (+ vb 2)))
               (dist (aref cmds (+ vb 3))) (dictp (aref cmds (+ vb 4))))
          (declare (type (integer 0 #.(ash 1 40)) ins lit-start cpy dist)
                   (type (integer 0 15) dictp))
          (let ((cost (+ 24 (* 2 ins))))
            (declare (type fixnum cost))
            ;; reserve 64 KiB beyond this command (an insert over 32 KiB
            ;; costs more than 64 KiB itself; SLACK must not go negative)
            (when (> cost slack)
              (setf slack (+ 65536 cost))
              (sync-out)
              (b:w-ensure w slack)
              (sync-in))
            (decf slack cost))
          (multiple-value-bind (icode ixv ixb)
              (length-code ins ins-c ins-x ins-xb ins-b ins-bt)
            (multiple-value-bind (ccode cxv cxb)
                (if (plusp cpy)
                    (length-code (copy-code-len cpy dictp) cpy-c cpy-x cpy-xb cpy-b cpy-bt)
                    (values 0 0 0))
              (let* ((ring-pos (aref rb 4))
                     (repeat (and (plusp cpy) (zerop dictp)
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
                          (if (and short-dist (zerop dictp))
                              (special-distance-code rb dist)
                              (values nil 0 0))
                        (if scode
                            (setf dcode scode dxv sxv dxb sxb)
                            (multiple-value-setq (dcode dxv dxb)
                              (encode-distance dist)))))
                  (unless (or (plusp dictp) (= dcode 0))
                    (setf (aref rb (logand ring-pos 3)) dist)
                    (setf (aref rb 4) (1+ ring-pos))))
                (unless cmd-single
                  (wr-pm w acc nbits wpos (aref cmd-rc csym) (aref cmd-ln csym)))
                (wr-pm w acc nbits wpos ixv ixb)
                (wr-pm w acc nbits wpos cxv cxb)
                (unless lit-single
                  (if (>= ins 16)
                      (progn
                        (sync-out)
                        (b:w-emit-run w data lit-start (+ lit-start ins)
                                      lit-rc lit-ln)
                        (sync-in))
                      (loop for i of-type fixnum from lit-start below (+ lit-start ins)
                            do (let ((sym (aref data i)))
                                 (wr-raw w acc nbits wpos (aref lit-rc sym)
                                         (aref lit-ln sym))))))
                (when (>= dcode 0)
                  (unless dist-single
                    (wr-pm w acc nbits wpos (aref dist-rc dcode)
                           (aref dist-ln dcode)))
                  (wr-raw w acc nbits wpos dxv dxb)))))))
        (sync-out))))))

;;; ---- compressed meta-block --------------------------------------------

#+cl-brotli-x86-64
(progn
(deftable +fast-x-luts+
  ;; per-length (extra << 16 | extra bits << 8 | flag << 7 | code) words for
  ;; %ASM-FAST-EMIT: insert lengths < 6210, copy lengths < 2118 and
  ;; last-distance copy lengths < 2120 (flag: the code implies an explicit
  ;; distance code 0)
  (flet ((table (n fn first flagged)
           (let ((v (make-array n :element-type '(unsigned-byte 32) :initial-element 0)))
             (loop for i from first below n
                   do (multiple-value-bind (cc e nb) (funcall fn i)
                        (setf (aref v i)
                              (logior (ash e 16) (ash nb 8) cc
                                      (if (and flagged (>= (aref +q0-cmd-map+ cc) 128)) 128 0)))))
             v)))
    (list (table 6210 #'q0-insert-len 0 nil)
          (table 2118 #'q0-copy-len 2 nil)
          (table 2120 #'q0-copy-last-len 4 t))))

(defun %asm-fast-emit-drive (w data cv nc lit-rc lit-ln lit-single cmd-rc cmd-ln
                             dist-rc dist-ln)
  "WRITE-FAST-BLOCK-BODY's command loop via %ASM-FAST-EMIT, growing W
whenever it stops for room."
  (declare (type b:bwr w) (type (simple-array (unsigned-byte 8) (*)) data)
           (type (simple-array (unsigned-byte 32) (*)) cv) (type fixnum nc)
           (type (simple-array fixnum (*)) lit-rc lit-ln cmd-rc cmd-ln dist-rc dist-ln)
           (optimize (speed 3) (safety 0)))
  (destructuring-bind (insx copyx clastx) +fast-x-luts+
    (let ((lit (make-array 256 :element-type '(unsigned-byte 64) :initial-element 0))
          (cmd (make-array 64 :element-type '(unsigned-byte 64) :initial-element 0))
          (dist (make-array 64 :element-type '(unsigned-byte 64) :initial-element 0))
          (st (arena-u64s +q0-st-size+))
          (ctx (arena-svec +q0-ctx-size+)))
      (declare (type (simple-array (unsigned-byte 64) (*)) lit cmd dist st)
               (type simple-vector ctx))
      (unless lit-single
        (dotimes (c 256)
          (setf (aref lit c) (logior (ash (aref lit-rc c) 8) (aref lit-ln c)))))
      (dotimes (c 64)
        (let ((m (aref +q0-cmd-map+ c)))
          (setf (aref cmd c) (logior (ash (aref cmd-rc m) 8) (aref cmd-ln m))
                (aref dist c) (logior (ash (aref dist-rc c) 8) (aref dist-ln c)))))
      (setf (svref ctx +q0c-data+) data (svref ctx +q0c-cv+) cv
            (svref ctx +q0c-litlut+) lit (svref ctx +q0c-cmdlut+) cmd
            (svref ctx +q0c-distlut+) dist (svref ctx +q0c-insx+) insx
            (svref ctx +q0c-copyx+) copyx (svref ctx +q0c-clastx+) clastx)
      (setf (aref st +q0-ci+) 0 (aref st +q0-nc+) nc
            (aref st +q0-last-dist+) (ldb (byte 64 0) -1)
            (aref st +q0-c39flag+) (if (>= (aref +q0-cmd-map+ 39) 128) 128 0))
      (loop
        (let ((ci (aref st +q0-ci+)))
          (declare (type fixnum ci))
          ;; room for the next command at least, and 64 KiB more
          (b:w-ensure w (+ 65536 (if (< ci nc) (* 2 (aref cv (* 4 ci))) 0)))
          (%bwr-settle w)
          (setf (aref st +q0-wpos+) (b:bwr-pos w)
                (aref st +q0-wacc+) (b::bwr-acc w)
                (aref st +q0-wnbits+) (b::bwr-nbits w)
                (aref st +q0-wcap+) (- (length (b:bwr-out w)) 16)
                (svref ctx +q0c-out+) (b:bwr-out w))
          (%asm-fast-emit st ctx)
          (let ((out (b:bwr-out w)) (pos (aref st +q0-wpos+))
                (acc (aref st +q0-wacc+)) (nb (aref st +q0-wnbits+)))
            (declare (type (simple-array (unsigned-byte 8) (*)) out)
                     (type fixnum pos nb) (type (unsigned-byte 64) acc))
            (loop while (>= nb 8)
                  do (setf (aref out pos) (logand acc 255)
                           acc (ash acc -8) nb (- nb 8))
                     (incf pos))
            (setf (b:bwr-pos w) pos (b::bwr-acc w) acc (b::bwr-nbits w) nb))
          (when (zerop (aref st +q0-exit+)) (return nil)))))))
)

(defun write-trivial-metablocks (w data cmds n5 rb &key short-dist (max-lit-bits 15))
  "C's q2/q3 stream shape (EncodeData): the input in 16 KiB blocks, and a
meta-block flushed at the end of the first block where literals + commands
since the last flush reach MAX_NUM_DELAYED_SYMBOLS (0x2FFF), each written
by WRITE-TRIVIAL-BLOCK-BODY with its own trees (the local statistics are
worth 1-2% on binary input).  A copy running past the block end moves the
boundary to its end (C truncates the copy there and finds the rest again
at the same distance); an insert spanning the boundary is split, its first
part the meta-block's final, insert-only command.  Writes every MLEN
header itself; the last meta-block is the stream's last."
  (declare (type b:bwr w)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type (simple-array fixnum (*)) cmds rb)
           (type fixnum n5))
  (let* ((n (length data))
         (ncmd (truncate n5 5))
         (ci 0) (lits 0) (cnt 0) (mb-start 0) (first-ci 0)
         (head nil)                       ; (ins ls cpy dist dictp) for FIRST-CI
         (b 16384))
    (declare (type fixnum n ncmd ci lits cnt mb-start first-ci b))
    (labels ((cmd (i k)
               (declare (type fixnum i k))
               (if (and head (= i first-ci))
                   (the fixnum (nth k head))
                   (aref cmds (+ (* 5 i) k))))
             (emit (end last-ci tail lastp)
               ;; commands FIRST-CI..LAST-CI-1 (+ an insert-only TAIL)
               (let* ((k (+ (- last-ci first-ci) (if tail 1 0)))
                      (sub (make-array (* 5 k) :element-type 'fixnum)))
                 (loop for i from first-ci below last-ci for o from 0 by 5 do
                   (dotimes (j 5) (setf (aref sub (+ o j)) (cmd i j))))
                 (when tail
                   (let ((o (* 5 (- last-ci first-ci))))
                     (setf (aref sub o) tail (aref sub (+ o 1)) (- end tail)
                           (aref sub (+ o 2)) 0 (aref sub (+ o 3)) 0
                           (aref sub (+ o 4)) 0)))
                 (write-mlen-header w (- end mb-start) lastp)
                 (write-trivial-block-body w data sub rb :short-dist short-dist
                                                         :max-lit-bits max-lit-bits
                                                         :n5 (length sub)))))
      (loop
        (when (>= b n)
          (if (zerop first-ci)
              ;; one meta-block: the commands as they are, no copy
              (progn
                (write-mlen-header w n t)
                (write-trivial-block-body w data cmds rb :short-dist short-dist
                                                         :max-lit-bits max-lit-bits
                                                         :n5 n5))
              (emit n ncmd nil t))
          (return))
        ;; the commands C creates in this block: copy starting before B
        (loop while (and (< ci ncmd) (plusp (cmd ci 2))
                         (< (+ (cmd ci 1) (cmd ci 0)) b))
              do (incf lits (cmd ci 0)) (incf cnt) (incf ci))
        (if (< (+ lits cnt) #x2FFF)
            (incf b 16384)
            (let* ((last-end (if (> ci first-ci) (+ (cmd (1- ci) 1) (cmd (1- ci) 0) (cmd (1- ci) 2)) mb-start))
                   (end (max b last-end))
                   (tail nil) (next-head nil))
              (declare (type fixnum last-end end))
              (when (and (= end b) (< ci ncmd) (< (cmd ci 1) b))
                ;; split the insert spanning B
                (let ((ins (cmd ci 0)) (ls (cmd ci 1)))
                  (setf tail (- b ls)
                        next-head (list (- ins tail) b (cmd ci 2) (cmd ci 3) (cmd ci 4)))))
              (when (>= end n)
                ;; the boundary reached the end: one final meta-block
                (emit n ncmd nil t)
                (return))
              (emit end ci tail nil)
              (setf mb-start end first-ci ci head next-head lits 0 cnt 0)
              (incf b 16384)
              (loop while (<= b end) do (incf b 16384))))))))

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
      #+cl-brotli-x86-64
      (unless (or cmd-single dist-single)
        (%asm-fast-emit-drive w data cv nc lit-rc lit-ln (and lit-single t)
                              cmd-rc cmd-ln dist-rc dist-ln)
        (return-from write-fast-block-body nil))
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
                (setf slack (+ 65536 cost))
                (b:w-ensure w slack))
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
                      &key (short-dist t) (quality 5) (n5 (length cmds)))
  "Turn raw LZ77 commands into flat fixnum records and tally literal/command/
distance frequencies.  Returns (values RECS NCOMMANDS LITFREQ CMDFREQ DISTFREQ).
RB is the distance ring shared by all meta-blocks of the stream; it must
persist across chunks just like the decoder's ring.  SHORT-DIST enables the 15
short distance-ring codes; low qualities disable them to avoid 15 comparisons
per command."
  (let* ((ncmd (truncate n5 5))
         ;; pooled (4 MB per MiB of text at q5): read only below
         ;; NCMD * stride, consumed before the next PLAN-COMMANDS
         (recs (pooled-fixnums :recs (* +cmd-stride+ ncmd)))
         (ri 0)
         ;; C ChooseContextMode for q10+: signed for non-UTF8 input, and
         ;; the context map comes from clustering this parse's literals.
         ;; Cost is proportional to the literals, and a parse with few
         ;; literals (repetitive input) gains nothing from 64 contexts:
         ;; those keep the static path, which costs nothing.
         (hq (and (>= quality *hq-min-quality*) *hq-context-modeling*
                  (>= (loop for vb of-type fixnum from 0 below n5 by 5
                            sum (the fixnum (aref cmds vb)) of-type fixnum)
                      64)))
         (lit-mode (if (and hq (not (literals-mostly-utf8-p
                                      data cmds (if (>= quality 10) most-positive-fixnum 32768) n5)))
                       3 2))
         ;; Below q10 only non-UTF8 input clusters: there it is worth ~5% of
         ;; size; on UTF8 text ~0.5% for ~6% more time (C's q9 uses static
         ;; maps for both).  And only from 256 KiB: below that the static
         ;; map is as small or smaller (binary 64 KiB 1.004 vs 1.010 of C)
         ;; and the clustering cost milliseconds per call.
         (hq (and hq (or (>= quality 10)
                         (and (= lit-mode 3) (>= (length data) 262144)))))
         (ctx (multiple-value-list
               (if hq
                   (hq-context-map data cmds lit-mode n5)
                   (literal-contexts data quality))))
         (lit-k (first ctx))
         (lit-cmap (second ctx))
         (litfreq (make-array (* lit-k 256) :element-type 'fixnum
                                            :initial-element 0))
         (cmdfreq (make-array 704 :element-type 'fixnum :initial-element 0))
         (distfreq (make-array 64 :element-type 'fixnum :initial-element 0))
         ;; LENGTH-CODE is inline, but its five table args are
         ;; DEFPARAMETERS: every call re-reads them from global cells.
         ;; Bound once here (the zopfli path already does this).
         (ins-c +ins-code+) (ins-x +ins-xval+) (ins-xb +ins-xbits+)
         (ins-b +ins-base+) (ins-bt +ins-bits+)
         (cpy-c +cpy-code+) (cpy-x +cpy-xval+) (cpy-xb +cpy-xbits+)
         (cpy-b +cpy-base+) (cpy-bt +cpy-bits+)
         (ctxlut +ctx-lut+) (lb (* 512 lit-mode)))
    (declare (type fixnum ri lb)
             (type (simple-array (unsigned-byte 8) (2048)) ctxlut)
             (type (simple-array (unsigned-byte 8) (*)) data)
             (type (simple-array fixnum (*)) recs litfreq cmdfreq distfreq
                                     rb cmds)
             ;; every CMAP variant is a #(...) literal vector (or NIL for
             ;; the unmodelled path); without this the per-literal AREF in
             ;; the loop below fell back to the generic hairy accessor
             (type (or null simple-vector) lit-cmap))
    ;; Flat fixnum vector, 5 entries per command (INS LIT-START CPY DIST
    ;; DICTP); DICTP is 0/1 here so the truthiness tests below use
    ;; ZEROP/PLUSP instead of NOT/OR (0 is truthy in Lisp).
    (loop for ci of-type fixnum from 0 below (truncate n5 5) do
      (let* ((vb (* 5 ci))
             (ins (aref cmds vb))
             (lit-start (aref cmds (+ vb 1)))
             (cpy (aref cmds (+ vb 2)))
             (dist (aref cmds (+ vb 3)))
             (dictp (aref cmds (+ vb 4)))
             (ring-pos (aref rb 4)))
        (declare (type fixnum ins lit-start cpy dist dictp ring-pos))
        (multiple-value-bind (icode ixv ixb)
            (length-code ins ins-c ins-x ins-xb ins-b ins-bt)
          (declare (type fixnum icode ixv ixb))
          (let ((copyp (plusp cpy)))
            (multiple-value-bind (ccode cxv cxb)
                (if copyp
                    (length-code (copy-code-len cpy dictp) cpy-c cpy-x cpy-xb cpy-b cpy-bt)
                    (values 0 0 0))
              (declare (type fixnum ccode cxv cxb))
              (let* ((repeat (and copyp (zerop dictp)
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
                                               (logior (aref ctxlut (+ lb p1))
                                                       (aref ctxlut (+ lb 256 p2))))))
                               (declare (type fixnum sym p1 p2 cid))
                               (incf (aref litfreq (+ (* cid 256) sym))))))
                (when copyp
                  (unless dist0
                    (if repeat
                        (setf dcode 0)
                        (multiple-value-bind (scode sxv sxb)
                            (if (and short-dist (zerop dictp))
                                (special-distance-code rb dist)
                                (values nil 0 0))
                          (if scode
                              (setf dcode scode dxv sxv dxb sxb)
                              (multiple-value-setq (dcode dxv dxb)
                                (encode-distance dist)))))
                    (incf (aref distfreq dcode))
                    ;; Distance symbol 0 reuses the last distance without
                    ;; pushing; dictionary references are not pushed either.
                    (unless (or (plusp dictp) (= dcode 0))
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
    (values recs ncmd litfreq cmdfreq distfreq lit-k lit-cmap lit-mode)))

(defun write-mlen-header (w n last)
  (let* ((m1 (1- n)) (nib (cond ((<= m1 #xFFFF) 4) ((<= m1 #xFFFFF) 5) (t 6))))
    (b:wbits w (if last 1 0) 1)                          ; ISLAST
    (when last (b:wbits w 0 1))                          ; ISLASTEMPTY=0
    (b:wbits w (- nib 4) 2)                              ; MNIBBLES
    (b:wbits w m1 (* 4 nib))                             ; MLEN-1
    (unless last (b:wbits w 0 1))))                      ; ISUNCOMPRESSED=0


;; ---- literal context modeling (C encode.c: DecideOverLiteralContext
;; ---- / ChooseContextMap / ShouldUseComplexStaticContextMap) --------------

(deftable +ctx-simple-utf8+
  #(0 0 1 1 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0))

(deftable +ctx-continuation+
  #(1 1 2 2 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0))

(deftable +ctx-complex-utf8+
  #(11 11 12 12 0 0 0 0 1 1 9 9 2 2 2 2
    1 1 1 1 8 3 3 3 1 1 1 1 2 2 2 2
    8 4 4 4 8 7 4 4 8 0 0 0 3 3 3 3
    5 5 10 5 5 5 10 5 6 6 6 6 6 6 6 6))

(declaim (type simple-vector +ctx-simple-utf8+ +ctx-continuation+
                         +ctx-complex-utf8+))

(declaim (inline estimate-entropy))
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
        ;; FAST-LOG2: the same libm values, tabled below 2048 (the
        ;; splitters call this ~3x256 bins per block decision)
        (when (plusp p)
          (incf result (* (float p 1.0d0) (fast-log2 p))))))
    (if (zerop total)
        0.0d0
        (- (* (float total 1.0d0) (fast-log2 total)) result))))

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
              do (let ((cls (aref lut (ash (aref data pos) -6))))
                   (declare (type fixnum cls))
                   ;; C: histo[prev + lut[b>>6]]++, prev = lut[b>>6] * 3
                   (incf (aref bigram (+ prev cls)))
                   (setf prev (* 3 cls))))))
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


(declaim (inline %approx-log2))
(defun %approx-log2 (v)
  "log2 of a positive fixnum without libm: exact below 2048, else the top
11 bits through the table (relative error < 2^-10) - cluster decisions only."
  (declare (type (integer 1 #.most-positive-fixnum) v) (optimize (speed 3) (safety 0)))
  (if (< v 2048)
      (aref +fast-log2-table+ v)
      (let ((k (- (integer-length v) 11)))
        (+ k (aref +fast-log2-table+ (ash v (- k)))))))

(defun %histo-cost (h off)
  "Estimated bits to code the 256-bin histogram H[OFF..OFF+256) with its own
prefix code: Shannon bits plus a code-description estimate."
  (declare (type (simple-array fixnum (*)) h) (type fixnum off)
           (optimize (speed 3) (safety 0)))
  (let ((total 0) (nnz 0) (sum 0.0d0))
    (declare (type fixnum total nnz) (type double-float sum))
    (loop for i of-type fixnum from off below (+ off 256) do
      (let ((c (aref h i)))
        (declare (type fixnum c))
        (when (plusp c)
          (incf total c) (incf nnz)
          (incf sum (* c (%approx-log2 c))))))
    (if (<= nnz 1)
        (if (zerop nnz) 0.0d0 12.0d0)
        (+ (- (* total (%approx-log2 total)) sum)
           *hq-tree-bits-base*
           (* *hq-tree-bits-per-symbol* nnz)))))

(defun literals-mostly-utf8-p (data cmds &optional (limit most-positive-fixnum) (n5 (length cmds)))
  "C BrotliIsMostlyUTF8 (ratio 0.75) over the parse's literal runs (up to
LIMIT literal bytes) - not the whole input."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type (simple-array fixnum (*)) cmds)
           (optimize (speed 3) (safety 0)))
  ;; LIMIT caps the literal bytes examined: at q9 the gate runs on every
  ;; UTF8 input only to skip the modeling (a full parse of JSON's ~250 KB of
  ;; literals cost several percent), so q9 samples 32 KiB; q10/q11 scan all
  ;; (a sample misjudged ELF binaries as UTF8 there).
  (let ((good 0) (total 0))
    (declare (type fixnum good total))
    (loop for vb of-type fixnum from 0 below n5 by 5
          while (< total limit) do
      (let* ((ls (aref cmds (+ vb 1))) (end (+ ls (aref cmds vb))) (i ls))
        (declare (type fixnum ls end i))
        (incf total (- end ls))
        (loop while (< i end) do
          (multiple-value-bind (cp bytes) (parse-as-utf8 data i end)
            (declare (type fixnum cp bytes))
            (when (< cp #x110000) (incf good bytes))
            (incf i bytes)))))
    (> (* 4 good) (* 3 total))))

(defun hq-context-map (data cmds mode &optional (n5 (length cmds)))
  "C's q10+ literal context modeling (BrotliBuildMetaBlock without block
splits): 64 literal histograms under context MODE (2 UTF8, 3 signed) from
the parse's literals, merged greedily while a merge saves estimated bits
\(the BrotliClusterHistograms idea).  Returns (values K CMAP64), or
\(values 1 NIL) when everything merges into one histogram."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type (simple-array fixnum (*)) cmds)
           (type (integer 0 3) mode)
           (optimize (speed 3) (safety 0)))
  (let ((h (make-array (* 64 256) :element-type 'fixnum :initial-element 0))
        (lut +ctx-lut+) (lb (* 512 mode)))
    (declare (type (simple-array fixnum (*)) h)
             (type (simple-array (unsigned-byte 8) (2048)) lut)
             (type fixnum lb))
    (loop for vb of-type fixnum from 0 below n5 by 5 do
      (let ((ins (aref cmds vb)) (ls (aref cmds (+ vb 1))))
        (declare (type fixnum ins ls))
        (loop for i of-type fixnum from ls below (+ ls ins) do
          (let* ((p1 (if (plusp i) (aref data (1- i)) 0))
                 (p2 (if (> i 1) (aref data (- i 2)) 0))
                 (cid (logior (aref lut (+ lb p1)) (aref lut (+ lb 256 p2)))))
            (declare (type fixnum p1 p2 cid))
            (incf (aref h (+ (* cid 256) (aref data i))))))))
    ;; clusters: OWNER[c] = representative context, COST[c] for representatives
    (let ((owner (make-array 64 :element-type 'fixnum))
          (cost (make-array 64 :element-type 'double-float))
          (alive (make-array 64 :element-type 'bit :initial-element 0))
          (tmp (make-array 256 :element-type 'fixnum)))
      (declare (type (simple-array fixnum (64)) owner)
               (type (simple-array double-float (64)) cost)
               (type (simple-array bit (64)) alive)
               (type (simple-array fixnum (256)) tmp))
      (dotimes (c 64)
        (setf (aref owner c) c (aref cost c) (%histo-cost h (* c 256)))
        (when (loop for i from (* c 256) below (* (1+ c) 256)
                    thereis (plusp (aref h i)))
          (setf (aref alive c) 1)))
      (let ((gain (make-array (* 64 64) :element-type 'double-float
                                        :initial-element 0.0d0)))
        (declare (type (simple-array double-float (4096)) gain))
      (flet ((merged-cost (a b)
               (declare (type fixnum a b))
               (dotimes (i 256)
                 (setf (aref tmp i) (+ (aref h (+ (* a 256) i))
                                       (aref h (+ (* b 256) i)))))
               (%histo-cost tmp 0)))
        ;; GAIN[a*64+b] (a < b) caches the saving of merging a and b; a
        ;; merge only invalidates the pairs that involve the merged cluster.
        (flet ((refresh (a b)
                 (declare (type fixnum a b))
                 (when (> a b) (rotatef a b))
                 (setf (aref gain (+ (* a 64) b))
                       (- (+ (aref cost a) (aref cost b)) (merged-cost a b)))))
          (dotimes (a 64)
            (when (= 1 (aref alive a))
              (loop for b of-type fixnum from (1+ a) below 64 do
                (when (= 1 (aref alive b)) (refresh a b)))))
        (loop
          (let ((best-gain 0.0d0) (ba -1) (bb -1))
            (declare (type double-float best-gain) (type fixnum ba bb))
            (dotimes (a 64)
              (when (= 1 (aref alive a))
                (loop for b of-type fixnum from (1+ a) below 64 do
                  (when (= 1 (aref alive b))
                    (let ((g (aref gain (+ (* a 64) b))))
                      (declare (type double-float g))
                      (when (> g best-gain)
                        (setf best-gain g ba a bb b)))))))
            (when (< ba 0) (return))
            ;; merge BB into BA
            (dotimes (i 256)
              (incf (aref h (+ (* ba 256) i)) (aref h (+ (* bb 256) i)))
              (setf (aref h (+ (* bb 256) i)) 0))
            (setf (aref cost ba) (%histo-cost h (* ba 256))
                  (aref alive bb) 0)
            (dotimes (c 64)
              (when (and (= 1 (aref alive c)) (/= c ba)) (refresh ba c)))
            (dotimes (c 64)
              (when (= (aref owner c) bb) (setf (aref owner c) ba))))))))
      ;; dense cluster ids in first-use order; empty contexts join cluster 0
      (let ((ids (make-array 64 :element-type 'fixnum :initial-element -1))
            (cmap (make-array 64 :initial-element 0))
            (k 0))
        (declare (type (simple-array fixnum (64)) ids) (type fixnum k))
        (dotimes (c 64)
          (let ((o (aref owner c)))
            (when (= 1 (aref alive o))
              (when (< (aref ids o) 0) (setf (aref ids o) k) (incf k))
              (setf (svref cmap c) (aref ids o)))))
        (if (<= k 1) (values 1 nil) (values k cmap))))))

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

(defun write-context-map (w cmap size k)
  "Write SIZE context-map entries mapping onto K trees in READ-CONTEXT-MAP's
format with RLEMAX=0 and the IMTF bit clear."
  (declare (type b:bwr w) (type fixnum size k))
  (b:wbits w 0 1)                             ; RLEMAX = 0
  (let* ((freqs (make-array k :element-type 'fixnum :initial-element 1))
         (et (build-etree freqs k 15)))
    (write-etree w et k)
    (dotimes (cid size)
      (declare (type fixnum cid))
      (etree-emit w et (aref cmap cid))))
  (b:wbits w 0 1))                            ; no IMTF

(defun blen-sym (len)
  "The block-length prefix symbol for LEN.  +blen-base+ ranges are
contiguous, so the largest base <= LEN is the correct symbol."
  (declare (type fixnum len))
  (loop for s of-type fixnum from 25 downto 0
        when (<= (aref +blen-base+ s) len) return s))

(defun write-blen (w tree len)
  "Write block length LEN through the block-length prefix code TREE."
  (declare (type b:bwr w) (type fixnum len))
  (let ((s (blen-sym len)))
    (declare (type fixnum s))
    (etree-emit w tree s)
    (b:wbits w (- len (aref +blen-base+ s)) (aref +blen-bits+ s))))

(defun histo-slice (flat k size)
  "The K-th SIZE-symbol histogram of a flat K*SIZE frequency array."
  (declare (type (simple-array fixnum (*)) flat) (type fixnum k size))
  (let ((f (make-array size :element-type 'fixnum :initial-element 0)))
    (declare (type (simple-array fixnum (*)) f))
    (dotimes (j size f)
      (declare (type fixnum j))
      (setf (aref f j) (aref flat (+ (* k size) j))))))

(defmacro %greedy-splitter-body (n alphabet min-block threshold feed)
  "The body of C's greedy BlockSplitter (v1.0.9 metablock_inc.h): N, ALPHABET,
MIN-BLOCK, THRESHOLD are variables of the caller; FEED is a form that calls
\(ADD SYM) for every symbol of the stream in order.  Returns (values TYPES
LENGTHS NBLOCKS NTYPES HISTOS), HISTOS[t] being type t's histogram."
  `(let ((n ,n) (alphabet ,alphabet) (min-block ,min-block) (threshold ,threshold))
     (declare (type fixnum n alphabet min-block)
              (type double-float threshold))

  (let* ((max-blocks (max 1 (1+ (floor n min-block))))
         (max-types (min max-blocks 257))
         (types (make-array max-blocks :element-type '(unsigned-byte 8)
                                     :initial-element 0))
         (lengths (make-array max-blocks :element-type 'fixnum
                                        :initial-element 0))
         ;; one spare histogram beyond MAX-TYPES (C's "one more" comment);
         ;; allocated as block types appear (CLEAR-HISTO), not up front:
         ;; 258 command histograms are 1.4 MB, real streams use a few
         (histos (let ((v (make-array (1+ max-types) :initial-element nil)))
                   (setf (aref v 0) (make-array alphabet :element-type 'fixnum
                                                         :initial-element 0))
                   v))
         (scratch0 (make-array alphabet :element-type 'fixnum
                                       :initial-element 0))
         (scratch1 (make-array alphabet :element-type 'fixnum
                                       :initial-element 0))
         (nblocks 0) (ntypes 0) (curr-ix 0)
         (target min-block) (bsize 0)
         (last-ix0 0) (last-ix1 0)
         (last-ent0 0.0d0) (last-ent1 0.0d0)
         (merge-count 0))
    (declare (type (simple-array (unsigned-byte 8) (*)) types)
             (type (simple-array fixnum (*)) lengths scratch0 scratch1)
             (type fixnum nblocks ntypes curr-ix target bsize
                   last-ix0 last-ix1 merge-count)
             (type double-float last-ent0 last-ent1))
    (labels ((clear-histo (ix)
               (declare (type fixnum ix))
               (let ((h (aref histos ix)))
                 (if h
                     (let ((h h))
                       (declare (type (simple-array fixnum (*)) h))
                       (dotimes (j alphabet)
                         (declare (type fixnum j))
                         (setf (aref h j) 0)))
                     (setf (aref histos ix)
                           (make-array alphabet :element-type 'fixnum
                                                :initial-element 0)))))
             (entropy (ix)
               (declare (type fixnum ix))
               (estimate-entropy (aref histos ix) 0 alphabet))
             (finish (final)
               (declare (type boolean final))
               (when (< bsize min-block) (setf bsize min-block))
               (cond
                 ((zerop nblocks)
                  ;; first block
                  (setf (aref lengths 0) bsize
                        (aref types 0) 0
                        last-ent0 (entropy 0)
                        last-ent1 last-ent0)
                  (incf nblocks) (incf ntypes)
                  (incf curr-ix)
                  (when (< curr-ix (1+ max-types)) (clear-histo curr-ix))
                  (setf bsize 0))
                 ((plusp bsize)
                  (let ((ent (entropy curr-ix))
                        (ce0 0.0d0) (ce1 0.0d0)
                        (d0 0.0d0) (d1 0.0d0))
                    (declare (type double-float ent ce0 ce1 d0 d1))
                    (dotimes (j 2)
                      (declare (type fixnum j))
                      (let ((dst (if (zerop j) scratch0 scratch1))
                            (src (the (simple-array fixnum (*)) (aref histos (if (zerop j) last-ix0
                                                  last-ix1))))
                            (cur (the (simple-array fixnum (*)) (aref histos curr-ix))))
                        (declare (type (simple-array fixnum (*)) dst src cur))
                        (dotimes (a alphabet)
                          (declare (type fixnum a))
                          (setf (aref dst a) (+ (aref cur a) (aref src a))))
                        (let ((e (estimate-entropy dst 0 alphabet)))
                          (declare (type double-float e))
                          (if (zerop j)
                              (setf ce0 e d0 (- e ent last-ent0))
                              (setf ce1 e d1 (- e ent last-ent1))))))
                    (cond
                      ((and (< ntypes 256)
                            (> d0 threshold) (> d1 threshold))
                       ;; new block type
                       (setf (aref lengths nblocks) bsize
                             (aref types nblocks) ntypes
                             last-ix1 last-ix0
                             last-ix0 ntypes
                             last-ent1 last-ent0
                             last-ent0 ent)
                       (incf nblocks) (incf ntypes)
                       (incf curr-ix)
                       (when (< curr-ix (1+ max-types))
                         (clear-histo curr-ix))
                       (setf bsize 0 merge-count 0 target min-block))
                      ((< d1 (- d0 20.0d0))
                       ;; block with the second-last type
                       (setf (aref lengths nblocks) bsize
                             (aref types nblocks) (aref types (- nblocks 2)))
                       (rotatef last-ix0 last-ix1)
                       (replace (the (simple-array fixnum (*)) (aref histos last-ix0)) scratch1)
                       (setf last-ent1 last-ent0
                             last-ent0 ce1)
                       (incf nblocks)
                       (setf bsize 0)
                       (clear-histo curr-ix)
                       (setf merge-count 0 target min-block))
                      (t
                       ;; merge with the last block
                       (incf (aref lengths (1- nblocks)) bsize)
                       (replace (the (simple-array fixnum (*)) (aref histos last-ix0)) scratch0)
                       (setf last-ent0 ce0)
                       (when (= ntypes 1) (setf last-ent1 last-ent0))
                       (setf bsize 0)
                       (clear-histo curr-ix)
                       (incf merge-count)
                       (when (> merge-count 1)
                         (incf target min-block)))))))
               )
             (add (sym)
               (declare (type fixnum sym))
               (incf (aref (the (simple-array fixnum (*)) (aref histos curr-ix)) sym))
               (incf bsize)
               (when (= bsize target)
                 (finish nil))))
      (declare (inline clear-histo entropy))
,feed
      (finish t))
    (values types lengths nblocks ntypes histos))))

(defun split-block (syms n alphabet min-block threshold)
  "C's greedy BlockSplitter (v1.0.9 metablock_inc.h) for one category.
SYMS is the symbol stream - for distances, only distance-bearing entries.
Collects MIN-BLOCK symbols per decision and merges/emits by the
entropy-difference thresholds.  Returns (values TYPES LENGTHS NBLOCKS
NTYPES); LENGTHS are in symbol units and may overshoot N at the tail
(harmless: the decoder only reads a switch when a count reaches zero)."
  (declare (type (simple-array (unsigned-byte 16) (*)) syms)
           (type fixnum n alphabet min-block)
           (type double-float threshold)
           (optimize (speed 3) (safety 0)))
  (%greedy-splitter-body n alphabet min-block threshold
    (dotimes (i n)
      (declare (type fixnum i))
      (add (aref syms i)))))

(defun split-literals (recs ncmd data n)
  "SPLIT-BLOCK over the literal stream of the plan RECS (N literals), read
in place: C's literal splitter (256, 512, 400.0)."
  (declare (type (simple-array fixnum (*)) recs)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum ncmd n)
           (optimize (speed 3) (safety 0)))
  (let ((alphabet 256) (min-block 512) (threshold 400.0d0))
    (%greedy-splitter-body n alphabet min-block threshold
      (dotimes (k ncmd)
        (declare (type fixnum k))
        (let* ((b (* k +cmd-stride+))
               (ins (aref recs b)) (ls (aref recs (+ b 1))))
          (declare (type fixnum b ins ls))
          (loop for i of-type fixnum from ls below (+ ls ins)
                do (add (aref data i))))))))

(defun block-type-codes (types nblocks)
  "C BlockTypeCodeCalculator: the switch code of every block (index 0, the
implicit first block, unused): 1 = previous type + 1, 0 = the type before
the previous one, else type + 2.  The greedy splitter mostly alternates
between its last two types, so the cheap codes dominate."
  (declare (type (simple-array (unsigned-byte 8) (*)) types)
           (type fixnum nblocks)
           (optimize (speed 3) (safety 0)))
  (let ((codes (make-array (max 1 nblocks) :element-type 'fixnum :initial-element 0))
        (last 1) (second-last 0))
    (declare (type fixnum last second-last))
    (dotimes (i nblocks codes)
      (let* ((tp (aref types i))
             (code (cond ((= tp (1+ last)) 1)
                         ((= tp second-last) 0)
                         (t (+ tp 2)))))
        (declare (type fixnum tp code))
        (setf (aref codes i) code
              second-last last
              last tp)))))

(defun write-blk-header (w first-len type-tree tsize len-tree)
  "The optional block-type/length prefix codes + first count - the inverse
of the decoder's READ-BLK-HEADER - for a category with >= 2 block types."
  (declare (type b:bwr w) (type fixnum first-len tsize))
  (write-etree w type-tree tsize)
  (write-etree w len-tree 26)
  (write-blen w len-tree first-len))

(defun literal-split (recs ncmd data)
  "C's greedy literal BlockSplitter (InitBlockSplitter(256, 512, 400.0)) over
the literal stream of the plan RECS - the single-context case of
BrotliBuildMetaBlockGreedy.  Returns (values TYPES LENGTHS NBLOCKS NTYPES
HISTOS); one block when there are too few literals to split."
  (declare (type (simple-array fixnum (*)) recs)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum ncmd)
           (optimize (speed 3) (safety 0)))
  (let ((nlits 0))
    (declare (type fixnum nlits))
    (dotimes (k ncmd)
      (incf nlits (the fixnum (aref recs (* k +cmd-stride+)))))
    (if (< nlits 1024)
        (values (make-array 1 :element-type '(unsigned-byte 8) :initial-element 0)
                (make-array 1 :element-type 'fixnum :initial-element (max 1 nlits))
                1 1 nil)
        (split-literals recs ncmd data nlits))))

(defun literal-type-trees (histos nltypes rle)
  "One literal tree per literal block type, from the splitter's per-type
histograms."
  (declare (type simple-vector histos) (type fixnum nltypes))
  (let ((v (make-array nltypes)))
    (dotimes (t0 nltypes v)
      (setf (aref v t0) (build-etree (aref histos t0) 256 15 rle)))))

(defun write-compressed-block-body (w data base-pos window use-dict dict-limit rb
                                    &key (max-chain 128) (lazy t) (short-dist t)
                                      (skip-match nil) (insert-interior t)
                                      (score-p nil) (checks 1)
                                      (quality 5)
                                      (bt nil)
                                      (quick nil)
                                      cmds)
  "Write the NBLTYPES/trees/commands part of a compressed meta-block.  The
MLEN header must already have been written.  RB is the stream-wide distance
ring shared with the decoder.  CMDS, when supplied, is a precomputed command
list covering exactly this block.  Command and distance streams are split
into block types with C's greedy BlockSplitter (v1.0.9); when the splitter
finds no split the header degrades to the single-type form byte-for-byte."
  (declare (type b:bwr w)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum base-pos window)
           (type (or null fixnum) dict-limit)
           (type (simple-array fixnum (*)) rb)
           (type fixnum max-chain))
  (multiple-value-bind (recs ncmd litf cmdf distf lit-k lit-cmap lit-mode)
        (multiple-value-bind (v used)
            (if cmds
                (values cmds (length cmds))
                (lz77 data window :use-dict use-dict :dict-limit dict-limit
                                  :base-pos base-pos :max-chain max-chain :lazy lazy
                                  :skip-match skip-match
                                  :insert-interior insert-interior
                                  :score-p score-p :checks checks :bt bt
                                  :quick quick))
          ;; the quick/H6/chain matchers return a pooled, untrimmed vector: only
          ;; its first USED entries are this input's commands
          (plan-commands data v rb :short-dist short-dist :quality quality
                                   :n5 (or used (length v))))
    (declare (type (simple-array fixnum (*)) recs litf cmdf distf)
             (type fixnum ncmd lit-k)
             (type (or null simple-vector) lit-cmap)
             (ignorable cmdf distf))
    ;; ---- splitter inputs: command symbols and distance symbols ----------
    (let* ((cmd-syms (make-array ncmd :element-type '(unsigned-byte 16)))
           (nd (loop for k of-type fixnum below ncmd
                     count (>= (aref recs (+ (* k +cmd-stride+) 7)) 0)))
           (dist-syms (make-array nd :element-type '(unsigned-byte 16))))
      (declare (type fixnum nd)
               (type (simple-array (unsigned-byte 16) (*))
                     cmd-syms dist-syms))
      (dotimes (k ncmd)
        (declare (type fixnum k))
        (setf (aref cmd-syms k) (aref recs (+ (* k +cmd-stride+) 2))))
      (let ((j 0))
        (declare (type fixnum j))
        (dotimes (k ncmd)
          (declare (type fixnum k))
          (let ((d (aref recs (+ (* k +cmd-stride+) 7))))
            (declare (type fixnum d))
            (when (>= d 0)
              (setf (aref dist-syms j) d)
              (incf j)))))
      (multiple-value-bind (itypes ilens niblocks nitypes ihistos)
          (split-block cmd-syms ncmd 704 1024 500.0d0)
        (declare (type fixnum niblocks nitypes)
                 ;; SPLIT-BLOCK returns (values ub8-types fixnum-lengths ...)
                 (type (simple-array (unsigned-byte 8) (*)) itypes)
                 (type (simple-array fixnum (*)) ilens))
        (multiple-value-bind (dtypes dlens ndblocks ndtypes dhistos)
            (split-block dist-syms nd 64 512 100.0d0)
          (declare (type fixnum ndblocks ndtypes)
                   (type (simple-array (unsigned-byte 8) (*)) dtypes)
                   (type (simple-array fixnum (*)) dlens))
          ;; ---- per-type histograms, trees, switch trees ----------------
          (let* ((lsplit (if (= lit-k 1)
                             (multiple-value-list (literal-split recs ncmd data))
                             (list (make-array 1 :element-type '(unsigned-byte 8)
                                                 :initial-element 0)
                                   (make-array 1 :element-type 'fixnum
                                                 :initial-element 1)
                                   1 1)))
                 (ltypes (first lsplit))
                 (llens (second lsplit))
                 (nlblocks (third lsplit))
                 (nltypes (fourth lsplit))
                 )
            (declare (type simple-vector ihistos dhistos))
            (let* ((cmd-ets (let ((v (make-array nitypes)))
                            (dotimes (t0 nitypes v)
                              (declare (type fixnum t0))
                              (setf (aref v t0)
                                    ;; the splitter's per-type histograms
                                    (build-etree (aref ihistos t0)
                                                 704 15 (>= quality 4))))))
                 (dist-ets (let ((v (make-array ndtypes)))
                             (dotimes (t0 ndtypes v)
                               (declare (type fixnum t0))
                               (setf (aref v t0)
                                     (build-etree (aref dhistos t0)
                                                  64 15 (>= quality 4))))))
                 ;; C BrotliOptimizeHistograms (q4+): RLE-friendly counts
                 ;; for the literal, command and distance trees only
                 (lit (when (= lit-k 1) (build-etree litf 256 15 (>= quality 4))))
                 ;; C's greedy literal blocks (single-context case)
                 (lit-ets (when (> nltypes 1)
                            (literal-type-trees (fifth lsplit) nltypes
                                                (>= quality 4))))
                 (lits (when (>= lit-k 2)
                         (let ((v (make-array lit-k)))
                           (dotimes (k lit-k v)
                             (setf (aref v k)
                                   (build-etree (histo-slice litf k 256)
                                                256 15 (>= quality 4))))))))
            ;; ---- block-type / block-length switch codes ----------------
            (let* ((icodes (block-type-codes itypes niblocks))
                   (dcodes (block-type-codes dtypes ndblocks))
                   (lcodes (block-type-codes ltypes nlblocks))
                   (l-type-tree
                    (when (> nltypes 1)
                      (let ((tf (make-array (+ nltypes 2) :element-type 'fixnum
                                                          :initial-element 0)))
                        (declare (type (simple-array fixnum (*)) tf))
                        (loop for b of-type fixnum from 1 below nlblocks
                              do (incf (aref tf (aref lcodes b))))
                        (build-etree tf (+ nltypes 2) 15))))
                   (l-len-tree
                    (when (> nltypes 1)
                      (let ((lf (make-array 26 :element-type 'fixnum :initial-element 0)))
                        (declare (type (simple-array fixnum (*)) lf))
                        (dotimes (b nlblocks)
                          (declare (type fixnum b))
                          (incf (aref lf (blen-sym (aref llens b)))))
                        (build-etree lf 26 15))))
                   (i-type-tree
                    (when (> nitypes 1)
                      (let ((tf (make-array (+ nitypes 2)
                                            :element-type 'fixnum
                                            :initial-element 0)))
                        (declare (type (simple-array fixnum (*)) tf))
                        (loop for b of-type fixnum from 1 below niblocks
                              do (incf (aref tf (aref icodes b))))
                        (build-etree tf (+ nitypes 2) 15))))
                   (i-len-tree
                    (when (> nitypes 1)
                      (let ((lf (make-array 26 :element-type 'fixnum
                                               :initial-element 0)))
                        (declare (type (simple-array fixnum (*)) lf))
                        (dotimes (b niblocks)
                          (declare (type fixnum b))
                          (incf (aref lf (blen-sym (aref ilens b)))))
                        (build-etree lf 26 15))))
                   (d-type-tree
                    (when (> ndtypes 1)
                      (let ((tf (make-array (+ ndtypes 2)
                                            :element-type 'fixnum
                                            :initial-element 0)))
                        (declare (type (simple-array fixnum (*)) tf))
                        (loop for b of-type fixnum from 1 below ndblocks
                              do (incf (aref tf (aref dcodes b))))
                        (build-etree tf (+ ndtypes 2) 15))))
                   (d-len-tree
                    (when (> ndtypes 1)
                      (let ((lf (make-array 26 :element-type 'fixnum
                                               :initial-element 0)))
                        (declare (type (simple-array fixnum (*)) lf))
                        (dotimes (b ndblocks)
                          (declare (type fixnum b))
                          (incf (aref lf (blen-sym (aref dlens b)))))
                        (build-etree lf 26 15)))))
              ;; ---- header --------------------------------------------
              ;; NBLTYPES L: 1 when contexts carry the literals (as in C's
              ;; q5+ context modeling), else C's greedy literal blocks
              (write-nbltypes w nltypes)
              (when (> nltypes 1)
                (write-blk-header w (aref llens 0) l-type-tree (+ nltypes 2)
                                  l-len-tree))
              (write-nbltypes w nitypes)
              (when (> nitypes 1)
                (write-blk-header w (aref ilens 0) i-type-tree (+ nitypes 2)
                                  i-len-tree))
              (write-nbltypes w ndtypes)
              (when (> ndtypes 1)
                (write-blk-header w (aref dlens 0) d-type-tree (+ ndtypes 2)
                                  d-len-tree))
              (b:wbits w 0 2)                ; NPOSTFIX=0
              (b:wbits w 0 4)                ; NDIRECT=0
              (if (= lit-k 1)
                  (dotimes (t0 nltypes)      ; context mode per type (unused)
                    (b:wbits w 0 2))
                  (b:wbits w lit-mode 2))    ; context mode: 2 UTF8, 3 signed
              (cond ((>= lit-k 2)
                     (write-nbltypes w lit-k)
                     (write-context-map w lit-cmap 64 lit-k))
                    ((> nltypes 1)
                     ;; tree t for all 64 contexts of literal type t
                     (write-nbltypes w nltypes)
                     (let ((lm (make-array (* 64 nltypes) :element-type 'fixnum)))
                       (declare (type (simple-array fixnum (*)) lm))
                       (dotimes (i (* 64 nltypes))
                         (setf (aref lm i) (ash i -6)))
                       (write-context-map w lm (* 64 nltypes) nltypes)))
                    (t (b:wbits w 0 1)))     ; NTREESL=1
              (if (= ndtypes 1)
                  (b:wbits w 0 1)            ; NTREESD=1
                  (progn
                    (write-nbltypes w ndtypes)
                    ;; identity distance context map: all 4 copy-length
                    ;; contexts of type t select tree t
                    (let ((dm (make-array (* 4 ndtypes)
                                          :element-type 'fixnum
                                          :initial-element 0)))
                      (declare (type (simple-array fixnum (*)) dm))
                      (dotimes (t0 ndtypes)
                        (declare (type fixnum t0))
                        (dotimes (c 4)
                          (declare (type fixnum c))
                          (setf (aref dm (+ (* 4 t0) c)) t0)))
                      (write-context-map w dm (* 4 ndtypes) ndtypes))))
              (cond ((>= lit-k 2)
                     (dotimes (k lit-k)
                       (declare (type fixnum k))
                       (write-etree w (aref lits k) 256)))
                    ((> nltypes 1)
                     (dotimes (t0 nltypes)
                       (write-etree w (aref lit-ets t0) 256)))
                    (t (write-etree w lit 256)))
              (dotimes (t0 nitypes)
                (declare (type fixnum t0))
                (write-etree w (aref cmd-ets t0) 704))
              (dotimes (t0 ndtypes)
                (declare (type fixnum t0))
                (write-etree w (aref dist-ets t0) 64))
              ;; ---- emit loop ------------------------------------------
              (let ((lit-single (and lit (etree-single lit)))
                    (lit-rc (or (and lit (etree-rcodes lit)) +empty-fixnums+))
                    (lit-ln (or (and lit (etree-lengths lit)) +empty-fixnums+))
                    (lit-rcl (if (>= lit-k 2)
                               (let ((v (make-array lit-k)))
                                 (dotimes (k lit-k v)
                                   (setf (aref v k)
                                         (or (etree-rcodes (aref lits k))
                                             +empty-fixnums+))))
                               #()))
                    (lit-lnl (if (>= lit-k 2)
                               (let ((v (make-array lit-k)))
                                 (dotimes (k lit-k v)
                                   (setf (aref v k)
                                         (or (etree-lengths (aref lits k))
                                             +empty-fixnums+))))
                               #()))
                    (lit-sng (if (>= lit-k 2)
                               (let ((v (make-array lit-k :initial-element nil)))
                                 (dotimes (k lit-k v)
                                   (setf (aref v k)
                                         (etree-single (aref lits k)))))
                               #()))
                    (cmd-rcs (let ((v (make-array nitypes)))
                               (dotimes (t0 nitypes v)
                                 (setf (aref v t0)
                                       (or (etree-rcodes (aref cmd-ets t0))
                                           +empty-fixnums+)))))
                    (cmd-lns (let ((v (make-array nitypes)))
                               (dotimes (t0 nitypes v)
                                 (setf (aref v t0)
                                       (or (etree-lengths (aref cmd-ets t0))
                                           +empty-fixnums+)))))
                    (cmd-sngs (let ((v (make-array nitypes :initial-element nil)))
                                (dotimes (t0 nitypes v)
                                  (setf (aref v t0)
                                        (etree-single (aref cmd-ets t0))))))
                    (dist-rcs (let ((v (make-array ndtypes)))
                                (dotimes (t0 ndtypes v)
                                  (setf (aref v t0)
                                        (or (etree-rcodes (aref dist-ets t0))
                                            +empty-fixnums+)))))
                    (dist-lns (let ((v (make-array ndtypes)))
                                (dotimes (t0 ndtypes v)
                                  (setf (aref v t0)
                                        (or (etree-lengths (aref dist-ets t0))
                                            +empty-fixnums+)))))
                    (dist-sngs (let ((v (make-array ndtypes :initial-element nil)))
                                 (dotimes (t0 ndtypes v)
                                   (setf (aref v t0)
                                         (etree-single (aref dist-ets t0))))))
                    (itype 0) (iblk 0) (ileft (aref ilens 0))
                    (dtype 0) (dblk 0) (dleft (aref dlens 0))
                    (lblk 0) (lleft (aref llens 0))
                    (slack 0))
                (declare (type simple-vector lit-rcl lit-lnl lit-sng
                                       cmd-rcs cmd-lns cmd-sngs
                                       dist-rcs dist-lns dist-sngs)
                         (type (simple-array fixnum (*)) lit-rc lit-ln)
                         (type fixnum itype iblk ileft dtype dblk dleft slack
                               lblk lleft))
                (when (> nltypes 1)
                  (let ((et (aref lit-ets 0)))
                    (setf lit-single (etree-single et)
                          lit-rc (or (etree-rcodes et) +empty-fixnums+)
                          lit-ln (or (etree-lengths et) +empty-fixnums+))))
                (dotimes (k ncmd)
                  (declare (type fixnum k))
                  (let ((b (* k +cmd-stride+)))
                    (declare (type fixnum b))
                    ;; I-block switch: the decoder reads it before the
                    ;; command when the previous block's count is exhausted.
                    (when (> nitypes 1)
                      (when (zerop ileft)
                        (incf iblk)
                        (let ((nt (aref itypes iblk)) (nl (aref ilens iblk)))
                          (declare (type fixnum nt nl))
                          (etree-emit w i-type-tree (aref icodes iblk))
                          (write-blen w i-len-tree nl)
                          (setf itype nt ileft nl)))
                      (decf ileft))
                    (let ((ins (aref recs b))
                          (ls (aref recs (+ b 1)))
                          (ctxlut +ctx-lut+) (lb (* 512 (the (integer 0 3) lit-mode))))
                      (declare (type fixnum ins ls lb)
                               (type (simple-array (unsigned-byte 8) (2048)) ctxlut))
                      ;; One capacity check covers every bit this command can
                      ;; emit: at most ~13 bytes of command/distance overhead
                      ;; plus two bytes per literal (code lengths <= 15 bits),
                      ;; plus the eight-byte slack the raw writer needs.
                      (let ((cost (+ 24 (* 2 ins))))
                        (declare (type fixnum cost))
                        (when (> cost slack)
                          (setf slack (+ 65536 cost))
                          (b:w-ensure w slack))
                        (decf slack cost))
                      (let ((crc (the (simple-array fixnum (*)) (aref cmd-rcs itype)))
                            (cln (the (simple-array fixnum (*)) (aref cmd-lns itype)))
                            (csng (aref cmd-sngs itype)))
                        (unless csng
                          (b:%wbits-raw w (aref crc (aref recs (+ b 2)))
                                        (aref cln (aref recs (+ b 2))))))
                      (b:%wbits-raw-pm w (aref recs (+ b 3))
                                       (aref recs (+ b 4)))
                      (b:%wbits-raw-pm w (aref recs (+ b 5))
                                       (aref recs (+ b 6)))
                      (if (>= lit-k 2)
                          (loop for i of-type fixnum from ls below (+ ls ins)
                                do (let* ((sym (aref data i))
                                          (p1 (if (plusp i)
                                                  (aref data (1- i)) 0))
                                          (p2 (if (> i 1)
                                                  (aref data (- i 2)) 0))
                                          (cid (aref lit-cmap
                                                     (logior (aref ctxlut (+ lb p1))
                                                             (aref ctxlut (+ lb 256 p2))))))
                                     (declare (type fixnum sym p1 p2 cid))
                                     (unless (aref lit-sng cid)
                                       (b:%wbits-raw
                                        w (aref (the (simple-array fixnum (*)) (aref lit-rcl cid)) sym)
                                        (aref (the (simple-array fixnum (*)) (aref lit-lnl cid)) sym)))))
                          (flet ((run (from to)
                                   (declare (type fixnum from to))
                                   (unless lit-single
                                     ;; Long runs amortize the pin/state setup
                                     ;; of the run writer; short runs are
                                     ;; cheaper inline.
                                     (if (>= (- to from) 16)
                                         (b:w-emit-run w data from to lit-rc lit-ln)
                                         (loop for i of-type fixnum from from below to
                                               do (let ((sym (aref data i)))
                                                    (b:%wbits-raw w (aref lit-rc sym)
                                                                  (aref lit-ln sym))))))))
                            (if (= nltypes 1)
                                (run ls (+ ls ins))
                                ;; literal block switches: read by the decoder
                                ;; before a literal once the count is spent
                                (let ((i ls) (end (+ ls ins)))
                                  (declare (type fixnum i end))
                                  (loop while (< i end) do
                                    (when (zerop lleft)
                                      (incf lblk)
                                      (let ((et (aref lit-ets (aref ltypes lblk))))
                                        (etree-emit w l-type-tree (aref lcodes lblk))
                                        (write-blen w l-len-tree (aref llens lblk))
                                        (setf lleft (aref llens lblk)
                                              lit-single (etree-single et)
                                              lit-rc (or (etree-rcodes et) +empty-fixnums+)
                                              lit-ln (or (etree-lengths et) +empty-fixnums+))))
                                    (let ((m (min lleft (- end i))))
                                      (declare (type fixnum m))
                                      (run i (+ i m))
                                      (incf i m)
                                      (decf lleft m)))))))
                      (let ((dcode (aref recs (+ b 7))))
                        (declare (type fixnum dcode))
                        (when (>= dcode 0)
                          ;; D-block switch: read by the decoder only for
                          ;; commands that carry a distance symbol.
                          (when (> ndtypes 1)
                            (when (zerop dleft)
                              (incf dblk)
                              (let ((nt (aref dtypes dblk))
                                    (nl (aref dlens dblk)))
                                (declare (type fixnum nt nl))
                                (etree-emit w d-type-tree (aref dcodes dblk))
                                (write-blen w d-len-tree nl)
                                (setf dtype nt dleft nl)))
                            (decf dleft))
                          (let ((drc (the (simple-array fixnum (*)) (aref dist-rcs dtype)))
                                (dln (the (simple-array fixnum (*)) (aref dist-lns dtype)))
                                (dsng (aref dist-sngs dtype)))
                            (unless dsng
                              (b:%wbits-raw w (aref drc dcode)
                                            (aref dln dcode))))
                          (b:%wbits-raw-pm w (aref recs (+ b 8))
                                           (aref recs (+ b 9)))))))))))))))))


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

(defun cmds->list (v)
  "Flat 5-fixnum command vector -> list of 5-element lists with DICTP NIL
or the dictionary code (1 + cut), the representation PARTITION-COMMANDS and
SPLIT-COMMAND-AT expect.  Only the >16MiB multi-meta-block path pays this
conversion."
  (declare (type (simple-array fixnum (*)) v) (optimize (speed 3) (safety 0)))
  (let ((out '()))
    (loop for i from (- (length v) 5) downto 0 by 5 do
      (push (list (aref v i) (aref v (+ i 1)) (aref v (+ i 2))
                  (aref v (+ i 3)) (if (zerop (aref v (+ i 4))) nil (aref v (+ i 4))))
            out))
    out))

(defun block->cmds (lst)
  "Inverse of CMDS->LIST: a partitioned command list back to an exact flat
5-fixnum vector (DICTP 0, or 1 + the bytes a dictionary word was cut) for
the writers."
  (declare (type list lst) (optimize (speed 3) (safety 0)))
  (let* ((n (length lst))
         (v (make-array (* 5 n) :element-type 'fixnum)))
    (declare (type (simple-array fixnum (*)) v) (type fixnum n))
    (loop for c in lst for i of-type fixnum from 0 by 5 do
      (setf (aref v i) (car c)
            (aref v (+ i 1)) (cadr c)
            (aref v (+ i 2)) (caddr c)
            (aref v (+ i 3)) (cadddr c)
            ;; DICTP: NIL -> 0, T (the zopfli path's flag) -> 1, or the
            ;; matchers' 1 + cut
            (aref v (+ i 4)) (let ((d (car (cddddr c))))
                               (cond ((null d) 0) ((integerp d) d) (t 1)))))
    v))

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
                                    (quality 5)
                                    (one-pass nil)
                                    (bt nil)
                                    (quick nil)
                                    (mb-flush nil))
  "Entropy-coded brotli stream for INPUT.  Inputs larger than one meta-block
are split into <= 2^24-byte compressed meta-blocks followed by an empty last
meta-block."
  (let* ((data (b:to-octets input))
         (n (length data))
         (w (acquire-bwr n))
         (wbits (min 24 (max 10 (integer-length (max 1 n)))))
         (window (- (ash 1 wbits) 16))
         (rb (make-array 5 :element-type 'fixnum
                          :initial-contents '(16 15 11 4 4)))
         ;; C ChooseHasher for q2-q4: H2, H3, then H4 below 1 MiB / H54.
         (quick (case quick
                  (2 '(16 1 5)) (3 '(16 2 5))
                  (4 (if (>= n #.(ash 1 20)) '(20 4 7) '(17 4 5)))
                  ;; C's H5 below 1 MiB, H6 from there (%LZ77-H6)
                  ((5 6 7 8 9) (list :h6 quick)))))
    (write-wbits w wbits)
    (cond
      ((zerop n)
       (b:wbits w 1 1) (b:wbits w 1 1))                    ; ISLAST + ISLASTEMPTY
      ((and fast-fragment (not one-pass))
       ;; q1: C's two-pass compressor, 128 KiB meta-blocks
       (write-q1-stream w data window))
      ((<= n #.(ash 1 24))
       (unless (and trivial mb-flush)
         (write-mlen-header w n t))
       (cond
         (fast-fragment
          (if one-pass
              ;; C's BrotliCompressFragmentFast: the scan itself writes the
              ;; meta-block body (trees were built from the pre-scan
              ;; histogram inside the fragment).
              (lz77 data window
                    :max-chain max-chain :lazy nil :skip-match t
                    :use-dict nil :insert-interior nil :one-pass w
                    :fast-fragment t)
              (multiple-value-bind (cv nc litf cmdf distf)
                  (lz77 data window
                        :max-chain max-chain :lazy nil :skip-match t
                        :use-dict nil :insert-interior nil
                        :fast-fragment t)
                (write-fast-block-body w data cv nc litf cmdf distf))))
         (trivial
          (multiple-value-bind (cmds used)
              (lz77 data window :use-dict use-dict :dict-limit dict-limit
                                :base-pos 0 :max-chain max-chain :lazy lazy
                                :skip-match skip-match
                                :insert-interior insert-interior
                                :quick quick)
            (if mb-flush
                (write-trivial-metablocks w data cmds (or used (length cmds)) rb
                                          :short-dist short-dist
                                          :max-lit-bits max-lit-bits)
                (write-trivial-block-body w data cmds rb :short-dist short-dist
                                                         :max-lit-bits max-lit-bits
                                                         :n5 (or used (length cmds))))))
         (t
          (write-compressed-block-body w data 0 window use-dict dict-limit rb
                                       :max-chain max-chain :lazy lazy
                                       :short-dist short-dist
                                       :skip-match skip-match
                                       :insert-interior insert-interior
                                       :score-p score-p :checks checks
                                       :quality quality :bt bt
                                       :quick quick))))
      (t
       (let* ((mb-chain (if fast-fragment 32 max-chain))
              (mb-lazy (if fast-fragment t lazy))
              (mb-skip (if fast-fragment nil skip-match))
              (mb-interior (if fast-fragment t insert-interior))
              (cmds (multiple-value-bind (v used)
                        (lz77 data window :use-dict use-dict
                                   :dict-limit dict-limit :base-pos 0
                                   :max-chain mb-chain :lazy mb-lazy
                                   :skip-match mb-skip
                                   :insert-interior mb-interior
                                   :score-p score-p :checks checks
                                   :bt bt :quick quick)
                      ;; the quick matcher's vector is pooled and untrimmed
                      (if (and used (/= used (length v))) (subseq v 0 used) v)))
              (remaining (partition-commands (cmds->list cmds) #.(ash 1 24)))
              (pos 0))
         (loop while remaining do
           (let* ((block (pop remaining))
                  (lastp (null remaining))
                  (outlen (reduce #'+ block :key #'command-output-length
                                        :initial-value 0)))
             (write-mlen-header w outlen lastp)
             (if trivial
                 (write-trivial-block-body w data (block->cmds block) rb
                                           :short-dist short-dist
                                           :max-lit-bits max-lit-bits)
                 (write-compressed-block-body w data 0 window use-dict dict-limit
                                              rb :max-chain max-chain
                                                 :lazy lazy :short-dist short-dist
                                                 :skip-match skip-match
                                                 :insert-interior insert-interior
                                                 :quality quality
                                                 :bt bt
                                                 :cmds (block->cmds block)))
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
         ;; typed fixnum: the untyped simple-vector made every one of the
         ;; 16K sample iterations do a boxed read + boxed write (this runs
         ;; on EVERY compress call); same counting, no boxing
         (seen (make-array 256 :element-type 'fixnum :initial-element 0))
         (unique 0) (maxfreq 0))
    (declare (type (simple-array fixnum (256)) seen))
    (when (< sample 4) (return-from incompressible-p nil))
    ;; Fast exit for the common case: 16+ repeated 4-byte groups among the
    ;; first KiB's 256 already mean compressible (a 2^15-bit set holds 256
    ;; random keys with ~1 false repeat).  Only a NIL can come early, and
    ;; a wrong NIL costs time, not size (the stored fallback still compares
    ;; lengths); the full test below is unchanged.
    (when (>= sample 1024)
      (let ((bits (make-array 4096 :element-type '(unsigned-byte 8)
                                   :initial-element 0))
            (dups 0))
        (declare (type (simple-array (unsigned-byte 8) (4096)) bits)
                 (type fixnum dups) (dynamic-extent bits))
        (loop for i of-type fixnum from 0 below 1024 by 4 do
          (let* ((key (dict-key4 data i))
                 (h (logand (* key #x9E3779B1) #x7FFF))
                 (byte (ash h -3))
                 (mask (ash 1 (logand h 7))))
            (declare (type fixnum key h byte mask))
            (if (logtest (aref bits byte) mask)
                (when (>= (incf dups) 16)
                  (return-from incompressible-p nil))
                (setf (aref bits byte) (logior (aref bits byte) mask)))))))
    ;; counts in four interleaved lanes (a run of one byte value made each
    ;; increment wait on the last), then UNIQUE and MAXFREQ from the sums
    (let ((lanes (make-array 1024 :element-type 'fixnum :initial-element 0))
          (i 0))
      (declare (type (simple-array fixnum (1024)) lanes) (type fixnum i)
               (dynamic-extent lanes))
      (loop while (<= (+ i 4) sample)
            do (incf (aref lanes (aref data i)))
               (incf (aref lanes (+ 256 (aref data (+ i 1)))))
               (incf (aref lanes (+ 512 (aref data (+ i 2)))))
               (incf (aref lanes (+ 768 (aref data (+ i 3)))))
               (incf i 4))
      (loop while (< i sample) do (incf (aref lanes (aref data i))) (incf i))
      (dotimes (b 256)
        (let ((c (+ (aref lanes b) (aref lanes (+ 256 b))
                    (aref lanes (+ 512 b)) (aref lanes (+ 768 b)))))
          (declare (type fixnum c))
          (setf (aref seen b) c)
          (when (plusp c) (incf unique))
          (when (> c maxfreq) (setf maxfreq c)))))
    (and (> unique 230)
         (< maxfreq (/ sample 10))
         ;; A 2^21-bit hashed set: equal 4-byte keys collide exactly, and
         ;; the false-collision rate for 16K keys is ~64, below the
         ;; acceptance threshold.  Far cheaper than an EQL hash table.
         ;; (on the stack: a fresh 64 KiB heap vector per call was most of
         ;; this check on repetitive inputs; and the scan stops once the
         ;; answer is known)
         (let ((bits (make-array (ash 1 16) :element-type '(unsigned-byte 8)
                                 :initial-element 0))
               (duplicates 0)
               (limit (max 16 (/ sample 100))))
           (declare (type (simple-array (unsigned-byte 8) (65536)) bits)
                    (type fixnum duplicates) (dynamic-extent bits))
           (loop for i from 0 below (- sample 3) by 4 do
             (let* ((key (dict-key4 data i))
                    (h (logand (* key #x9E3779B1) #x7FFFF))
                    (byte (ash h -3))
                    (mask (ash 1 (logand h 7))))
               (declare (type fixnum key h byte mask))
               (if (logtest (aref bits byte) mask)
                   (when (>= (incf duplicates) limit) (return))
                   (setf (aref bits byte) (logior (aref bits byte) mask)))))
           (< duplicates limit)))))

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
          :insert-interior nil :fast-fragment t :one-pass t))
    ;; C's q1 (compress_fragment_two_pass) uses a 128K-entry table with a
    ;; 6-byte minimum match; with max-chain 2 the fragment dispatcher selects
    ;; table-bits 17 / min-match 6.  max-chain 1 gave q1 the same 15-bit/5-byte
    ;; table as q0, producing byte-identical output and a 5-13% ratio loss.
    (1 '(:max-chain 2 :lazy nil :use-dict nil :short-dist nil :skip-match t
          :insert-interior nil :fast-fragment t))
    ;; q2/q3: C's H2 / H3 with C's meta-block flushing (16 KiB input
    ;; blocks, flush at 0x2FFF literals + commands: WRITE-TRIVIAL-METABLOCKS)
    (2 '(:quick 2 :max-chain 3 :lazy nil :use-dict nil :short-dist t :skip-match t
          :insert-interior nil :trivial t :max-lit-bits 15 :mb-flush t
          :static-small t))
    (3 '(:quick 3 :max-chain 5 :lazy nil :use-dict nil :short-dist t :skip-match t
          :insert-interior nil :trivial t :max-lit-bits 15 :mb-flush t))
    ;; q4: C's H4 / H54 with BrotliBuildMetaBlockGreedy (literal, command
    ;; and distance block splitting, one literal context) and the full
    ;; StoreMetaBlock - the q5+ writer at quality 4
    (4 '(:quick 4 :max-chain 10 :lazy nil :use-dict nil :short-dist t :skip-match t
          :insert-interior nil :quality 4))
    ;; (Chain matcher, i.e. inputs under 64 KiB at q5-q9:) Score machinery
    ;; is enabled where its measured trade fits: q5/q6
    ;; (-14% speed for -1.5% size at q5, and q5 is the 10%-cap violator)
    ;; and q10/q11 (17-20x speed headroom, sizes 13-21% over C).  q7/q8/q9
    ;; run WITHOUT it: the score-accepted best-len stays below the greedy
    ;; max, which weakens probe-ok and blows up mlen scans (+26..137% with
    ;; long chains) — measured -25% speed for -1.2% size at q7, -25% for
    ;; -1.0% at q9 (json q9 even grew 477 B), outside the recorded 5-15%
    ;; envelope at levels whose sizes are already inside the cap.
    ;; See GAP-ANALYSIS for the full per-level table.
    ;; q5-q9: C's own matcher (H6, see DEFINE-H6-MATCHER; block bits q-1,
    ;; 4/4/10/10/16 cache candidates) - C's ratio (the chain matcher was
    ;; 1-6% larger at q7-q9) at C's speed or better (the assembly walk
    ;; prefetches the next ring).  The chain settings below remain the
    ;; matcher for inputs under 64 KiB.
    (5 '(:quick 5 :max-chain 6 :lazy t :use-dict nil :short-dist t :quality 5
          :score-p t :checks 4))
    ;; q6 was under-chained relative to C's bucket (block_bits 5 = 32
    ;; entries vs our 8): html q6 measured 1.121 vs C, the only cap
    ;; violation left.  16 mirrors C's q5/q6 effective search depth.
    ;; q6: C's H6 as well (assembly matcher on x86-64): faster than the
    ;; chain matcher there (libc 0.51 -> 0.76x of C) at C's ratio
    (6 '(:quick 6 :max-chain 16 :lazy t :use-dict nil :short-dist t :quality 6
          :score-p t :checks 4))
    ;; C parity: ChooseHasher picks H6 for lgwin>=19 + size>=1MiB with
    ;; num_last_distances_to_check = quality<7 ? 4 : quality<9 ? 10 : 16,
    ;; and selection by BackwardReferenceScore at every level >= 5 - so
    ;; q7-q9 run the score shape with the 10/10/16 cache candidates too
    ;; (they previously ran greedy with a single last-distance check).
    (7 '(:quick 7 :max-chain 16 :lazy t :use-dict nil :short-dist t :quality 7))
    (8 '(:quick 8 :max-chain 32 :lazy t :use-dict nil :short-dist t :quality 8))
    (9 '(:quick 9 :max-chain 48 :lazy t :use-dict nil :short-dist t :quality 9))
    (10 '(:max-chain 256 :lazy t :use-dict t :short-dist t :quality 10
           :score-p t :checks 16 :bt 16))
    (t '(:max-chain 512 :lazy t :use-dict t :short-dist t :quality 11
          :score-p t :checks 16 :bt 64))))

(defun %compress-bytes (data n params)
  "The COMPRESS selection (entropy candidates plus stored fallback),
returning fresh octets.  Shared by COMPRESS and COMPRESS-INTO."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum n)
           (type list params))
  (let ((*q2-static-codes* (getf params :static-small)))
    (%compress-bytes-1 data n params)))

(defun %compress-bytes-1 (data n params)
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
               (bt (getf params :bt nil))
               (one-pass (getf params :one-pass nil))
               (quick (getf params :quick nil))
               (mb-flush (getf params :mb-flush nil))
               ;; C consults the static dictionary at q10/11 regardless of
               ;; content (its probe is an array lookup); the old text-like
               ;; gate here cost binary 20%+ vs C at small sizes.  q<=9
               ;; pass :use-dict nil, so this only affects q10/11.
               (dict-ok (getf params :use-dict))
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
                                                :quality quality
                                                :bt bt
                                                :one-pass one-pass
                                                :quick quick
                                                :mb-flush mb-flush)
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
                                                :quality quality
                                                :bt bt
                                                :one-pass one-pass
                                                :quick quick
                                                :mb-flush mb-flush))))
          ;; Gate on the INPUT size: gating on the output size re-ran the
          ;; whole q10/q11 pipeline for the most compressible inputs (1 MiB
          ;; of zeros -> 13 bytes paid for two zopfli runs, a 2x cliff).
          (when (and dict-ok (< n 4096))
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
                                                :quality quality
                                                :bt bt
                                                :one-pass one-pass
                                                :quick quick
                                                :mb-flush mb-flush)))
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

(defun make-compressor ()
  "Return a reusable compressor: a function with COMPRESS's call shape
\(INPUT &key QUALITY) that keeps a private scratch pool for the big
encoder arrays across calls, so steady-state compression allocates
almost nothing and triggers no GC (plain COMPRESS re-allocates ~72
bytes per input byte on every call).

Thread safety - no locks, no implementation-specific threading code:
the pool is captured in the closure's lexical environment and bound to
the dynamic variable *SCRATCH-POOL* only for the duration of each call.
Dynamic bindings are thread-local in every Common Lisp, so each
compressor's pool is visible only to the thread currently inside that
closure, and two compressors share nothing at all.  Like a zlib stream
or BrotliEncoderState, a single compressor must not be driven by two
threads simultaneously: use one per thread (or per connection).
Separate compressors - and plain COMPRESS - are fully concurrent and
produce byte-identical output."
  (let ((pool (make-hash-table :test 'eql))
        (arena (make-arena)))
    (lambda (input &rest args)
      (let ((*scratch-pool* pool) (*arena* arena))
        (unwind-protect (apply #'compress input args)
          (arena-release arena))))))

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
