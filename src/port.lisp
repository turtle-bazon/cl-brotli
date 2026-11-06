;;;; src/port.lisp — the one place that knows about implementation-specific
;;;; memory access.
;;;;
;;;; Hot loops read octet vectors through "pointers".  On SBCL (64-bit,
;;;; little-endian) a pointer is a SYSTEM-AREA-POINTER into a pinned vector
;;;; and the readers compile to single unaligned loads.  Everywhere else a
;;;; pointer is the octet vector itself and the readers assemble the same
;;;; little-endian values from byte references, so every implementation
;;;; computes identical hashes, match lengths and output streams.
;;;;
;;;; Push :CL-BROTLI-PORTABLE onto *FEATURES* before loading to force the
;;;; portable path on SBCL as well (used to test it).
(in-package #:cl-brotli.lisp.bitio)

(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; Packed encoder records use fixnum bits up to ~50 (e.g. ZLEN: dist at
  ;; bits 25..50) under (SAFETY 0); a narrower fixnum would corrupt them
  ;; silently.  Every 64-bit Lisp has >= 60-bit fixnums (CCL 61, SBCL/ECL 63).
  (unless (>= (integer-length most-positive-fixnum) 60)
    (error "cl-brotli needs a 64-bit Lisp (fixnums of at least 60 bits)."))
  #+(and sbcl little-endian 64-bit (not cl-brotli-portable))
  (pushnew :cl-brotli-sap *features*)
  ;; The x86-64 VOPs (src/vops.lisp) and count-trailing-zeros intrinsic.
  #+(and sbcl x86-64 little-endian 64-bit (not cl-brotli-portable))
  (pushnew :cl-brotli-x86-64 *features*))

(deftype ptr ()
  "A readable view of an octet vector: see WITH-PTRS."
  #+cl-brotli-sap 'sb-sys:system-area-pointer
  #-cl-brotli-sap '(simple-array (unsigned-byte 8) (*)))

(deftype ptr-off ()
  "A pointer displaced by a byte offset (PTR+), read with OFF-U8/OFF-U32."
  #+cl-brotli-sap 'sb-sys:system-area-pointer
  #-cl-brotli-sap 'fixnum)

(defmacro with-ptrs (bindings &body body)
  "(WITH-PTRS ((P VECTOR-FORM) ...) BODY): bind each P to a pointer to the
octet vector, valid (pinned) for the dynamic extent of BODY.  A NIL vector
form binds P to NIL."
  (let ((vars (loop repeat (length bindings) collect (gensym "V"))))
    #+cl-brotli-sap
    `(let ,(mapcar (lambda (v b) `(,v ,(second b))) vars bindings)
       (sb-sys:with-pinned-objects ,vars
         (let ,(mapcar (lambda (v b) `(,(first b) (and ,v (sb-sys:vector-sap ,v))))
                       vars bindings)
           ,@body)))
    #-cl-brotli-sap
    `(let ,(mapcar (lambda (v b) `(,v ,(second b))) vars bindings)
       (let ,(mapcar (lambda (v b) `(,(first b) ,v)) vars bindings)
         ,@body))))

(defmacro %le-bytes (p i nbytes)
  (let ((pp (gensym "P")) (ii (gensym "I")))
    `(let ((,pp ,p) (,ii ,i))
       (declare (type (simple-array (unsigned-byte 8) (*)) ,pp)
                (type fixnum ,ii))
       (logior ,@(loop for k below nbytes
                       collect (if (zerop k)
                                   `(aref ,pp ,ii)
                                   `(ash (aref ,pp (+ ,ii ,k)) ,(* 8 k))))))))

(defmacro ptr-u8 (p i)
  #+cl-brotli-sap `(sb-sys:sap-ref-8 ,p ,i)
  #-cl-brotli-sap `(aref (the (simple-array (unsigned-byte 8) (*)) ,p) ,i))
(defmacro ptr-u16 (p i)
  #+cl-brotli-sap `(sb-sys:sap-ref-16 ,p ,i)
  #-cl-brotli-sap `(the (unsigned-byte 16) (%le-bytes ,p ,i 2)))
(defmacro ptr-u32 (p i)
  #+cl-brotli-sap `(sb-sys:sap-ref-32 ,p ,i)
  #-cl-brotli-sap `(the (unsigned-byte 32) (%le-bytes ,p ,i 4)))
(defmacro ptr-u64 (p i)
  #+cl-brotli-sap `(sb-sys:sap-ref-64 ,p ,i)
  #-cl-brotli-sap `(the (unsigned-byte 64) (%le-bytes ,p ,i 8)))

(defmacro ptr+ (p off)
  "P displaced by OFF bytes.  Portable pointers cannot be displaced, so
the portable PTR-OFF is just the offset; read it back with OFF-U8/OFF-U32
passing the base pointer too."
  #+cl-brotli-sap `(sb-sys:sap+ ,p ,off)
  #-cl-brotli-sap (progn p off))
(defmacro off-u8 (p poff k)
  #+cl-brotli-sap (progn p `(sb-sys:sap-ref-8 ,poff ,k))
  #-cl-brotli-sap `(ptr-u8 ,p (+ ,poff ,k)))
(defmacro off-u32 (p poff k)
  #+cl-brotli-sap (progn p `(sb-sys:sap-ref-32 ,poff ,k))
  #-cl-brotli-sap `(ptr-u32 ,p (+ ,poff ,k)))

(declaim (inline ctz64))
(defun ctz64 (x)
  "Trailing zero bits of a non-zero (unsigned-byte 64)."
  (declare (type (unsigned-byte 64) x)
           (optimize (speed 3) (safety 0)))
  #+cl-brotli-x86-64 (sb-kernel:count-trailing-zeros x)
  #-cl-brotli-x86-64 (1- (integer-length (logand x (- x)))))

(defmacro deftable (name value &optional doc)
  "A constant lookup table.  On SBCL a load-time global
\(SB-EXT:DEFINE-LOAD-TIME-GLOBAL: value computed at load time, like
DEFPARAMETER; DEFGLOBAL would also evaluate it at compile time).  A global
can never be dynamically bound, so a read is one load - a DEFPARAMETER read
is a thread-local symbol-value check plus a global load (5 instructions in
every hot loop that touches the table).  Elsewhere DEFPARAMETER."
  #+sbcl `(sb-ext:define-load-time-global ,name ,value ,@(when doc (list doc)))
  #-sbcl `(defparameter ,name ,value ,@(when doc (list doc))))
