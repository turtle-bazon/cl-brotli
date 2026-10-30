;;;; src/dict.lisp — brotli static dictionary + word transforms (RFC 7932 §8).
(in-package #:cl-brotli.pure)

(defparameter +ndbits+ #(0 0 0 0 10 10 11 11 10 10 10 10 10 9 9 8 7 7 8 7 7 6 6 5 5))
(defun nwords (len) (if (>= len 4) (ash 1 (aref +ndbits+ len)) 0))
(defparameter +doffset+
  (let ((d (make-array 26 :initial-element 0)))
    (loop for l from 0 to 24 do (setf (aref d (1+ l)) (+ (aref d l) (* l (nwords l)))))
    d))

(defvar *dict* nil)
(defun load-dict ()
  (or *dict*
      (setf *dict*
            (let ((p (asdf:system-relative-pathname "cl-brotli" "data/dictionary.bin")))
              (with-open-file (s p :element-type '(unsigned-byte 8))
                (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
                  (read-sequence v s) v))))))

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
