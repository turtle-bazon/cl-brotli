(defpackage #:cl-brotli.lisp.bitio
  (:use #:cl)
  (:export #:octets #:to-octets
           #:brd #:make-brd #:rbit #:rbits #:r-align #:r-bytes #:r-bytes-into #:r-eof-p
           #:peek-bits #:bits-available
           #:brd-bytes #:brd-pos #:brd-end #:brd-acc #:brd-nbits #:brd-sap #:%word-at
           #:bwr #:make-bwr #:wbits #:w-align #:w-bytes #:w-bytes-range #:bwr-out
           #:w-ensure #:%wbits-raw #:%wbits-raw-pm #:w-emit-run #:make-bwr-into
           #:bwr-pos #:bwr-limit #:bwr-result
           #:ptr #:ptr-off #:with-ptrs #:ptr-u8 #:ptr-u16 #:ptr-u32 #:ptr-u64
           #:ptr+ #:off-u8 #:off-u32 #:ctz64))
(defpackage #:cl-brotli.lisp
  (:use #:cl)
  (:local-nicknames (#:b #:cl-brotli.lisp.bitio))
  (:import-from #:cl-brotli.lisp.bitio
                #:ptr #:ptr-off #:with-ptrs #:ptr-u8 #:ptr-u16 #:ptr-u32
                #:ptr-u64 #:ptr+ #:off-u8 #:off-u32 #:ctz64)
  (:export #:decompress #:compress #:brotli-error
             #:compress-into #:decompress-into #:max-compressed-size
             #:make-compressor
             #:brotli-output-overflow))
