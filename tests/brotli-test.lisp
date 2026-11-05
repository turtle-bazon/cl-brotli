(in-package #:cl-brotli/tests)

(def-suite brotli-suite :description "Lisp Brotli and CFFI reference differential")
(in-suite brotli-suite)

(defun octets (string)
  (flexi-streams:string-to-octets string :external-format :utf-8))

(defun slurp (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((out (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence out s)
      out)))

(test lisp-empty-roundtrip
  (let ((data (make-array 0 :element-type '(unsigned-byte 8))))
    (is (equalp (cl-brotli:decompress (cl-brotli:compress data)) data))))

(test lisp-text-roundtrip
  (let ((data (octets "the quick brown fox jumps over the lazy dog")))
    (is (equalp (cl-brotli:decompress (cl-brotli:compress data)) data))))

(test lisp-binary-roundtrip
  (let ((data (make-array 10000 :element-type '(unsigned-byte 8))))
    (dotimes (i (length data)) (setf (aref data i) (mod (* i 37) 256)))
    (is (equalp (cl-brotli:decompress (cl-brotli:compress data)) data))))

(test lisp-periodic-ramp-compresses
  ;; A 0..255 ramp has 256 distinct byte values and a flat byte distribution,
  ;; but repeats every 4-byte window.  It must not be mistaken for random data.
  (let* ((n (* 1024 1024))
         (data (make-array n :element-type '(unsigned-byte 8))))
    (dotimes (i n)
      (setf (aref data i) (mod i 256)))
    (let ((compressed (cl-brotli:compress data)))
      (is (< (length compressed) 2000))
      (is (equalp (cl-brotli:decompress compressed) data))
      (is (equalp (cl-brotli.reference:decompress compressed) data)))))

(test lisp-multi-meta-block
  ;; The encoder must split inputs larger than one 16 MiB meta-block.
  (let* ((unit (octets "The quick brown fox jumps over the lazy dog. Brotli multi-block. "))
         (ulen (length unit))
         (n (1+ (ash 1 24)))
         (data (make-array n :element-type '(unsigned-byte 8))))
    (dotimes (i n)
      (setf (aref data i) (aref unit (mod i ulen))))
    (let ((compressed (cl-brotli:compress data)))
      (is (< (length compressed) 2000))
      (is (equalp (cl-brotli:decompress compressed) data))
      (is (equalp (cl-brotli.reference:decompress compressed) data)))))

(test invalid-distance-is-rejected
  (let ((out (make-array 16 :element-type '(unsigned-byte 8)
                            :adjustable t :fill-pointer 8)))
    (dotimes (i 8) (setf (aref out i) i))
    (signals cl-brotli:brotli-error
      (cl-brotli.lisp::out-copy out 0 2))))

(test reference-decode-vectors
  (let ((dir (merge-pathnames "tests/vectors/"
                              (asdf:system-source-directory "cl-brotli"))))
    (dolist (br (directory (merge-pathnames "*.br" dir)))
      (let* ((name (pathname-name br))
             (base (subseq name 0 (position #\. name)))
             (raw (merge-pathnames (format nil "~A.raw" base) dir)))
        (when (probe-file raw)
          (is (equalp (cl-brotli:decompress (slurp br)) (slurp raw))))))))

(test differential-lisp-to-reference
  (let ((data (octets "hello brotli differential")))
    (is (equalp (cl-brotli.reference:decompress
                 (cl-brotli:compress data))
                data))))

(test differential-reference-to-lisp
  (let ((data (octets "hello brotli differential")))
    (is (equalp (cl-brotli:decompress
                 (cl-brotli.reference:compress data))
                data))))

(test lisp-quality-levels
  ;; Every effort level must produce a stream both decoders accept.
  (let* ((unit (octets "The quick brown fox jumps over the lazy dog. Brotli quality level. "))
         (ulen (length unit))
         (n 65536)
         (data (make-array n :element-type '(unsigned-byte 8))))
    (dotimes (i n)
      (setf (aref data i) (aref unit (mod i ulen))))
    (dotimes (q 12)
      (let ((compressed (cl-brotli:compress data :quality q)))
        (is (equalp (cl-brotli:decompress compressed) data))
        (is (equalp (cl-brotli.reference:decompress compressed) data))))))

(test differential-random-sizes
  (dolist (n '(0 1 2 10 100 1000 10000))
    (let ((data (make-array n :element-type '(unsigned-byte 8))))
      (dotimes (i n) (setf (aref data i) (mod (* i 131) 251)))
      ;; Lisp encoder must produce streams the C reference can decode.
      (is (equalp (cl-brotli.reference:decompress (cl-brotli:compress data)) data))
      ;; Lisp decoder must decode streams the C reference produces.
      (is (equalp (cl-brotli:decompress (cl-brotli.reference:compress data)) data)))))

(test differential-large-secondary-tables
  ;; 1 MiB regression coverage for long Huffman codes: secondary-table
  ;; lookups refill the bit reservoir, but small corpora keep it full and
  ;; never exercise that refill.  A 5-bit secondary refill with a 7-bit
  ;; index passed this whole suite and failed only on 1 MiB inputs.
  (let ((n (ash 1 20)))
    (flet ((check (data)
             (dolist (q '(1 5))
               (let ((compressed (cl-brotli:compress data :quality q)))
                 (is (equalp (cl-brotli:decompress compressed) data))
                 (is (equalp (cl-brotli.reference:decompress compressed) data))))
             (let ((c-stream (cl-brotli.reference:compress data :quality 5)))
               (is (equalp (cl-brotli:decompress c-stream) data)))))
      ;; Periodic bytes: heavy on commands and distances.
      (let ((data (make-array n :element-type '(unsigned-byte 8))))
        (dotimes (i n) (setf (aref data i) (mod (* i 131) 251)))
        (check data))
      ;; Varied records: heavy on literals with long matches nearby.
      (let ((out (make-array n :element-type '(unsigned-byte 8)
                                   :fill-pointer 0)))
        (dotimes (k (ceiling n 64))
          (let ((s (format nil "<div id='r~D'><h2>w~D ~D</h2><p>t~D t~D.</p></div>"
                           (mod k 100000) (mod k 50) k (mod k 50) k)))
            (dotimes (i (length s))
              (when (< (fill-pointer out) n)
                (vector-push (char-code (char s i)) out)))))
        (check (coerce out '(simple-array (unsigned-byte 8) (*))))))))

(test into-api
  ;; Allocation-free entry points: byte-identical streams, exact offsets,
  ;; in-place writes, and clean overflow signals.
  (flet ((roundtrip (data q)
           (let* ((n (length data))
                  (one-shot (cl-brotli:compress data :quality q)))
             ;; The bound must hold for every quality.
             (is (<= (length one-shot) (cl-brotli:max-compressed-size n)))
             ;; Exact-size buffer, written from a nonzero offset.
             (let ((out (make-array (+ 17 (cl-brotli:max-compressed-size n))
                                    :element-type '(unsigned-byte 8)
                                    :initial-element #xAA)))
               (is (= (cl-brotli:compress-into data out :start 17 :quality q)
                      (+ 17 (length one-shot))))
               (is (equalp (subseq out 17 (+ 17 (length one-shot))) one-shot))
               (is (= (aref out 0) #xAA))
               ;; Decode back out of the offset stream slice.
               (let ((back (make-array (+ 5 n) :element-type '(unsigned-byte 8))))
                 (is (= (cl-brotli:decompress-into out back :start 5
                                                        :istart 17
                                                        :iend (+ 17 (length one-shot)))
                        (+ 5 n)))
                 (is (equalp (subseq back 5 (+ 5 n)) data))))))
         (overflows (data q)
           ;; Too-small buffers signal overflow with the required size.
           (let ((tiny (make-array 4 :element-type '(unsigned-byte 8))))
             (signals cl-brotli:brotli-output-overflow
               (cl-brotli:compress-into data tiny :quality q)))
           (let ((c (cl-brotli:compress data :quality q))
                 (short (make-array 1 :element-type '(unsigned-byte 8))))
             (signals cl-brotli:brotli-output-overflow
               (cl-brotli:decompress-into c short)))))
    ;; Tiled text (entropy path).
    (let* ((unit (octets "Pack my box with five dozen liquor jugs. Into API. "))
           (ulen (length unit))
           (n 262144)
           (data (make-array n :element-type '(unsigned-byte 8))))
      (dotimes (i n) (setf (aref data i) (aref unit (mod i ulen))))
      (dolist (q '(1 5 11)) (roundtrip data q) (overflows data q)))
    ;; Patterned bytes (stored path: the former megabyte-temp case).
    (let ((data (make-array 65536 :element-type '(unsigned-byte 8))))
      (dotimes (i 65536) (setf (aref data i) (mod (* i 131) 251)))
      (dolist (q '(0 5)) (roundtrip data q) (overflows data q)))
    ;; Empty input.
    (roundtrip (make-array 0 :element-type '(unsigned-byte 8)) 5)))

;;;; ---- multi-threaded coverage ----
;;;;
;;;; The codec is used from a concurrent HTTP server: no shared mutable
;;;; state between threads, one compressor per thread, and a cold-start
;;;; dictionary build that must survive concurrent first use.  Workers
;;;; only COMPUTE - every FIVEAM assertion runs on the main thread (a
;;;; worker's *TEST* context is not ours).

(defun mt-text (n)
  "Deterministic N-byte printable-ASCII corpus: text-like, so the
static dictionary path is taken."
  (let* ((unit (octets "The quick brown fox jumps over the lazy dog. Brotli mt test. "))
         (ulen (length unit))
         (data (make-array n :element-type '(unsigned-byte 8))))
    (dotimes (i n) (setf (aref data i) (aref unit (mod i ulen))))
    data))

(defun mt-bytes (n)
  "Deterministic N-byte patterned corpus: not text-like (dictionary
off) and the same length as MT-TEXT, so both share one pooled scratch
entry - reusing it across different content is what must not leak."
  (let ((data (make-array n :element-type '(unsigned-byte 8))))
    (dotimes (i n) (setf (aref data i) (mod (+ (* i 131) (ash i -8)) 251)))
    data))

(defun mt-map (n fn)
  "Run (FN i) for i in 0..N-1 in N fresh threads, collecting results in
order as (:ok VALUE-LIST) or (:error CONDITION).  Sequential fallback
where no thread implementation is available."
  (let ((results (make-array n :initial-element nil))
        (threads '()))
    (flet ((call-worker (idx)
             (handler-case
                 (setf (aref results idx) (list :ok (funcall fn idx)))
               (error (e) (setf (aref results idx) (list :error e))))))
      #+sbcl
      (progn
        (dotimes (i n)
          ;; fresh binding per iteration: DOTIMES' variable is ONE binding
          (let ((idx i))
            (push (sb-thread:make-thread
                   (lambda () (call-worker idx))
                   :name (format nil "cl-brotli-mt-~D" idx))
                  threads)))
        (dolist (th threads) (sb-thread:join-thread th)))
      #-sbcl
      (dotimes (i n) (call-worker i)))
    results))

(defun mt-check (results references)
  "Each worker returned a list of compressed buffers; position J of
every worker's list must be byte-equal to (ELT REFERENCES J)."
  (loop for r across results
        for i from 0
        do (is (eq (first r) :ok)
               "worker ~D failed: ~A" i
               (if (eq (first r) :ok) "output differs" (second r)))
           (when (eq (first r) :ok)
             (loop for v in (second r)
                   for ref in references
                   for j from 0
                   do (is (equalp v ref)
                          "worker ~D call ~D differs from reference" i j)))))

(test lisp-plain-compress-threaded
  ;; Stateless COMPRESS from 8 threads must match the single-thread
  ;; reference exactly (twice each, so stale-state bugs have a chance
  ;; to show) and roundtrip.
  (let* ((n 262144)
         (data (mt-text n))
         (reference (cl-brotli:compress data :quality 11))
         (results (mt-map 8 (lambda (i)
                              (declare (ignore i))
                              (dotimes (k 2) (cl-brotli:compress data :quality 11))
                              (list (cl-brotli:compress data :quality 11))))))
    (mt-check results (list reference))
    (is (equalp (cl-brotli:decompress reference) data))))

(test lisp-make-compressor-threaded
  ;; One private compressor per thread, several calls each, alternating
  ;; two different corpora of the SAME length: the pooled arrays are
  ;; reused across calls (same pool entry) but must never be shared
  ;; between threads nor carry one corpus's bytes into the other.
  (let* ((n 262144)
         (text (mt-text n))
         (bytes (mt-bytes n))
         (ref-text (cl-brotli:compress text :quality 11))
         (ref-bytes (cl-brotli:compress bytes :quality 11))
         (results (mt-map 8
                          (lambda (i)
                            (declare (ignore i))
                            (let ((c (cl-brotli:make-compressor)))
                              (list (funcall c text :quality 11)
                                    (funcall c bytes :quality 11)
                                    (funcall c text :quality 11)))))))
    (mt-check results (list ref-text ref-bytes ref-text))
    (is (equalp (cl-brotli:decompress ref-text) text))
    (is (equalp (cl-brotli:decompress ref-bytes) bytes))))

(test lisp-make-compressor-identical-to-plain
  ;; The pooled closure path must be byte-identical to plain COMPRESS
  ;; at every quality that touches the pooled arrays (0: stored, 5:
  ;; score path, 10/11: BT path).
  (dolist (data (list (mt-text 65536) (mt-bytes 65536)))
    (let ((c (cl-brotli:make-compressor)))
      (dolist (q '(0 5 10 11))
        (is (equalp (funcall c data :quality q)
                    (cl-brotli:compress data :quality q))
            "compressor differs from plain at q~D" q)))))

(test lisp-dictionary-first-use-threaded
  ;; Cold start: drop the dictionary globals and let 8 threads race the
  ;; very first load + index build, at both the BT quality (DICT-MATCHES-
  ;; AT) and the score quality (DICT-MATCH-AT).  The index is published
  ;; as one word, so no thread may observe a torn (flat . bstart) pair.
  (let* ((data (mt-text 262144))
         (reset (lambda ()
                  (setf cl-brotli.lisp::*dict* nil
                        cl-brotli.lisp::*dict-index* nil))))
    (dolist (q '(11 5))
      (funcall reset)
      (let ((reference (cl-brotli:compress data :quality q)))
        (funcall reset)
        (mt-check (mt-map 8 (lambda (i)
                              (declare (ignore i))
                              (list (cl-brotli:compress data :quality q))))
                  (list reference))))))
