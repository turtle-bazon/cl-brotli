;;;; src/brotli.lisp — Brotli stream framing + the top-level codec entries.
;;;;
;;;; This file owns the window (WBITS) header, the meta-block loop (metadata,
;;;; uncompressed, and dispatch to the compressed decoder in decompress.lisp),
;;;; the per-stream distance ring buffer, and COMPRESS (stored meta-blocks).
;;;; DECOMPRESS is a full RFC 7932 decoder; verified byte-for-byte against the
;;;; brotli reference (node/python).
(in-package #:cl-brotli.lisp)

(define-condition brotli-error (error)
  ((msg :initarg :msg :reader brotli-error-msg))
  (:report (lambda (c s) (format s "brotli: ~a" (brotli-error-msg c)))))
(defun berr (fmt &rest a) (error 'brotli-error :msg (apply #'format nil fmt a)))

;;; ---- WBITS (window) header (RFC 7932 9.1) -----------------------------
(defun read-wbits (r)
  (if (zerop (b:rbit r)) 16
      (let ((n (b:rbits r 3)))
        (if (plusp n) (+ 17 n)
            (let ((m (b:rbits r 3))) (if (zerop m) 17 (+ 8 m)))))))

(defun write-wbits (w wbits)
  (cond ((= wbits 16) (b:wbits w 0 1))
        ((<= 18 wbits 24) (b:wbits w 1 1) (b:wbits w (- wbits 17) 3))
        ((= wbits 17) (b:wbits w 1 1) (b:wbits w 0 3) (b:wbits w 0 3))
        ((<= 10 wbits 16) (b:wbits w 1 1) (b:wbits w 0 3) (b:wbits w (- wbits 8) 3))
        (t (berr "unsupported WBITS ~d" wbits))))

;;; ---- decompress -------------------------------------------------------
(defun %out () (make-outbuf (make-array 4096 :element-type '(unsigned-byte 8))))
(defun %append (out src)
  (let ((pos (outbuf-pos out)) (n (length src)))
    (%grow out (+ pos n))
    (replace (outbuf-data out) src :start1 pos)
    (setf (outbuf-pos out) (+ pos n))))

(defun %decompress (r)
  "Decode a brotli stream from the reader R."
  (let* ((out (%out))
         (window (- (ash 1 (read-wbits r)) 16))
         ;; distance ring buffer: 4 slots + rolling write index (slot 4),
         ;; pre-seeded with 4 pushes so the initial last distances are 16,15,11,4.
         (rb (make-array 5 :element-type 'fixnum
                          :initial-contents '(16 15 11 4 4))))
    (loop named blocks do
      (let ((islast (b:rbit r)))
        (when (and (= islast 1) (= (b:rbit r) 1)) (return-from blocks)) ; ISLAST + ISLASTEMPTY
        (let ((mnib (b:rbits r 2)))
          (cond
            ((= mnib 3)                                                   ; metadata meta-block
             (when (plusp (b:rbit r)) (berr "reserved bit set"))
             (let ((sb (b:rbits r 2)))
               (if (zerop sb)
                   (b:r-align r)
                   (let ((len (1+ (b:rbits r (* 8 sb))))) (b:r-align r) (b:r-bytes r len)))))
            (t
             (let ((mlen (1+ (b:rbits r (* 4 (+ mnib 4))))))
               (cond
                 ;; ISUNCOMPRESSED bit is present only for non-last meta-blocks
                 ((and (= islast 0) (= (b:rbit r) 1))
                  (b:r-align r)
                  ;; Copy straight into the output buffer; the old
                  ;; R-BYTES + APPEND path allocated and copied each stored
                  ;; block twice.
                  (let ((pos (outbuf-pos out)))
                    (%grow out (+ pos mlen))
                    (b:r-bytes-into r (outbuf-data out) pos mlen)
                    (setf (outbuf-pos out) (+ pos mlen))))
                 (t (decode-compressed-meta-block r out mlen window rb)))))))
        (when (= islast 1) (return-from blocks))))
    (let ((data (outbuf-data out)) (pos (outbuf-pos out)))
      (if (= pos (length data)) data (subseq data 0 pos)))))

(defun decompress (input)
  "Decode a brotli stream (RFC 7932).  Returns OCTETS.  Handles uncompressed and
compressed meta-blocks, plus metadata blocks; the distance ring buffer and the
static dictionary span the whole stream."
  (let ((data (b:to-octets input)))
    #+(and sbcl little-endian)
    (sb-sys:with-pinned-objects (data)
      (let ((r (b:make-brd data)))
        (setf (b:brd-sap r) (sb-sys:vector-sap data))
        (%decompress r)))
    #-(and sbcl little-endian)
    (%decompress (b:make-brd data))))

;;; ---- compress (uncompressed/stored meta-blocks) -----------------------
(defconstant +mlen-max+ #xFFFFFF)   ; 6 nibbles

(defun compress-stored (input)
  "Encode INPUT as a valid brotli stream of uncompressed (stored) meta-blocks.
Reference-decodable; no actual compression.  Used as the fallback when entropy
coding would not shrink the data (see COMPRESS in encode.lisp)."
  (let* ((data (b:to-octets input)) (n (length data))
         (w (b:make-bwr (max 1024 (+ n 1024)))))
    (write-wbits w 16)
    (if (zerop n)
        (progn (b:wbits w 1 1) (b:wbits w 1 1))                          ; ISLAST + ISLASTEMPTY
        (let ((pos 0))
          (loop while (< pos n) do
            (let* ((chunk (min (- n pos) +mlen-max+))
                   (m1 (1- chunk))
                   (nib (cond ((<= m1 #xFFFF) 4) ((<= m1 #xFFFFF) 5) (t 6))))
              (b:wbits w 0 1)                                            ; ISLAST=0
              (b:wbits w (- nib 4) 2)                                    ; MNIBBLES
              (b:wbits w m1 (* 4 nib))                                   ; MLEN-1
              (b:wbits w 1 1)                                            ; ISUNCOMPRESSED
              (b:w-align w)
              (b:w-bytes-range w data pos (+ pos chunk))
              (incf pos chunk)))
          (b:wbits w 1 1) (b:wbits w 1 1)))                             ; final empty last block
    (b:w-align w)
    (b:bwr-result w)))
