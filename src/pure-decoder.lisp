(in-package #:cl-brotli)

;;; ---------------------------------------------------------------------------
;;; Pure-Lisp Brotli decoder (work in progress)
;;;
;;; This is the beginning of a pure Common Lisp implementation.  It currently
;;; handles only the empty Brotli stream and is not yet Brotli-complete.
;;; ---------------------------------------------------------------------------

(defstruct (bit-reader (:constructor %make-bit-reader))
  (data #() :type (vector (unsigned-byte 8)))
  (pos 0 :type fixnum)
  (bit 0 :type fixnum)
  (value 0 :type fixnum))

(defun make-bit-reader (data)
  (%make-bit-reader :data (cl-brotli::%ensure-octets data)))

(defun bit-reader-read-byte (br)
  (let ((data (bit-reader-data br))
        (pos (bit-reader-pos br)))
    (when (>= pos (length data))
      (error "Unexpected end of Brotli input"))
    (prog1 (aref data pos)
      (setf (bit-reader-pos br) (1+ pos)))))

(defun decompress-pure (data)
  "Decode a Brotli stream using pure Common Lisp.

Currently handles only the empty stream.  Full decoding is not implemented."
  (let ((bytes (cl-brotli::%ensure-octets data)))
    (if (and (= (length bytes) 1) (= (aref bytes 0) #x06))
        (make-array 0 :element-type '(unsigned-byte 8))
        (error "Pure-Lisp Brotli decoder not implemented for this stream"))))
