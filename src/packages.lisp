(defpackage #:cl-brotli.lisp.bitio
  (:use #:cl)
  (:export #:octets #:to-octets
           #:brd #:make-brd #:rbit #:rbits #:r-align #:r-bytes #:r-eof-p
           #:peek-bits #:bits-available
           #:brd-bytes #:brd-pos #:brd-end #:brd-acc #:brd-nbits #:brd-sap #:%word-at
           #:bwr #:make-bwr #:wbits #:w-align #:w-bytes #:w-bytes-range #:bwr-out
           #:w-ensure #:%wbits-raw #:w-emit-run
           #:bwr-pos #:bwr-result))
(defpackage #:cl-brotli.lisp
  (:use #:cl)
  (:local-nicknames (#:b #:cl-brotli.lisp.bitio))
  (:export #:decompress #:compress #:brotli-error))
