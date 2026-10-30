(in-package #:cl-brotli/tests)

(def-suite brotli-suite :description "Brotli round trips")
(in-suite brotli-suite)

(test empty-roundtrip
  (is (equalp (cl-brotli:decompress (cl-brotli:compress (make-array 0 :element-type '(unsigned-byte 8))))
               (make-array 0 :element-type '(unsigned-byte 8)))))

(test string-roundtrip
  (let* ((s "hello brotli")
         (b (flexi-streams:string-to-octets s :external-format :utf-8))
         (d (cl-brotli:decompress (cl-brotli:compress b))))
    (is (equalp d b))))

(test binary-roundtrip
  (let* ((b (make-array 1000 :element-type '(unsigned-byte 8) :initial-element #xAB))
         (d (cl-brotli:decompress (cl-brotli:compress b))))
    (is (equalp d b))))
