;;;; mutation/journal.lisp -- readable durable receipts for committed mutations.

(in-package :cl-agent)

(defun mutation-journal-path (transaction)
  (merge-pathnames (format nil "~a.sexp" (mutation-id transaction))
                   (mutation-journal-directory)))

(defun write-mutation-journal (transaction)
  (ensure-mutation-directories)
  (call-with-atomic-output-file
   (mutation-journal-path transaction)
   (lambda (out) (let ((*print-pretty* t)) (pprint (mutation->plist transaction) out)))))

(defun commit-mutation (transaction &key (enable-p t))
  "Atomically publish the active source only after a successful install."
  (unless (eq (mutation-state transaction) :installed)
    (error "Mutation ~a must be installed before commit" (mutation-id transaction)))
  (write-string-atomically (mutation-target transaction) (mutation-source transaction))
  (when enable-p (set-extension-enabled (mutation-filename transaction) t))
  (setf (mutation-state transaction) :committed)
  (mutation-receipt transaction :committed :target (namestring (mutation-target transaction))
                    :enabled-p enable-p)
  (write-mutation-journal transaction)
  (emit-event :mutation-committed :component (mutation-owner transaction)
              :payload (mutation->plist transaction))
  transaction)
