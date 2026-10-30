(defpackage #:cl-brotli
  (:use #:cl)
  (:import-from #:cl-brotli.pure
                #:compress
                #:decompress
                #:brotli-error)
  (:export #:compress
           #:decompress
           #:brotli-error))
