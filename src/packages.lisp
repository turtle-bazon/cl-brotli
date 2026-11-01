(defpackage #:cl-brotli.lisp.bitio
  (:use #:cl)
  (:export #:octets #:to-octets
           #:brd #:make-brd #:rbit #:rbits #:r-align #:r-bytes #:r-eof-p
           #:peek-bits #:bits-available
           #:bwr #:make-bwr #:wbits #:w-align #:w-bytes #:bwr-out))
(defpackage #:cl-brotli.lisp
  (:use #:cl)
  (:local-nicknames (#:b #:cl-brotli.lisp.bitio))
  (:export #:decompress #:compress #:brotli-error))
