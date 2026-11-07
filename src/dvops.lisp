;;;; src/dvops.lisp — x86-64 assembly for the decoder's command loops (SBCL).
;;;;
;;;; Like src/vops.lisp this is only a speed path: each routine here has a
;;;; portable Lisp counterpart in src/decompress.lisp that computes the same
;;;; output, and that Lisp code also handles everything the assembly leaves
;;;; out (input near its end, invalid streams).
;;;;
;;;; Why assembly: SBCL has no callee-saved registers and tags anything of
;;;; fixnum range, so its version of the command loop keeps half its state
;;;; in stack slots and shifts values in and out of fixnum form.  Here the
;;;; whole loop runs in registers on untagged values.
;;;;
;;;; Protocol.  A routine takes two vectors:
;;;;   ST  (simple-array (unsigned-byte 64) (*)): every scalar - bit reader,
;;;;       positions, tree parameters, block-switch state, the distance
;;;;       ring - read on entry and written back on exit (slots +ST-...+);
;;;;   CTX simple-vector of the arrays it touches (input, output, tables).
;;;; Arrays are reached through CTX, i.e. through properly tagged pointers
;;;; loaded into registers.  SBCL scans registers conservatively, so nothing
;;;; addressed this way can move while it runs and nothing needs pinning.
;;;; Nothing is ever stored into CTX (no write barrier needed).
;;;; On exit ST[+ST-EXIT+] says why it stopped:
;;;;   0  the meta-block is complete;
;;;;   1  the next command needs the Lisp loop (input near its end, or
;;;;      anything invalid).  Bit reader, output position, block counts
;;;;      and types are those at the START of that command - the routine
;;;;      commits nothing it has not fully decoded - so Lisp decodes it
;;;;      again (bytes already written are rewritten with the same values);
;;;;   2  the command's copy is a static-dictionary word: everything up to
;;;;      the copy is done, ST[+ST-DIST+] / ST[+ST-CLEN+] hold distance and
;;;;      length; Lisp writes the word and calls the routine again.
;;;;
;;;; Bit reader: the 64-bit "branchless refill" (acc |= load64(p) << nb;
;;;; p += (63-nb)>>3; nb |= 56).  Bits of ACC at and above NB are the next
;;;; input bits, not zero; they are masked off on exit, where whole bytes
;;;; beyond 56 bits are also handed back so that ACC fits a fixnum.
;;;;
;;;; Tree tables (see BUILD-HUFF): one (unsigned-byte 16) array per tree,
;;;; entry = symbol << 4 | length, length 15 = subtable marker whose symbol
;;;; field is the subtable index.  A tree's parameters are one packed word:
;;;; mask | root bits << 16 | sub bits << 24 | sub mask << 32.
;;;;
;;;; Baseline x86-64 only (SSE2 MOVDQU for copies; no BMI).
#+cl-brotli-x86-64
(in-package #:sb-vm)

#+cl-brotli-x86-64
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *brotli-st-slots*
    `(:acc :nb :p :pos :target :end8 :origin :window
      :ring0 :ring1 :ring2 :ring3 :ring-idx :npostfix :ndirect :postfix-mask
      :exit :snap-acc :snap-nb :snap-p :snap-pos :pend :cmd :clen :dist :tmp
      :cmd-param :lparam :dparam
      ,@(loop for i below 16 collect (intern (format nil "DSC~D" i) :keyword))
      ;; general meta-blocks
      :ltype :lprev :lntypes :lcount :itype :iprev :intypes :icount
      :dtype :dprev :dntypes :dcount
      :lbt-param :lbl-param :ibt-param :ibl-param :dbt-param :dbl-param
      :lutoff :litrow :triv :drow :left :flags :dtree :lutp :rowp :cend
      :snap-lcount :snap-icount :snap-dcount
      :snap-ltype :snap-lprev :snap-itype :snap-iprev :snap-dtype :snap-dprev
      ,@(loop for i below 26 collect (intern (format nil "BLEN~D" i) :keyword))))
  (defparameter *brotli-ctx-slots*
    '(:in :out :cmdlut :ctable :ltable :dtable
      :ctx-table :ctabs :cparams :cmapl :ltabs :lparams :cmapd :dtabs :dparams
      :lbt :lbl :ibt :ibl :dbt :dbl :cmodes :ltriv :dict :dtrans :dmeta :ctxtabs))
  (defun brotli-st-index (slot)
    (or (position slot *brotli-st-slots*) (error "no ST slot ~S" slot)))
  (defun brotli-ctx-index (slot)
    (or (position slot *brotli-ctx-slots*) (error "no CTX slot ~S" slot)))
  (defmacro define-brotli-slot-constants ()
    `(progn
       ,@(loop for s in *brotli-st-slots* for i from 0
               collect `(defconstant ,(intern (format nil "+ST-~A+" s) "CL-BROTLI.LISP") ,i))
       (defconstant cl-brotli.lisp::+st-size+ ,(length *brotli-st-slots*))
       ,@(loop for s in *brotli-ctx-slots* for i from 0
               collect `(defconstant ,(intern (format nil "+CTX-~A+" s) "CL-BROTLI.LISP") ,i))
       (defconstant cl-brotli.lisp::+ctx-size+ ,(length *brotli-ctx-slots*)))))

#+cl-brotli-x86-64
(define-brotli-slot-constants)

#+cl-brotli-x86-64
(eval-when (:compile-toplevel :load-toplevel :execute)
  (sb-c::defknown (cl-brotli.lisp::%asm-simple-meta-block
                   cl-brotli.lisp::%asm-general-meta-block)
      ((simple-array (unsigned-byte 64) (*)) simple-vector)
      (values) ()
      :overwrite-fndb-silently t)

  ;; The emitters below run while a VOP is assembled; the VOP binds these
  ;; to its TNs and labels.
  (defvar *b-st*) (defvar *b-ctx*) (defvar *b-rcx*) (defvar *b-acc*)
  (defvar *b-nb*) (defvar *b-p*) (defvar *b-pos*) (defvar *b-e*)
  (defvar *b-tt*) (defvar *b-u*) (defvar *b-w*) (defvar *b-x0*)
  (defvar *b-bail*) (defvar *b-dict*) (defvar *b-done*) (defvar *b-cmd-loop*)
  ;; XMM registers holding the command-start snapshot (acc nb p pos, then
  ;; the block counts): a register move per value instead of a store
  (defvar *b-snap*)

  (defconstant +b-d+ (- (* vector-data-offset n-word-bytes) other-pointer-lowtag))

  (defun b-sv (slot &optional (k 0))
    "ST[SLOT] (+ K bytes)."
    (ea (+ +b-d+ (* 8 (brotli-st-index slot)) k) *b-st*))
  (defun b-cx (slot)
    "CTX[SLOT]."
    (ea (+ +b-d+ (* 8 (brotli-ctx-index slot))) *b-ctx*))

  (defun b-refill (tmp)
    ;; >= 56 bits in ACC; bail when 8 bytes are not readable at P
    (inst cmp *b-p* (b-sv :end8))
    (inst jmp :g *b-bail*)
    (inst mov tmp (b-cx :in))
    (inst mov tmp (ea +b-d+ tmp *b-p*))
    (inst mov *b-rcx* *b-nb*)
    (inst shl tmp :cl)
    (inst or *b-acc* tmp)
    (inst mov tmp 63)
    (inst sub tmp *b-nb*)
    (inst shr tmp 3)
    (inst add *b-p* tmp)
    (inst or *b-nb* 56))

  (defun b-ensure (bits tmp)
    (let ((ok (gen-label)))
      (inst cmp *b-nb* bits)
      (inst jmp :ae ok)
      (b-refill tmp)
      (emit-label ok)))

  (defun b-getbits (dst)
    ;; DST = low RCX bits of ACC, consumed (RCX <= 24)
    (inst mov dst 1)
    (inst shl dst :cl)
    (inst dec dst)
    (inst and dst *b-acc*)
    (inst shr *b-acc* :cl)
    (inst sub *b-nb* *b-rcx*))

  (defun b-sym (tbl pslot)
    ;; E = next symbol of the tree with table TBL and parameter word
    ;; ST[PSLOT] (mask | root bits << 16).  Needs NB >= 15; clobbers RCX TT
    ;; W.  A root entry with length > root bits marks a subtable of width
    ;; length - root bits at the offset in its symbol field.
    (let ((sub (gen-label)) (out (gen-label)))
      (inst movzx '(:word :dword) *b-e* (b-sv pslot 0))          ; mask
      (inst and *b-e* *b-acc*)
      (inst movzx '(:word :dword) *b-e* (ea +b-d+ tbl *b-e* 2))
      (inst movzx '(:byte :dword) *b-tt* (b-sv pslot 2))         ; root bits
      (inst mov *b-rcx* *b-e*)
      (inst and *b-rcx* 15)
      (inst cmp *b-rcx* *b-tt*)
      (inst jmp :a sub)
      (inst shr *b-acc* :cl)
      (inst sub *b-nb* *b-rcx*)
      (inst shr *b-e* 4)
      (inst jmp out)
      (emit-label sub)
      (inst shr *b-e* 4)                                         ; offset
      (inst sub *b-rcx* *b-tt*)                                  ; width
      (inst mov *b-w* 1)
      (inst shl *b-w* :cl)
      (inst dec *b-w*)
      (inst mov *b-rcx* *b-tt*)
      (inst mov *b-tt* *b-acc*)
      (inst shr *b-tt* :cl)
      (inst and *b-tt* *b-w*)
      (inst add *b-e* *b-tt*)
      (inst movzx '(:word :dword) *b-e* (ea +b-d+ tbl *b-e* 2))
      (inst mov *b-tt* *b-e*)
      (inst and *b-tt* 15)
      (inst jmp :z *b-bail*)                                     ; hole: invalid
      (inst add *b-rcx* *b-tt*)
      (inst shr *b-acc* :cl)
      (inst sub *b-nb* *b-rcx*)
      (inst shr *b-e* 4)
      (emit-label out)))

  (defun b-lit-sub ()
    ;; second level of an 8-bit-root literal table in U: E = marker entry,
    ;; RCX = its length field (8 + width).  Clobbers TT.
    (inst shr *b-e* 4)                                           ; offset
    (inst sub *b-rcx* 8)                                         ; width
    (inst mov *b-tt* 1)
    (inst shl *b-tt* :cl)
    (inst dec *b-tt*)
    (inst mov *b-rcx* *b-acc*)
    (inst shr *b-rcx* 8)
    (inst and *b-tt* *b-rcx*)
    (inst add *b-e* *b-tt*)
    (inst movzx '(:word :dword) *b-e* (ea +b-d+ *b-u* *b-e* 2))
    (inst mov *b-rcx* *b-e*)
    (inst and *b-rcx* 15)
    (inst jmp :z *b-bail*)
    (inst add *b-rcx* 8)
    (inst shr *b-acc* :cl)
    (inst sub *b-nb* *b-rcx*)
    (inst shr *b-e* 4))

  (defun b-lits-fixed ()
    ;; literals up to ST[PEND] (> POS) from the table in U, output in W
    (let ((top (gen-label)) (sub (gen-label)) (store (gen-label)) (out (gen-label)))
      (emit-label top)
      (b-ensure 15 *b-e*)
      (inst movzx '(:byte :dword) *b-e* *b-acc*)
      (inst movzx '(:word :dword) *b-e* (ea +b-d+ *b-u* *b-e* 2))
      (inst mov *b-rcx* *b-e*)
      (inst and *b-rcx* 15)
      (inst cmp *b-rcx* 8)
      (inst jmp :a sub)
      (inst shr *b-acc* :cl)
      (inst sub *b-nb* *b-rcx*)
      (inst shr *b-e* 4)
      (emit-label store)
      (inst mov :byte (ea +b-d+ *b-w* *b-pos*) *b-e*)
      (inst inc *b-pos*)
      (inst cmp *b-pos* (b-sv :pend))
      (inst jmp :l top)
      (inst jmp out)
      (emit-label sub)
      (b-lit-sub)
      (inst jmp store)
      (emit-label out)))

  (defun b-command-lengths (&optional after-lut)
    ;; E = command symbol -> E = insert length, ST[CLEN] = copy length.
    ;; Packed LUT word: ilen base | ilen bits << 16 | clen bits << 24 |
    ;; clen base << 32 | distance context << 48.  AFTER-LUT emits code to
    ;; run with E = command, W = LUT word (may use TT U).
    (inst mov (b-sv :cmd) *b-e*)
    (inst mov *b-u* (b-cx :cmdlut))
    (inst mov *b-w* (ea +b-d+ *b-u* *b-e* 8))
    (when after-lut (funcall after-lut))
    (b-ensure 24 *b-e*)
    (inst mov *b-rcx* *b-w*)
    (inst shr *b-rcx* 16)
    (inst and *b-rcx* 255)
    (b-getbits *b-tt*)
    (inst movzx '(:word :dword) *b-e* *b-w*)
    (inst add *b-e* *b-tt*)
    (b-ensure 24 *b-tt*)
    (inst mov *b-rcx* *b-w*)
    (inst shr *b-rcx* 24)
    (inst and *b-rcx* 255)
    (b-getbits *b-tt*)
    (inst shr *b-w* 32)
    (inst movzx '(:word :dword) *b-w* *b-w*)       ; drop the context
    (inst add *b-w* *b-tt*)
    (inst mov (b-sv :clen) *b-w*)
    ;; insert past the meta-block: Lisp signals it
    (inst mov *b-tt* (b-sv :target))
    (inst sub *b-tt* *b-pos*)
    (inst cmp *b-e* *b-tt*)
    (inst jmp :a *b-bail*))

  (defun b-after-literals ()
    ;; meta-block may end after the literals; copy past the end goes to Lisp
    ;; (checked before the ring changes, so a bail leaves the ring intact)
    (inst cmp *b-pos* (b-sv :target))
    (inst jmp :ge *b-done*)
    (inst mov *b-w* (b-sv :clen))
    (inst mov *b-tt* (b-sv :target))
    (inst sub *b-tt* *b-pos*)
    (inst cmp *b-w* *b-tt*)
    (inst jmp :a *b-bail*))

  (defun b-ring-ea (idx-reg)
    (ea (+ +b-d+ (* 8 (brotli-st-index :ring0))) *b-st* idx-reg 8))

  (defun b-implicit-distance (noupdate)
    ;; distance code 0 of a "dist0" command: the last distance, no push
    (inst mov *b-u* (b-sv :ring-idx))
    (inst add *b-u* 3)
    (inst and *b-u* 3)
    (inst mov *b-u* (b-ring-ea *b-u*))
    (inst jmp noupdate))

  (defun b-distance-value (update noupdate)
    ;; E = distance code -> U = distance; continue at UPDATE (push on the
    ;; ring) or NOUPDATE (code 0)
    (let ((long (gen-label)) (direct (gen-label)) (ok (gen-label)))
      (inst cmp *b-e* 16)
      (inst jmp :ae long)
      ;; short codes: ring[(idx + k) & 3] + delta, packed k + 4*delta
      (inst mov *b-tt* (ea (+ +b-d+ (* 8 (brotli-st-index :dsc0))) *b-st* *b-e* 8))
      (inst mov *b-u* *b-tt*)
      (inst and *b-u* 3)
      (inst add *b-u* (b-sv :ring-idx))
      (inst and *b-u* 3)
      (inst mov *b-u* (b-ring-ea *b-u*))
      (inst sar *b-tt* 2)
      (inst add *b-u* *b-tt*)
      (inst test *b-e* *b-e*)
      (inst jmp :nz update)
      (inst jmp noupdate)
      (emit-label long)
      (inst mov *b-tt* *b-e*)
      (inst sub *b-tt* 16)
      (inst sub *b-tt* (b-sv :ndirect))
      (inst jmp :l direct)
      ;; d = dcode - 16 - ndirect, hcode = d >> npostfix,
      ;; lcode = d & postfix-mask, ndistbits = 1 + (hcode >> 1)
      (inst mov *b-rcx* (b-sv :npostfix))
      (inst mov *b-u* *b-tt*)
      (inst shr *b-u* :cl)
      (inst and *b-tt* (b-sv :postfix-mask))
      (inst mov (b-sv :tmp) *b-tt*)
      (inst mov *b-tt* *b-u*)
      (inst shr *b-tt* 1)
      (inst inc *b-tt*)
      (inst cmp *b-nb* *b-tt*)
      (inst jmp :ae ok)
      (b-refill *b-e*)
      (emit-label ok)
      (inst mov *b-rcx* *b-tt*)
      (b-getbits *b-e*)
      ;; (((2 + (hcode & 1)) << ndistbits) - 4 + extra) << npostfix
      ;;   + lcode + ndirect + 1
      (inst and *b-u* 1)
      (inst add *b-u* 2)
      (inst shl *b-u* :cl)
      (inst sub *b-u* 4)
      (inst add *b-u* *b-e*)
      (inst mov *b-rcx* (b-sv :npostfix))
      (inst shl *b-u* :cl)
      (inst add *b-u* (b-sv :tmp))
      (inst add *b-u* (b-sv :ndirect))
      (inst inc *b-u*)
      (inst jmp update)
      (emit-label direct)
      (inst lea *b-u* (ea -15 *b-e*))
      (inst jmp update)))

  (defun b-dict-word (fallback)
    ;; Static-dictionary word (RFC 7932 8) for distance U > max distance TT
    ;; and length ST[CLEN].  CTX[DICT]: the dictionary + 32 bytes of
    ;; padding; CTX[DMETA]: ndbits[0..24], doffset[0..25] (u64);
    ;; CTX[DTRANS]: 32-byte transform records: plen kind k slen first-cut
    ;; last-cut upper(0/1 first/2 all) _ prefix[8] suffix[8] _[8].
    ;; With 64 bytes of room before the meta-block end, prefix, word and
    ;; suffix are written with fixed-size stores; otherwise (and for
    ;; invalid references) FALLBACK, i.e. Lisp.  ACC NB P are parked in the
    ;; snapshot XMM registers (no bail can follow).
    (destructuring-bind (x1 x2 x3 &rest more) *b-snap*
      (declare (ignore more))
      (let ((lisp (gen-label)) (lisp-restore (gen-label)) (upper (gen-label))
            (up-done (gen-label)) (up-loop (gen-label)) (up-next (gen-label))
            (c2 (gen-label)) (c3 (gen-label)) (step1 (gen-label)) (step2 (gen-label))
            (step3 (gen-label)))
        (inst mov (b-sv :dist) *b-u*)
        (inst lea *b-rcx* (ea 64 *b-pos*))
        (inst cmp *b-rcx* (b-sv :target))
        (inst jmp :g lisp)
        (inst mov *b-w* (b-sv :clen))
        (inst cmp *b-w* 4)
        (inst jmp :b lisp)
        (inst cmp *b-w* 24)
        (inst jmp :a lisp)
        (inst movq x1 *b-acc*)
        (inst movq x2 *b-nb*)
        (inst movq x3 *b-p*)
        (inst mov *b-acc* (b-cx :dmeta))
        (inst mov *b-rcx* (ea +b-d+ *b-acc* *b-w* 8))     ; ndbits[len]
        (inst sub *b-u* *b-tt*)
        (inst dec *b-u*)                                  ; word id
        (inst mov *b-tt* *b-u*)
        (inst shr *b-tt* :cl)                             ; transform id
        (inst cmp *b-tt* 120)
        (inst jmp :a lisp-restore)
        (inst mov *b-nb* 1)
        (inst shl *b-nb* :cl)
        (inst dec *b-nb*)
        (inst and *b-u* *b-nb*)                           ; word index
        (inst imul *b-u* *b-w*)
        (inst add *b-u* (ea (+ +b-d+ 200) *b-acc* *b-w* 8)) ; + doffset[len]
        (inst shl *b-tt* 5)
        (inst mov *b-acc* (b-cx :dtrans))
        ;; omit first / last: cut = min(k, len)
        (inst movzx '(:byte :dword) *b-rcx* (ea (+ +b-d+ 4) *b-acc* *b-tt*))
        (inst cmp *b-rcx* *b-w*)
        (inst cmov :a *b-rcx* *b-w*)
        (inst add *b-u* *b-rcx*)
        (inst sub *b-w* *b-rcx*)
        (inst movzx '(:byte :dword) *b-rcx* (ea (+ +b-d+ 5) *b-acc* *b-tt*))
        (inst cmp *b-rcx* *b-w*)
        (inst cmov :a *b-rcx* *b-w*)
        (inst sub *b-w* *b-rcx*)
        (inst mov *b-nb* (b-cx :out))
        (inst mov *b-p* (b-cx :dict))
        ;; prefix
        (inst mov *b-rcx* (ea (+ +b-d+ 8) *b-acc* *b-tt*))
        (inst mov (ea +b-d+ *b-nb* *b-pos*) *b-rcx*)
        (inst movzx '(:byte :dword) *b-rcx* (ea +b-d+ *b-acc* *b-tt*))
        (inst add *b-pos* *b-rcx*)
        ;; word (<= 24 bytes; 32 copied)
        (inst movdqu *b-x0* (ea +b-d+ *b-p* *b-u*))
        (inst movdqu (ea +b-d+ *b-nb* *b-pos*) *b-x0*)
        (inst movdqu *b-x0* (ea (+ 16 +b-d+) *b-p* *b-u*))
        (inst movdqu (ea (+ 16 +b-d+) *b-nb* *b-pos*) *b-x0*)
        (inst movzx '(:byte :dword) *b-rcx* (ea (+ +b-d+ 6) *b-acc* *b-tt*))
        (inst test *b-rcx* *b-rcx*)
        (inst jmp :nz upper)
        (emit-label up-done)
        (inst add *b-pos* *b-w*)
        ;; suffix
        (inst mov *b-rcx* (ea (+ +b-d+ 16) *b-acc* *b-tt*))
        (inst mov (ea +b-d+ *b-nb* *b-pos*) *b-rcx*)
        (inst movzx '(:byte :dword) *b-rcx* (ea (+ +b-d+ 3) *b-acc* *b-tt*))
        (inst add *b-pos* *b-rcx*)
        (inst movq *b-acc* x1)
        (inst movq *b-nb* x2)
        (inst movq *b-p* x3)
        (inst jmp *b-cmd-loop*)
        ;; uppercase (RFC 7932 8, ToUpperCase) on the word at POS..POS+W:
        ;; RCX = 1 first character, 2 all.  E = index, U = end.
        (emit-label upper)
        (inst mov *b-e* *b-pos*)
        (inst lea *b-u* (ea 0 *b-pos* *b-w*))
        (inst mov (b-sv :tmp) *b-rcx*)
        (emit-label up-loop)
        (inst cmp *b-e* *b-u*)
        (inst jmp :ge up-done)
        (inst movzx '(:byte :dword) *b-rcx* (ea +b-d+ *b-nb* *b-e*))
        (inst cmp *b-rcx* 192)
        (inst jmp :ae c2)
        (inst sub *b-rcx* 97)                             ; 'a'..'z' -> 0..25
        (inst cmp *b-rcx* 25)
        (inst jmp :a step1)
        (inst xor :byte (ea +b-d+ *b-nb* *b-e*) 32)
        (emit-label step1)
        (inst inc *b-e*)
        (inst jmp up-next)
        (emit-label c2)
        (inst cmp *b-rcx* 224)
        (inst jmp :ae c3)
        (inst lea *b-rcx* (ea 1 *b-e*))
        (inst cmp *b-rcx* *b-u*)
        (inst jmp :ge step2)
        (inst xor :byte (ea (+ 1 +b-d+) *b-nb* *b-e*) 32)
        (emit-label step2)
        (inst add *b-e* 2)
        (inst jmp up-next)
        (emit-label c3)
        (inst lea *b-rcx* (ea 2 *b-e*))
        (inst cmp *b-rcx* *b-u*)
        (inst jmp :ge step3)
        (inst xor :byte (ea (+ 2 +b-d+) *b-nb* *b-e*) 5)
        (emit-label step3)
        (inst add *b-e* 3)
        (emit-label up-next)
        (inst cmp :qword (b-sv :tmp) 1)                   ; first character only
        (inst jmp :e up-done)
        (inst jmp up-loop)
        (emit-label lisp-restore)
        (inst movq *b-acc* x1)
        (inst movq *b-nb* x2)
        (inst movq *b-p* x3)
        (emit-label lisp)
        (inst mov *b-u* (b-sv :dist))
        (inst jmp fallback))))

  (defun b-maxdist (dst)
    ;; DST = min(window, pos - origin)
    (inst mov dst *b-pos*)
    (inst sub dst (b-sv :origin))
    (inst cmp dst (b-sv :window))
    (inst cmov :a dst (b-sv :window)))

  (defun b-distance-and-copy (update noupdate)
    ;; U = distance.  UPDATE: a new distance, pushed on the ring if it is a
    ;; back-reference.  Then the copy of ST[CLEN] bytes; back to CMD-LOOP.
    (let ((copy (gen-label)) (copy16 (gen-label)) (small (gen-label))
          (cs-loop (gen-label)) (grow (gen-label)) (grown (gen-label))
          (fix (gen-label)) (bytes (gen-label)) (dict (gen-label))
          (near-end (gen-label)) (near16 (gen-label)) (near-small (gen-label))
          (ns-loop (gen-label)) (ns-step (gen-label)) (ns-stepped (gen-label))
          (ns-pat (gen-label)) (ns-done (gen-label)))
      (emit-label update)
      (b-maxdist *b-tt*)
      (inst test *b-u* *b-u*)
      (inst jmp :le *b-bail*)
      (inst cmp *b-u* *b-tt*)
      (inst jmp :a dict)
      (inst mov *b-w* (b-sv :ring-idx))
      (inst mov *b-tt* *b-w*)
      (inst and *b-tt* 3)
      (inst mov (b-ring-ea *b-tt*) *b-u*)
      (inst inc *b-w*)
      (inst mov (b-sv :ring-idx) *b-w*)
      (inst jmp copy)
      (emit-label noupdate)
      (b-maxdist *b-tt*)
      (inst test *b-u* *b-u*)
      (inst jmp :le *b-bail*)
      (inst cmp *b-u* *b-tt*)
      (inst jmp :a dict)
      ;; U = distance, W = length, TT = source index, E = output
      (emit-label copy)
      (inst mov *b-w* (b-sv :clen))
      (inst mov *b-e* (b-cx :out))
      (inst mov *b-tt* *b-pos*)
      (inst sub *b-tt* *b-u*)
      ;; chunked copies may write up to 15 bytes past the copy: only while
      ;; that stays inside the meta-block
      (inst lea *b-rcx* (ea 16 *b-pos* *b-w*))
      (inst cmp *b-rcx* (b-sv :target))
      (inst jmp :g near-end)
      (inst cmp *b-u* 16)
      (inst jmp :b small)
      ;; overlapping and long (periodic data): after 64 bytes read from the
      ;; furthest whole period back, so that loads stop waiting on the
      ;; store just made (a 16-byte load straddling recent stores cannot
      ;; be forwarded)
      (inst cmp *b-u* *b-w*)
      (inst jmp :ae copy16)
      (inst cmp *b-w* 128)
      (inst jmp :be copy16)
      (dotimes (k 4)
        (inst movdqu *b-x0* (ea +b-d+ *b-e* *b-tt*))
        (inst movdqu (ea +b-d+ *b-e* *b-pos*) *b-x0*)
        (inst add *b-tt* 16)
        (inst add *b-pos* 16))
      (inst sub *b-w* 64)
      (inst cmp *b-u* 64)                          ; already 4 stores back
      (inst jmp :ae copy16)
      ;; 64 bytes are written: any multiple of the distance up to 64 +
      ;; distance reads only written bytes; take the first one past 64
      (inst mov *b-rcx* *b-u*)
      (emit-label grow)
      (inst cmp *b-rcx* 64)
      (inst jmp :a grown)
      (inst add *b-rcx* *b-u*)
      (inst jmp grow)
      (emit-label grown)
      (inst mov *b-tt* *b-pos*)
      (inst sub *b-tt* *b-rcx*)
      (emit-label copy16)
      (inst movdqu *b-x0* (ea +b-d+ *b-e* *b-tt*))
      (inst movdqu (ea +b-d+ *b-e* *b-pos*) *b-x0*)
      (inst add *b-tt* 16)
      (inst add *b-pos* 16)
      (inst sub *b-w* 16)
      (inst jmp :g copy16)
      (emit-label fix)
      (inst add *b-pos* *b-w*)                     ; undo the overshoot
      (inst jmp *b-cmd-loop*)
      ;; distance < 16: the first 16 bytes one at a time; longer copies
      ;; then repeat that 16-byte pattern with stores only, stepping by the
      ;; largest multiple of the distance <= 16
      (emit-label small)
      (inst mov (b-sv :tmp) *b-u*)
      (inst mov *b-u* 16)
      (emit-label cs-loop)
      (inst movzx '(:byte :dword) *b-rcx* (ea +b-d+ *b-e* *b-tt*))
      (inst mov :byte (ea +b-d+ *b-e* *b-pos*) *b-rcx*)
      (inst inc *b-tt*)
      (inst inc *b-pos*)
      (inst dec *b-u*)
      (inst jmp :nz cs-loop)
      (inst sub *b-w* 16)
      (inst jmp :le fix)
      (inst movdqu *b-x0* (ea (- +b-d+ 16) *b-e* *b-pos*))   ; phase 0 at pos-16
      (inst mov *b-u* (b-sv :tmp))
      (inst mov *b-rcx* *b-u*)
      (let ((step (gen-label)) (stepped (gen-label)) (pat (gen-label)))
        (emit-label step)
        (inst lea *b-tt* (ea 0 *b-rcx* *b-u*))
        (inst cmp *b-tt* 16)
        (inst jmp :a stepped)
        (inst mov *b-rcx* *b-tt*)
        (inst jmp step)
        (emit-label stepped)
        (inst lea *b-tt* (ea -16 *b-pos* *b-rcx*))  ; next store: start + step
        (inst add *b-w* *b-pos*)                    ; W = end
        (emit-label pat)
        (inst movdqu (ea +b-d+ *b-e* *b-tt*) *b-x0*)
        (inst add *b-tt* *b-rcx*)
        (inst cmp *b-tt* *b-w*)
        (inst jmp :b pat)
        (inst mov *b-pos* *b-w*)
        (inst jmp *b-cmd-loop*))
      ;; Ends within 16 bytes of the meta-block end (a copy filling the
      ;; rest of the block - 100 KB ones in zero runs): the bulk as above
      ;; but stopping 16 short, then an exact finish.
      (emit-label near-end)
      (inst cmp *b-w* 32)
      (inst jmp :b bytes)
      (inst lea *b-rcx* (ea 0 *b-pos* *b-w*))
      (inst mov (b-sv :cend) *b-rcx*)              ; end of the copy
      (inst cmp *b-u* 16)
      (inst jmp :b near-small)
      ;; distance >= 16: chunks for all but the last 16 bytes (they write at
      ;; most to end - 1), then one 16-byte move ending exactly at the end
      ;; (its source ends at end - distance <= end - 16: written already)
      (inst sub *b-w* 16)
      (emit-label near16)
      (inst movdqu *b-x0* (ea +b-d+ *b-e* *b-tt*))
      (inst movdqu (ea +b-d+ *b-e* *b-pos*) *b-x0*)
      (inst add *b-tt* 16)
      (inst add *b-pos* 16)
      (inst sub *b-w* 16)
      (inst jmp :g near16)
      (inst mov *b-pos* (b-sv :cend))
      (inst mov *b-tt* *b-pos*)
      (inst sub *b-tt* *b-u*)
      (inst movdqu *b-x0* (ea (- +b-d+ 16) *b-e* *b-tt*))
      (inst movdqu (ea (- +b-d+ 16) *b-e* *b-pos*) *b-x0*)
      (inst jmp *b-cmd-loop*)
      ;; distance < 16: 16 bytes one at a time, pattern stores while they
      ;; fit, the rest one at a time
      (emit-label near-small)
      (inst mov (b-sv :tmp) *b-u*)
      (inst mov *b-u* 16)
      (emit-label ns-loop)
      (inst movzx '(:byte :dword) *b-rcx* (ea +b-d+ *b-e* *b-tt*))
      (inst mov :byte (ea +b-d+ *b-e* *b-pos*) *b-rcx*)
      (inst inc *b-tt*)
      (inst inc *b-pos*)
      (inst dec *b-u*)
      (inst jmp :nz ns-loop)
      (inst movdqu *b-x0* (ea (- +b-d+ 16) *b-e* *b-pos*))
      (inst mov *b-u* (b-sv :tmp))
      (inst mov *b-rcx* *b-u*)
      (emit-label ns-step)
      (inst lea *b-tt* (ea 0 *b-rcx* *b-u*))
      (inst cmp *b-tt* 16)
      (inst jmp :a ns-stepped)
      (inst mov *b-rcx* *b-tt*)
      (inst jmp ns-step)
      (emit-label ns-stepped)
      (inst lea *b-tt* (ea -16 *b-pos* *b-rcx*))  ; next store: start + step
      (inst mov *b-w* (b-sv :cend))
      (emit-label ns-pat)
      (inst lea *b-u* (ea 16 *b-tt*))
      (inst cmp *b-u* *b-w*)
      (inst jmp :a ns-done)
      (inst movdqu (ea +b-d+ *b-e* *b-tt*) *b-x0*)
      (inst add *b-tt* *b-rcx*)
      (inst jmp ns-pat)
      (emit-label ns-done)
      ;; written up to the last store's end (or the first 16 bytes)
      (inst lea *b-pos* (ea 16 *b-tt*))
      (inst sub *b-pos* *b-rcx*)
      (inst mov *b-u* (b-sv :tmp))
      (inst mov *b-tt* *b-pos*)
      (inst sub *b-tt* *b-u*)
      (inst sub *b-w* *b-pos*)
      (inst test *b-w* *b-w*)
      (inst jmp :le *b-cmd-loop*)
      ;; near the meta-block end: exact byte copy
      (emit-label bytes)
      (inst movzx '(:byte :dword) *b-rcx* (ea +b-d+ *b-e* *b-tt*))
      (inst mov :byte (ea +b-d+ *b-e* *b-pos*) *b-rcx*)
      (inst inc *b-tt*)
      (inst inc *b-pos*)
      (inst dec *b-w*)
      (inst jmp :g bytes)
      (inst jmp *b-cmd-loop*)
      (emit-label dict)
      (b-dict-word *b-dict*)))

  (defun b-lit-pointers ()
    ;; Raw pointers for the context-literal loop (the driver pins both
    ;; vectors): ST[LUTP] = the block type's context-mode LUT, ST[ROWP] =
    ;; its row of 64 per-context table descriptors in CTX[CTXTABS].
    (inst mov *b-u* (b-cx :ctx-table))
    (inst add *b-u* (b-sv :lutoff))
    (inst add *b-u* +b-d+)
    (inst mov (b-sv :lutp) *b-u*)
    (inst mov *b-u* (b-cx :ctxtabs))
    (inst mov *b-tt* (b-sv :litrow))
    (inst lea *b-u* (ea +b-d+ *b-u* *b-tt* 8))
    (inst mov (b-sv :rowp) *b-u*))

  (defun b-select-dist-tree-early ()
    ;; B-SELECT-DIST-TREE from the command's LUT word (E = command, W =
    ;; word): only for commands with an explicit distance
    (let ((skip (gen-label)))
      (inst cmp *b-e* 128)
      (inst jmp :b skip)
      (inst mov *b-tt* *b-w*)
      (inst shr *b-tt* 48)
      (inst add *b-tt* (b-sv :drow))
      (inst mov *b-u* (b-cx :cmapd))
      (inst movzx '(:byte :dword) *b-tt* (ea +b-d+ *b-u* *b-tt*))
      (inst mov (b-sv :dtree) *b-tt*)
      (inst mov *b-u* (b-cx :dparams))
      (inst mov *b-u* (ea +b-d+ *b-u* *b-tt* 8))
      (inst mov (b-sv :dparam) *b-u*)
      (emit-label skip)))

  (defun b-select-dist-tree ()
    ;; distance tree for this command's copy length context min(clen-2, 3)
    ;; and the current distance block type -> ST[DTREE], ST[DPARAM].  C
    ;; does this when it reads the command, so that the lookups are done
    ;; by the time the distance is read after the literals.
    (let ((c-ok (gen-label)))
      (inst mov *b-tt* (b-sv :clen))
      (inst sub *b-tt* 2)
      (inst cmp *b-tt* 3)
      (inst jmp :be c-ok)
      (inst mov *b-tt* 3)
      (emit-label c-ok)
      (inst add *b-tt* (b-sv :drow))
      (inst mov *b-u* (b-cx :cmapd))
      (inst movzx '(:byte :dword) *b-tt* (ea +b-d+ *b-u* *b-tt*))
      (inst mov (b-sv :dtree) *b-tt*)
      (inst mov *b-u* (b-cx :dparams))
      (inst mov *b-u* (ea +b-d+ *b-u* *b-tt* 8))
      (inst mov (b-sv :dparam) *b-u*)))

  (defun b-snapshot ()
    (destructuring-bind (x1 x2 x3 x4 &rest more) *b-snap*
      (declare (ignore more))
      (inst movq x1 *b-acc*)
      (inst movq x2 *b-nb*)
      (inst movq x3 *b-p*)
      (inst movq x4 *b-pos*)))

  (defun b-exits (restore-more)
    ;; BAIL restores the command-start snapshot (RESTORE-MORE emits the
    ;; rest); DICT keeps everything.  Then write the state back.
    (let ((finish (gen-label)) (give (gen-label)) (given (gen-label)))
      (emit-label *b-bail*)
      (destructuring-bind (x1 x2 x3 x4 &rest more) *b-snap*
        (declare (ignore more))
        (inst movq *b-acc* x1)
        (inst movq *b-nb* x2)
        (inst movq *b-p* x3)
        (inst movq *b-pos* x4))
      (funcall restore-more)
      (inst mov *b-e* 1)
      (inst jmp finish)
      (emit-label *b-dict*)
      (inst mov (b-sv :dist) *b-u*)
      (inst mov *b-e* 2)
      (inst jmp finish)
      (emit-label *b-done*)
      (inst xor *b-e* *b-e*)
      (emit-label finish)
      (inst mov (b-sv :exit) *b-e*)
      ;; hand back whole bytes above 56 bits, then clear the bits at and
      ;; above NB: the Lisp reader wants ACC < 2^NB, a fixnum
      (emit-label give)
      (inst cmp *b-nb* 56)
      (inst jmp :be given)
      (inst sub *b-nb* 8)
      (inst dec *b-p*)
      (inst jmp give)
      (emit-label given)
      (inst mov *b-rcx* *b-nb*)
      (inst mov *b-e* 1)
      (inst shl *b-e* :cl)
      (inst dec *b-e*)
      (inst and *b-acc* *b-e*)
      (inst mov (b-sv :acc) *b-acc*)
      (inst mov (b-sv :nb) *b-nb*)
      (inst mov (b-sv :p) *b-p*)
      (inst mov (b-sv :pos) *b-pos*)))

  (defun b-block-switch (type prev ntypes count bt bl bt-param bl-param
                         flag snap-type snap-prev)
    ;; read a block switch command of one category: new type and count
    (let ((noted (gen-label)) (use-prev (gen-label)) (use-inc (gen-label))
          (set (gen-label)))
      (inst cmp :qword (b-sv ntypes) 1)
      (inst jmp :be *b-bail*)
      ;; first switch of this category in the command: remember the old
      ;; type for a bail
      (inst mov *b-tt* (b-sv :flags))
      (inst test *b-tt* flag)
      (inst jmp :nz noted)
      (inst or *b-tt* flag)
      (inst mov (b-sv :flags) *b-tt*)
      (inst mov *b-tt* (b-sv type))
      (inst mov (b-sv snap-type) *b-tt*)
      (inst mov *b-tt* (b-sv prev))
      (inst mov (b-sv snap-prev) *b-tt*)
      (emit-label noted)
      (b-ensure 15 *b-e*)
      (inst mov *b-u* (b-cx bt))
      (b-sym *b-u* bt-param)
      (inst mov *b-tt* (b-sv type))
      (inst cmp *b-e* 1)
      (inst jmp :b use-prev)
      (inst jmp :e use-inc)
      (inst sub *b-e* 2)
      (inst jmp set)
      (emit-label use-prev)
      (inst mov *b-e* (b-sv prev))
      (inst jmp set)
      (emit-label use-inc)
      (inst lea *b-e* (ea 1 *b-tt*))
      (inst cmp *b-e* (b-sv ntypes))
      (inst jmp :b set)
      (inst xor *b-e* *b-e*)
      (emit-label set)
      (inst mov (b-sv prev) *b-tt*)
      (inst mov (b-sv type) *b-e*)
      (b-ensure 15 *b-e*)
      (inst mov *b-u* (b-cx bl))
      (b-sym *b-u* bl-param)                       ; block length code 0..25
      (b-ensure 24 *b-tt*)
      (inst mov *b-tt* (ea (+ +b-d+ (* 8 (brotli-st-index :blen0))) *b-st* *b-e* 8))
      (inst mov *b-rcx* *b-tt*)
      (inst shr *b-rcx* 32)
      (b-getbits *b-u*)
      (inst mov :dword *b-e* *b-tt*)
      (inst add *b-e* *b-u*)
      (inst mov (b-sv count) *b-e*))))

#+cl-brotli-x86-64
(sb-ext:without-package-locks
  (define-vop (cl-brotli-asm-simple-meta-block)
    ;; one block type and one tree per category (C's q0-q4 shape)
    (:policy :fast-safe)
    (:translate cl-brotli.lisp::%asm-simple-meta-block)
    (:args (st :scs (descriptor-reg))
           (ctx :scs (descriptor-reg)))
    (:arg-types simple-array-unsigned-byte-64 simple-vector)
    (:temporary (:sc unsigned-reg :offset rcx-offset) rcx)
    (:temporary (:sc unsigned-reg) acc)
    (:temporary (:sc unsigned-reg) nb)
    (:temporary (:sc unsigned-reg) p)
    (:temporary (:sc unsigned-reg) pos)
    (:temporary (:sc unsigned-reg) e)
    (:temporary (:sc unsigned-reg) tt)
    (:temporary (:sc unsigned-reg) u)
    (:temporary (:sc unsigned-reg) w)
    (:temporary (:sc int-sse-reg) x0)
    (:temporary (:sc int-sse-reg) x1)
    (:temporary (:sc int-sse-reg) x2)
    (:temporary (:sc int-sse-reg) x3)
    (:temporary (:sc int-sse-reg) x4)
    (:generator 1000
      (let ((*b-st* st) (*b-ctx* ctx) (*b-rcx* rcx) (*b-acc* acc) (*b-nb* nb)
            (*b-p* p) (*b-pos* pos) (*b-e* e) (*b-tt* tt) (*b-u* u) (*b-w* w)
            (*b-x0* x0) (*b-snap* (list x1 x2 x3 x4))
            (*b-bail* (gen-label)) (*b-dict* (gen-label)) (*b-done* (gen-label))
            (*b-cmd-loop* (gen-label))
            (lits-done (gen-label)) (dist-read (gen-label))
            (update (gen-label)) (noupdate (gen-label)))
        (inst mov acc (b-sv :acc))
        (inst mov nb (b-sv :nb))
        (inst mov p (b-sv :p))
        (inst mov pos (b-sv :pos))
        (emit-label *b-cmd-loop*)
        (inst cmp pos (b-sv :target))
        (inst jmp :ge *b-done*)
        (b-snapshot)
        (b-ensure 15 e)
        (inst mov u (b-cx :ctable))
        (b-sym u :cmd-param)
        (b-command-lengths)
        (inst test e e)
        (inst jmp :z lits-done)
        (inst lea tt (ea 0 pos e))
        (inst mov (b-sv :pend) tt)
        (inst mov u (b-cx :ltable))
        (inst mov w (b-cx :out))
        (b-lits-fixed)
        (emit-label lits-done)
        (b-after-literals)
        (inst mov e (b-sv :cmd))
        (inst cmp e 128)
        (inst jmp :ae dist-read)
        (b-implicit-distance noupdate)
        (emit-label dist-read)
        (b-ensure 15 e)
        (inst mov u (b-cx :dtable))
        (b-sym u :dparam)
        (b-distance-value update noupdate)
        (b-distance-and-copy update noupdate)
        (b-exits (lambda ()))))))

#+cl-brotli-x86-64
(sb-ext:without-package-locks
  (define-vop (cl-brotli-asm-general-meta-block)
    ;; block switches, context-modeled literals, distance context maps
    (:policy :fast-safe)
    (:translate cl-brotli.lisp::%asm-general-meta-block)
    (:args (st :scs (descriptor-reg))
           (ctx :scs (descriptor-reg)))
    (:arg-types simple-array-unsigned-byte-64 simple-vector)
    (:temporary (:sc unsigned-reg :offset rcx-offset) rcx)
    (:temporary (:sc unsigned-reg) acc)
    (:temporary (:sc unsigned-reg) nb)
    (:temporary (:sc unsigned-reg) p)
    (:temporary (:sc unsigned-reg) pos)
    (:temporary (:sc unsigned-reg) e)
    (:temporary (:sc unsigned-reg) tt)
    (:temporary (:sc unsigned-reg) u)
    (:temporary (:sc unsigned-reg) w)
    (:temporary (:sc unsigned-reg) p12)
    (:temporary (:sc int-sse-reg) x0)
    (:temporary (:sc int-sse-reg) x1)
    (:temporary (:sc int-sse-reg) x2)
    (:temporary (:sc int-sse-reg) x3)
    (:temporary (:sc int-sse-reg) x4)
    (:temporary (:sc int-sse-reg) x5)
    (:temporary (:sc int-sse-reg) x6)
    (:temporary (:sc int-sse-reg) x7)
    (:generator 1000
      (let ((*b-st* st) (*b-ctx* ctx) (*b-rcx* rcx) (*b-acc* acc) (*b-nb* nb)
            (*b-p* p) (*b-pos* pos) (*b-e* e) (*b-tt* tt) (*b-u* u) (*b-w* w)
            (*b-x0* x0) (*b-snap* (list x1 x2 x3 x4 x5 x6 x7))
            (*b-bail* (gen-label)) (*b-dict* (gen-label)) (*b-done* (gen-label))
            (*b-cmd-loop* (gen-label))
            (i-ok (gen-label)) (piece-loop (gen-label)) (have (gen-label))
            (ctx-piece (gen-label)) (piece-end (gen-label)) (lits-done (gen-label))
            (ctx-lit (gen-label)) (ctx-sub (gen-label)) (ctx-store (gen-label))
            (p-small (gen-label)) (p-go (gen-label))
            (dist-read (gen-label)) (d-ok (gen-label))
            (update (gen-label)) (noupdate (gen-label)))
        (inst mov acc (b-sv :acc))
        (inst mov nb (b-sv :nb))
        (inst mov p (b-sv :p))
        (inst mov pos (b-sv :pos))
        (b-lit-pointers)
        ;; ------------------------------------------------------ command
        (emit-label *b-cmd-loop*)
        (inst cmp pos (b-sv :target))
        (inst jmp :ge *b-done*)
        (b-snapshot)
        (inst movq x5 (b-sv :lcount))
        (inst movq x7 (b-sv :dcount))
        (inst mov e (b-sv :icount))
        (inst movq x6 e)
        (inst mov :qword (b-sv :flags) 0)
        (inst test e e)
        (inst jmp :nz i-ok)
        (b-block-switch :itype :iprev :intypes :icount :ibt :ibl
                        :ibt-param :ibl-param 2 :snap-itype :snap-iprev)
        (inst mov tt (b-sv :itype))
        (inst mov u (b-cx :cparams))
        (inst mov u (ea +b-d+ u tt 8))
        (inst mov (b-sv :cmd-param) u)
        (inst mov e (b-sv :icount))
        (emit-label i-ok)
        (inst dec e)
        (inst mov (b-sv :icount) e)
        (b-ensure 15 e)
        (inst mov u (b-cx :ctabs))
        (inst mov tt (b-sv :itype))
        (inst mov u (ea +b-d+ u tt 8))
        (b-sym u :cmd-param)
        (b-command-lengths #'b-select-dist-tree-early)
        (inst test e e)
        (inst jmp :z lits-done)
        (inst mov (b-sv :left) e)
        ;; ------------------------------------------------------ literals
        ;; in pieces that end at literal-block boundaries
        (emit-label piece-loop)
        (inst mov e (b-sv :lcount))
        (inst test e e)
        (inst jmp :nz have)
        (b-block-switch :ltype :lprev :lntypes :lcount :lbt :lbl
                        :lbt-param :lbl-param 1 :snap-ltype :snap-lprev)
        (inst mov tt (b-sv :ltype))
        (inst mov u (b-cx :cmodes))
        (inst movzx '(:byte :dword) u (ea +b-d+ u tt))
        (inst shl u 9)
        (inst mov (b-sv :lutoff) u)
        (inst mov u tt)
        (inst shl u 6)
        (inst mov (b-sv :litrow) u)
        (inst mov u (b-cx :ltriv))
        (inst mov u (ea +b-d+ u tt 8))
        (inst mov (b-sv :triv) u)
        (b-lit-pointers)
        (inst mov e (b-sv :lcount))
        (emit-label have)
        ;; piece = min(count, left)
        (inst mov tt (b-sv :left))
        (inst cmp e tt)
        (inst cmov :a e tt)
        (inst mov tt (b-sv :lcount))
        (inst sub tt e)
        (inst mov (b-sv :lcount) tt)
        (inst mov tt (b-sv :left))
        (inst sub tt e)
        (inst mov (b-sv :left) tt)
        (inst lea tt (ea 0 pos e))
        (inst mov (b-sv :pend) tt)
        (inst mov w (b-cx :out))
        (inst mov tt (b-sv :triv))
        (inst test tt tt)
        (inst jmp :s ctx-piece)
        ;; one tree for every context of this block type
        (inst mov u (b-cx :ltabs))
        (inst mov u (ea +b-d+ u tt 8))
        (b-lits-fixed)
        (inst jmp piece-end)
        ;; context-modeled: P12 = p1, W = p2 (zero before the origin).  Per
        ;; literal: LUT[p1] | LUT[256 + p2] -> the context's table (one load
        ;; from the block type's descriptor row) -> entry; the next p1 is
        ;; the symbol itself.
        (emit-label ctx-piece)
        (inst xor p12 p12)
        (inst xor tt tt)
        (inst mov u pos)
        (inst sub u (b-sv :origin))
        (inst cmp u 2)
        (inst jmp :b p-small)
        (inst movzx '(:byte :dword) p12 (ea (- +b-d+ 1) w pos))
        (inst movzx '(:byte :dword) tt (ea (- +b-d+ 2) w pos))
        (inst jmp p-go)
        (emit-label p-small)
        (inst test u u)
        (inst jmp :z p-go)
        (inst movzx '(:byte :dword) p12 (ea (- +b-d+ 1) w pos))
        (emit-label p-go)
        (inst mov w tt)
        (emit-label ctx-lit)
        (b-ensure 15 e)
        (inst mov u (b-sv :lutp))
        (inst movzx '(:byte :dword) e (ea 0 u p12))            ; LUT[p1]
        (inst movzx '(:byte :dword) tt (ea 256 u w))           ; LUT[256+p2]
        (inst or e tt)
        (inst mov u (b-sv :rowp))
        (inst mov u (ea 0 u e 8))                              ; table
        (inst movzx '(:byte :dword) e acc)
        (inst movzx '(:word :dword) e (ea +b-d+ u e 2))
        (inst mov rcx e)
        (inst and rcx 15)
        (inst cmp rcx 8)
        (inst jmp :a ctx-sub)
        (inst shr acc :cl)
        (inst sub nb rcx)
        (inst shr e 4)
        (emit-label ctx-store)
        (inst mov u (b-cx :out))
        (inst mov :byte (ea +b-d+ u pos) e)
        (inst inc pos)
        (inst mov w p12)
        (inst mov p12 e)
        (inst cmp pos (b-sv :pend))
        (inst jmp :l ctx-lit)
        (emit-label piece-end)
        (inst mov e (b-sv :left))
        (inst test e e)
        (inst jmp :nz piece-loop)
        (emit-label lits-done)
        (b-after-literals)
        ;; ------------------------------------------------------ distance
        (inst mov e (b-sv :cmd))
        (inst cmp e 128)
        (inst jmp :ae dist-read)
        (b-implicit-distance noupdate)
        (emit-label dist-read)
        (inst mov e (b-sv :dcount))
        (inst test e e)
        (inst jmp :nz d-ok)
        (b-block-switch :dtype :dprev :dntypes :dcount :dbt :dbl
                        :dbt-param :dbl-param 4 :snap-dtype :snap-dprev)
        (inst mov tt (b-sv :dtype))
        (inst shl tt 2)
        (inst mov (b-sv :drow) tt)
        (b-select-dist-tree)                       ; new block type
        (inst mov e (b-sv :dcount))
        (emit-label d-ok)
        (inst dec e)
        (inst mov (b-sv :dcount) e)
        (inst mov u (b-cx :dtabs))
        (inst mov tt (b-sv :dtree))
        (inst mov u (ea +b-d+ u tt 8))
        (b-ensure 15 e)
        (b-sym u :dparam)
        (b-distance-value update noupdate)
        (b-distance-and-copy update noupdate)
        ;; literal code longer than 8 bits
        (emit-label ctx-sub)
        (b-lit-sub)
        (inst jmp ctx-store)
        (b-exits
         (lambda ()
           ;; counts as at the command start; types/prevs of categories
           ;; that switched in this command
           (let ((nl (gen-label)) (ni (gen-label)) (nd (gen-label)))
             (inst movq (b-sv :lcount) x5)
             (inst movq (b-sv :icount) x6)
             (inst movq (b-sv :dcount) x7)
             (inst mov e (b-sv :flags))
             (inst test e 1)
             (inst jmp :z nl)
             (inst mov tt (b-sv :snap-ltype))
             (inst mov (b-sv :ltype) tt)
             (inst mov tt (b-sv :snap-lprev))
             (inst mov (b-sv :lprev) tt)
             (emit-label nl)
             (inst test e 2)
             (inst jmp :z ni)
             (inst mov tt (b-sv :snap-itype))
             (inst mov (b-sv :itype) tt)
             (inst mov tt (b-sv :snap-iprev))
             (inst mov (b-sv :iprev) tt)
             (emit-label ni)
             (inst test e 4)
             (inst jmp :z nd)
             (inst mov tt (b-sv :snap-dtype))
             (inst mov (b-sv :dtype) tt)
             (inst mov tt (b-sv :snap-dprev))
             (inst mov (b-sv :dprev) tt)
             (emit-label nd))))))))
