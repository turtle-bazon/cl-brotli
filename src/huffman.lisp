;;;; src/huffman.lisp — canonical prefix (Huffman) codes, read LSB-first
;;;; (DEFLATE/zlib convention).  Simple + complex code descriptions (RFC 7932 §3).
(in-package #:cl-brotli.lisp)

(declaim (optimize (speed 3) (safety 0)))

(defconstant +max-bits+ 15)
(defconstant +huff-table-bits+ 10)
;; Root-table width per alphabet (C: HUFFMAN_TABLE_BITS = 8 for every
;; symbol tree).  Literal trees are the many ones (C q5 streams: ~130 per
;; meta-block), so a smaller root cuts both build stores and cache
;; footprint; codes longer than the root use a second-level table sized to
;; the tree's longest code.
(defconstant +lit-root-bits+ 8)
(defconstant +other-root-bits+ 10)

(defstruct huff (count nil :type (or null (simple-array fixnum (16))))
  (lengths nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (symbol nil :type (or null simple-vector))
  (single 0 :type (integer 0 703))
  (table nil :type (or null (simple-array (unsigned-byte 16) (*))))
  (table-bits 0 :type fixnum)
  (mask 0 :type fixnum)
  ;; widest second-level table: longest code - TABLE-BITS (0 = none)
  (sub-bits 0 :type (integer 0 15)))

;; COUNT of every multi-symbol tree: only its non-NILness is read (NIL
;; marks a single-symbol tree); the real histogram is scratch of the reader.
(deftable +huff-multi+ (make-array 16 :element-type 'fixnum :initial-element 0))
(declaim (type (simple-array fixnum (16)) +huff-multi+))

(deftable +reverse-byte+
  (let ((v (make-array 256 :element-type '(unsigned-byte 8) :initial-element 0)))
    (dotimes (i 256 v)
      (let ((x i) (r 0))
        (dotimes (k 8)
          (setf r (logior (ash r 1) (logand x 1)) x (ash x -1)))
        (setf (aref v i) r)))))

(declaim (type (simple-array (unsigned-byte 8) (256)) +reverse-byte+))
(declaim (inline %reverse-bits))
(defun %reverse-bits (value bits)
  "Reverse the low BITS bits of VALUE (0 <= BITS <= 15)."
  (declare (type (unsigned-byte 16) value) (type (integer 0 16) bits)
           (optimize (speed 3) (safety 0)))
  (ash (logior (ash (aref +reverse-byte+ (logand value #xff)) 8)
               (aref +reverse-byte+ (logand (ash value -8) #xff)))
       (- bits 16)))

(defun make-single-huff (sym n)
  "The one-symbol code for SYM in an N-symbol alphabet: a real table of
zero-length entries (8-bit root for literal-sized alphabets, like every
literal tree), so the readers need no single-tree branch.  COUNT stays NIL,
which READ-HUFF uses to tell this case apart near the end of the input."
  (declare (type fixnum sym n))
  (let ((tb (if (= n 256) +lit-root-bits+ 1)))
    (make-huff :single sym
               :table (make-array (ash 1 tb) :element-type '(unsigned-byte 16)
                                             :initial-element (ash sym 4))
               :table-bits tb :mask (1- (ash 1 tb)))))

;;; Table building (C's BrotliBuildHuffmanTable layout) in one pass over
;;; the symbols, in symbol order - no sort.  Canonical codes are assigned
;;; per length in symbol order (CODE = NEXT[LEN]++), so a symbol's slots
;;; follow from its code alone, and the second-level tables' layout (which
;;; root prefix gets how wide a table, where) depends on the length
;;; histogram only: %HUFF-LAYOUT computes it per prefix first.

(deftable +rev10+
  (let ((v (make-array 1024 :element-type '(unsigned-byte 16))))
    (dotimes (i 1024 v)
      (let ((r 0))
        (dotimes (k 10) (when (logbitp k i) (setf r (logior r (ash 1 (- 9 k))))))
        (setf (aref v i) r)))))
(declaim (type (simple-array (unsigned-byte 16) (1024)) +rev10+))

(defun %huff-layout (count next tbits maxlen pe)
  "The second-level tables of a complete code from its length histogram
COUNT and first codes NEXT.  The codes of length L > TBITS are the
contiguous range NEXT[L] .. NEXT[L] + COUNT[L] - 1, so they cover a
contiguous range of root prefixes; a prefix's table is as wide as its
longest code needs (C's NextTableBitSize), so assigning the widths by
ascending length leaves each prefix its widest.  The long codes fill the
top of the code space, prefixes P0 .. 2^TBITS - 1 in order: PE[P - P0] <-
the root entry (offset << 4 | TBITS + width), offsets from 2^TBITS on.
Returns (values TOTAL P0)."
  (declare (type (simple-array fixnum (16)) count next)
           (type (integer 1 10) tbits) (type (integer 1 15) maxlen)
           (type (simple-array (unsigned-byte 16) (1024)) pe)
           (optimize (speed 3) (safety 0)))
  (let ((p0 (ash 1 tbits)) (top (ash 1 tbits)))
    (declare (type fixnum p0 top))
    ;; widths into PE (by prefix - P0 once P0 is known: first pass by
    ;; absolute prefix, PE has 1024 slots)
    (loop for l of-type fixnum from (1+ tbits) to maxlen do
      (let ((c (aref count l)))
        (declare (type fixnum c))
        (when (plusp c)
          (let* ((r (- l tbits))
                 (lo (ash (aref next l) (- r)))
                 (hi (min (1- top) (ash (+ (aref next l) c -1) (- r)))))
            (declare (type (integer 1 14) r) (type fixnum lo hi))
            (when (< lo p0) (setf p0 lo))
            (loop for p of-type fixnum from lo to hi
                  do (setf (aref pe p) r))))))
    (let ((total top))
      (declare (type fixnum total))
      (loop for p of-type fixnum from p0 below top do
        (let ((w (aref pe p)))
          (declare (type (integer 0 14) w))
          (setf (aref pe p) (logior (ash (logand total 4095) 4) (+ tbits w)))
          (incf total (ash 1 w))))
      (values total p0))))

(declaim (inline %huff-pack))
(defun %huff-pack (s l rank)
  "A nonzero-length symbol for the table builder: symbol | length << 10 |
rank << 14, RANK = how many lower symbols have the same length."
  (logior s (ash l 10) (ash rank 14)))

(defun %huff-fill (table nzs nnz count next tbits maxlen pe p0)
  "Every symbol's entries, in canonical (length, symbol) order like C.  NZS
holds the NNZ nonzero-length symbols packed with their length and rank
\(%HUFF-PACK), so a symbol's place in that order is OFFS[length] + rank:
independent stores, not a counter in memory per length (on Zen 2 each
store-to-load forwarded increment costs ~8 cycles).  Then per length a
loop whose shape is constant - a code's replication depends on its length
only, so the loops predict.  A code of up to TBITS bits is replicated over
the root, a longer one over its prefix's second-level table (whose root
entry %HUFF-LAYOUT wrote)."
  (declare (type (simple-array (unsigned-byte 16) (*)) table)
           (type (simple-array (unsigned-byte 32) (*)) nzs)
           (type (integer 0 1024) nnz)
           (type (simple-array fixnum (16)) count next)
           (type (integer 1 10) tbits) (type (integer 1 15) maxlen)
           (type (simple-array (unsigned-byte 16) (1024)) pe) (type fixnum p0)
           (optimize (speed 3) (safety 0)))
  (let ((sorted (make-array 1024 :element-type '(unsigned-byte 16)))
        (offs (make-array 16 :element-type 'fixnum))
        (rev +rev10+) (tsize (ash 1 tbits)))
    (declare (type (simple-array (unsigned-byte 16) (1024)) sorted rev)
             (type (simple-array fixnum (16)) offs)
             (dynamic-extent sorted offs)
             (type (integer 2 1024) tsize))
    (let ((o 0))
      (declare (type fixnum o))
      (loop for l of-type fixnum from 1 to 15 do
        (setf (aref offs l) o)
        (incf o (aref count l))))
    (dotimes (k nnz)
      (let ((e (aref nzs k)))
        (setf (aref sorted (logand 1023 (+ (aref offs (logand 15 (ash e -10)))
                                           (ash e -14))))
              (logand e 1023))))
    (let ((k 0))
      (declare (type (integer 0 1024) k))
      ;; codes of up to TBITS bits, by doubling (C's memcpy trick, at
      ;; every length): the table's first 2^(L-1) entries hold the codes
      ;; shorter than L replicated; copying them onto the next 2^(L-1)
      ;; replicates them once more, then each L-bit code is ONE store at
      ;; its reversed code.  No per-code replication loops (a 3-bit code
      ;; under a 10-bit root was 128 strided stores).  The slots the
      ;; copies leave for longer codes are overwritten by them, and the
      ;; subtable pointers are written last.
      (let ((lim (min tbits maxlen)))
        (declare (type (integer 1 10) lim))
        (loop for l of-type (integer 1 16) from 1 to tbits do
          (when (> l 1)
            (let ((half (ash 1 (1- l))))
              (declare (type (integer 1 512) half))
              (replace table table :start1 half :end1 (* 2 half) :end2 half)))
          (when (<= l lim)
            (let ((c (aref count l)) (code (aref next l)) (sh (- 10 l)))
              (declare (type (integer 0 1024) c) (type fixnum code)
                       (type (integer 0 9) sh))
              (dotimes (j c)
                (setf (aref table (aref rev (logand 1023 (ash (+ code j) sh))))
                      (logior (ash (aref sorted (+ k j)) 4) l)))
              (incf k c)))))
      ;; the root entries of the long codes' prefixes (%HUFF-LAYOUT)
      (loop for p of-type fixnum from p0 below tsize do
        (setf (aref table (aref rev (ash p (- 10 tbits)))) (aref pe p)))
      ;; longer codes: into their prefix's table.  R <= 7: literal roots
      ;; are 8 bits, other trees have long codes only with 10-bit roots.
      (loop for l of-type (integer 1 16) from (1+ tbits) to maxlen do
        (let* ((c (aref count l)) (code (aref next l))
               (r (min 7 (- l tbits))) (step (ash 1 r)) (sh (- 10 r))
               (psh (- 10 tbits)))
          (declare (type (integer 0 1024) c) (type fixnum code)
                   (type (integer 1 7) r) (type (integer 2 128) step)
                   (type (integer 3 9) sh) (type (integer 0 9) psh))
          (dotimes (j c)
            (let* ((cj (+ code j))
                   (e (aref table (aref rev (logand 1023 (ash (ash cj (- r)) psh)))))
                   (off (ash e -4))
                   (end (ash 1 (logand 15 (- (logand e 15) tbits))))
                   (entry (logior (ash (aref sorted (+ k j)) 4) r))
                   (i (aref rev (logand 1023 (ash (logand cj (1- step)) sh)))))
              (declare (type fixnum cj off end i) (type (unsigned-byte 16) e entry))
              (loop (setf (aref table (+ off i)) entry)
                    (incf i step)
                    (when (>= i end) (return)))))
          (incf k c))))))

(defun %huff-build (n count nzs nnz)
  "Canonical Huffman code of an N-symbol alphabet in C's table layout
\(BrotliBuildHuffmanTable): one (unsigned-byte 16) array holding a root
table of 2^TABLE-BITS entries, then one second-level table per root prefix
of the long codes, each just as wide as its longest code needs.  Entry =
symbol << 4 | length; a root entry whose length field exceeds TABLE-BITS
marks a subtable: field - TABLE-BITS is its width, the symbol field its
absolute offset.  COUNT[1..15] is the length histogram, NZS the NNZ
nonzero-length symbols in increasing order, packed (%HUFF-PACK).  The code
must be complete (the readers reject anything else), so every entry is
written."
  (declare (type (integer 1 1024) n)
           (type (simple-array fixnum (16)) count)
           (type (simple-array (unsigned-byte 32) (*)) nzs)
           (type (integer 0 1024) nnz)
           (optimize (speed 3) (safety 0)))
  (when (<= nnz 1)
    ;; A real table of zero-length entries (C does the same): readers need
    ;; no single-tree branch.  COUNT stays NIL, which READ-HUFF uses to
    ;; tell this case apart near the end of the input.
    (return-from %huff-build
      (make-single-huff (if (= nnz 1) (logand (aref nzs 0) 1023) 0) n)))
  (let ((maxlen 1))
    (declare (type (integer 1 15) maxlen))
    (loop for l of-type (integer 1 16) from 2 to +max-bits+ do
      (when (plusp (aref count l)) (setf maxlen l)))
    ;; Literal trees (n = 256) always get exactly an 8-bit root - shorter
    ;; codes are replicated - so the literal loops can use constant mask
    ;; and width.  Other trees get just what their longest code needs (a
    ;; code-length code: 2^5 entries), at most 10 bits.
    (let* ((table-bits (if (= n 256)
                           +lit-root-bits+
                           (min +other-root-bits+ maxlen)))
           (next (make-array (1+ +max-bits+) :element-type 'fixnum))
           (pe (make-array 1024 :element-type '(unsigned-byte 16))))
      (declare (type (integer 1 10) table-bits)
               (type (simple-array fixnum (16)) next)
               (type (simple-array (unsigned-byte 16) (1024)) pe)
               (dynamic-extent next pe))
      (let ((code 0))
        (declare (type fixnum code))
        (setf (aref next 0) 0)
        (loop for bits of-type fixnum from 1 to +max-bits+ do
          (setf code (ash (+ code (if (= bits 1) 0 (aref count (1- bits)))) 1)
                (aref next bits) code)))
      (multiple-value-bind (total p0)
          (if (> maxlen table-bits)
              (%huff-layout count next table-bits maxlen pe)
              (values (ash 1 table-bits) (ash 1 table-bits)))
        (declare (type fixnum total p0))
        (when (> total 4096)
          ;; subtable offsets live in the 12-bit symbol field
          (cl-brotli.lisp::berr "invalid prefix code"))
        (let ((table (make-array total :element-type '(unsigned-byte 16))))
          (%huff-fill table nzs nnz count next table-bits maxlen pe p0)
          (make-huff :count +huff-multi+ :table table
                     :table-bits table-bits
                     :mask (1- (ash 1 table-bits))
                     :sub-bits (max 0 (- maxlen table-bits))))))))

(defun build-huff (lengths n)
  "%HUFF-BUILD from code LENGTHS[0:n-1] (0 = absent)."
  (declare (type (simple-array (unsigned-byte 8) (*)) lengths)
           (type (integer 1 1024) n)
           (optimize (speed 3) (safety 0)))
  (let ((count (make-array 16 :element-type 'fixnum :initial-element 0))
        (nzs (make-array 1024 :element-type '(unsigned-byte 32)))
        (nnz 0))
    (declare (dynamic-extent count nzs) (type (integer 0 1024) nnz))
    (dotimes (s n)
      (let ((l (aref lengths s)))
        (declare (type (integer 0 15) l))
        (when (plusp l)
          (setf (aref nzs nnz) (%huff-pack s l (aref count l)))
          (incf (aref count l))
          (incf nnz))))
    (%huff-build n count nzs nnz)))

(declaim (inline consume-bits))
(defun consume-bits (r n)
  "Discard N bits that PEEK-BITS has already made available."
  (declare (type b:brd r) (type fixnum n)
           (optimize (speed 3) (safety 0)))
  (setf (b:brd-acc r) (ash (b:brd-acc r) (- n)))
  (decf (b:brd-nbits r) n))

(declaim (inline read-huff))
;; Decoded symbols are < 704 (the largest alphabet).  Without a declared
;; result type every comparison on a symbol (block switches, context maps,
;; the command loop) compiled to generic arithmetic.
(declaim (ftype (function (t t) (values (integer 0 4095) &optional))
                read-huff read-huff-slow))

(defun read-huff-slow (r h)
  "Fewer bits remain than READ-HUFF's lookup needs.  A code of length L <=
K (the K < TABLE-BITS remaining bits) is replicated over every root index
whose low L bits are its bits, so the zero-padded index of the remaining
bits finds it.  The same holds one level down: a long code whose root
entry points to a subtable is replicated over the subtable indexes that
share its low bits, so with fewer bits left than the subtable's full width
the zero-padded index of what remains still finds it (C's
BrotliSafeReadSymbol: a stream may legitimately end right after such a
code).  Anything longer means the stream ends inside a code."
  (declare (type huff h) (optimize (speed 1) (safety 1)))
  (let* ((table (huff-table h))
         (tb (huff-table-bits h))
         (avail (b:bits-available r))
         (k (min avail tb)))
    (declare (type (simple-array (unsigned-byte 16) (*)) table)
             (type (integer 0 10) tb k) (type fixnum avail))
    (let* ((entry (aref table (b:peek-bits r k)))
           (len (logand entry 15)))
      (declare (type (unsigned-byte 16) entry) (type (integer 0 15) len))
      (when (and (plusp len) (<= len k))
        (consume-bits r len)
        (return-from read-huff-slow (ash entry -4)))
      (when (and (> len tb) (> avail tb))
        ;; subtable of width LEN - TB; K2 of its bits remain
        (let* ((k2 (min (- avail tb) (- len tb)))
               (idx (ash (b:peek-bits r (+ tb k2)) (- tb)))
               (entry2 (aref table (+ (ash entry -4) idx)))
               (len2 (logand entry2 15)))
          (declare (type fixnum k2 idx) (type (unsigned-byte 16) entry2)
                   (type (integer 0 15) len2))
          (when (and (plusp len2) (<= len2 k2))
            (consume-bits r (+ tb len2))
            (return-from read-huff-slow (ash entry2 -4)))))
      ;; truncated: let the reader report the end of its input
      (b:rbits r (min 24 (1+ (b:bits-available r))))
      (berr "invalid prefix code"))))

(defun read-huff (r h)
  "Decode one symbol from R using canonical code H.  Short codes use the
10-bit primary table; longer codes use a secondary table.  PEEK-BITS fills
the reservoir or signals end-of-input, so the old BITS-AVAILABLE guards are
redundant on the fast path."
  (declare (type huff h))
  ;; single-symbol trees (no COUNT; their table is all zero-length
  ;; entries) need no input at all - also at the very end of the stream
  (unless (huff-count h) (return-from read-huff (huff-single h)))
  (let ((table (huff-table h)) (table-bits (huff-table-bits h)))
    (declare (type (simple-array (unsigned-byte 16) (*)) table)
             (type fixnum table-bits))
    ;; A valid stream may end with a code shorter than the primary table
    ;; width.  PEEK-BITS would otherwise insist on TABLE-BITS bits and report
    ;; end-of-input; the canonical slow walk can decode the remaining bits.
    (if (or (>= (b:brd-nbits r) table-bits)
            (>= (b:bits-available r) table-bits))
        (let ((entry (aref table
                           (progn
                              (unless (>= (b:brd-nbits r) table-bits)
                                (b::%fill-bits r table-bits))
                              (logand (b:brd-acc r) (huff-mask h))))))
          (declare (type fixnum entry))
          (cond
            ((<= (logand entry 15) table-bits)    ; direct hit
             (let ((len (logand entry 15)))
               (declare (type fixnum len))
               (consume-bits r len)
               (ash entry -4)))
            (t                                    ; subtable of width len - table-bits
             (if (or (>= (b:brd-nbits r) (logand entry 15))
                     (>= (b:bits-available r) (logand entry 15)))
                 (let ((sb (- (logand entry 15) table-bits)))
                   (declare (type (integer 1 14) sb))
                   (consume-bits r table-bits)
                   (let* ((sub-base (ash entry -4))
                          (entry2 (aref table
                                        (+ sub-base
                                           (progn
                                             (unless (>= (b:brd-nbits r) sb)
                                               (b::%fill-bits r sb))
                                             (logand (b:brd-acc r) (1- (ash 1 sb))))))))
                     (declare (type fixnum sub-base entry2))
                     (if (plusp (logand entry2 15))
                         (let ((rem (logand entry2 15)))
                           (declare (type fixnum rem))
                           (consume-bits r rem)
                           (ash entry2 -4))
                         (berr "invalid prefix code"))))
                 (read-huff-slow r h)))))
        (read-huff-slow r h))))

;; Straight-line groups of reads (command symbol + its two extras; distance
;; symbol + extra) with the reservoir in locals instead of the BRD struct:
;; one load and one store of ACC/NBITS/POS per group instead of per read.
;; BODY must not call anything that takes R itself - the slow fallbacks
;; below sync the locals through R around their own calls.
(defun read-huff-ool (r h)
  "Out-of-line READ-HUFF for the local readers' cold path.  Inlining the
whole of READ-HUFF there (as before) put its variables in every hot loop's
register allocation: the disassembly showed the loop counter, output
position, table and mask all living in stack slots."
  (declare (type b:brd r) (type huff h) (optimize (speed 3) (safety 0)))
  (read-huff r h))
(declaim (notinline read-huff-ool))
(defun rbits-ool (r n)
  "Out-of-line B:RBITS for LBITS' cold path (an inline RBITS brought its
refill loop and a +WIDE-MASKS+ symbol-value fetch to every call site)."
  (declare (type b:brd r) (type (integer 0 24) n) (optimize (speed 3) (safety 0)))
  (b:rbits r n))
(declaim (notinline rbits-ool))

(defmacro with-local-bits ((r) &body body)
  (let ((acc (gensym "ACC")) (nb (gensym "NB")) (p (gensym "P"))
        (end (gensym "END")) (src (gensym "SRC")) (end8 (gensym "END8")))
    `(let* ((,acc (b:brd-acc ,r)) (,nb (b:brd-nbits ,r)) (,p (b:brd-pos ,r))
            (,end (b:brd-end ,r))
            (,src #+cl-brotli-sap (b:brd-sap ,r) #-cl-brotli-sap (b:brd-bytes ,r))
            ;; last position an 8-byte refill may read from; -1 disables the
            ;; fast refill (no SAP), so the hot test is one compare
            (,end8 (if ,src (- ,end 8) -1)))
       (declare (type fixnum ,end8) (ignorable ,end))
       ;; ACC is an untagged u64 in a register (it never exceeds 59 bits);
       ;; as a FIXNUM every shift paid a tag/untag pair.  It is converted
       ;; only where it is synced with the BRD slot.
       (declare (type (unsigned-byte 64) ,acc) (type fixnum ,p ,end)
                (type (integer 0 59) ,nb)
                #+cl-brotli-sap (type (or null sb-sys:system-area-pointer) ,src)
                #-cl-brotli-sap (type (simple-array (unsigned-byte 8) (*)) ,src))
       (macrolet ((%lfill (need)
                    `(when (and (< ,',nb ,need) (<= ,',p ,',end8))
                       ;; (59 - nb) >> 3 is already <= 7; the mask is a shift,
                       ;; not a lookup in +WIDE-MASKS+ (a special variable:
                       ;; a thread-local symbol-value fetch per refill)
                       (let* ((bytes (ash (- 59 ,',nb) -3))
                              (w (logand (ptr-u64 #+cl-brotli-sap (the sb-sys:system-area-pointer ,',src)
                                                  #-cl-brotli-sap ,',src
                                                  ,',p)
                                         (1- (ash 1 (* 8 bytes))))))
                         (declare (type (integer 0 7) bytes) (type (unsigned-byte 64) w))
                         (setf ,',acc (logior ,',acc (logand (ash w ,',nb) #xFFFFFFFFFFFFFFFF))
                               ,',nb (+ ,',nb (* 8 bytes))
                               ,',p (+ ,',p bytes)))))
                  (%lslow (form)
                    `(progn
                       (setf (b:brd-acc ,',r) (the fixnum ,',acc) (b:brd-nbits ,',r) ,',nb
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
                    (let ((tr (gensym "TREE")))
                      `(let ((,tr ,tree))
                         (declare (type huff ,tr))
                         (lsym* ,tr (huff-table ,tr) (huff-table-bits ,tr)
                                (huff-mask ,tr)))))
                  (lsym-fast (tree table table-bits mask)
                    ;; Fast mode (C's "safe = 0"): the caller has checked
                    ;; that the input holds enough bytes for every symbol it
                    ;; will read here, so the refill needs no end test and
                    ;; nothing in this expansion calls a function - which
                    ;; lets SBCL keep the loop's variables in registers (no
                    ;; register survives a full call).  Returns -1 for
                    ;; anything but a one- or two-level hit; the caller then
                    ;; falls back to LSYM*.
                    (let ((tr (gensym "TREE")) (tb (gensym "TBL")))
                      `(let* ((,tr ,tree) (,tb ,table))
                         (declare (type huff ,tr)
                                  (type (simple-array (unsigned-byte 16) (*)) ,tb))
                         (block lsym
                           (when (< ,',nb 15)
                             (let* ((bytes (ash (- 59 ,',nb) -3))
                                    (w (logand (ptr-u64 #+cl-brotli-sap (the sb-sys:system-area-pointer ,',src)
                                                        #-cl-brotli-sap ,',src
                                                        ,',p)
                                               (1- (ash 1 (* 8 bytes))))))
                               (declare (type (integer 0 7) bytes) (type (unsigned-byte 64) w))
                               (setf ,',acc (logior ,',acc (logand (ash w ,',nb) #xFFFFFFFFFFFFFFFF))
                                     ,',nb (+ ,',nb (* 8 bytes))
                                     ,',p (+ ,',p bytes))))
                           (let* ((tbits ,table-bits)
                                  (entry (aref ,tb (logand ,',acc ,mask)))
                                  (len (logand entry 15)))
                             (declare (type (integer 1 10) tbits)
                                      (type (unsigned-byte 16) entry)
                                      (type (integer 0 15) len))
                             (when (<= len tbits)         ; direct hit
                               (setf ,',acc (ash ,',acc (- len)) ,',nb (- ,',nb len))
                               (return-from lsym (ash entry -4)))
                             (progn                       ; subtable marker
                               (let* ((e2 (aref ,tb (+ (ash entry -4)
                                                       (logand (ash ,',acc (- tbits))
                                                               (1- (ash 1 (- len tbits)))))))
                                      (rem (logand e2 15)))
                                 (declare (type (unsigned-byte 16) e2) (type (integer 0 15) rem))
                                 (when (plusp rem)
                                   (setf ,',acc (ash ,',acc (- (+ tbits rem)))
                                         ,',nb (- ,',nb (+ tbits rem)))
                                   (return-from lsym (ash e2 -4)))))
                             -1)))))
                  (fast-input-p (nbytes)
                    ;; at least NBYTES of input beyond P for 8-byte refills
                    `(<= (+ ,',p ,nbytes) ,',end8))
                  (lsym* (tree table table-bits mask)
                    ;; TABLE / TABLE-BITS / MASK may be variables hoisted out
                    ;; of a loop (single-tree streams): SBCL does not hoist
                    ;; the struct reads past the output stores by itself.
                    (let ((tr (gensym "TREE")) (tb (gensym "TBL")))
                      `(let* ((,tr ,tree) (,tb ,table))
                         (declare (type huff ,tr)
                                  (type (or null (simple-array (unsigned-byte 16) (*))) ,tb))
                         (block lsym
                           (unless ,tb (return-from lsym (huff-single ,tr)))
                           (let ((tbits ,table-bits))
                             (declare (type (integer 1 10) tbits))
                             (%lfill 15)
                             (when (>= ,',nb tbits)
                               (let* ((entry (aref ,tb (logand ,',acc ,mask)))
                                      (len (logand entry 15)))
                                 (declare (type (unsigned-byte 16) entry)
                                          (type (integer 0 15) len))
                                 (cond
                                   ((<= len tbits)              ; direct hit
                                    (setf ,',acc (ash ,',acc (- len))
                                          ,',nb (- ,',nb len))
                                    (return-from lsym (ash entry -4)))
                                   ((>= ,',nb len)              ; marker: len = tbits + width
                                    (let* ((e2 (aref ,tb (+ (ash entry -4)
                                                            (logand (ash ,',acc (- tbits))
                                                                    (1- (ash 1 (- len tbits)))))))
                                           (rem (logand e2 15)))
                                      (declare (type (unsigned-byte 16) e2)
                                               (type (integer 0 15) rem))
                                      (when (plusp rem)
                                        (setf ,',acc (ash ,',acc (- (+ tbits rem)))
                                              ,',nb (- ,',nb (+ tbits rem)))
                                        (return-from lsym (ash e2 -4)))))))))
                           (%lslow (read-huff-ool ,',r ,tr)))))))
         (multiple-value-prog1 (progn ,@body)
           (setf (b:brd-acc ,r) (the fixnum ,acc) (b:brd-nbits ,r) ,nb (b:brd-pos ,r) ,p))))))

(defun alphabet-bits (size) (max 1 (integer-length (1- size))))

;;; fixed clcl code (RFC 7932 §3.5), read LSB-first:
;;; 0->00  3->10  4->01  2->011  1->0111  5->1111
(declaim (inline read-clcl))
(deftable +clcl-peek+
  ;; C kCodeLengthPrefixValue / Length by 4 peeked bits: value | length << 4
  (let ((v (make-array 16 :element-type '(unsigned-byte 8))))
    (dotimes (i 16 v)
      (setf (aref v i)
            (cond ((= (logand i 3) 0) (logior 0 (ash 2 4)))
                  ((= (logand i 3) 2) (logior 3 (ash 2 4)))
                  ((= (logand i 3) 1) (logior 4 (ash 2 4)))
                  ((= (logand i 7) 3) (logior 2 (ash 3 4)))
                  ((= (logand i 15) 7) (logior 1 (ash 4 4)))
                  (t (logior 5 (ash 4 4))))))))
(declaim (type (simple-array (unsigned-byte 8) (16)) +clcl-peek+))

(defun read-clcl (r)
  "One code-length-code length: 4 peeked bits through C's table when 4 bits
remain, else bit by bit (the stream may end right after a short code)."
  (declare (type b:brd r) (optimize (speed 3) (safety 0)))
  (when (or (>= (b:brd-nbits r) 4) (>= (b:bits-available r) 4))
    (let ((e (aref +clcl-peek+ (b:peek-bits r 4))))
      (consume-bits r (ash e -4))
      (return-from read-clcl (logand e 15))))
  (if (zerop (b:rbit r))
      (if (zerop (b:rbit r)) 0 3)
      (if (zerop (b:rbit r)) 4
          (if (zerop (b:rbit r)) 2
              (if (zerop (b:rbit r)) 1 5)))))

(deftable +clcl-order+
  (coerce '(1 2 3 4 0 5 17 6 16 7 8 9 10 11 12 13 14 15) '(simple-array fixnum (18))))
(declaim (type (simple-array fixnum (18)) +clcl-order+))

(defvar *cl-huff-cache* (make-array 256 :initial-element nil)
  "Recent code-length-code tables: (KEY . HUFF), KEY the 18 lengths (3 bits
each).  Encoders reuse a handful of these across trees and streams.  A
HUFF is never modified once built, so entries are shared between threads
\(a racing store only replaces one valid entry by another).")
(declaim (type simple-vector *cl-huff-cache*))

(defun cached-cl-huff (cl-lengths)
  "BUILD-HUFF of the 18 code-length-code lengths CL-LENGTHS, memoised."
  (declare (type (simple-array (unsigned-byte 8) (*)) cl-lengths)
           (optimize (speed 3) (safety 0)))
  (let ((key 0))
    (declare (type (unsigned-byte 54) key))
    (dotimes (i 18) (setf key (logior key (ash (logand (aref cl-lengths i) 7) (* 3 i)))))
    (let* ((cache *cl-huff-cache*)
           (ix (logand 255 (logxor key (ash key -8) (ash key -17) (ash key -29) (ash key -41))))
           (e (svref cache ix)))
      (if (and (consp e) (eql (car e) key))
          (cdr e)
          (let ((h (build-huff cl-lengths 18)))
            (setf (svref cache ix) (cons key h))
            h)))))

(defun read-complex-prefix (r hskip alphabet-size)
  (declare (type b:brd r) (type (integer 0 3) hskip)
           (type (integer 1 1024) alphabet-size)
           (optimize (speed 3) (safety 0)))
  (let ((cl-lengths (make-array 18 :element-type '(unsigned-byte 8)
                                     :initial-element 0))
          (space2 0) (ncodes 0))
    (declare (type fixnum space2 ncodes) (dynamic-extent cl-lengths))
    (loop for i of-type fixnum from hskip below 18 do
      (let ((len (read-clcl r)))
        (declare (type (integer 0 5) len))
        (setf (aref cl-lengths (aref +clcl-order+ i)) len)
        (when (plusp len)
          (incf ncodes)
          (incf space2 (ash 32 (- len)))
          (when (>= space2 32) (return)))))
    ;; C: BROTLI_DECODER_ERROR_FORMAT_CL_SPACE.  An over- or under-full
    ;; code-length code would make BUILD-HUFF index past its tables.
    (unless (or (= ncodes 1) (= space2 32))
      (cl-brotli.lisp::berr "invalid code-length code"))
    (let ((clh (cached-cl-huff cl-lengths))
          (symbol 0) (prev-code-len 8) (repeat 0) (repeat-code-len 0) (space 32768)
          ;; length histogram, and the nonzero-length symbols in order
          ;; packed with length and rank (C's symbol lists): the table
          ;; builder visits only these, and needs no per-symbol array
          (count (make-array (1+ +max-bits+) :element-type 'fixnum :initial-element 0))
          (nzs (make-array alphabet-size :element-type '(unsigned-byte 32)))
          (nnz 0))
      (declare (type fixnum symbol repeat space)
               (type (integer 0 15) prev-code-len repeat-code-len)
               (type (simple-array fixnum (16)) count)
               (type (simple-array (unsigned-byte 32) (*)) nzs)
               (type (integer 0 1024) nnz)
               ;; %HUFF-BUILD keeps none of them
               (dynamic-extent count nzs))
      (with-local-bits (r)
      (loop while (and (< symbol alphabet-size) (> space 0)) do
        (let ((c (lsym clh)))
          (declare (type (integer 0 17) c))
          (if (< c 16)
              (progn (setf repeat 0)
                     (when (plusp c)
                       (let ((rank (aref count c)))
                         (declare (type (integer 0 1023) rank))
                         (setf (aref nzs nnz) (%huff-pack symbol c rank)
                               (aref count c) (1+ rank)))
                       (incf nnz)
                       (setf prev-code-len c) (decf space (ash 32768 (- c))))
                     (incf symbol))
              (let* ((extra-bits (- c 14))                  ; 16->2, 17->3
                     (new-len (if (= c 16) prev-code-len 0)))
                (declare (type (integer 2 3) extra-bits) (type (integer 0 15) new-len))
                (unless (= repeat-code-len new-len) (setf repeat 0 repeat-code-len new-len))
                (let ((old-repeat repeat))
                  (when (plusp repeat) (setf repeat (ash (- repeat 2) extra-bits)))
                  (incf repeat (+ (lbits extra-bits) 3))
                  (let ((delta (- repeat old-repeat)))
                    (declare (type fixnum delta))
                    (when (plusp new-len) (decf space (ash delta (- 15 new-len))))
                    (let ((written (min delta (- alphabet-size symbol))))
                      (declare (type fixnum written))
                      (when (plusp written)
                        (when (plusp new-len)
                          (let ((rank (aref count new-len)))
                            (declare (type (integer 0 1023) rank))
                            (dotimes (q written)
                              (setf (aref nzs (+ nnz q))
                                    (%huff-pack (+ symbol q) new-len (+ rank q))))
                            (setf (aref count new-len) (+ rank written))
                            (incf nnz written)))
                        (incf symbol written))))))))))
      ;; C: BROTLI_DECODER_ERROR_FORMAT_HUFFMAN_SPACE - the code must be
      ;; exactly complete.
      (unless (zerop space)
        (cl-brotli.lisp::berr "incomplete or oversubscribed prefix code"))
      (%huff-build alphabet-size count nzs nnz))))

(defun read-prefix-code (r alphabet-size)
  "Read a prefix code (simple or complex); return a HUFF."
  (let ((kind (b:rbits r 2)))
    (if (= kind 1)
        (let* ((nsym (1+ (b:rbits r 2))) (ab (alphabet-bits alphabet-size)) (syms (make-array nsym)))
          (dotimes (i nsym)
            (let ((v (b:rbits r ab)))
              ;; C: ..._SIMPLE_HUFFMAN_ALPHABET / ..._SIMPLE_HUFFMAN_SAME
              (when (>= v alphabet-size)
                (cl-brotli.lisp::berr "prefix symbol ~d outside alphabet ~d" v alphabet-size))
              (dotimes (j i)
                (when (= v (aref syms j))
                  (cl-brotli.lisp::berr "duplicate symbol in simple prefix code")))
              (setf (aref syms i) v)))
          (if (= nsym 1)
              (make-single-huff (aref syms 0) alphabet-size)
              (let ((lengths (make-array alphabet-size
                                  :element-type '(unsigned-byte 8)
                                  :initial-element 0)))
                (ecase nsym
                  (2 (setf (aref lengths (aref syms 0)) 1 (aref lengths (aref syms 1)) 1))
                  (3 (setf (aref lengths (aref syms 0)) 1 (aref lengths (aref syms 1)) 2 (aref lengths (aref syms 2)) 2))
                  (4 (if (= 1 (b:rbit r))
                         (setf (aref lengths (aref syms 0)) 1 (aref lengths (aref syms 1)) 2
                               (aref lengths (aref syms 2)) 3 (aref lengths (aref syms 3)) 3)
                         (dotimes (i 4) (setf (aref lengths (aref syms i)) 2)))))
                (build-huff lengths alphabet-size))))
        (read-complex-prefix r kind alphabet-size))))
