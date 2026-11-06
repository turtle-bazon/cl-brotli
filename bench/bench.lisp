(defpackage #:cl-brotli-bench
  (:use #:cl)
  (:export #:main #:run-benchmark))

(in-package #:cl-brotli-bench)

;;;; Benchmark cl-brotli against the system C Brotli library.
;;;;
;;;; The harness measures the same input through:
;;;;
;;;;   * cl-brotli:compress / decompress          -- the public Lisp API
;;;;     via make-compressor: a per-cell compressor context whose
;;;;     private pool keeps the encoder's big arrays across reps (the
;;;;     steady-state pattern a server sees, and the like-for-like
;;;;     counterpart of C's reused preallocated buffers)
;;;;   * C core BrotliEncoderCompress / BrotliDecoderDecompress
;;;;     with preallocated foreign buffers        -- library cost without
;;;;                                                 Lisp allocation/copying
;;;;   * cl-brotli.reference:compress / decompress -- the one-shot CFFI wrapper
;;;;                                                 used by the tests
;;;;
;;;; Every stream is cross-checked with both decoders before it is timed.
;;;; Throughput is MiB/s of uncompressed data.  "lisp/C" > 1 means cl-brotli
;;;; is faster (or, for sizes, larger).

;;; ------------------------------------------------------------------
;;; C Brotli bindings and buffers
;;; ------------------------------------------------------------------

(cffi:defcfun ("memcpy" %memcpy) :pointer
  (destination :pointer) (source :pointer) (count :size))

(cffi:defcfun ("BrotliEncoderVersion" %brotli-encoder-version) :uint32)

(defun brotli-version-string ()
  (let ((v (%brotli-encoder-version)))
    (format nil "~D.~D.~D"
            (ldb (byte 8 24) v)
            (ldb (byte 12 12) v)
            (ldb (byte 12 0) v))))

(defun foreign-octets (data)
  "Copy DATA into a fresh foreign unsigned-char buffer.  Always allocates at
least one byte so zero-length inputs still have a valid pointer."
  (let* ((n (length data))
         (ptr (cffi:foreign-alloc :unsigned-char :count (max 1 n))))
    (when (plusp n)
      (cffi:with-pointer-to-vector-data (source data)
        (%memcpy ptr source n)))
    ptr))

(defun foreign-to-octets (pointer count)
  "Copy COUNT octets from POINTER into a fresh Lisp octet vector."
  (let ((out (make-array count :element-type '(unsigned-byte 8))))
    (when (plusp count)
      (cffi:with-pointer-to-vector-data (destination out)
        (%memcpy destination pointer count)))
    out))

(defstruct (c-compressor (:constructor %make-c-compressor))
  (input nil)
  (input-size 0 :type fixnum)
  (output nil)
  (output-capacity 0 :type fixnum)
  (size-pointer nil))

(defun make-c-compressor (data)
  (let* ((n (length data))
         (capacity (max 1 (cl-brotli.reference:brotli-encoder-max-compressed-size n))))
    (%make-c-compressor
     :input (foreign-octets data)
     :input-size n
     :output (cffi:foreign-alloc :unsigned-char :count capacity)
     :output-capacity capacity
     :size-pointer (cffi:foreign-alloc :size))))

(defun free-c-compressor (compressor)
  (when compressor
    (cffi:foreign-free (c-compressor-input compressor))
    (cffi:foreign-free (c-compressor-output compressor))
    (cffi:foreign-free (c-compressor-size-pointer compressor))))

(defun c-compress-core (compressor quality lgwin mode)
  "Call BrotliEncoderCompress once; return the encoded size."
  (let ((size-pointer (c-compressor-size-pointer compressor)))
    (setf (cffi:mem-ref size-pointer :size)
          (c-compressor-output-capacity compressor))
    (let ((ok (cl-brotli.reference:brotli-encoder-compress
               quality lgwin mode
               (c-compressor-input-size compressor)
               (if (zerop (c-compressor-input-size compressor))
                   (cffi:null-pointer)
                   (c-compressor-input compressor))
               size-pointer
               (c-compressor-output compressor))))
      (unless (plusp ok)
        (error "C Brotli compression failed (quality ~D, lgwin ~D, mode ~D)"
               quality lgwin mode))
      (cffi:mem-ref size-pointer :size))))

(defun c-compressor-result (compressor)
  (foreign-to-octets (c-compressor-output compressor)
                     (cffi:mem-ref (c-compressor-size-pointer compressor) :size)))

(defstruct (c-decompressor (:constructor %make-c-decompressor))
  (input nil)
  (input-size 0 :type fixnum)
  (output nil)
  (output-capacity 0 :type fixnum)
  (size-pointer nil))

(defun make-c-decompressor (encoded uncompressed-size)
  (let* ((n (length encoded))
         (capacity (max 1 uncompressed-size)))
    (%make-c-decompressor
     :input (foreign-octets encoded)
     :input-size n
     :output (cffi:foreign-alloc :unsigned-char :count capacity)
     :output-capacity capacity
     :size-pointer (cffi:foreign-alloc :size))))

(defun free-c-decompressor (decompressor)
  (when decompressor
    (cffi:foreign-free (c-decompressor-input decompressor))
    (cffi:foreign-free (c-decompressor-output decompressor))
    (cffi:foreign-free (c-decompressor-size-pointer decompressor))))

(defun c-decompress-core (decompressor)
  "Call BrotliDecoderDecompress once; return the decoded size."
  (let ((size-pointer (c-decompressor-size-pointer decompressor)))
    (setf (cffi:mem-ref size-pointer :size)
          (c-decompressor-output-capacity decompressor))
    (let ((ok (cl-brotli.reference:brotli-decoder-decompress
               (c-decompressor-input-size decompressor)
               (if (zerop (c-decompressor-input-size decompressor))
                   (cffi:null-pointer)
                   (c-decompressor-input decompressor))
               size-pointer
               (c-decompressor-output decompressor))))
      (unless (plusp ok)
        (error "C Brotli decompression failed"))
      (cffi:mem-ref size-pointer :size))))

(defun c-decompressor-result (decompressor)
  (foreign-to-octets (c-decompressor-output decompressor)
                     (cffi:mem-ref (c-decompressor-size-pointer decompressor) :size)))

;;; ------------------------------------------------------------------
;;; Datasets
;;; ------------------------------------------------------------------

(defparameter *default-size* (* 1024 1024))

(defparameter *dataset-names*
  '(:text :html :json :source :binary :zeros :random :periodic :pattern :dict :utf8))

(defparameter *default-datasets* *dataset-names*)

(defun project-root ()
  (asdf:system-source-directory "cl-brotli"))

(defun read-file-octets (path &key max)
  (with-open-file (stream path :direction :input
                               :element-type '(unsigned-byte 8))
    (let* ((available (file-length stream))
           (n (if max (min available max) available))
           (octets (make-array n :element-type '(unsigned-byte 8))))
      (read-sequence octets stream)
      octets)))

(defun concatenate-octets (parts)
  (let* ((total (reduce #'+ parts :key #'length :initial-value 0))
         (out (make-array total :element-type '(unsigned-byte 8)))
         (pos 0))
    (dolist (part parts out)
      (replace out part :start1 pos)
      (incf pos (length part)))))

(defun tile-octets (octets n)
  "Return N octets taken from OCTETS, repeating it when it is shorter."
  (let ((m (length octets)))
    (cond
      ((zerop n) (make-array 0 :element-type '(unsigned-byte 8)))
      ((zerop m) (error "cannot tile an empty octet vector"))
      ((= n m) octets)
      ((< n m) (subseq octets 0 n))
      (t
       (let ((out (make-array n :element-type '(unsigned-byte 8))))
         (loop for start from 0 below n by m
               do (replace out octets
                           :start1 start
                           :end1 (min n (+ start m))))
         out)))))

(defun first-existing (paths)
  (find-if #'probe-file paths))

(defun fnv1a32 (octets)
  "32-bit FNV-1a fingerprint of OCTETS, as a hex string.
The harness prints this for every dataset so that runs on different hosts
(and runs where a real corpus file is missing) can be compared only when the
input bytes actually match."
  (declare (type (simple-array (unsigned-byte 8) (*)) octets)
           (optimize (speed 3) (safety 0)))
  (let ((hash #x811C9DC5))
    (declare (type (unsigned-byte 32) hash))
    (dotimes (i (length octets))
      (setf hash (logand #xFFFFFFFF
                         (* (logxor hash (aref octets i)) #x01000193))))
    (format nil "~8,'0X" hash)))

(defun repo-source-octets ()
  (let* ((root (project-root))
         (files (append
                 (directory (merge-pathnames "src/*.lisp" root))
                 (directory (merge-pathnames "src/*.lisp" root))
                 (list (merge-pathnames "README.md" root)
                       (merge-pathnames "NOTICE" root)
                       (merge-pathnames "tests/brotli-test.lisp" root))))
         (files (remove-if-not #'probe-file files)))
    (concatenate-octets (mapcar #'read-file-octets files))))

(defun external-source-octets ()
  "A source corpus outside this repository, so benchmark data does not change
when cl-brotli itself is edited."
  (let* ((home (user-homedir-pathname))
         (dirs (list (merge-pathnames "cl-newzlib/src/" home)
                     (merge-pathnames "pesekey/pesekey/src/" home)))
         (files (loop for dir in dirs
                      when (probe-file dir)
                        append (directory (merge-pathnames "*.lisp" dir)))))
    (if files
        (concatenate-octets (mapcar #'read-file-octets files))
        (repo-source-octets))))

(defun make-random-octets (n &optional (seed #x9E3779B9))
  (let ((out (make-array n :element-type '(unsigned-byte 8)))
        (x (logand seed #xFFFFFFFF)))
    (dotimes (i n out)
      (setf x (logand #xFFFFFFFF (logxor x (ash x 13))))
      (setf x (logand #xFFFFFFFF (logxor x (ash x -17))))
      (setf x (logand #xFFFFFFFF (logxor x (ash x 5))))
      (setf (aref out i) (logand x #xFF)))))

(defun make-ramp-octets (n)
  (let ((out (make-array n :element-type '(unsigned-byte 8))))
    (dotimes (i n out)
      (setf (aref out i) (mod i 256)))))

(defun make-pattern-octets (n &optional (period 256) (seed #x12345678))
  (let ((pattern (make-random-octets period seed)))
    (tile-octets pattern n)))

(defun make-utf8-octets (n)
  (let ((sample (flexi-streams:string-to-octets
                 (concatenate 'string
                              "Привет, мир! Это проверка UTF-8 текста. "
                              "你好，世界！这是一个 UTF-8 测试。 "
                              "¡Hola! ¿Qué tal? Ça va bien. "
                              "日本語のテキストも含まれます。 "
                              "Emoji: 😀 🚀 📦 ✅. "
                              "Καλημέρα κόσμε. مرحبا بالعالم. ")
                 :external-format :utf-8)))
    (tile-octets sample n)))

(defun json-source-path ()
  (first-existing
   (list #p"/home/turtle/.ghcup/ghc/9.10.3/share/doc/ghc-9.10.3/html/libraries/base-4.20.2.0-9cd7/doc-index.json"
         #p"/home/turtle/.ghcup/ghc/9.10.3/share/doc/ghc-9.10.3/html/libraries/ghc-internal-9.1003.0-b213/doc-index.json")))

(defun make-json-octets (n)
  "Use a real JSON document when available, otherwise generate records.
Both branches are deterministic for a given N and source file."
  (let ((path (json-source-path)))
    (if path
        (tile-octets (read-file-octets path :max n) n)
        ;; Fallback: deterministic JSON-like records.
        (let ((out (make-array n :element-type '(unsigned-byte 8) :fill-pointer 0))
              (s 1234567))
          (flet ((emit (string)
                   (loop for ch across string
                         while (< (fill-pointer out) n)
                         do (vector-push (char-code ch) out)))
                 (rnd (bound)
                   (setf s (logand (+ (* s 1103515245) 12345) #x7FFFFFFF))
                   (mod s bound)))
            (emit "[")
            (loop while (< (fill-pointer out) n)
                  do (emit (format nil
                                   "{\"id\":~D,\"name\":\"user~D\",\"active\":~A,\"score\":~D},"
                                   (rnd 1000000) (rnd 1000000)
                                   (if (zerop (rnd 2)) "true" "false")
                                   (rnd 1000))))
            (coerce out '(simple-array (unsigned-byte 8) (*))))))))

(defparameter *html-words*
  #("compression" "benchmark" "encoder" "decoder" "stream" "window" "huffman"
    "literal" "distance" "context" "block" "transform" "dictionary" "quality"
    "throughput" "ratio" "buffer" "octets" "length" "symbol" "table" "prefix"
    "command" "metablock" "reference" "implementation" "performance" "dataset"))

(defun make-html-octets (n)
  "Deterministic HTML-like document used when no system HTML corpus is found.
Keeps the dataset meaningful on minimal hosts instead of silently tiling
Common Lisp source, which would make HTML nearly identical to SOURCE."
  (let ((out (make-array n :element-type '(unsigned-byte 8) :fill-pointer 0))
        (s 7654321)
        (words (length *html-words*)))
    (labels ((emit (string)
               (loop for ch across string
                     while (< (fill-pointer out) n)
                     do (vector-push (char-code ch) out)))
             (rnd (bound)
               (setf s (logand (+ (* s 1103515245) 12345) #x7FFFFFFF))
               (mod s bound))
             (word () (aref *html-words* (rnd words))))
      (emit "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>Brotli benchmark corpus</title></head><body>\n")
      (loop while (< (fill-pointer out) n)
            do (emit (format nil
                             "<div class=\"item\" id=\"row-~D\"><h2>~A ~D</h2><p>~A ~A ~A, ~A ~A.</p><ul><li>~A: ~D</li><li>~A: ~D</li></ul><a href=\"/~A/~D\">~A</a></div>\n"
                             (rnd 1000000) (word) (rnd 1000000)
                             (word) (word) (word) (word) (word)
                             (word) (rnd 10000) (word) (rnd 10000)
                             (word) (rnd 1000000) (word))))
      (emit "</body></html>\n")
      (coerce out '(simple-array (unsigned-byte 8) (*))))))

(defun %make-dataset (name size)
  (ecase name
    (:text
     (let ((path (first-existing
                  (list #p"/usr/share/common-licenses/GPL-3"
                        (merge-pathnames "README.md" (project-root))))))
       (list :name "text"
             :description (namestring path)
             :data (tile-octets (read-file-octets path) size))))
    (:html
     (let ((path (first-existing
                  (list #p"/usr/share/doc/rclone/MANUAL.html"
                        #p"/usr/share/doc/fish/relnotes.html"))))
       (if path
           (list :name "html"
                 :description (namestring path)
                 :data (tile-octets (read-file-octets path :max size) size))
           (list :name "html"
                 :description "generated HTML records"
                 :data (make-html-octets size)))))
    (:json
     (list :name "json"
           :description (if (json-source-path)
                            (namestring (json-source-path))
                            "generated JSON records")
           :data (make-json-octets size)))
    (:source
     (list :name "source"
           ;; Say which corpus was actually used: the fallback is this
           ;; repository's own src/, which changes whenever cl-brotli is
           ;; edited (its fingerprint then differs run to run).
           :description (if (some #'probe-file
                                  (list (merge-pathnames "cl-newzlib/src/" (user-homedir-pathname))
                                        (merge-pathnames "pesekey/pesekey/src/" (user-homedir-pathname))))
                            "cl-newzlib + pesekey source (stable corpus)"
                            "FALLBACK: cl-brotli's own src/ (not stable across edits)")
           :data (tile-octets (external-source-octets) size)))
    (:binary
     (let ((path (first-existing
                  (list #p"/home/turtle/.roswell/impls/x86-64/linux/sbcl-bin/2.6.9/bin/sbcl"
                        #p"/usr/local/bin/sbcl"
                        #p"/usr/bin/sbcl"
                        #p"/usr/bin/bash"
                        #p"/bin/bash"))))
       (unless path
         (error "no binary dataset file found"))
       (list :name "binary"
             :description (namestring path)
             :data (tile-octets (read-file-octets path :max size) size))))
    (:zeros
     (list :name "zeros"
           :description "generated zeroes"
           :data (make-array size :element-type '(unsigned-byte 8)
                                  :initial-element 0)))
    (:random
     (list :name "random"
           :description "generated xorshift32 bytes"
           :data (make-random-octets size)))
    (:periodic
     (list :name "periodic"
           :description "0..255 ramp repeated"
           :data (make-ramp-octets size)))
    (:pattern
     (list :name "pattern"
           :description "256-byte pseudo-random pattern repeated"
           :data (make-pattern-octets size)))
    (:dict
     (let ((path (merge-pathnames "tests/vectors/dict.raw" (project-root))))
       (if (probe-file path)
           (list :name "dict"
                 :description "Brotli dictionary test vector, tiled"
                 :data (tile-octets (read-file-octets path) size))
           (list :name "dict"
                 :description "repository source"
                 :data (tile-octets (repo-source-octets) size)))))
    (:utf8
     (list :name "utf8"
           :description "multilingual UTF-8 text"
           :data (make-utf8-octets size)))))

(defun make-dataset (name size)
  "Build dataset NAME of SIZE octets and attach a content fingerprint."
  (let* ((spec (%make-dataset name size))
         (data (getf spec :data)))
    (setf (getf spec :hash) (fnv1a32 data))
    spec))

;;; ------------------------------------------------------------------
;;; Timing and reporting
;;; ------------------------------------------------------------------

(defun full-gc ()
  #+sbcl (sb-ext:gc :full t)
  #-sbcl (values))

(defun median (values)
  (let* ((sorted (sort (copy-list values) #'<))
         (n (length sorted)))
    (nth (floor n 2) sorted)))

(defun now-seconds ()
  "Microsecond-resolution wall clock; GET-INTERNAL-REAL-TIME is too coarse
for sub-millisecond operations on some builds (it reports zero ticks for a
single fast decode)."
  #+sbcl (multiple-value-bind (sec usec) (sb-ext:get-time-of-day)
           (+ (coerce sec 'double-float) (/ usec 1000000.0d0)))
  #-sbcl (/ (get-internal-real-time) 1.0d0 internal-time-units-per-second))

(defun time-reps (thunk reps)
  (let ((start (now-seconds)))
    (dotimes (i reps)
      (declare (ignore i))
      (funcall thunk))
    (/ (- (now-seconds) start) reps)))

(defun measure (thunk &key (target 0.2) (samples 3) (max-reps 1000))
  "Return (values MEDIAN BEST REPS) seconds per call."
  (funcall thunk)
  (let* ((one (max (time-reps thunk 1) 1e-7))
         (reps (max 1 (min max-reps (floor target one))))
         (times (loop repeat samples
                      collect (progn
                                (full-gc)
                                (time-reps thunk reps)))))
    (values (median times) (reduce #'min times) reps)))

(defun measure-pair (thunk-a thunk-b &key (target 0.2) (samples 3) (max-reps 1000))
  "Alternate A/B samples and return their medians."
  (funcall thunk-a)
  (funcall thunk-b)
  (let* ((one-a (max (time-reps thunk-a 1) 1e-7))
         (one-b (max (time-reps thunk-b 1) 1e-7))
         (reps-a (max 1 (min max-reps (floor target one-a))))
         (reps-b (max 1 (min max-reps (floor target one-b))))
         (times-a '())
         (times-b '()))
    (dotimes (i samples)
      (declare (ignore i))
      (full-gc)
      (push (time-reps thunk-a reps-a) times-a)
      (push (time-reps thunk-b reps-b) times-b))
    (values (median times-a) (median times-b))))

(defun format-size (octets)
  "Human-readable size for report headings; keeps 0/1/10/1K distinct."
  (cond ((< octets 1024) (format nil "~D B" octets))
        ((< octets (* 1024 1024))
         (format nil "~,1f KiB" (/ octets 1024.0)))
        (t (format nil "~,2f MiB" (/ octets 1048576.0)))))

(defun mib-per-second (octets seconds)
  (if (or (zerop octets) (zerop seconds))
      0.0
      (/ octets 1048576.0 seconds)))

(defun speed-ratio (a b)
  (if (or (zerop a) (zerop b))
      0.0
      (/ a b)))

(defun geometric-mean (values)
  (let ((values (remove-if-not #'plusp values)))
    (if values
        (exp (/ (loop for value in values sum (log value)) (length values)))
        0.0)))

(defun measure-consing (thunk &key (reps 1))
  "Return Lisp bytes consed per call.  Foreign C-core allocation is not
included; this is mostly useful for the lisp Lisp side and the CFFI wrapper."
  (funcall thunk)
  (let ((before (sb-ext:get-bytes-consed)))
    (dotimes (i reps)
      (declare (ignore i))
      (funcall thunk))
    (/ (- (sb-ext:get-bytes-consed) before) reps)))

(defstruct bench-row
  dataset
  description
  data-hash
  size
  mode
  lgwin
  level
  c-size
  lisp-size
  c-comp-core
  c-comp-one-shot
  lisp-comp
  c-decomp-core
  c-decomp-one-shot
  lisp-decomp
  lisp-stream-c-decomp
  lisp-stream-lisp-decomp
  lisp-comp-consed
  c-comp-consed
  lisp-decomp-consed
  c-decomp-consed)

(defun print-table-row (fmt &rest args)
  (apply #'format t fmt args)
  (terpri))

(defun print-header (options)
  (format t "~&=== cl-brotli vs C Brotli ===~%")
  (format t "Lisp:  ~A ~A~%" (lisp-implementation-type)
          (lisp-implementation-version))
  (format t "C Brotli: ~A~%" (brotli-version-string))
  (format t "Sizes: ~{~A~^, ~}   Datasets: ~{~A~^, ~}~%"
          (mapcar #'format-size (getf options :sizes))
          (mapcar #'symbol-name (getf options :datasets)))
  (format t "C/lisp levels: ~{~D~^, ~}   Windows: ~{~D~^, ~}   Modes: ~{~D~^, ~}~%"
          (getf options :levels) (getf options :windows) (getf options :modes))
  (format t "Samples: ~D   Target: ~,2fs   Consing: ~A~%"
          (getf options :samples) (getf options :target)
          (if (getf options :consing) "on" "off"))
  (let ((cpu (ignore-errors
               (with-open-file (stream "/proc/cpuinfo")
                 (loop for line = (read-line stream nil)
                       while line
                       when (search "model name" line)
                         do (return (string-trim " "
                                                 (subseq line
                                                         (1+ (position #\: line))))))))))
    (when cpu (format t "CPU:   ~A~%" cpu)))
  (format t "~%"))

(defun print-compression-table (rows)
  (print-table-row "| C q | lgwin | mode | C size | lisp size | lisp/C size | C core MiB/s | C one-shot MiB/s | lisp MiB/s | lisp/C core | lisp/C one-shot |")
  (print-table-row "|----:|------:|-----:|-------:|----------:|------------:|-------------:|-----------------:|-----------:|------------:|----------------:|")
  (dolist (r rows)
    (let* ((n (bench-row-size r))
           (c-size (bench-row-c-size r))
           (lisp-size (bench-row-lisp-size r))
           (c-core (mib-per-second n (bench-row-c-comp-core r)))
           (c-one (mib-per-second n (bench-row-c-comp-one-shot r)))
           (lisp (mib-per-second n (bench-row-lisp-comp r))))
      (print-table-row "| ~D | ~D | ~D | ~D | ~D | ~,3f | ~,1f | ~,1f | ~,1f | ~,2fx | ~,2fx |"
                       (bench-row-level r) (bench-row-lgwin r) (bench-row-mode r)
                       c-size lisp-size
                       (if (zerop c-size) 0.0 (/ lisp-size (float c-size)))
                       c-core c-one lisp
                       (speed-ratio lisp c-core)
                       (speed-ratio lisp c-one)))))

(defun print-decompression-table (rows)
  (print-table-row "| C q | lgwin | mode | C core MiB/s | C one-shot MiB/s | lisp MiB/s | lisp/C core | lisp/C one-shot |")
  (print-table-row "|----:|------:|-----:|-------------:|-----------------:|-----------:|------------:|----------------:|")
  (dolist (r rows)
    (let* ((n (bench-row-size r))
           (c-core (mib-per-second n (bench-row-c-decomp-core r)))
           (c-one (mib-per-second n (bench-row-c-decomp-one-shot r)))
           (lisp (mib-per-second n (bench-row-lisp-decomp r))))
      (print-table-row "| ~D | ~D | ~D | ~,1f | ~,1f | ~,1f | ~,2fx | ~,2fx |"
                       (bench-row-level r) (bench-row-lgwin r) (bench-row-mode r)
                       c-core c-one lisp
                       (speed-ratio lisp c-core)
                       (speed-ratio lisp c-one)))))

(defun print-lisp-stream-table (rows)
  (let ((n (bench-row-size (first rows))))
    (print-table-row "| C q | C decode MiB/s | lisp decode MiB/s | lisp/C |")
    (print-table-row "|----:|---------------:|-------------------:|--------:|")
    (dolist (row (remove-duplicates rows :key #'bench-row-level))
      (let ((c (mib-per-second n (bench-row-lisp-stream-c-decomp row)))
            (lisp (mib-per-second n (bench-row-lisp-stream-lisp-decomp row))))
        (print-table-row "| ~D | ~,1f | ~,1f | ~,2fx |"
                         (bench-row-level row) c lisp
                         (speed-ratio lisp c))))))

(defun print-consing-table (row)
  (print-table-row "| operation | lisp Lisp consed | C one-shot consed |")
  (print-table-row "|-----------|-----------------:|------------------:|")
  (print-table-row "| compress | ~D | ~D |"
                   (bench-row-lisp-comp-consed row)
                   (bench-row-c-comp-consed row))
  (print-table-row "| decompress (C stream) | ~D | ~D |"
                   (bench-row-lisp-decomp-consed row)
                   (bench-row-c-decomp-consed row)))

(defun print-dataset-report (rows dataset size description)
  (format t "## ~A — ~A [fnv1a32=~A] (~A)~%~%"
          dataset description (bench-row-data-hash (first rows))
          (format-size size))
  (format t "### compression~%~%")
  (print-compression-table rows)
  (format t "~%### decompression of the C stream~%~%")
  (print-decompression-table rows)
  (format t "~%### lisp-encoded stream: decoder comparison~%~%")
  (print-lisp-stream-table rows)
  (when (bench-row-lisp-comp-consed (first rows))
    (format t "~%### Lisp allocation (bytes consed per call; C core foreign allocation excluded)~%~%")
    (print-consing-table (first rows)))
  (format t "~%"))

(defun print-summary (all-rows)
  (format t "## Summary (geometric mean lisp/C, grouped by size/mode/lgwin/q)~%~%")
  (print-table-row "| size | mode | lgwin | C q | size (lisp/C) | comp core (lisp/C) | comp 1-shot (lisp/C) | decomp core (lisp/C) | decomp 1-shot (lisp/C) |")
  (print-table-row "|-----:|-----:|------:|----:|--------------:|-------------------:|---------------------:|---------------------:|-----------------------:|")
  (let ((keys (remove-duplicates
               (mapcar (lambda (r)
                         (list (bench-row-size r) (bench-row-mode r)
                               (bench-row-lgwin r) (bench-row-level r)))
                       all-rows)
               :test #'equal)))
    (dolist (key keys)
      (destructuring-bind (size mode lgwin level) key
        (let ((rows (remove-if-not
                     (lambda (r)
                       (and (= (bench-row-size r) size)
                            (= (bench-row-mode r) mode)
                            (= (bench-row-lgwin r) lgwin)
                            (= (bench-row-level r) level)))
                     all-rows)))
          (print-table-row "| ~A | ~D | ~D | ~D | ~,3f | ~,2fx | ~,2fx | ~,2fx | ~,2fx |"
                           (format-size size) mode lgwin level
                           (geometric-mean
                            (mapcar (lambda (r)
                                      (if (zerop (bench-row-c-size r))
                                          0.0
                                          (/ (bench-row-lisp-size r)
                                             (float (bench-row-c-size r)))))
                                    rows))
                           (geometric-mean
                            (mapcar (lambda (r)
                                      (speed-ratio (bench-row-c-comp-core r)
                                                   (bench-row-lisp-comp r)))
                                    rows))
                           (geometric-mean
                            (mapcar (lambda (r)
                                      (speed-ratio (bench-row-c-comp-one-shot r)
                                                   (bench-row-lisp-comp r)))
                                    rows))
                           (geometric-mean
                            (mapcar (lambda (r)
                                      (speed-ratio (bench-row-c-decomp-core r)
                                                   (bench-row-lisp-decomp r)))
                                    rows))
                           (geometric-mean
                            (mapcar (lambda (r)
                                      (speed-ratio (bench-row-c-decomp-one-shot r)
                                                   (bench-row-lisp-decomp r)))
                                    rows)))))))
  (format t "~%"))

;;; ------------------------------------------------------------------
;;; Benchmark core
;;; ------------------------------------------------------------------

(defun validate-lisp-stream (data lisp-compressed)
  (unless (equalp data (cl-brotli:decompress lisp-compressed))
    (error "lisp stream did not decode with cl-brotli"))
  (unless (equalp data (cl-brotli.reference:decompress lisp-compressed))
    (error "lisp stream did not decode with the C reference")))

(defun validate-c-stream (data c-compressed level lgwin mode)
  (unless (equalp data (cl-brotli:decompress c-compressed))
    (error "C stream did not decode with cl-brotli (q~D lgwin ~D mode ~D)"
           level lgwin mode))
  (unless (equalp data (cl-brotli.reference:decompress c-compressed))
    (error "C stream did not decode with the C reference (q~D lgwin ~D mode ~D)"
           level lgwin mode)))

(defun benchmark-dataset (dataset-name size options)
  (let* ((spec (make-dataset dataset-name size))
         (data (getf spec :data))
         (n (length data))
         (samples (getf options :samples))
         (target (getf options :target))
         (consing (getf options :consing))
         (rows '()))
    ;; Level is the outer loop: the lisp encoder has no mode/window knob, so
    ;; its stream, timing, and decode pair are reused across C mode/window
    ;; variants instead of being recomputed for every cell.
    (dolist (level (getf options :levels))
      ;; One compressor per cell: its closure keeps the encoder's big
      ;; arrays across calls, so the timing measures steady-state
      ;; compression (the production pattern for a multi-threaded
      ;; server) instead of paying the per-call large-object GC tax
      ;; that the plain one-shot COMPRESS pays.  Output is byte-
      ;; identical to plain COMPRESS (tested), so sizes and validation
      ;; are unaffected; the plain numbers are recorded in
      ;; bench/GAP-ANALYSIS.md (Rev 147).
      (let* ((lisp-press (cl-brotli:make-compressor))
             (lisp-compressed (funcall lisp-press data :quality level))
             (lisp-size (length lisp-compressed))
             (lisp-comp-time nil)
             (lisp-comp-consed nil)
             (lisp-stream-c-time nil)
             (lisp-stream-lisp-time nil))
        (validate-lisp-stream data lisp-compressed)
        (multiple-value-bind (median best reps)
            (measure (lambda () (funcall lisp-press data :quality level))
                     :target target :samples samples)
          (declare (ignore best reps))
          (setf lisp-comp-time median))
        (when consing
          (setf lisp-comp-consed
                (measure-consing
                 (lambda () (funcall lisp-press data :quality level)))))
        ;; Decode the lisp stream with both decoders once per level.
        (let ((lcd (make-c-decompressor lisp-compressed n)))
          (unwind-protect
               (multiple-value-bind (c-time lisp-time)
                   (measure-pair (lambda () (c-decompress-core lcd))
                                 (lambda () (cl-brotli:decompress lisp-compressed))
                                 :target target :samples samples)
                 (setf lisp-stream-c-time c-time
                       lisp-stream-lisp-time lisp-time))
            (free-c-decompressor lcd)))
        (dolist (mode (getf options :modes))
          (dolist (lgwin (getf options :windows))
            (let ((cc (make-c-compressor data)))
              (unwind-protect
                   (let* ((c-size (c-compress-core cc level lgwin mode))
                          (c-compressed (c-compressor-result cc))
                          (c-one-shot (cl-brotli.reference:compress
                                       data :quality level :lgwin lgwin :mode mode)))
                     (unless (= (length c-one-shot) c-size)
                       (error "C core and one-shot sizes differ (~D vs ~D) for ~A q~D lgwin ~D mode ~D"
                              c-size (length c-one-shot) dataset-name level lgwin mode))
                     (unless (equalp c-compressed c-one-shot)
                       (error "C core and one-shot outputs differ for ~A q~D lgwin ~D mode ~D"
                              dataset-name level lgwin mode))
                     (validate-c-stream data c-compressed level lgwin mode)
                     ;; Time C core vs C one-shot compression.
                     (multiple-value-bind (c-core-time c-one-time)
                         (measure-pair (lambda () (c-compress-core cc level lgwin mode))
                                       (lambda () (cl-brotli.reference:compress
                                                   data :quality level :lgwin lgwin :mode mode))
                                       :target target :samples samples)
                       ;; Validate and time lisp vs C-core decode of the C stream.
                       (let ((cd (make-c-decompressor c-compressed n)))
                         (unwind-protect
                              (progn
                                (c-decompress-core cd)
                                (let ((decoded (c-decompressor-result cd)))
                                  (unless (equalp decoded data)
                                    (error "C core decode mismatch for ~A q~D"
                                           dataset-name level))))
                           (free-c-decompressor cd)))
                       (let ((cd (make-c-decompressor c-compressed n)))
                         (unwind-protect
                              (multiple-value-bind (c-dec-core lisp-dec)
                                  (measure-pair (lambda () (c-decompress-core cd))
                                                (lambda () (cl-brotli:decompress c-compressed))
                                                :target target :samples samples)
                                (multiple-value-bind (c-dec-core-2 c-dec-one)
                                    (measure-pair (lambda () (c-decompress-core cd))
                                                  (lambda () (cl-brotli.reference:decompress c-compressed))
                                                  :target target :samples samples)
                                  (declare (ignore c-dec-core-2))
                                  (let ((row (make-bench-row
                                              :dataset dataset-name
                                              :description (getf spec :description)
                                              :data-hash (getf spec :hash)
                                              :size n :mode mode :lgwin lgwin :level level
                                              :c-size c-size
                                              :lisp-size lisp-size
                                              :c-comp-core c-core-time
                                              :c-comp-one-shot c-one-time
                                              :lisp-comp lisp-comp-time
                                              :c-decomp-core c-dec-core
                                              :c-decomp-one-shot c-dec-one
                                              :lisp-decomp lisp-dec
                                              :lisp-stream-c-decomp lisp-stream-c-time
                                              :lisp-stream-lisp-decomp lisp-stream-lisp-time
                                              :lisp-comp-consed lisp-comp-consed
                                              :c-comp-consed
                                              (and consing
                                                   (measure-consing
                                                    (lambda ()
                                                      (cl-brotli.reference:compress
                                                       data :quality level
                                                       :lgwin lgwin :mode mode))))
                                              :lisp-decomp-consed
                                              (and consing
                                                   (measure-consing
                                                    (lambda ()
                                                      (cl-brotli:decompress c-compressed))))
                                              :c-decomp-consed
                                              (and consing
                                                   (measure-consing
                                                    (lambda ()
                                                      (cl-brotli.reference:decompress
                                                       c-compressed)))))))
                                    (push row rows)))))
                           (free-c-decompressor cd)))))
                (free-c-compressor cc))))))
    (nreverse rows)))

(defun run-benchmark (&optional (options nil))
  (setf options (or options (parse-args nil)))
  (print-header options)
  (let ((all-rows '()))
    (dolist (size (getf options :sizes))
      (dolist (name (getf options :datasets))
        (format *error-output* "~&  ~A @ ~A~%" name (format-size size))
        (let ((rows (benchmark-dataset name size options)))
          (when rows
            (print-dataset-report rows (bench-row-dataset (first rows)) size
                                  (bench-row-description (first rows)))
            (setf all-rows (append all-rows rows))))))
    (when all-rows
      (print-summary all-rows)
      (when (getf options :csv)
        (write-csv (getf options :csv) all-rows)))
    all-rows))

;;; ------------------------------------------------------------------
;;; CSV output
;;; ------------------------------------------------------------------

(defun csv-escape (value)
  (let ((string (if (floatp value)
                    ;; SBCL prints double floats as 1.5d0, which spreadsheet
                    ;; and CSV tools do not parse.
                    (format nil "~,12f" value)
                    (princ-to-string value))))
    (if (or (find #\, string) (find #\" string) (find #\Newline string))
        (with-output-to-string (out)
          (write-char #\" out)
          (loop for ch across string
                do (if (char= ch #\")
                       (write-string "\"\"" out)
                       (write-char ch out)))
          (write-char #\" out))
        string)))

(defun write-csv (path rows)
  (with-open-file (stream path :direction :output :if-exists :supersede
                               :if-does-not-exist :create)
    (let ((columns '(dataset description data-hash size mode lgwin level c-size lisp-size
                      c-comp-core c-comp-one-shot lisp-comp
                      c-decomp-core c-decomp-one-shot lisp-decomp
                      lisp-stream-c-decomp lisp-stream-lisp-decomp
                      lisp-comp-consed c-comp-consed
                      lisp-decomp-consed c-decomp-consed)))
      (format stream "~{~A~^,~}~%" (mapcar #'string-downcase
                                           (mapcar #'symbol-name columns)))
      (dolist (row rows)
        (format stream "~{~A~^,~}~%"
                (mapcar (lambda (column)
                          (let ((accessor
                                  (intern (format nil "BENCH-ROW-~A"
                                                  (symbol-name column))
                                          'cl-brotli-bench)))
                            (csv-escape (funcall accessor row))))
                        columns))))))

;;; ------------------------------------------------------------------
;;; Command line
;;; ------------------------------------------------------------------

(defun usage ()
  (format t "~&Usage: bench/run.sh [options]~%~%")
  (format t "  --size N          dataset size (default 1MiB; K/M/G suffixes)~%")
  (format t "  --sizes LIST      multiple sizes, e.g. 0,1K,1M,16M~%")
  (format t "  --datasets LIST   ~{~A~^, ~} (default all)~%"
          *dataset-names*)
  (format t "  --levels LIST     C and lisp quality levels (default 0..11)~%")
  (format t "  --windows LIST    C lgwin values (default 22)~%")
  (format t "  --modes LIST      C modes (default 0; 0=generic, 1=text, 2=font)~%")
  (format t "  --samples N       timed samples per measurement (default 3)~%")
  (format t "  --target SECONDS  minimum time per sample (default 0.2)~%")
  (format t "  --consing         also report Lisp bytes consed per call~%")
  (format t "  --csv FILE        write raw rows to FILE~%")
  (format t "  --quick           --size 1M --levels 0,5,11 --samples 1 --target 0.1~%")
  (format t "  --help            show this help~%"))

(defun parse-size (string)
  (multiple-value-bind (number end)
      (parse-integer string :junk-allowed t)
    (unless number
      (error "invalid size: ~S" string))
    (let* ((suffix (string-downcase (string-trim " " (subseq string end))))
           (multiplier (cond
                         ((member suffix '("" "b") :test #'string=) 1)
                         ((member suffix '("k" "kb" "kib") :test #'string=) 1024)
                         ((member suffix '("m" "mb" "mib") :test #'string=)
                          (* 1024 1024))
                         ((member suffix '("g" "gb" "gib") :test #'string=)
                          (* 1024 1024 1024))
                         (t (error "invalid size suffix: ~S" suffix)))))
      (* number multiplier))))

(defun split-comma (string)
  (loop with start = 0
        for comma = (position #\, string :start start)
        collect (string-trim " " (subseq string start comma))
        while comma
        do (setf start (1+ comma))))

(defun parse-integers (string)
  (mapcar (lambda (part)
            (or (parse-integer part :junk-allowed nil)
                (error "invalid integer: ~S" part)))
          (split-comma string)))

(defun parse-sizes (string)
  (mapcar #'parse-size (split-comma string)))

(defun parse-datasets (string)
  (mapcar (lambda (part)
            (let ((keyword (intern (string-upcase part) :keyword)))
              (unless (member keyword *dataset-names*)
                (error "unknown dataset: ~S (expected one of ~{~A~^, ~})"
                       part (mapcar #'symbol-name *dataset-names*)))
              keyword))
          (split-comma string)))

(defun parse-args (argv)
  (let ((options (list :sizes (list *default-size*)
                       :datasets *default-datasets*
                       :levels (loop for i from 0 to 11 collect i)
                       :windows '(22)
                       :modes '(0)
                       :samples 3
                       :target 0.2
                       :consing nil
                       :csv nil)))
    (loop while argv
          for key = (pop argv)
          do (cond
               ((string= key "--help")
                (usage)
                (sb-ext:exit :code 0))
               ((string= key "--quick")
                (setf (getf options :sizes) (list (* 1024 1024))
                      (getf options :levels) '(0 5 11)
                      (getf options :samples) 1
                      (getf options :target) 0.1))
               ((string= key "--size")
                (setf (getf options :sizes) (list (parse-size (pop argv)))))
               ((string= key "--sizes")
                (setf (getf options :sizes) (parse-sizes (pop argv))))
               ((string= key "--datasets")
                (setf (getf options :datasets) (parse-datasets (pop argv))))
               ((string= key "--levels")
                (setf (getf options :levels) (parse-integers (pop argv))))
               ((string= key "--windows")
                (setf (getf options :windows) (parse-integers (pop argv))))
               ((string= key "--modes")
                (setf (getf options :modes) (parse-integers (pop argv))))
               ((string= key "--samples")
                (setf (getf options :samples) (parse-integer (pop argv))))
               ((string= key "--target")
                (setf (getf options :target) (read-from-string (pop argv))))
               ((string= key "--consing")
                (setf (getf options :consing) t))
               ((string= key "--csv")
                (setf (getf options :csv) (pop argv)))
               (t (error "unknown option: ~S (try --help)" key))))
    options))

(defun main ()
  (let ((argv (rest sb-ext:*posix-argv*)))
    (when (and argv (string= (first argv) "--"))
      (pop argv))
    (handler-case
        (run-benchmark (parse-args argv))
      (error (e)
        (format *error-output* "~&benchmark failed: ~A~%" e)
        (sb-ext:exit :code 1)))))
