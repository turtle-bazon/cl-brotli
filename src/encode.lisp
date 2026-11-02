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
       (let* ((lengths (build-code-lengths freqs size maxbits))
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
      (t (setf l (build-code-lengths clfreq 18 5))))
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

(defun dict-key4 (vec pos)
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
            (dolist (tid +dict-transforms+)
              (let* ((base (subseq dict off (+ off len)))
                     (word (if (zerop tid)
                               base
                               (apply-transform base (aref +transforms+ tid)))))
                (when (loop for i below len
                            always (= (aref data (+ p i)) (aref word i)))
                  (setf best-len len best-idx idx best-tid tid)
                  (return))))))))
    (values best-len best-idx best-tid)))

;;; ---- LZ77 (greedy hash-chain match finder) ----------------------------

(declaim (inline %hash4 %match-len))
(defun %hash4 (data i hmask)
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum i hmask)
           (optimize (speed 3) (safety 0)))
  (let ((v (logior (aref data i) (ash (aref data (1+ i)) 8)
                   (ash (aref data (+ i 2)) 16) (ash (aref data (+ i 3)) 24))))
    (logand (ash (logand (the (unsigned-byte 64)
                              (* (the (unsigned-byte 32) v) 2654435761))
                         #xffffffff)
                 -15)
            hmask)))

(defun %match-len (data a b n)
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum a b n)
           (optimize (speed 3) (safety 0)))
  (let ((len 0) (maxl (- n b)))
    (declare (type fixnum len maxl))
    (loop while (and (< len maxl) (= (aref data (+ a len)) (aref data (+ b len)))) do (incf len))
    len))

#+sbcl
(declaim (inline %hash4-sap))
#+sbcl
(declaim (inline %hashf-sap))
#+sbcl
(defun %hashf-sap (sap i hmask)
  "C Brotli's fast-fragment hash: multiply the low 32-bit word by kHashMul32
and take the high bits, masked to the table size.  The constant -15 shift
keeps ASH inline."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum i hmask)
           (optimize (speed 3) (safety 0)))
  (let ((v (sb-sys:sap-ref-32 sap i)))
    (logand (ash (logand (the (unsigned-byte 64)
                              (* (the (unsigned-byte 32) v) #x1E35A7BD))
                         #xFFFFFFFF)
                 -15)
            hmask)))

#+sbcl
(defun %hash4-sap (sap i hmask)
  (declare (type sb-sys:system-area-pointer sap) (type fixnum i hmask)
           (optimize (speed 3) (safety 0)))
  (let ((v (sb-sys:sap-ref-32 sap i)))
    (logand (ash (logand (the (unsigned-byte 64)
                              (* (the (unsigned-byte 32) v) 2654435761))
                         #xffffffff)
                 -15)
            hmask)))

#+(and sbcl x86-64 64-bit little-endian)
(declaim (inline %trailing-zeros))
#+(and sbcl x86-64 64-bit little-endian)
(defun %trailing-zeros (x)
  (declare (type (unsigned-byte 64) x)
           (optimize (speed 3) (safety 0)))
  (sb-kernel:count-trailing-zeros x))

#+(and sbcl x86-64 64-bit little-endian)
(declaim (inline %match-len-sap))
#+(and sbcl x86-64 64-bit little-endian)
(defun %match-len-sap (sap a b n)
  "Word-at-a-time match extension; A < B and A+MAXL < N, so 8-byte loads
at both ends stay inside the vector.  On a mismatch inside a word, TZCNT
finds the first differing byte in one step (the same trick as C Brotli's
FindMatchLengthWithLimit)."
  (declare (type sb-sys:system-area-pointer sap)
           (type fixnum a b n)
           (optimize (speed 3) (safety 0)))
  (let ((len 0) (maxl (- n b)))
    (declare (type fixnum len maxl))
    (loop while (<= (+ len 8) maxl)
          do (let ((x (logxor (sb-sys:sap-ref-64 sap (+ a len))
                              (sb-sys:sap-ref-64 sap (+ b len)))))
               (declare (type (unsigned-byte 64) x))
               (unless (zerop x)
                 (return-from %match-len-sap
                   (+ len (ash (%trailing-zeros x) -3))))
               (incf len 8)))
    (loop while (and (< len maxl)
                     (= (sb-sys:sap-ref-8 sap (+ a len))
                        (sb-sys:sap-ref-8 sap (+ b len))))
          do (incf len))
    len))

#+(and sbcl x86-64 64-bit little-endian)
(defun %match-len-sap-call (sap a b n)
  "%MATCH-LEN-SAP behind a non-inlined call boundary.  The fragment matcher
uses this so the inlined RETURN-FROM block exists only once per expansion."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum a b n)
           (optimize (speed 3) (safety 0)))
  (%match-len-sap sap a b n))

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
              skip-match insert-interior)
  "Implementation of LZ77.  SAP is a system-area pointer for DATA on SBCL,
or NIL on other implementations."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum window base-pos max-chain)
           (optimize (speed 3) (safety 0)))
  #+sbcl (declare (type (or null sb-sys:system-area-pointer) sap))
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
               (skip 32) (dict-used 0))
          (declare (type (simple-array (unsigned-byte 32) (*)) head)
                   (type (or null (simple-array (unsigned-byte 32) (*))) prev)
                   (type fixnum p lit-start last skip dict-used))
          (labels (#+sbcl
                   (hash (i)
                     (if sap (%hash4-sap sap i hmask) (%hash4 data i hmask)))
                   #-sbcl
                   (hash (i) (%hash4 data i hmask))
                   #+(and sbcl x86-64 64-bit little-endian)
                   (mlen (a b) (%match-len-sap sap a b n))
                   #-(and sbcl x86-64 64-bit little-endian)
                   (mlen (a b) (%match-len data a b n))
                   (ins (q h)
                     (let ((old (aref head h)))
                       (setf (aref head h) q)
                       (when chained (setf (aref prev q) old))))
                   (probe-ok (cand pos best-len)
                     #+(and sbcl x86-64 64-bit little-endian)
                     (let ((probe (if (>= best-len 3) best-len 3)))
                       (if (<= (+ pos probe 4) n)
                           (= (sb-sys:sap-ref-32 sap (+ cand (- probe 3)))
                              (sb-sys:sap-ref-32 sap (+ pos (- probe 3))))
                           t))
                     #-(and sbcl x86-64 64-bit little-endian)
                     (declare (ignore cand pos best-len))
                     #-(and sbcl x86-64 64-bit little-endian)
                     t)
                   (find-match (pos h)
                     (let ((cand (aref head h)) (best-len 0) (best-dist 0))
                       (if chained
                           (let ((chain max-chain))
                             (loop while (and (/= cand #xFFFFFFFF) (> chain 0)) do
                               (when (> (- pos cand) window) (return))
                               (when (probe-ok cand pos best-len)
                                 (let ((ml (mlen cand pos)))
                                   (when (> ml best-len)
                                     (setf best-len ml best-dist (- pos cand)))))
                               (setf cand (aref prev cand)) (decf chain)))
                           (when (and (/= cand #xFFFFFFFF) (<= (- pos cand) window))
                             (when (probe-ok cand pos best-len)
                               (let ((ml (mlen cand pos)))
                                 (when (> ml best-len)
                                   (setf best-len ml best-dist (- pos cand)))))))
                       (values best-len best-dist)))
                   (emit-normal (best-len best-dist inserted h)
                     (unless inserted (ins p h))
                     (if (>= best-len min-match)
                         (progn
                           (push (list (- p lit-start) lit-start best-len
                                       best-dist nil)
                                 cmds)
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
            (declare (inline hash ins mlen probe-ok))
            (loop while (<= p last) do
              (let* ((ph (hash p)))
                (multiple-value-bind (best-len best-dist) (find-match p ph)
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
                          (emit-normal best-len best-dist nil ph)))))))
            (when (< lit-start n)
              (push (list (- n lit-start) lit-start 0 0 nil) cmds))
            (nreverse cmds))))))

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
         (cmds '()) (lit-start 0) (p 1) (limit (- n k))
         (last-dist -1) (back (if (= k 5) 3 5)))
    (declare (type fixnum k min-match p lit-start limit last-dist back)
             (type (simple-array (unsigned-byte 32) (*)) table))
    (labels ((hash (i) (%hashf-sap sap i hmask))
             (prefix-match (a b)
               (and (= (sb-sys:sap-ref-32 sap a)
                       (sb-sys:sap-ref-32 sap b))
                    (if (= k 5)
                        (= (sb-sys:sap-ref-8 sap (+ a 4))
                           (sb-sys:sap-ref-8 sap (+ b 4)))
                        (= (sb-sys:sap-ref-16 sap (+ a 4))
                           (sb-sys:sap-ref-16 sap (+ b 4))))))
             (mlen (a b) (%match-len-sap-call sap a b n)))
        (declare (inline hash prefix-match))
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
                       (matched (+ min-match (mlen (+ cand k) (+ p k))))
                       (distance (- base cand))
                       (insert (- base lit-start)))
                  (declare (type fixnum matched distance insert))
                  (push (list insert lit-start matched distance nil) cmds)
                  (incf p matched)
                  (setf lit-start p
                        last-dist distance))
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
                                           (mlen (+ cand2 k) (+ p k))))
                               (distance (- base cand2)))
                          (declare (type fixnum matched distance))
                          (push (list 0 p matched distance nil) cmds)
                          (setf last-dist distance)
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
        (push (list (- n lit-start) lit-start 0 0 nil) cmds))
      (nreverse cmds))))

(defun lz77 (data window &key (use-dict (text-like-data-p data)) dict-limit
                              (base-pos 0) (max-chain 128) (lazy t)
                              (skip-match nil) (insert-interior t))
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
               base-pos max-chain lazy skip-match insert-interior)))
  #-sbcl
  (%lz77 data nil window use-dict dict-limit base-pos max-chain lazy
          skip-match insert-interior))

;;; ---- compressed meta-block --------------------------------------------

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

(defun q0-histograms (data cmds)
  "Return (values LITFREQ CMDFREQ DISTFREQ) for the fast command list CMDS.
CMDFREQ is over the 64 fast command codes; DISTFREQ is over distance
symbols 0..63.  The command/distance histograms start from C's seed."
  (declare (type (simple-array (unsigned-byte 8) (*)) data))
  (let ((litf (make-array 256 :element-type 'fixnum :initial-element 0))
        (cmdf (make-array 64 :element-type 'fixnum :initial-element 0))
        (distf (make-array 64 :element-type 'fixnum :initial-element 0))
        (last-dist -1))
    (declare (type (simple-array fixnum (256)) litf)
             (type (simple-array fixnum (64)) cmdf distf)
             (type fixnum last-dist))
    (replace cmdf +q0-seed-cmd+)
    (replace distf +q0-seed-dist+)
    (dolist (c cmds)
      (let ((ins (car c))
            (lit-start (cadr c))
            (cpy (caddr c))
            (dist (cadddr c)))
        (declare (type fixnum ins lit-start cpy dist))
        (loop for i from lit-start below (+ lit-start ins)
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
             (incf (aref cmdf cc)))))))
    (values litf cmdf distf)))

(defun write-fast-block-body (w data cmds)
  "Emit a q0/q1 meta-block body from the fast-fragment command list, using
the fast command/distance alphabet with trees built from the actual histograms.
The MLEN header must already have been written."
  (declare (type b:bwr w)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (optimize (speed 3) (safety 0)))
  (multiple-value-bind (litf cmdf distf) (q0-histograms data cmds)
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
           (last-dist -1))
      (declare (type fixnum last-dist)
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
                        (b:%wbits-raw w (aref cmd-rc (aref cmd-map c))
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
                          (b:%wbits-raw w ,extra ,nbits))))))
        (dolist (c cmds)
          (let ((ins (car c))
                (lit-start (cadr c))
                (cpy (caddr c))
                (dist (cadddr c)))
            (declare (type fixnum ins lit-start cpy dist))
            (cond
              ((and (plusp ins) (plusp cpy))
               (b:w-ensure w (+ 32 (* 2 ins)))
               (multiple-value-bind (cc e nb) (q0-insert-len ins)
                 (emit-cmd cc e nb))
               (unless lit-single
                 (b:w-emit-run w data lit-start (+ lit-start ins) lit-rc lit-ln))
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
               (b:w-ensure w 32)
               (multiple-value-bind (cc e nb) (q0-copy-len cpy)
                 (emit-cmd cc e nb))
               (multiple-value-bind (cc e nb) (q0-distance dist)
                 (emit-dist cc e nb))
               (setf last-dist dist))
              (t
               (b:w-ensure w (+ 32 (* 2 ins)))
               (multiple-value-bind (cc e nb) (q0-insert-len ins)
                 (emit-cmd cc e nb))
               (unless lit-single
                 (b:w-emit-run w data lit-start (+ lit-start ins) lit-rc lit-ln))))))))))


;;; Flat command records: 10 fixnums per command.  A struct per command was
;;; ~15% of low-quality compression time; CPY is not needed by the emitter,
;;; and a negative DCODE means "no distance bits".
(defconstant +cmd-stride+ 10)
;; offsets: 0 ins, 1 lit-start, 2 csym, 3 ixv, 4 ixb, 5 cxv, 6 cxb,
;;          7 dcode (-1 = none), 8 dxv, 9 dxb

(defun plan-commands (data cmds
                      &optional (rb (make-array 5 :element-type 'fixnum
                                                  :initial-contents '(16 15 11 4 4)))
                      &key (short-dist t))
  "Turn raw LZ77 commands into flat fixnum records and tally literal/command/
distance frequencies.  Returns (values RECS NCOMMANDS LITFREQ CMDFREQ DISTFREQ).
RB is the distance ring shared by all meta-blocks of the stream; it must
persist across chunks just like the decoder's ring.  SHORT-DIST enables the 15
short distance-ring codes; low qualities disable them to avoid 15 comparisons
per command."
  (let* ((ncmd (length cmds))
         (recs (make-array (* +cmd-stride+ ncmd)
                           :element-type 'fixnum :initial-element 0))
         (ri 0)
         (litfreq (make-array 256 :element-type 'fixnum :initial-element 0))
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
                (loop for i from lit-start below (+ lit-start ins)
                      do (incf (aref litfreq (aref data i))))
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
    (values recs ncmd litfreq cmdfreq distfreq)))

(defun write-mlen-header (w n last)
  (let* ((m1 (1- n)) (nib (cond ((<= m1 #xFFFF) 4) ((<= m1 #xFFFFF) 5) (t 6))))
    (b:wbits w (if last 1 0) 1)                          ; ISLAST
    (when last (b:wbits w 0 1))                          ; ISLASTEMPTY=0
    (b:wbits w (- nib 4) 2)                              ; MNIBBLES
    (b:wbits w m1 (* 4 nib))                             ; MLEN-1
    (unless last (b:wbits w 0 1))))                      ; ISUNCOMPRESSED=0

(defun write-compressed-block-body (w data base-pos window use-dict dict-limit rb
                                    &key (max-chain 128) (lazy t) (short-dist t)
                                      (skip-match nil) (insert-interior t) cmds)
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
  (multiple-value-bind (recs ncmd litf cmdf distf)
        (plan-commands
         data
         (or cmds
             (lz77 data window :use-dict use-dict :dict-limit dict-limit
                            :base-pos base-pos :max-chain max-chain :lazy lazy
                            :skip-match skip-match
                            :insert-interior insert-interior))
         rb :short-dist short-dist)
      (declare (type (simple-array fixnum (*)) recs litf cmdf distf)
               (type fixnum ncmd))
      (let ((lit (build-etree litf 256 15))
            (cmd (build-etree cmdf 704 15))
            (dist (build-etree distf 64 15)))
        (b:wbits w 0 1) (b:wbits w 0 1) (b:wbits w 0 1)   ; NBLTYPES L/I/D = 1
        (b:wbits w 0 2)                                   ; NPOSTFIX=0
        (b:wbits w 0 4)                                   ; NDIRECT=0
        (b:wbits w 0 2)                                   ; context mode (literal type 0)
        (b:wbits w 0 1) (b:wbits w 0 1)                   ; NTREESL=1, NTREESD=1
        (write-etree w lit 256)
        (write-etree w cmd 704)
        (write-etree w dist 64)
        ;; Hoist the per-tree slot reads and the "single symbol" tests out of
        ;; the per-command loop.  Literal-heavy blocks otherwise re-read four
        ;; slots and re-test a branch for every literal.
        (let ((cmd-single (etree-single cmd))
              (lit-single (etree-single lit))
              (dist-single (etree-single dist))
              (cmd-rc (or (etree-rcodes cmd) +empty-fixnums+))
              (cmd-ln (or (etree-lengths cmd) +empty-fixnums+))
              (lit-rc (or (etree-rcodes lit) +empty-fixnums+))
              (lit-ln (or (etree-lengths lit) +empty-fixnums+))
              (dist-rc (or (etree-rcodes dist) +empty-fixnums+))
              (dist-ln (or (etree-lengths dist) +empty-fixnums+)))
          (declare (type (simple-array fixnum (*))
                         cmd-rc cmd-ln lit-rc lit-ln dist-rc dist-ln))
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
                (b:w-ensure w (+ 24 (* 2 ins)))
                (unless cmd-single
                  (b:%wbits-raw w (aref cmd-rc (aref recs (+ b 2)))
                                (aref cmd-ln (aref recs (+ b 2)))))
                (b:%wbits-raw w (aref recs (+ b 3)) (aref recs (+ b 4)))
                (b:%wbits-raw w (aref recs (+ b 5)) (aref recs (+ b 6)))
                (unless lit-single
                  ;; Long runs amortize the pin/state setup of the run
                  ;; writer; short runs are cheaper inline.
                  (if (>= ins 16)
                      (b:w-emit-run w data ls (+ ls ins) lit-rc lit-ln)
                      (loop for i from ls below (+ ls ins)
                            do (let ((sym (aref data i)))
                                 (b:%wbits-raw w (aref lit-rc sym)
                                               (aref lit-ln sym))))))
                (let ((dcode (aref recs (+ b 7))))
                  (declare (type fixnum dcode))
                  (when (>= dcode 0)
                    (unless dist-single
                      (b:%wbits-raw w (aref dist-rc dcode)
                                    (aref dist-ln dcode)))
                    (b:%wbits-raw w (aref recs (+ b 8))
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
                                    (fast-fragment nil))
  "Entropy-coded brotli stream for INPUT.  Inputs larger than one meta-block
are split into <= 2^24-byte compressed meta-blocks followed by an empty last
meta-block."
  (let* ((data (b:to-octets input))
         (n (length data))
         (w (b:make-bwr (max 1024 (+ n 1024))))
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
       (if fast-fragment
           (write-fast-block-body
            w data
            (lz77 data window
                   :max-chain max-chain :lazy nil :skip-match t
                   :use-dict nil :insert-interior nil))
           (write-compressed-block-body w data 0 window use-dict dict-limit rb
                                        :max-chain max-chain :lazy lazy
                                        :short-dist short-dist
                                        :skip-match skip-match
                                        :insert-interior insert-interior)))
      (t
       (let* ((cmds (lz77 data window :use-dict use-dict
                                   :dict-limit dict-limit :base-pos 0
                                   :max-chain max-chain :lazy lazy))
              (blocks (partition-commands cmds #.(ash 1 24)))
              (pos 0))
         (dolist (block blocks)
           (let ((outlen (reduce #'+ block :key #'command-output-length
                                       :initial-value 0)))
             (write-mlen-header w outlen nil)
             (write-compressed-block-body w data 0 window use-dict dict-limit
                                          rb :max-chain max-chain
                                             :lazy lazy :short-dist short-dist
                                             :skip-match skip-match
                                             :insert-interior insert-interior
                                             :cmds block)
             (incf pos outlen)))
         (unless (= pos n)
           (error "multi-block encoder produced ~D bytes, expected ~D" pos n))
         (b:wbits w 1 1) (b:wbits w 1 1))))                ; final empty last block
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
         (let ((table (make-hash-table :test #'eql :size sample))
               (duplicates 0))
           (loop for i from 0 below (- sample 3) do
             (let ((key (dict-key4 data i)))
               (if (gethash key table)
                   (incf duplicates)
                   (setf (gethash key table) t))))
           (< duplicates (max 16 (/ sample 100)))))))

(defun quality-params (quality)
  "Encoder effort settings for QUALITY 0..11.  The mapping is deliberately
simple: quality 0 is stored blocks, low qualities use a short greedy chain,
middle qualities add lazy matching, and high qualities widen the chain and
enable the static dictionary."
  (case quality
    ;; Quality 0 is the fast path, not raw stored blocks: stored would be
    ;; ~30x larger than C q0 on text-like data.  The stored fallback is still
    ;; used whenever entropy coding cannot beat the input size.
    (0 '(:max-chain 1 :lazy nil :use-dict nil :short-dist nil :skip-match t
          :insert-interior nil :fast-fragment t))
    (1 '(:max-chain 2 :lazy nil :use-dict nil :short-dist nil :skip-match t
          :insert-interior nil :fast-fragment t))
    (2 '(:max-chain 4 :lazy nil :use-dict nil :short-dist nil :skip-match t :insert-interior nil))
    (3 '(:max-chain 8 :lazy nil :use-dict nil :short-dist nil :skip-match t :insert-interior nil))
    (4 '(:max-chain 16 :lazy nil :use-dict nil :short-dist nil :skip-match t :insert-interior nil))
    (5 '(:max-chain 32 :lazy t :use-dict nil :short-dist t))
    (6 '(:max-chain 48 :lazy t :use-dict nil :short-dist t))
    (7 '(:max-chain 64 :lazy t :use-dict nil :short-dist t))
    (8 '(:max-chain 96 :lazy t :use-dict nil :short-dist t))
    (9 '(:max-chain 128 :lazy t :use-dict nil :short-dist t))
    (10 '(:max-chain 256 :lazy t :use-dict t :short-dist t))
    (t '(:max-chain 512 :lazy t :use-dict t :short-dist t))))

(defun compress (input &key (quality 11))
  "Compress INPUT to a brotli stream.  QUALITY is an effort level 0..11:
0 emits stored blocks, low levels use a short greedy hash chain, and high
levels use lazy matching, a wider chain, and dictionary-assisted matching.
The stored fallback is only built when the entropy-coded candidates are not
already smaller than the input."
  (let* ((data (b:to-octets input))
         (n (length data))
         (params (quality-params quality)))
    (if (or (eq (getf params :mode) :stored) (incompressible-p data))
        (compress-stored data)
        (let* ((max-chain (getf params :max-chain 128))
               (lazy (getf params :lazy t))
               (short-dist (getf params :short-dist t))
               (skip-match (getf params :skip-match nil))
               (insert-interior (getf params :insert-interior t))
               (fast-fragment (getf params :fast-fragment nil))
               (dict-ok (and (getf params :use-dict) (text-like-data-p data)))
               (plain (compress-entropy data :use-dict nil
                                               :max-chain max-chain
                                               :lazy lazy
                                               :short-dist short-dist
                                               :skip-match skip-match
                                               :insert-interior insert-interior
                                               :fast-fragment fast-fragment))
               (best plain))
          (when dict-ok
            (let ((alt (compress-entropy data :use-dict t
                                                :max-chain max-chain
                                                :lazy lazy
                                                :short-dist short-dist
                                                :skip-match skip-match
                                                :insert-interior insert-interior
                                                :fast-fragment fast-fragment)))
              (when (< (length alt) (length best)) (setf best alt))))
          (when (>= (length best) (+ n 32))
            (let ((stored (compress-stored data)))
              (when (< (length stored) (length best)) (setf best stored))))
          best))))
