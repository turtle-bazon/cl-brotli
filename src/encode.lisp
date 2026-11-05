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

(defparameter +ins-code+ (first +ins-lc+))
(defparameter +ins-xval+ (second +ins-lc+))
(defparameter +ins-xbits+ (third +ins-lc+))
(defparameter +cpy-code+ (first +cpy-lc+))
(defparameter +cpy-xval+ (second +cpy-lc+))
(defparameter +cpy-xbits+ (third +cpy-lc+))
(declaim (type (simple-array fixnum (*))
               +ins-code+ +ins-xval+ +ins-xbits+
               +cpy-code+ +cpy-xval+ +cpy-xbits+))
(defparameter +ins-xbits-f+
  (let ((v (make-array (length +ins-xbits+) :element-type 'single-float
                                             :initial-element 0.0f0)))
    (dotimes (i (length +ins-xbits+) v)
      (setf (aref v i) (float (aref +ins-xbits+ i) 1.0f0))))
  "Insert-length extra bits as single-float for the hot DP loops.")
(defparameter +cpy-xbits-f+
  (let ((v (make-array (length +cpy-xbits+) :element-type 'single-float
                                             :initial-element 0.0f0)))
    (dotimes (i (length +cpy-xbits+) v)
      (setf (aref v i) (float (aref +cpy-xbits+ i) 1.0f0))))
  "Copy-length extra bits as single-float for the hot DP loops.")
(declaim (type (simple-array single-float (*)) +ins-xbits-f+ +cpy-xbits-f+))
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
      (loop for c from (1- (length base)) downto 0
            when (>= len (aref base c))
              do (return (values c (float (aref bits c) 1.0f0))))))
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
      (loop for c from (1- (length base)) downto 0
            when (>= len (aref base c))
              do (return (values c (- len (aref base c)) (aref bits c))))))

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

(declaim (inline cmd-symbol-dist0))
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

;; Flat dictionary index (counting-sort, like C's contiguous
;; dict_words): one packed fixnum per base word - (len << 10) |
;; word-index - in a single array, with bucket start offsets.  The old
;; cons-per-word hash buckets made every probe chase scattered cons
;; cells (~8% of html q10 in sb-sprof).
(declaim (type (or null (simple-array fixnum (*))) *dict-flat*)
         (type (or null (simple-array fixnum (65537))) *dict-bstart*)
         (type (or null sb-sys:system-area-pointer) *dict-sap*))
(defvar *dict-flat* nil)
(defvar *dict-bstart* nil)
;; SAP of the dictionary vector, set inside LZ77's pinned region (the
;; dictionary is loaded before the pin when use-dict, so the pointer is
;; stable for the whole match search).
(defvar *dict-sap* nil)

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
  "Ensure the flat dictionary index is built; returns the packed word
array.  Words are scattered in (len, idx) ascending order - the old
builder's push order - and each bucket range is read back reversed, so
first-match-wins picks stay identical to the cons-list version."
  (or *dict-flat*
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
          (setf *dict-flat* flat
                *dict-bstart* counts)
          flat))))

(defparameter +dict-transforms+
  (loop for tid from 0 below (length +transforms+)
        for tr = (aref +transforms+ tid)
        when (and (zerop (length (first tr)))
                  (member (second tr) '(:identity :upper-first :upper-all))
                  (zerop (length (third tr))))
          collect tid)
  "Dictionary transforms that preserve word length (identity and uppercase).")

(defparameter +dict-tid0+
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

#+(and sbcl x86-64 64-bit little-endian)
(defun %dict-match0-sap (data-sap dict-sap p off len)
  "Word-at-a-time identity compare of DATA[P..P+LEN) against
DICT[OFF..OFF+LEN) across the two pinned arrays; returns the first
mismatching byte position (LEN when they are equal).  Same TZCNT trick
as %MATCH-LEN-SAP, but across two different arrays."
  (declare (type sb-sys:system-area-pointer data-sap dict-sap)
           (type fixnum p off len)
           (optimize (speed 3) (safety 0)))
  (let ((i 0))
    (declare (type fixnum i))
    (loop while (<= (+ i 8) len) do
      (let ((x (logxor (sb-sys:sap-ref-64 data-sap (+ p i))
                       (sb-sys:sap-ref-64 dict-sap (+ off i)))))
        (declare (type (unsigned-byte 64) x))
        (unless (zerop x)
          (return-from %dict-match0-sap
            (+ i (ash (%trailing-zeros x) -3)))))
      (incf i 8))
    (loop while (and (< i len)
                     (= (sb-sys:sap-ref-8 data-sap (+ p i))
                        (sb-sys:sap-ref-8 dict-sap (+ off i))))
          do (incf i))
    i))

(defun dict-match-at (data p n min-len)
  "Longest dictionary word starting at DATA[P] with length >= MIN-CLOP,
as \(values length index transform-id).  Only length-preserving transforms
are considered so command copy lengths remain the base-word lengths."
  (declare (type fixnum p n min-len))
  (let* ((bucket (dict-bucket (dict-key4 data p)))
         (flat (dict-index))
         (starts *dict-bstart*)
         (best-len 0) (best-idx nil) (best-tid 0)
         (dict (load-dict)))
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
                 (let ((off (+ (aref +doffset+ len) (* idx len))))
                   (dolist (tk +dict-transform-kinds+)
                     (when (%dict-word-match-p data p dict off len (cdr tk))
                       (setf best-len len best-idx idx best-tid (car tk))
                       (return)))))))
    (values best-len best-idx best-tid)))

(defun dict-matches-at (sap data p n min-len dist-base dists)
  "C BrotliFindAllStaticDictionaryMatches (length-preserving transforms
only): for every dictionary word of length LEN in [MIN-LEN, 24] that
matches DATA[P..), set DISTS[LEN] to its backward distance and return the
number of lengths filled.  DIST-BASE = min(window, position), so every
distance lands just above the decoder's max-distance and is therefore read
as a dictionary reference."
  (declare (type sb-sys:system-area-pointer sap)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum p n min-len)
           (type (integer 0 #x1FFFFFF) dist-base)
           (type (simple-array fixnum (25)) dists)
           (optimize (speed 3) (safety 0)))
  (let* ((key (if (and sap (<= (+ p 4) n))
                  (sb-sys:sap-ref-32 sap p)
                  (dict-key4 data p)))
         (bucket (dict-bucket key))
         (flat (dict-index))
         (starts *dict-bstart*)
         (dsap *dict-sap*)
         (dict (load-dict))
         (count 0))
    (declare (type (simple-array fixnum (*)) flat)
             (type (simple-array fixnum (65537)) starts)
             (type (or null sb-sys:system-area-pointer) dsap)
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
                   (zerop (aref dists len)))
          (let ((off (+ (aref +doffset+ len) (* idx len)))
                (skip1 nil))
            (declare (type boolean skip1))
            ;; KIND 0 (identity): word-at-a-time compare across the two
            ;; pinned arrays - it covers the common exact-match case and
            ;; yields the failure position for the kind-1 skip.
            (let ((fpos (if (and dsap
                                 #+(and sbcl x86-64 64-bit little-endian) t)
                            (%dict-match0-sap sap dsap p off len)
                            (nth-value 1
                                       (%dict-word-match-p data p dict
                                                            off len 0)))))
              (declare (type fixnum fpos))
              (cond
                ((>= fpos len)
                 (setf (aref dists len)
                       (+ dist-base 1 idx
                          (* (the (integer 0 127) +dict-tid0+)
                             (the (integer 0 2048) (nwords len)))))
                 (incf count))
                (t
                 ;; KIND 1 (upper-first) only changes the first UTF-8
                 ;; character: if identity failed at or beyond that
                 ;; character's width, KIND 1 fails at the same byte.
                 (when (>= fpos (let ((c (aref dict off)))
                                  (if (< c 192) 1
                                      (if (< c 224) 2 3))))
                   (setf skip1 t))
                 (dolist (tk +dict-transform-kinds+)
                   (let ((kd (cdr tk)))
                     (declare (type fixnum kd))
                     (when (and (/= kd 0)
                                (not (and skip1 (= kd 1))))
                       (when (%dict-word-match-p data p dict off len kd)
                         (setf (aref dists len)
                               (+ dist-base 1 idx
                                  (* (the (integer 0 127) (car tk))
                                     (the (integer 0 2048) (nwords len)))))
                         (incf count)
                         (return))))))))))))
        count))

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


(defparameter +zdc-jo+
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
    (loop for i of-type fixnum from 1 below len do
      (let ((a offset) (b (logand (1+ offset) 7)))
        (declare (type fixnum a b))
        (when (> (aref cd-a a) (aref cd-a b))
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
       (if (and (<= (+ start 2) end)
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
       (if (and (<= (+ start 3) end)
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

(defparameter +fast-log2-table+
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
         (c1 0) (c2 0)
         (mostly nil)
         (max-utf8 0))
    (declare (type fixnum len c1 c2 max-utf8) (type boolean mostly))
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
                    (cost (+ (- liw (fast-log2 h))
                             0.029d0)))
               (declare (type double-float cost))
               (when (< cost 1.0d0)
                 (setf cost (+ (* 0.5d0 cost) 0.5d0)))
               (setf (aref costs (1+ i)) (float cost 1.0f0)))))))
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
                    (cost (+ (- liw (fast-log2 h))
                             0.029d0)))
               (declare (type double-float cost))
               (when (< cost 1.0d0)
                 (setf cost (+ (* 0.5d0 cost) 0.5d0)))
               (when (< i 2000)
                 (incf cost (+ 0.35d0 (* 0.000175d0 i))))
               (setf (aref costs (1+ i)) (float cost 1.0f0)))))))
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
                    (cost (+ (- (fast-log2 (aref in-u upos))
                                (fast-log2 h))
                             0.029d0)))
               (declare (type fixnum upos) (type double-float cost))
               (when (< cost 1.0d0)
                 (setf cost (+ (* 0.5d0 cost) 0.5d0)))
               (when (< i 2000)
                 (incf cost (+ 0.35d0 (* 0.000175d0 i))))
               (setf (aref costs (1+ i)) (float cost 1.0f0))))))))
    costs))

(defun zopfli-analytic-model (data n)
  "C ZopfliCostModelSetFromLiteralCosts: estimated literal costs as a
prefix sum + analytic command/distance costs (log2(11+i)/log2(20+i))."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum n) (optimize (speed 3) (safety 0)))
  (let* ((prefix (make-array (+ n 2) :element-type 'single-float
                                     :initial-element 0.0f0))
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
    (dotimes (i n)
      (let ((r (aref prefix (1+ i))))
        (declare (type single-float r))
        (setf (aref prefix (1+ i)) (+ (aref prefix i) r))))
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
  (let ((hl (make-array 256 :element-type 'fixnum :initial-element 0))
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
          (multiple-value-bind (icode ixv ixb)
              (length-code ins +ins-code+ +ins-xval+ +ins-xbits+
                               +ins-base+ +ins-bits+)
            (declare (ignore ixv ixb))
            (multiple-value-bind (ccode cxv cxb)
                (length-code cpy +cpy-code+ +cpy-xval+ +cpy-xbits+
                                 +cpy-base+ +cpy-bits+)
              (declare (ignore cxv cxb))
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
    ;; Literal costs: plain prefix of cost_literal[data[i]] (C's carry
    ;; dance resets every iteration, i.e. reduces to this).
    (let ((prefix (zmodel-lit-prefix model)))
      (declare (type (simple-array single-float (*)) prefix))
      (setf (aref prefix 0) 0.0f0)
      (dotimes (i n)
        (setf (aref prefix (1+ i))
              (+ (aref prefix i) (aref ct (aref data i))))))
    model))

(defun %lz77 (data sap window use-dict dict-limit base-pos max-chain lazy
              skip-match insert-interior &optional (score-p nil) (checks 1)
              (bt nil))
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
  (let* ((n (length data)) (min-match 4)
         ;; Zopfli DP node arrays are whole-input sized (~52 bytes/byte of
         ;; input): cap BT/DP activation so 16 MiB chunks fall back to the
         ;; score path (C runs the DP per ~128 KiB metablock; per-chunk DP
         ;; partitioning is future work).
         (bt (if (and bt (<= n #.(ash 1 23))) bt nil)))
    (if (< n min-match)
        (if (zerop n) '() (list (list n 0 0 0 nil)))
        (let* ((hbits 17) (hmask (1- (ash 1 hbits)))
               (chained (and (not bt) (> max-chain 1)))
               ;; H10 binary-tree matcher (q10/11, C hash_to_binary_tree):
               ;; 17-bit buckets, two forest slots per position, insertion
               ;; watermark (positions below BT-NEXT are already stored),
               ;; 128-entry match scratch.  BT is the short-back scan size.
               (bt-short (if (integerp bt) bt 16))
               (bt-buckets (and bt (make-array 131072
                                 :element-type '(unsigned-byte 32)
                                 :initial-element #xFFFFFFFF)))
               ;; No initial fill: like C (Prepare clears buckets only),
               ;; every forest read is preceded by a write - the bucket
               ;; root and every chained prev were written on all of
               ;; their insert's exit paths, and the current node's slots
               ;; are only ever written (termination, >=comp, or branch).
               ;; Saves an 8 MB memset per compress.
               (bt-forest (and bt (make-array (* 2 (+ n 8))
                                 :element-type '(unsigned-byte 32))))
               (bt-next 0) (bt-cnt 0) (bt-cpos -1) (bt-cbest 0)
               (bt-md (and bt (make-array 128 :element-type 'fixnum)))
               (bt-ml (and bt (make-array 128 :element-type 'fixnum)))
               ;; Zopfli DP state (only when BT is active)
               (zmodel (and bt (zopfli-analytic-model data n)))
               ;; 64 cells of padding beyond N: ComputeMinimumCopyLength's
               ;; scan then needs no num_bytes bound check - the +infinity
               ;; padding stops it at exactly the length C's bound would
               ;; (nodes[N+1..] are never real nodes for the other users,
               ;; which all stay <= N).
               (zcostf (and bt (make-array (+ n 64)
                                :element-type 'single-float)))
               ;; No :initial-element on the big arrays: z-iterate FILLs
               ;; them before any read (the initial-element form consed a
               ;; second full-array fill per compress).
               (zlen (and bt (make-array (1+ n) :element-type 'fixnum)))
               (zdist (and bt (make-array (1+ n) :element-type 'fixnum)))
               (zins (and bt (make-array (1+ n) :element-type 'fixnum)))
               (zsc (and bt (make-array (1+ n) :element-type 'fixnum)))
               (znext (and bt (make-array (1+ n) :element-type 'fixnum)))
               (zq (and bt (make-zpq)))
               (z-sdc #(4 11 15 16))
               (z-dc (make-array 4 :element-type 'fixnum))
               (z-dmatch (and bt (make-array 25 :element-type 'fixnum)))
               ;; HQ (q11) pre-collected match storage: one packed entry per
               ;; match, (dist << 25) | (dict-flag << 24) | len.
               (z-nm (and bt (>= bt 64)
                          (make-array (1+ n) :element-type 'fixnum
                                             :initial-element 0)))
               ;; C allocates 4 * num_bytes matches; we clamp at the same
               ;; (4 * n) capacity (measured corpora peak at 3.77/byte).
               (z-flat (and bt (>= bt 64)
                            (make-array (* 4 n) :element-type 'fixnum)))
               (z-cands (if (and bt (>= bt 64)) 2 1))
               (z-maxlen (if (and bt (>= bt 64)) 325 150))
               ;; Loop invariants for the DP l-loops, bound once: the
               ;; table length was re-read (symbol + array header) and
               ;; cmd-symbol re-multiplied (icode * 24) on every one of
               ;; the 25-50M length iterations per MiB.
               (cpy-n (length +cpy-code+))
               (ins-n (length +ins-code+))
               (cmd-tab +cmd-symbol-table+)
               (head (make-array (ash 1 hbits)
                                 :element-type '(unsigned-byte 32)
                                 :initial-element #xFFFFFFFF))
               ;; Every entry read from PREV was written when that position
               ;; was inserted, so no initial fill is needed.
               (prev (and chained
                          (make-array n :element-type '(unsigned-byte 32))))
               (cmds '()) (lit-start 0) (p 0) (last (- n min-match))
               (skip 32) (dict-used 0) (last-dist 0)
               ;; NIL dict-limit means "no limit": folding it into one
               ;; fixnum local keeps every gate a fixnum compare (the
               ;; (OR NULL FIXNUM) parameter made SBCL emit GENERIC-<
               ;; at all three probe gates).
               (dlim (the fixnum (or dict-limit most-positive-fixnum)))
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
                   (type (or null (simple-array (unsigned-byte 32) (*)))
                         bt-buckets bt-forest)
                   (type (or null (simple-array fixnum (128))) bt-md bt-ml)
                   (type fixnum bt-short bt-next bt-cnt bt-cpos bt-cbest)
                   ;; Plain (non-null) types: the z-state is only ever
                   ;; touched from the z-labels, which run iff BT is active;
                   ;; the (or null ...) form forced a hairy type check on
                   ;; every aref.
                   (type zmodel zmodel)
                   (type (simple-array single-float (*)) zcostf)
                   (type (simple-array fixnum (*))
                         zlen zdist zins zsc znext)
                   (type (simple-array fixnum (25)) z-dmatch)
                   (type (simple-array fixnum (*)) z-nm z-flat)
                   (type zpq zq)
                   (type (simple-array fixnum (4)) z-dc)
                   (type fixnum z-cands z-maxlen)
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
                   #+(and sbcl x86-64 64-bit little-endian)
                   (mlen2 (a b e) (%match-len-sap sap a b e))
                   #-(and sbcl x86-64 64-bit little-endian)
                   (mlen2 (a b e) (%match-len data a b e))
                   (ins (q h)
                     (declare (type fixnum q h))
                     (if bt
                         (when (>= q bt-next)
                           (bt-do q nil))
                         (let ((old (aref head h)))
                           (declare (type fixnum old))
                           (setf (aref head h) q)
                           (when chained (setf (aref prev q) old)))))
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
                   (bt-hash (i)
                     "C H10 HashBytes: the low 32 bits of load32(I) *
kHashMul32 shifted down by 15 (17-bit bucket)."
                     (declare (type fixnum i))
                     #+(and sbcl x86-64 64-bit little-endian)
                     (let ((w (if (and sap (<= (+ i 4) n))
                                  (sb-sys:sap-ref-32 sap i)
                                  (logior (aref data i)
                                          (ash (aref data (1+ i)) 8)
                                          (ash (aref data (+ i 2)) 16)
                                          (ash (aref data (+ i 3)) 24)))))
                       (declare (type (unsigned-byte 32) w))
                       (logand (ash (logand (* w #x1E35A7BD) #xFFFFFFFF) -15)
                               #x1FFFF))
                     #-(and sbcl x86-64 64-bit little-endian)
                     (let ((w (logior (aref data i)
                                      (ash (aref data (1+ i)) 8)
                                      (ash (aref data (+ i 2)) 16)
                                      (ash (aref data (+ i 3)) 24))))
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
                                 (let ((score (- (+ 1935 (* 135 ml))
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
                              (loop for i of-type fixnum
                                      from (1- pos) downto (1+ stop)
                                    while (<= best 2) do
                                (when (> (- pos i) window) (return))
                                (when (and (= (aref data pos) (aref data i))
                                           (= (aref data (1+ pos))
                                              (aref data (1+ i))))
                                  (let ((len (mlen i pos)))
                                    (declare (type fixnum len))
                                    (when (> len best)
                                      (setf best len)
                                      (setf (aref bt-md cnt) (- pos i)
                                            (aref bt-ml cnt) len)
                                      (incf cnt)))))))
                          (when (< best max-len)
                            (let* ((comp (min max-len 128))
                                   (reroot (>= max-len 128))
                                   (key (bt-hash pos))
                                   (prev (aref bt-buckets key))
                                   (node-left (* 2 pos))
                                   (node-right (1+ node-left))
                                   (bl-left 0) (bl-right 0)
                                   (depth 64))
                              (declare (type fixnum comp key prev node-left
                                             node-right bl-left bl-right depth)
                                       (type boolean reroot))
                              (when reroot (setf (aref bt-buckets key) pos))
                              (loop
                                (let ((backward (- pos prev)))
                                  (declare (type fixnum backward))
                                  ;; BACKWARD <= 0 covers PREV = sentinel
                                  ;; (#xFFFFFFFF) and PREV = POS.
                                  (when (or (<= backward 0)
                                            (> backward window)
                                            (<= depth 0))
                                    (when reroot
                                      (setf (aref bt-forest node-left)
                                            #xFFFFFFFF
                                            (aref bt-forest node-right)
                                            #xFFFFFFFF))
                                    (return)))
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
                                                      (+ pos max-len)))))
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
                             (let ((score (+ 1920 (* 135 ml)
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
                         (let ((clen (logand (aref zlen p) #xFFFFFF)))
                           (declare (type fixnum clen))
                           (if (= clen 1)
                               ;; stub: C's initialized distance is 0 and
                               ;; its shortcut chain steps to p - 1.
                               (progn
                                 (setf (aref z-dc idx) 0)
                                 (incf idx)
                                 (setf p (aref zsc (1- p))))
                               (let ((ins (logand (aref zins p) #x7FFFFFF)))
                                 (declare (type fixnum ins))
                                 (setf (aref z-dc idx) (aref zdist p))
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
                       (setf (aref zlen q) (logior len (ash dictp 24))
                             (aref zdist q) dist
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
                                 (length-code-f (- pos start) +ins-code+ ins-n
                                              +ins-xbits-f+ +ins-base+ +ins-bits+)
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
                                       (left (aref data (+ pos (1- min-len)))))
                                   (declare (type fixnum best j dc0 pb)
                                            (type (unsigned-byte 8) left))
                                   (loop while (and (< j 16) (< best max-len))
                                         do
                                     (let* ((jo (aref +zdc-jo+ j))
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
                                                     (length-code-f l +cpy-code+ cpy-n +cpy-xbits-f+
                                                                    +cpy-base+
                                                                    +cpy-bits+)
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
                                                             (zerop (aref z-dmatch dl)))
                                                  do (incf dl))
                                            (when (> dl 24)
                                              (return))
                                            (setf dist (aref z-dmatch dl)
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
                                                   (length-code-f len +cpy-code+ cpy-n +cpy-xbits-f+
                                                                  +cpy-base+
                                                                  +cpy-bits+)
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
                     ;; No fill for zdist/zins/zsc/znext: an
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
                                 (let ((mi 0) (dfilled nil))
                                   (declare (type fixnum mi)
                                            (type boolean dfilled))
                                   (loop for k of-type fixnum below cnt do
                                     (let ((e (aref z-flat (+ off k))))
                                       (declare (type fixnum e))
                                       (if (logbitp 24 e)
                                           (progn
                                             ;; clear stale lengths once,
                                             ;; at the first dict entry
                                             (unless dfilled
                                               (fill z-dmatch 0)
                                               (setf dfilled t))
                                             (setf (aref z-dmatch
                                                         (logand e #xFFFFFF))
                                                   (ash e -25)
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
                                   (fill z-dmatch 0)
                                   (dict-matches-at sap data i n
                                                    (max 4 (1+
                                                            (if (plusp cnt)
                                                                bt-cbest 0)))
                                                    (min window (+ base-pos i))
                                                    z-dmatch)
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
                               (decf skip)
                               (loop while (plusp skip) do
                                 (incf i)
                                 (when (>= (+ i 3) n) (return))
                                 (z-eval i)
                                 ;; HQ: the skipped positions were recorded
                                 ;; by the pre-pass; step the flat cursor
                                 ;; past their entries.
                                 (when hq (incf off (aref z-nm i)))
                                 (decf skip)))
                             (incf i)))))
                     ;; C ComputeShortestPathFromNodes -> backward links
                     (let ((index n))
                       (declare (type fixnum index))
                       ;; Unwritten <=> ZLEN = 1 (fills are gone; written
                       ;; copy lengths are >= 2), so the zins half of C's
                       ;; stub test is redundant.
                       (loop while (= (aref zlen index) 1)
                             do (decf index))
                       (setf (aref znext index) -1)
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
                       (loop while (/= off -1) do
                         (let* ((q (+ pos off))
                                (zv (aref zlen q))
                                (cpy (logand zv #xFFFFFF))
                                (ins (logand (aref zins q) #x7FFFFFF))
                                (dist (aref zdist q))
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
                               (fill z-dmatch 0)
                               (dict-matches-at sap data i n
                                                (max 4 (1+ bt-cbest))
                                                (min window (+ base-pos i))
                                                z-dmatch)
                               (loop for l of-type fixnum from 4 to 24 do
                                 (let ((d (aref z-dmatch l)))
                                   (declare (type fixnum d))
                                   (when (plusp d) (record d l 1)))))
                             (loop for k of-type fixnum below cnt do
                               (record (aref bt-md k) (aref bt-ml k) 0))
                             (if longp
                                 (let ((mlen (aref bt-ml 0)))
                                   (declare (type fixnum mlen))
                                   ;; StoreRangeH10(pos+1,
                                   ;; min(pos+mlen, store_end))
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
                                         (incf ii))))
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
                                            (- range-end (ash best-dist 2)))))
                               (loop for q from range-start below range-end
                                     do (if bt (bt-do q nil)
                                            (ins q (hash q))))))
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
                             z-shortcut z-eval z-cache))
            (if bt
                (if (>= bt 64)
                    (z-iterate-hq)
                    (z-iterate nil))
                (progn
                  (loop while (<= p last) do
              (let* ((ph (hash p)))
                (multiple-value-bind (best-len best-dist best-score)
                    (cond (bt (if score-p (bt-score p) (bt-longest p)))
                          (score-p (find-match-score p ph))
                          (t (find-match p ph)))

                  (declare (type fixnum best-len best-dist best-score))
                  (let ((dict-p nil))
                    (when (and use-dict
                               (< dict-used dlim))
                      (multiple-value-bind (dict-len dict-idx dict-tid)
                          ;; min-len = best-len + 1 reproduces the outer
                          ;; (> dict-len best-len) guard while pruning the
                          ;; candidate scan (C: minlen = max(4, best_len+1)).
                          (dict-match-at data p n (1+ best-len))
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
                            (push (list (- p lit-start) lit-start dict-len dist t)
                                  cmds)
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
                    (push (list (- n lit-start) lit-start 0 0 nil) cmds))
                  (nreverse cmds))))))))

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
(defun %sample-lit-histogram (data n)
  "C BuildAndStoreLiteralPrefixCode's histogram over the RAW input (one-pass
builds the literal tree before LZ77 runs, so C approximates the literal
stream): exact below 32 KiB with C's weight-3 adjustment of the first 11
samples, stride-29 sampling plus one-count smoothing above."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum n)
           (optimize (speed 3) (safety 0)))
  (let ((f (make-array 256 :element-type 'fixnum :initial-element 0)))
    (declare (type (simple-array fixnum (256)) f))
    (if (< n #x8000)
        (progn
          (dotimes (i n)
            (declare (type fixnum i))
            (incf (aref f (aref data i))))
          (dotimes (i 256)
            (declare (type fixnum i))
            (incf (aref f i) (* 2 (min (aref f i) 11)))))
        (progn
          (loop for i of-type fixnum from 0 below n by 29
                do (incf (aref f (aref data i))))
          (dotimes (i 256)
            (declare (type fixnum i))
            (incf (aref f i) (+ 1 (* 2 (min (aref f i) 11)))))))
    f))

(defun %lz77-fragment (data sap window table-bits &optional w)
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
         (litf (if w (%sample-lit-histogram data n)
                      (make-array 256 :element-type 'fixnum
                                     :initial-element 0)))
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
    (declare (type fixnum k min-match p lit-start limit last-dist back nc shift)
             (type (simple-array (unsigned-byte 32) (*)) table cv)
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
    ;; One-pass mode (C BrotliCompressFragmentFast): trees come from what C
    ;; fixes up front - the sampled RAW-INPUT literal histogram (maxbits 8,
    ;; like C's BuildAndStoreHuffmanTreeFast) and the fixed seed command and
    ;; distance codes - and the header is written before the scan; the scan
    ;; then emits directly into W.  Two-pass mode leaves all of it untouched.
    (when w
      (setf lit-1p (build-etree litf 256 15)
            cmd-1p (fast-cmd-etree (build-etree cmdf 64 15))
            dist-1p (build-etree distf 64 14))
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
      (write-etree w cmd-1p 704)
      (write-etree w dist-1p 64))
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
             (mlen (a b) (%match-len-sap sap a b n))
             (emit-one (insert lit-start cpy dist last-dist)
               "Write one fast-path command into W (C's one-pass emit) and
return the updated last-distance.  Mirrors WRITE-FAST-BLOCK-BODY's
decisions; used only when W is non-nil."
               (declare (type fixnum insert lit-start cpy dist last-dist)
                        (optimize (speed 3) (safety 0)))
               (let ((cost (+ 32 (* 2 insert))))
                 (declare (type fixnum cost))
                 (when (> cost slack)
                   (setf slack 65536)
                   (b:w-ensure w (+ slack cost)))
                 (decf slack cost))
               (flet ((cmd-bits (cc)
                        (unless cmd-1p-single
                          (b:%wbits-raw-pm w (aref cmd-rc-1p (aref +q0-cmd-map+ cc))
                                           (aref cmd-ln-1p (aref +q0-cmd-map+ cc)))))
                      (dist0-bits ()
                        (unless dist-1p-single
                          (b:%wbits-raw w (aref dist-rc-1p 0)
                                        (aref dist-ln-1p 0))))
                      (lits ()
                        (unless lit-1p-single
                          (if (>= insert 8)
                              (b:w-emit-run w data lit-start (+ lit-start insert)
                                            lit-rc-1p lit-ln-1p)
                              (loop for i of-type fixnum
                                      from lit-start below (+ lit-start insert)
                                    do (let ((sym (aref data i)))
                                         (b:%wbits-raw-pm
                                          w (aref lit-rc-1p sym)
                                          (aref lit-ln-1p sym))))))))
                 (cond
                   ((and (plusp insert) (plusp cpy))
                    (multiple-value-bind (cc e nb) (q0-insert-len insert)
                      (cmd-bits cc)
                      (when (plusp nb) (b:%wbits-raw w e nb)))
                    (lits)
                    (if (= dist last-dist)
                        (dist0-bits)
                        (progn
                          (multiple-value-bind (cc e nb) (q0-distance dist)
                            (unless dist-1p-single
                              (b:%wbits-raw w (aref dist-rc-1p (- cc 64))
                                            (aref dist-ln-1p (- cc 64)))
                              (when (plusp nb) (b:%wbits-raw w e nb))))
                          (setf last-dist dist)))
                    (multiple-value-bind (cc e nb) (q0-copy-last-len cpy)
                      (cmd-bits cc)
                      (when (plusp nb) (b:%wbits-raw w e nb))
                      (when (>= (aref +q0-cmd-map+ cc) 128)
                        (dist0-bits))))
                   ((plusp cpy)
                    (multiple-value-bind (cc e nb) (q0-copy-len cpy)
                      (cmd-bits cc)
                      (when (plusp nb) (b:%wbits-raw w e nb)))
                    (lits)
                    (multiple-value-bind (cc e nb) (q0-distance dist)
                      (unless dist-1p-single
                        (b:%wbits-raw w (aref dist-rc-1p (- cc 64))
                                      (aref dist-ln-1p (- cc 64)))
                        (when (plusp nb) (b:%wbits-raw w e nb))))
                    (setf last-dist dist))
                   (t
                    (multiple-value-bind (cc e nb) (q0-insert-len insert)
                      (cmd-bits cc)
                      (when (plusp nb) (b:%wbits-raw w e nb)))
                    (lits))))
               last-dist)
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
                  (if w
                      (setf last-dist
                            (emit-one insert lit-start matched distance last-dist))
                      (progn
                        (push-cmd insert lit-start matched distance)
                        (setf last-dist
                              (note-fast-command data litf cmdf distf last-dist
                                                 insert lit-start matched
                                                 distance))))
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
                          (if w
                              (setf last-dist
                                    (emit-one 0 p matched distance last-dist))
                              (progn
                                (push-cmd 0 p matched distance)
                                (setf last-dist
                                      (note-fast-command data litf cmdf distf
                                         last-dist 0 p matched distance))))
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
          (if w
              (setf last-dist (emit-one insert lit-start 0 0 last-dist))
              (progn
                (push-cmd insert lit-start 0 0)
                (setf last-dist
                      (note-fast-command data litf cmdf distf last-dist
                                         insert lit-start 0 0))))))
      (values cv nc litf cmdf distf))))

(defun lz77 (data window &key (use-dict (text-like-data-p data)) dict-limit
                              (base-pos 0) (max-chain 128) (lazy t)
                              (skip-match nil) (insert-interior t)
                              (score-p nil) (checks 1) (one-pass nil)
                              (bt nil))
  "Return commands (insert-len lit-start copy-len distance dict-p); copy-len 0
marks a trailing insert-only command.  BASE-POS is the number of bytes already
produced before DATA; it is needed to encode dictionary distances correctly
when DATA is one chunk of a multi-meta-block stream.  MAX-CHAIN and LAZY trade
compression ratio for encoder throughput."
  #+sbcl
  (sb-sys:with-pinned-objects (data (if use-dict (load-dict) data))
    ;; Stable SAP for the word-at-a-time dictionary compare; refreshed
    ;; on every call (and cleared for dictionary-less runs).
    (setf *dict-sap*
          (and use-dict (sb-sys:vector-sap (load-dict))))
    #+(and sbcl x86-64 64-bit little-endian)
    (if (and skip-match (not lazy) (not use-dict) (<= max-chain 2))
        (%lz77-fragment data (sb-sys:vector-sap data) window
                        (if (<= max-chain 1) 15 17) one-pass)
        (%lz77 data (sb-sys:vector-sap data) window use-dict dict-limit
               base-pos max-chain lazy skip-match insert-interior
               score-p checks bt)))
  #-sbcl
  (%lz77 data nil window use-dict dict-limit base-pos max-chain lazy
         skip-match insert-interior score-p checks bt))

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
            (length-code ins +ins-code+ +ins-xval+ +ins-xbits+ +ins-base+ +ins-bits+)
          (declare (ignore ixv ixb))
          (multiple-value-bind (ccode cxv cxb)
              (if (plusp cpy)
                  (length-code cpy +cpy-code+ +cpy-xval+ +cpy-xbits+ +cpy-base+ +cpy-bits+)
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
              (length-code ins +ins-code+ +ins-xval+ +ins-xbits+ +ins-base+ +ins-bits+)
            (multiple-value-bind (ccode cxv cxb)
                (if (plusp cpy)
                    (length-code cpy +cpy-code+ +cpy-xval+ +cpy-xbits+ +cpy-base+ +cpy-bits+)
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
            (length-code ins +ins-code+ +ins-xval+ +ins-xbits+ +ins-base+ +ins-bits+)
          (declare (type fixnum icode ixv ixb))
          (let ((copyp (plusp cpy)))
            (multiple-value-bind (ccode cxv cxb)
                (if copyp
                    (length-code cpy +cpy-code+ +cpy-xval+ +cpy-xbits+ +cpy-base+ +cpy-bits+)
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
  (let* ((max-blocks (max 1 (1+ (floor n min-block))))
         (max-types (min max-blocks 257))
         (types (make-array max-blocks :element-type '(unsigned-byte 8)
                                     :initial-element 0))
         (lengths (make-array max-blocks :element-type 'fixnum
                                        :initial-element 0))
         ;; one spare histogram beyond MAX-TYPES (C's "one more" comment)
         (histos (let ((v (make-array (1+ max-types))))
                   (dotimes (i (1+ max-types) v)
                     (setf (aref v i)
                           (make-array alphabet :element-type 'fixnum
                                                :initial-element 0)))))
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
                 (declare (type (simple-array fixnum (*)) h))
                 (dotimes (j alphabet)
                   (declare (type fixnum j))
                   (setf (aref h j) 0))))
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
                            (src (aref histos (if (zerop j) last-ix0
                                                  last-ix1)))
                            (cur (aref histos curr-ix)))
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
                       (replace (aref histos last-ix0) scratch1)
                       (setf last-ent1 last-ent0
                             last-ent0 ce1)
                       (incf nblocks)
                       (setf bsize 0)
                       (clear-histo curr-ix)
                       (setf merge-count 0 target min-block))
                      (t
                       ;; merge with the last block
                       (incf (aref lengths (1- nblocks)) bsize)
                       (replace (aref histos last-ix0) scratch0)
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
               (incf (aref (aref histos curr-ix) sym))
               (incf bsize)
               (when (= bsize target)
                 (finish nil))))
      (declare (inline clear-histo entropy))
      (dotimes (i n)
        (declare (type fixnum i))
        (add (aref syms i)))
      (finish t))
    (values types lengths nblocks ntypes)))

(defun write-blk-header (w first-len type-tree tsize len-tree)
  "The optional block-type/length prefix codes + first count - the inverse
of the decoder's READ-BLK-HEADER - for a category with >= 2 block types."
  (declare (type b:bwr w) (type fixnum first-len tsize))
  (write-etree w type-tree tsize)
  (write-etree w len-tree 26)
  (write-blen w len-tree first-len))

(defun write-compressed-block-body (w data base-pos window use-dict dict-limit rb
                                    &key (max-chain 128) (lazy t) (short-dist t)
                                      (skip-match nil) (insert-interior t)
                                      (score-p nil) (checks 1)
                                      (quality 5)
                                      (bt nil)
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
  (multiple-value-bind (recs ncmd litf cmdf distf lit-k lit-cmap)
        (plan-commands
         data
         (or cmds
             (lz77 data window :use-dict use-dict :dict-limit dict-limit
                            :base-pos base-pos :max-chain max-chain :lazy lazy
                            :skip-match skip-match
                            :insert-interior insert-interior
                            :score-p score-p :checks checks :bt bt))
         rb :short-dist short-dist :quality quality)
    (declare (type (simple-array fixnum (*)) recs litf cmdf distf)
             (type fixnum ncmd lit-k)
             (type (or null simple-vector) lit-cmap)
             (ignorable cmdf distf))
    ;; ---- splitter inputs: command symbols and distance symbols ----------
    (let* ((cmd-syms (make-array ncmd :element-type '(unsigned-byte 16)))
           (nd (loop for k of-type fixnum below ncmd
                     count (>= (aref recs (+ (* k +cmd-stride+) 7)) 0)))
           (dist-syms (make-array nd :element-type '(unsigned-byte 16))))
      (declare (type fixnum nd))
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
      (multiple-value-bind (itypes ilens niblocks nitypes)
          (split-block cmd-syms ncmd 704 1024 500.0d0)
        (declare (type fixnum niblocks nitypes))
        (multiple-value-bind (dtypes dlens ndblocks ndtypes)
            (split-block dist-syms nd 64 512 100.0d0)
          (declare (type fixnum ndblocks ndtypes))
          ;; ---- per-type histograms, trees, switch trees ----------------
          (let* ((cmd-histo (make-array (* nitypes 704)
                                        :element-type 'fixnum
                                        :initial-element 0))
                 (dist-histo (make-array (* ndtypes 64)
                                         :element-type 'fixnum
                                         :initial-element 0)))
            (declare (type (simple-array fixnum (*)) cmd-histo dist-histo))
            ;; tally per block type
            (let ((k0 0))
              (declare (type fixnum k0))
              (dotimes (bi niblocks)
                (declare (type fixnum bi))
                (let ((tt (aref itypes bi)) (ln (aref ilens bi)))
                  (declare (type fixnum tt ln))
                  (loop for k of-type fixnum from k0 below (min ncmd (+ k0 ln))
                        do (incf (aref cmd-histo
                                       (+ (* tt 704)
                                          (aref recs (+ (* k +cmd-stride+) 2))))))
                  (incf k0 ln))))
            (let ((j0 0))
              (declare (type fixnum j0))
              (dotimes (bi ndblocks)
                (declare (type fixnum bi))
                (let ((tt (aref dtypes bi)) (ln (aref dlens bi)))
                  (declare (type fixnum tt ln))
                  (loop for j of-type fixnum from j0 below (min nd (+ j0 ln))
                        do (incf (aref dist-histo (+ (* tt 64) (aref dist-syms j)))))
                  (incf j0 ln))))
            (let* ((cmd-ets (let ((v (make-array nitypes)))
                            (dotimes (t0 nitypes v)
                              (declare (type fixnum t0))
                              (setf (aref v t0)
                                    (build-etree (histo-slice cmd-histo t0 704)
                                                 704 15)))))
                 (dist-ets (let ((v (make-array ndtypes)))
                             (dotimes (t0 ndtypes v)
                               (declare (type fixnum t0))
                               (setf (aref v t0)
                                     (build-etree (histo-slice dist-histo t0 64)
                                                  64 15)))))
                 (lit (when (= lit-k 1) (build-etree litf 256 15)))
                 (lits (when (>= lit-k 2)
                         (let ((v (make-array lit-k)))
                           (dotimes (k lit-k v)
                             (setf (aref v k)
                                   (build-etree (histo-slice litf k 256)
                                                256 15)))))))
            ;; ---- block-type / block-length switch codes ----------------
            (let* ((i-type-tree
                    (when (> nitypes 1)
                      (let ((tf (make-array (+ nitypes 2)
                                            :element-type 'fixnum
                                            :initial-element 0)))
                        (declare (type (simple-array fixnum (*)) tf))
                        (loop for b of-type fixnum from 1 below niblocks
                              do (incf (aref tf (+ (aref itypes b) 2))))
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
                              do (incf (aref tf (+ (aref dtypes b) 2))))
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
              (b:wbits w 0 1)                ; NBLTYPES L = 1 (contexts carry
                                             ; the literals, as in C's q5+)
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
                  (b:wbits w 0 2)            ; context mode (unused)
                  (b:wbits w 2 2))           ; context mode 2 = UTF8
              (if (= lit-k 1)
                  (b:wbits w 0 1)            ; NTREESL=1
                  (write-nbltypes w lit-k))
              (when (>= lit-k 2)
                (write-context-map w lit-cmap 64 lit-k))
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
              (if (= lit-k 1)
                  (write-etree w lit 256)
                  (dotimes (k lit-k)
                    (declare (type fixnum k))
                    (write-etree w (aref lits k) 256)))
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
                    (slack 0))
                (declare (type simple-vector lit-rcl lit-lnl lit-sng
                                       cmd-rcs cmd-lns cmd-sngs
                                       dist-rcs dist-lns dist-sngs)
                         (type (simple-array fixnum (*)) lit-rc lit-ln)
                         (type fixnum itype iblk ileft dtype dblk dleft slack))
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
                          (etree-emit w i-type-tree (+ nt 2))
                          (write-blen w i-len-tree nl)
                          (setf itype nt ileft nl)))
                      (decf ileft))
                    (let ((ins (aref recs b))
                          (ls (aref recs (+ b 1))))
                      (declare (type fixnum ins ls))
                      ;; One capacity check covers every bit this command can
                      ;; emit: at most ~13 bytes of command/distance overhead
                      ;; plus two bytes per literal (code lengths <= 15 bits),
                      ;; plus the eight-byte slack the raw writer needs.
                      (let ((cost (+ 24 (* 2 ins))))
                        (declare (type fixnum cost))
                        (when (> cost slack)
                          (setf slack 65536)
                          (b:w-ensure w (+ slack cost)))
                        (decf slack cost))
                      (let ((crc (aref cmd-rcs itype))
                            (cln (aref cmd-lns itype))
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
                                                     (logior (aref +lut0+ p1)
                                                             (aref +lut1+ p2)))))
                                     (declare (type fixnum sym p1 p2 cid))
                                     (unless (aref lit-sng cid)
                                       (b:%wbits-raw
                                        w (aref (aref lit-rcl cid) sym)
                                        (aref (aref lit-lnl cid) sym)))))
                          (unless lit-single
                            ;; Long runs amortize the pin/state setup of the
                            ;; run writer; short runs are cheaper inline.
                            (if (>= ins 16)
                                (b:w-emit-run w data ls (+ ls ins)
                                              lit-rc lit-ln)
                                (loop for i from ls below (+ ls ins)
                                      do (let ((sym (aref data i)))
                                           (b:%wbits-raw w (aref lit-rc sym)
                                                         (aref lit-ln sym)))))))
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
                                (etree-emit w d-type-tree (+ nt 2))
                                (write-blen w d-len-tree nl)
                                (setf dtype nt dleft nl)))
                            (decf dleft))
                          (let ((drc (aref dist-rcs dtype))
                                (dln (aref dist-lns dtype))
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
                                    (bt nil))
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
          (if one-pass
              ;; C's BrotliCompressFragmentFast: the scan itself writes the
              ;; meta-block body (trees were built from the pre-scan
              ;; histogram inside the fragment).
              (lz77 data window
                    :max-chain max-chain :lazy nil :skip-match t
                    :use-dict nil :insert-interior nil :one-pass w)
              (multiple-value-bind (cv nc litf cmdf distf)
                  (lz77 data window
                        :max-chain max-chain :lazy nil :skip-match t
                        :use-dict nil :insert-interior nil)
                (write-fast-block-body w data cv nc litf cmdf distf))))
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
                                       :quality quality :bt bt))))
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
                                   :score-p score-p :checks checks
                                   :bt bt))
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
                                                 :bt bt
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
          :insert-interior nil :fast-fragment t :one-pass t))
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
    ;; q6 was under-chained relative to C's bucket (block_bits 5 = 32
    ;; entries vs our 8): html q6 measured 1.121 vs C, the only cap
    ;; violation left.  16 mirrors C's q5/q6 effective search depth.
    (6 '(:max-chain 16 :lazy t :use-dict nil :short-dist t :quality 6
          :score-p t :checks 4))
    (7 '(:max-chain 24 :lazy t :use-dict nil :short-dist t :quality 7))
    (8 '(:max-chain 32 :lazy t :use-dict nil :short-dist t :quality 8))
    (9 '(:max-chain 128 :lazy t :use-dict nil :short-dist t :quality 9))
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
                                                :one-pass one-pass)
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
                                                :one-pass one-pass))))
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
                                                :quality quality
                                                :bt bt
                                                :one-pass one-pass)))
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
