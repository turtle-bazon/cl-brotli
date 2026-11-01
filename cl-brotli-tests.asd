(defsystem "cl-brotli-tests"
  :description "Tests for cl-brotli (Lisp and reference differential)"
  :version "0.0.1.0"
  :author "pesekey"
  :license "GPL-3.0"
  :depends-on ("cl-brotli" "cl-brotli-reference" "fiveam" "flexi-streams")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "package")
                             (:file "brotli-test"))))
  :perform (test-op (op c)
             (uiop:symbol-call "CL-BROTLI/TESTS" "RUN-TESTS")))
