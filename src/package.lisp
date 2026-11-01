(defpackage #:cl-brotli
  (:use #:cl)
  (:import-from #:cl-brotli.lisp
                #:compress
                #:decompress
                #:brotli-error)
  (:export #:compress
           #:decompress
           #:brotli-error))
