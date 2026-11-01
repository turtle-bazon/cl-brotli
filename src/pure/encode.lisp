;;;; src/encode.lisp — Brotli compressed encoder (entropy-coded meta-blocks).
;;;;
;;;; A real compressor: greedy LZ77 (hash-chain match finder) producing
;;;; insert-and-copy commands, then canonical (length-limited) Huffman coding of
;;;; the literal / command / distance alphabets.  One literal/command/distance
;;;; tree each (NBLTYPES = 1, no context maps, NPOSTFIX = NDIRECT = 0); distances
;;;; use the ring buffer's "last distance" (code 0) when they repeat.  The output
;;;; is a standard brotli stream, decodable by the reference (node/python).
;;;; COMPRESS falls back to stored meta-blocks when entropy coding wouldn't help.
(in-package #:cl-brotli.pure)

;;; ---- canonical code construction --------------------------------------

(defun canonical-codes (lengths n)
  "Codes per symbol for code LENGTHS, matching BUILD-HUFF/READ-HUFF (codes are
emitted MSB-first; DEFLATE canonical assignment)."
  (let ((count (make-array (1+ +max-bits+) :initial-element 0))
        (next (make-array (1+ +max-bits+) :initial-element 0))
        (codes (make-array n :initial-element 0)))
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
         (fr (make-array cap :initial-element 0))
         (lf (make-array cap :initial-element -1))
         (rg (make-array cap :initial-element -1))
         (lengths (make-array n :initial-element 0))
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

(defstruct etree lengths codes single simple)

(defun build-etree (freqs size maxbits)
  (let ((nz (loop for s below size when (plusp (aref freqs s)) collect s)))
    (cond
      ((<= (length nz) 1)
       (make-etree :single (if nz (first nz) 0)))
      ((<= (length nz) 4)
       (let* ((lengths (make-array size :initial-element 0))
              (n (length nz)))
         (loop for s in nz for i from 0 do
           (setf (aref lengths s)
                 (case n (2 1) (3 (if (zerop i) 1 2)) (t 2))))
         (make-etree :lengths lengths :codes (canonical-codes lengths size)
                     :simple nz)))
      (t
       (let ((lengths (build-code-lengths freqs size maxbits)))
         (make-etree :lengths lengths :codes (canonical-codes lengths size)))))))

(defun emit-bits-msb (w code len)
  (loop for i from (1- len) downto 0 do (b:wbits w (logand (ash code (- i)) 1) 1)))

(defun etree-emit (w et sym)
  (unless (etree-single et)
    (emit-bits-msb w (aref (etree-codes et) sym) (aref (etree-lengths et) sym))))

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

(defun length-code (len base bits)
  "Largest code C with BASE[C] <= LEN; returns (values C extra-val extra-bits)."
  (loop for c from (1- (length base)) downto 0
        when (>= len (aref base c))
          do (return (values c (- len (aref base c)) (aref bits c)))))

(defun cmd-symbol (icode ccode)
  (let* ((ir (cond ((< icode 8) 0) ((< icode 16) 1) (t 2)))
         (cr (cond ((< ccode 8) 0) ((< ccode 16) 1) (t 2)))
         (cell (aref (aref +celltab+ ir) cr)))
    (+ (* cell 64) (ash (- icode (* ir 8)) 3) (- ccode (* cr 8)))))

(defun cmd-symbol-dist0 (icode ccode)
  "Command symbol for the implicit-distance form.  Only valid for insert
codes 0..7 and copy codes 0..15 (command symbols 0..127)."
  (+ (* (ash ccode -3) 64) (* icode 8) (logand ccode 7)))

(defun encode-distance (d)
  "Distance D (>=1) -> (values dcode dextra-val dextra-bits) for NPOSTFIX=NDIRECT=0."
  (loop for nbits from 1 do
    (dotimes (b 2)
      (let ((offset (- (ash (+ 2 b) nbits) 4)))
        (when (<= (1+ offset) d (+ offset (ash 1 nbits)))
          (return-from encode-distance
            (values (+ 16 (* 2 (1- nbits)) b) (- d offset 1) nbits)))))))

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
    (logand (ash (logand (* v 2654435761) #xffffffff) -15) hmask)))

(defun %match-len (data a b n)
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum a b n)
           (optimize (speed 3) (safety 0)))
  (let ((len 0) (maxl (- n b)))
    (declare (type fixnum len maxl))
    (loop while (and (< len maxl) (= (aref data (+ a len)) (aref data (+ b len)))) do (incf len))
    len))

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

(defun lz77 (data window &optional (use-dict (text-like-data-p data)) dict-limit (base-pos 0))
  "Return commands (insert-len lit-start copy-len distance dict-p); copy-len 0
marks a trailing insert-only command.  BASE-POS is the number of bytes already
produced before DATA; it is needed to encode dictionary distances correctly
when DATA is one chunk of a multi-meta-block stream."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum window base-pos)
           (optimize (speed 3) (safety 0)))
  (let* ((n (length data)) (min-match 4))
    (if (< n min-match)
        (if (zerop n) '() (list (list n 0 0 0 nil)))
        (let* ((hbits 17) (hmask (1- (ash 1 hbits)))
               (head (make-array (ash 1 hbits) :initial-element -1))
               (prev (make-array n :initial-element -1))
               (cmds '()) (lit-start 0) (p 0) (max-chain 128) (last (- n min-match))
               (dict-used 0))
          (flet ((ins (q) (let ((h (%hash4 data q hmask)))
                            (setf (aref prev q) (aref head h) (aref head h) q))))
            (loop while (<= p last) do
              (let* ((h (%hash4 data p hmask)) (cand (aref head h))
                     (best-len 0) (best-dist 0) (chain max-chain))
                (loop while (and (>= cand 0) (> chain 0)) do
                  (when (> (- p cand) window) (return))
                  (let ((ml (%match-len data cand p n)))
                    (when (> ml best-len) (setf best-len ml best-dist (- p cand))))
                  (setf cand (aref prev cand)) (decf chain))
                (labels ((use-normal-match ()
                           (ins p)
                           (if (>= best-len min-match)
                               (progn
                                 (push (list (- p lit-start) lit-start best-len best-dist nil) cmds)
                                 (loop for q from (1+ p) below (min (+ p best-len) (1+ last)) do (ins q))
                                 (incf p best-len) (setf lit-start p))
                               (incf p))))
                  (if (and use-dict
                           (or (null dict-limit) (< dict-used dict-limit)))
                      (multiple-value-bind (dict-len dict-idx dict-tid)
                          (dict-match-at data p n)
                        (if (and (>= dict-len 9)
                                 (> dict-len best-len))
                            (let ((dist (+ (min window (+ base-pos p)) 1 dict-idx
                                           (* dict-tid (nwords dict-len)))))
                              (push (list (- p lit-start) lit-start dict-len dist t) cmds)
                              (incf dict-used)
                              (ins p)
                              (loop for q from (1+ p) below (min (+ p dict-len) (1+ last)) do (ins q))
                              (incf p dict-len) (setf lit-start p))
                            (use-normal-match)))
                      (use-normal-match))))))
          (when (< lit-start n) (push (list (- n lit-start) lit-start 0 0 nil) cmds))
          (nreverse cmds)))))

;;; ---- compressed meta-block --------------------------------------------

(defstruct cmdrec ins lit-start cpy csym ixv ixb cxv cxb has-dist dcode dxv dxb)

(defvar *cmpdata*)   ; the input being compressed (bound during PLAN-COMMANDS / emit)

(defun plan-commands (cmds &optional (rb (make-array 5 :initial-contents '(16 15 11 4 4))))
  "Turn raw LZ77 commands into CMDRECs and tally literal/command/distance freqs.
Returns (values records litfreq cmdfreq distfreq).  RB is the distance ring
shared by all meta-blocks of the stream; it must persist across chunks just
like the decoder's ring."
  (let ((litfreq (make-array 256 :initial-element 0))
        (cmdfreq (make-array 704 :initial-element 0))
        (distfreq (make-array 64 :initial-element 0))
        (recs '()))
    (flet ((ring (offset)
             (aref rb (logand (+ (aref rb 4) offset) 3)))
           (push-distance (d)
             (setf (aref rb (logand (aref rb 4) 3)) d)
             (incf (aref rb 4))))
      (dolist (c cmds)
        (destructuring-bind (ins lit-start cpy dist dictp) c
          (multiple-value-bind (icode ixv ixb) (length-code ins +ins-base+ +ins-bits+)
            (let ((copyp (plusp cpy)))
              (multiple-value-bind (ccode cxv cxb)
                  (if copyp (length-code cpy +cpy-base+ +cpy-bits+) (values 0 0 0))
                (let* ((repeat (and copyp (not dictp) (= dist (ring 3))))
                       (dist0 (and repeat (<= icode 7) (< ccode 16)))
                       (csym (if dist0
                                 (cmd-symbol-dist0 icode ccode)
                                 (cmd-symbol icode ccode)))
                       (dcode 0) (dxv 0) (dxb 0) (has-dist nil))
                  (incf (aref cmdfreq csym))
                  (loop for i from lit-start below (+ lit-start ins)
                        do (incf (aref litfreq (aref *cmpdata* i))))
                  (when copyp
                    (unless dist0
                      (setf has-dist t)
                      (if repeat
                          (setf dcode 0)
                          (multiple-value-bind (scode sxv sxb)
                              (special-distance-code rb dist)
                            (if scode
                                (setf dcode scode dxv sxv dxb sxb)
                                (multiple-value-setq (dcode dxv dxb)
                                  (encode-distance dist)))))
                      (incf (aref distfreq dcode))
                      ;; Distance symbol 0 reuses the last distance without
                      ;; pushing; dictionary references are not pushed either.
                      (unless (or dictp (= dcode 0))
                        (push-distance dist))))
                  (push (make-cmdrec :ins ins :lit-start lit-start :cpy cpy :csym csym
                                     :ixv ixv :ixb ixb :cxv cxv :cxb cxb
                                     :has-dist has-dist :dcode dcode :dxv dxv :dxb dxb)
                        recs))))))))
    (values (nreverse recs) litfreq cmdfreq distfreq)))

(defun write-mlen-header (w n last)
  (let* ((m1 (1- n)) (nib (cond ((<= m1 #xFFFF) 4) ((<= m1 #xFFFFF) 5) (t 6))))
    (b:wbits w (if last 1 0) 1)                          ; ISLAST
    (when last (b:wbits w 0 1))                          ; ISLASTEMPTY=0
    (b:wbits w (- nib 4) 2)                              ; MNIBBLES
    (b:wbits w m1 (* 4 nib))                             ; MLEN-1
    (unless last (b:wbits w 0 1))))                      ; ISUNCOMPRESSED=0

(defun write-compressed-block-body (w data base-pos window use-dict dict-limit rb
                                    &optional cmds)
  "Write the NBLTYPES/trees/commands part of a compressed meta-block.  The
MLEN header must already have been written.  RB is the stream-wide distance
ring shared with the decoder.  CMDS, when supplied, is a precomputed command
list covering exactly this block."
  (let ((*cmpdata* data))
    (multiple-value-bind (recs litf cmdf distf)
        (plan-commands (or cmds (lz77 data window use-dict dict-limit base-pos)) rb)
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
        (dolist (r recs)
          (etree-emit w cmd (cmdrec-csym r))
          (b:wbits w (cmdrec-ixv r) (cmdrec-ixb r))
          (b:wbits w (cmdrec-cxv r) (cmdrec-cxb r))
          (loop for i from (cmdrec-lit-start r) below (+ (cmdrec-lit-start r) (cmdrec-ins r))
                do (etree-emit w lit (aref data i)))
          (when (cmdrec-has-dist r)
            (etree-emit w dist (cmdrec-dcode r))
            (b:wbits w (cmdrec-dxv r) (cmdrec-dxb r))))))))

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

(defun compress-entropy (input &key (use-dict nil) (dict-limit nil))
  "Entropy-coded brotli stream for INPUT.  Inputs larger than one meta-block
are split into <= 2^24-byte compressed meta-blocks followed by an empty last
meta-block."
  (let* ((data (b:to-octets input))
         (n (length data))
         (w (b:make-bwr))
         (wbits (min 24 (max 10 (integer-length (max 1 n)))))
         (window (- (ash 1 wbits) 16))
         (rb (make-array 5 :initial-contents '(16 15 11 4 4))))
    (write-wbits w wbits)
    (cond
      ((zerop n)
       (b:wbits w 1 1) (b:wbits w 1 1))                    ; ISLAST + ISLASTEMPTY
      ((<= n #.(ash 1 24))
       (write-mlen-header w n t)
       (write-compressed-block-body w data 0 window use-dict dict-limit rb))
      (t
       (let* ((cmds (lz77 data window use-dict dict-limit 0))
              (blocks (partition-commands cmds #.(ash 1 24)))
              (pos 0))
         (dolist (block blocks)
           (let ((outlen (reduce #'+ block :key #'command-output-length
                                       :initial-value 0)))
             (write-mlen-header w outlen nil)
             (write-compressed-block-body w data 0 window use-dict dict-limit
                                          rb block)
             (incf pos outlen)))
         (unless (= pos n)
           (error "multi-block encoder produced ~D bytes, expected ~D" pos n))
         (b:wbits w 1 1) (b:wbits w 1 1))))                ; final empty last block
    (b:w-align w)
    (b:to-octets (b:bwr-out w))))

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

(defun compress (input)
  "Compress INPUT to a brotli stream.  Uses entropy-coded meta-blocks (LZ77 +
Huffman), falling back to stored meta-blocks when that wouldn't be smaller."
  (let* ((data (b:to-octets input))
         (stored (compress-stored data)))
    (if (incompressible-p data)
        stored
        (let* ((plain (compress-entropy data :use-dict nil))
               (variants (and (text-like-data-p data)
                              (list (compress-entropy data :use-dict t))))
               (best (first (sort (remove nil (list* plain stored variants))
                                  #'< :key #'length))))
          best))))
