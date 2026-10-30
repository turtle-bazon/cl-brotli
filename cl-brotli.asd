(defsystem "cl-brotli"
  :description "Common Lisp bindings and convenience API for Brotli compression"
  :version "0.0.1.0"
  :author "pesekey"
  :license "GPL-3.0"
  :depends-on ("cffi" "flexi-streams")
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:file "brotli")
                             (:file "pure-decoder")))))
