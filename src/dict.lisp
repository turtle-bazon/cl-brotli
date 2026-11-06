;;;; src/dict.lisp — brotli static dictionary + word transforms (RFC 7932 §8).
(in-package #:cl-brotli.lisp)

(defparameter +ndbits+
  (make-array 25 :element-type 'fixnum
                  :initial-contents '(0 0 0 0 10 10 11 11 10 10 10 10 10 9 9 8 7 7 8 7 7 6 6 5 5)))
(declaim (type (simple-array fixnum (25)) +ndbits+))
(declaim (inline nwords)
         (ftype (function ((integer 0 24)) (integer 0 2048)) nwords))
(defun nwords (len)
  "Number of dictionary words of length LEN (0 below 4).  Inlined with a
tight ftype so hot callers' distance arithmetic stays in fixnum range."
  (declare (type (integer 0 24) len) (optimize (speed 3) (safety 0)))
  (if (>= len 4) (ash 1 (aref +ndbits+ len)) 0))
(defparameter +doffset+
  (let ((d (make-array 26 :element-type 'fixnum :initial-element 0)))
    (loop for l from 0 to 24 do (setf (aref d (1+ l)) (+ (aref d l) (* l (nwords l)))))
    d))
;; typed: the hot dictionary probe reads (AREF +DOFFSET+ LEN) per
;; candidate; as a T vector it compiled to a data-vector-ref dispatch.
(declaim (type (simple-array fixnum (26)) +doffset+))

(defvar *dict* nil)
(declaim (inline load-dict)
         (ftype (function () (simple-array (unsigned-byte 8) (*))) load-dict))
(defun load-dict ()
  ;; THE: (OR *DICT* ...) derives (OR NULL ARRAY) - the NIL case takes the
  ;; SETF branch and always returns the vector, but SBCL cannot correlate
  ;; that, and the derived NULL made every hot (AREF DICT ...) a hairy
  ;; dispatch with a null check (VECTOR-HAIRY in the dictionary probe).
  (the (simple-array (unsigned-byte 8) (*))
       (or *dict*
           (setf *dict*
                 (let ((p (asdf:system-relative-pathname "cl-brotli" "data/dictionary.bin")))
                   (with-open-file (s p :element-type '(unsigned-byte 8))
                     (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
                       (read-sequence v s) v)))))))

;;; word transforms
(defun %ferment-at (w pos len)
  (let ((c (aref w pos)))
    (cond ((< c 192) (when (<= 97 c 122) (setf (aref w pos) (logxor c 32))) 1)
          ((< c 224) (when (< (1+ pos) len) (setf (aref w (1+ pos)) (logxor (aref w (1+ pos)) 32))) 2)
          (t (when (< (+ pos 2) len) (setf (aref w (+ pos 2)) (logxor (aref w (+ pos 2)) 5))) 3))))
(defun %ferment-first (w) (when (plusp (length w)) (%ferment-at w 0 (length w))))
(defun %ferment-all (w) (let ((i 0) (n (length w))) (loop while (< i n) do (incf i (%ferment-at w i n)))))

(defun apply-transform (word tr)
  "Apply transform TR = (prefix type suffix) to WORD (octets) -> octets."
  (destructuring-bind (prefix type suffix) tr
    (let* ((w (copy-seq word)) (n (length w)) (name (symbol-name type))
           (core (cond
                   ((eq type :identity) w)
                   ((eq type :upper-first) (%ferment-first w) w)
                   ((eq type :upper-all) (%ferment-all w) w)
                   ((eql 0 (search "OMIT-FIRST-" name))
                    (let ((k (parse-integer name :start 11))) (if (>= k n) #() (subseq w k))))
                   ((eql 0 (search "OMIT-LAST-" name))
                    (let ((k (parse-integer name :start 10))) (if (>= k n) #() (subseq w 0 (- n k)))))
                   (t (berr "unknown transform ~a" type)))))
      (concatenate '(simple-array (unsigned-byte 8) (*)) prefix core suffix))))

(defun dict-word (len dist max-dist)
  "Static-dictionary word for a (LEN, DIST) reference -> octets."
  (unless (<= 4 len 24) (berr "dictionary copy length ~d out of range" len))
  (let* ((nw (nwords len))
         (word-id (- dist (1+ max-dist)))
         (idx (mod word-id nw))
         (off (+ (aref +doffset+ len) (* idx len)))
         (base (subseq (load-dict) off (+ off len)))
         (tid (ash word-id (- (aref +ndbits+ len)))))
    (when (> tid 120) (berr "transform id ~d > 120" tid))
    (apply-transform base (aref +transforms+ tid))))

;;; Allocation-free decoder path.  Each transform is precompiled once into
;;; (PREFIX KIND K SUFFIX): KIND 0 identity, 1 uppercase-first, 2 uppercase-
;;; all, 3 omit-first-K, 4 omit-last-K.  DICT-WORD above re-parsed the
;;; transform's symbol name and made five temporary vectors per reference.
(defparameter +transforms-c+
  (map 'simple-vector
       (lambda (tr)
         (destructuring-bind (prefix type suffix) tr
           (let ((name (symbol-name type)))
             (multiple-value-bind (kind k)
                 (cond ((eq type :identity) (values 0 0))
                       ((eq type :upper-first) (values 1 0))
                       ((eq type :upper-all) (values 2 0))
                       ((eql 0 (search "OMIT-FIRST-" name))
                        (values 3 (parse-integer name :start 11)))
                       ((eql 0 (search "OMIT-LAST-" name))
                        (values 4 (parse-integer name :start 10)))
                       (t (error "unknown transform ~a" type)))
               (vector (coerce prefix '(simple-array (unsigned-byte 8) (*)))
                       kind k
                       (coerce suffix '(simple-array (unsigned-byte 8) (*))))))))
       +transforms+))
(declaim (type simple-vector +transforms-c+))

(defun dict-word-into (data pos limit len dist max-dist)
  "Write the static-dictionary word for a (LEN, DIST) reference into DATA at
POS, exactly as DICT-WORD would produce it, and return the new position.
Signals BROTLI-ERROR if the word would end past LIMIT."
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum pos limit len dist max-dist)
           (optimize (speed 3) (safety 0)))
  (unless (<= 4 len 24) (berr "dictionary copy length ~d out of range" len))
  (let* ((dict (load-dict))
         (word-id (- dist (1+ max-dist)))
         (idx (logand word-id (1- (nwords len))))
         (off (+ (aref +doffset+ len) (* idx len)))
         (tid (ash word-id (- (aref +ndbits+ len)))))
    (declare (type fixnum word-id idx off tid))
    (when (> tid 120) (berr "transform id ~d > 120" tid))
    (let* ((tr (svref +transforms-c+ tid))
           (prefix (svref tr 0))
           (kind (svref tr 1))
           (k (svref tr 2))
           (suffix (svref tr 3))
           (cstart off) (cend (+ off len)))
      (declare (type (simple-array (unsigned-byte 8) (*)) prefix suffix)
               (type fixnum kind k cstart cend))
      (case kind
        (3 (setf cstart (min cend (+ off k))))
        (4 (setf cend (max off (- cend k)))))
      (let* ((clen (- cend cstart))
             (total (+ (length prefix) clen (length suffix))))
        (declare (type fixnum clen total))
        (when (> total (- limit pos))
          (berr "dictionary word exceeds the meta-block"))
        (replace data prefix :start1 pos)
        (incf pos (length prefix))
        (replace data dict :start1 pos :start2 cstart :end2 cend)
        ;; Uppercase transforms (RFC 7932 8): in place on the copied core.
        (case kind
          (1 (when (plusp clen) (%ferment-at data pos (+ pos clen))))
          (2 (let ((i pos) (e (+ pos clen)))
               (declare (type fixnum i e))
               (loop while (< i e) do (incf i (%ferment-at data i e))))))
        (incf pos clen)
        (replace data suffix :start1 pos)
        (+ pos (length suffix))))))
