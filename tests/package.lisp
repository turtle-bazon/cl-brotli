(defpackage #:cl-brotli/tests
  (:use #:cl #:fiveam)
  (:export #:brotli-suite
           #:run-tests))

(in-package #:cl-brotli/tests)

(defun run-tests ()
  (let ((result (run 'brotli-suite)))
    (explain! result)
    (unless (results-status result)
      (error "cl-brotli tests failed"))
    result))
