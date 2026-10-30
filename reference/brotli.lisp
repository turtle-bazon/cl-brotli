(in-package #:cl-brotli.reference)

;;; ---------------------------------------------------------------------------
;;; Foreign library
;;; ---------------------------------------------------------------------------

(define-foreign-library libbrotlicommon
  (:unix (:or "libbrotlicommon.so.1" "libbrotlicommon.so"))
  (:windows "brotlicommon.dll"))

(define-foreign-library libbrotlienc
  (:unix (:or "libbrotlienc.so.1" "libbrotlienc.so"))
  (:windows "brotlienc.dll"))

(define-foreign-library libbrotlidec
  (:unix (:or "libbrotlidec.so.1" "libbrotlidec.so"))
  (:windows "brotlidec.dll"))

(use-foreign-library libbrotlicommon)
(use-foreign-library libbrotlienc)
(use-foreign-library libbrotlidec)

;;; ---------------------------------------------------------------------------
;;; One-shot C API
;;; ---------------------------------------------------------------------------

(defcfun ("BrotliEncoderMaxCompressedSize" brotli-encoder-max-compressed-size) :size
  (input-size :size))

(defcfun ("BrotliEncoderCompress" brotli-encoder-compress) :int
  (quality :int)
  (lgwin :int)
  (mode :int)
  (input-size :size)
  (input-buffer :pointer)
  (encoded-size :pointer)
  (encoded-buffer :pointer))

(defcfun ("BrotliDecoderDecompress" brotli-decoder-decompress) :int
  (encoded-size :size)
  (encoded-buffer :pointer)
  (decoded-size :pointer)
  (decoded-buffer :pointer))

(defcfun ("BrotliDecoderEstimateDecompressedSize" brotli-decoder-estimate-decompressed-size) :size
  (encoded-size :size)
  (encoded-buffer :pointer))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %ensure-octets (data)
  "DATA as a simple (UNSIGNED-BYTE 8) vector."
  (cond
    ((typep data '(simple-array (unsigned-byte 8) (*))) data)
    ((typep data '(vector (unsigned-byte 8)))
     (let ((out (make-array (length data) :element-type '(unsigned-byte 8))))
       (replace out data)
       out))
    ((stringp data)
     (flexi-streams:string-to-octets data :external-format :utf-8))
    (t
     (let* ((len (length data))
            (out (make-array len :element-type '(unsigned-byte 8))))
       (dotimes (i len out)
         (setf (aref out i) (elt data i)))))))

(defun %copy-to-foreign (ptr data)
  (let ((n (length data)))
    (dotimes (i n)
      (setf (cffi:mem-aref ptr :unsigned-char i) (aref data i)))))

(defun %copy-from-foreign (ptr n)
  (let ((out (make-array n :element-type '(unsigned-byte 8))))
    (dotimes (i n)
      (setf (aref out i) (cffi:mem-aref ptr :unsigned-char i)))
    out))

;;; ---------------------------------------------------------------------------
;;; High-level API
;;; ---------------------------------------------------------------------------

(defun compress (data &key (quality 11) (lgwin 22) (mode 0))
  "Compress DATA (string or octet vector) to a Brotli octet vector."
  (let* ((input (%ensure-octets data))
         (input-size (length input))
         (capacity (max 1 (brotli-encoder-max-compressed-size input-size))))
    (cffi:with-foreign-objects ((in-ptr :unsigned-char (max 1 input-size))
                                (out-ptr :unsigned-char capacity)
                                (size-ptr :size))
      (%copy-to-foreign in-ptr input)
      (setf (cffi:mem-ref size-ptr :size) capacity)
      (let ((ok (brotli-encoder-compress quality lgwin mode input-size
                                         (if (zerop input-size)
                                             (cffi:null-pointer)
                                             in-ptr)
                                         size-ptr out-ptr)))
        (unless (plusp ok)
          (error "Brotli compression failed"))
        (let ((encoded-size (cffi:mem-ref size-ptr :size)))
          (%copy-from-foreign out-ptr encoded-size))))))

(defun decompress (data)
  "Decompress a Brotli octet vector (or string of bytes) to an octet vector."
  (let* ((input (%ensure-octets data))
         (input-size (length input))
         (capacity (max 1 (* (max 1 input-size) 4))))
    (cffi:with-foreign-object (in-ptr :unsigned-char (max 1 input-size))
      (%copy-to-foreign in-ptr input)
      (loop
        (cffi:with-foreign-objects ((out-ptr :unsigned-char capacity)
                                    (size-ptr :size))
          (setf (cffi:mem-ref size-ptr :size) capacity)
          (let ((ok (brotli-decoder-decompress input-size in-ptr size-ptr out-ptr)))
            (cond
              ((plusp ok)
               (let ((decoded-size (cffi:mem-ref size-ptr :size)))
                 (return (%copy-from-foreign out-ptr decoded-size))))
              (t
               (let ((needed (cffi:mem-ref size-ptr :size)))
                 (setf capacity (if (and needed (> needed capacity))
                                    needed
                                    (* capacity 2)))
                 (when (> capacity (* (max 1 input-size) 64 1024 1024))
                   (error "Brotli decompression failed: output too large")))))))))))
