(defsystem "cl-brotli"
  :description "Pure Common Lisp Brotli codec (RFC 7932)"
  :version "0.0.1.0"
  :author "pesekey"
  :license "GPL-3.0"
  :depends-on ()
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:module "pure"
                              :serial t
                              :components ((:file "packages")
                                           (:file "bitio")
                                           (:file "tables")
                                           (:file "huffman")
                                           (:file "dict")
                                           (:file "decompress")
                                           (:file "brotli")
                                           (:file "encode")))
                             (:file "package")))))
