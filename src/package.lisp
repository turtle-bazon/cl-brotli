(defpackage #:cl-brotli
  (:use #:cl)
  (:import-from #:cl-brotli.lisp
                #:compress
                #:decompress
                #:brotli-error)
  (:export #:compress
           #:decompress
           #:brotli-error))

;;; The %MATCH-LEN-SAP VOP replaces calls compiled after src/vops.lisp; this
;;; runtime definition keeps FUNCALL and pre-VOP call sites working.
#+(and sbcl x86-64 64-bit little-endian)
(setf (symbol-function 'cl-brotli.lisp::%match-len-sap)
      (symbol-function 'cl-brotli.lisp::%match-len-sap-lisp))
