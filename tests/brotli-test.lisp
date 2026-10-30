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
