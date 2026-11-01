(defsystem "cl-brotli"
  :description "Common Lisp Brotli codec (RFC 7932)"
  :version "0.0.1.0"
  :author "pesekey"
  :license "GPL-3.0"
  :depends-on ()
  :in-order-to ((test-op (test-op "cl-brotli-tests")))
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "bitio")
                             (:file "tables")
                             (:file "huffman")
                             (:file "dict")
                             (:file "decompress")
                             (:file "brotli")
                             (:file "encode")
                             (:file "package")))))
