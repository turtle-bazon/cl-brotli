;;;; Entry point for `sbcl --script bench/run.lisp ...'.
;;;;
;;;; --script deliberately skips the user init file, so Quicklisp is loaded
;;;; explicitly when it is not already present.

(unless (find-package :ql)
  (load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))

(require :asdf)

(let ((root (uiop:pathname-parent-directory-pathname *load-truename*)))
  (pushnew root asdf:*central-registry* :test #'equal))

(asdf:load-system "cl-brotli-bench")
(cl-brotli-bench:main)
