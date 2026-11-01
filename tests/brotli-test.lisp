(in-package #:cl-brotli/tests)

(def-suite brotli-suite :description "Pure Brotli and CFFI reference differential")
(in-suite brotli-suite)

(defun octets (string)
  (flexi-streams:string-to-octets string :external-format :utf-8))

(defun slurp (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((out (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence out s)
      out)))

(test pure-empty-roundtrip
  (let ((data (make-array 0 :element-type '(unsigned-byte 8))))
    (is (equalp (cl-brotli:decompress (cl-brotli:compress data)) data))))

(test pure-text-roundtrip
  (let ((data (octets "the quick brown fox jumps over the lazy dog")))
    (is (equalp (cl-brotli:decompress (cl-brotli:compress data)) data))))

(test pure-binary-roundtrip
  (let ((data (make-array 10000 :element-type '(unsigned-byte 8))))
    (dotimes (i (length data)) (setf (aref data i) (mod (* i 37) 256)))
    (is (equalp (cl-brotli:decompress (cl-brotli:compress data)) data))))

(test pure-periodic-ramp-compresses
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

(test pure-multi-meta-block
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
      (cl-brotli.pure::out-copy out 0 2))))

(test reference-decode-vectors
  (let ((dir (merge-pathnames "tests/vectors/"
                              (asdf:system-source-directory "cl-brotli"))))
    (dolist (br (directory (merge-pathnames "*.br" dir)))
      (let* ((name (pathname-name br))
             (base (subseq name 0 (position #\. name)))
             (raw (merge-pathnames (format nil "~A.raw" base) dir)))
        (when (probe-file raw)
          (is (equalp (cl-brotli:decompress (slurp br)) (slurp raw))))))))

(test differential-pure-to-reference
  (let ((data (octets "hello brotli differential")))
    (is (equalp (cl-brotli.reference:decompress
                 (cl-brotli:compress data))
                data))))

(test differential-reference-to-pure
  (let ((data (octets "hello brotli differential")))
    (is (equalp (cl-brotli:decompress
                 (cl-brotli.reference:compress data))
                data))))

(test differential-random-sizes
  (dolist (n '(0 1 2 10 100 1000 10000))
    (let ((data (make-array n :element-type '(unsigned-byte 8))))
      (dotimes (i n) (setf (aref data i) (mod (* i 131) 251)))
      ;; Pure encoder must produce streams the C reference can decode.
      (is (equalp (cl-brotli.reference:decompress (cl-brotli:compress data)) data))
      ;; Pure decoder must decode streams the C reference produces.
      (is (equalp (cl-brotli:decompress (cl-brotli.reference:compress data)) data)))))
