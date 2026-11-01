(defpackage #:cl-brotli.pure.bitio
  (:use #:cl)
  (:export #:octets #:to-octets
           #:brd #:make-brd #:rbit #:rbits #:r-align #:r-bytes #:r-eof-p
           #:peek-bits #:bits-available
           #:bwr #:make-bwr #:wbits #:w-align #:w-bytes #:bwr-out))
(defpackage #:cl-brotli.pure
  (:use #:cl)
  (:local-nicknames (#:b #:cl-brotli.pure.bitio))
  (:export #:decompress #:compress #:brotli-error))
