(asdf:defsystem "cl-brotli-bench"
  :version "0.0.1.0"
  :description "Benchmark cl-brotli against the system C Brotli library."
  :depends-on ("cl-brotli"
               "cl-brotli-reference"
               "cffi"
               "flexi-streams")
  :serial t
  :components ((:module "bench"
                :serial t
                :components ((:file "bench")))))
