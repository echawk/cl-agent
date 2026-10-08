;;;; mutation/journal.lisp -- readable durable receipts for committed mutations.

(in-package :cl-agent)

(defun mutation-journal-path (transaction)
  (merge-pathnames (format nil "~a.sexp" (mutation-id transaction))
                   (mutation-journal-directory)))

(defun mutation-journal-value (value)
  "Project VALUE into readable, detached data for a durable journal.

Mutation review evidence can include implementation objects such as a MALLET
violation.  Those are useful while the transaction is live but have neither a
portable reader syntax nor a valid meaning after restart.  Keep ordinary
structured evidence intact and record such objects by their diagnostic text."
  (typecase value
    ((or null string number character symbol pathname) value)
    (cons (cons (mutation-journal-value (car value))
                (mutation-journal-value (cdr value))))
    (vector (map 'vector #'mutation-journal-value value))
    (t (princ-to-string value))))

(defun mutation-journal-projection (transaction)
  "Return the data-only durable projection of TRANSACTION."
  (mutation-journal-value (mutation->plist transaction)))

(defun write-mutation-journal (transaction)
  (ensure-mutation-directories)
  (sexp-store:snapshot-write (mutation-journal-path transaction)
                             (mutation-journal-projection transaction)))

(defun read-mutation-journal (transaction)
  "Return TRANSACTION's complete durable journal projection, or NIL if absent.

Unlike the former ad-hoc printer path, this rejects a partial or concatenated
file.  Recovery code can therefore treat a returned projection as one atomic
commit record rather than attempting to infer a transaction from torn text."
  (let ((path (mutation-journal-path transaction)))
    (when (probe-file path)
      (multiple-value-bind (journal complete-p)
          (sexp-store:snapshot-read path)
        (unless complete-p
          (error "Mutation journal ~a is not one complete snapshot" path))
        journal))))

(defun commit-mutation (transaction &key (enable-p t))
  "Atomically publish active source only after installation and exercises pass."
  (unless (eq (mutation-state transaction) :exercised)
    (error "Mutation ~a must pass exercises before commit" (mutation-id transaction)))
  (write-string-atomically (mutation-target transaction) (mutation-source transaction))
  (when enable-p (set-extension-enabled (mutation-filename transaction) t))
  (setf (mutation-state transaction) :committed)
  (mutation-receipt transaction :committed :target (namestring (mutation-target transaction))
                    :enabled-p enable-p)
  (write-mutation-journal transaction)
  (emit-event :mutation-committed :component (mutation-owner transaction)
              :payload (mutation->plist transaction))
  transaction)
