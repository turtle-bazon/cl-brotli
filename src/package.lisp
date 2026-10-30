(defpackage #:cl-brotli
  (:use #:cl #:cffi)
  (:export #:compress
           #:decompress
           #:brotli-encoder-compress
           #:brotli-decoder-decompress
           #:brotli-encoder-max-compressed-size
           #:brotli-decoder-estimate-decompressed-size))
