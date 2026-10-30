(defsystem "cl-brotli-reference"
  :description "CFFI reference bindings for Brotli (tests only)"
  :version "0.0.1.0"
  :author "pesekey"
  :license "GPL-3.0"
  :depends-on ("cffi" "flexi-streams")
  :serial t
  :components ((:module "reference"
                :serial t
                :components ((:file "package")
                             (:file "brotli")))))
