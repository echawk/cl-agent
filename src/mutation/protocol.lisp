;;;; mutation/protocol.lisp -- inspectable staged self-modification contracts.

(in-package :cl-agent)

(defclass mutation-transaction ()
  ((id :initarg :id :reader mutation-id)
   (owner :initarg :owner :reader mutation-owner)
   (filename :initarg :filename :reader mutation-filename)
   (target :initarg :target :reader mutation-target)
   (source :initarg :source :reader mutation-source)
   (staged-source :initarg :staged-source :reader mutation-staged-source)
   (state :initform :proposed :accessor mutation-state)
   (receipts :initform nil :accessor mutation-receipts)
   ;; Surgeon captures a callable undo closure for each top-level definition
   ;; installed by this transaction.  These are live-image state, deliberately
   ;; kept separate from the data-only definition-changes journal projection.
   (definition-undo-actions :initform nil :accessor mutation-definition-undo-actions)
   (definition-changes :initform nil :accessor mutation-definition-changes)
   ;; Registry snapshots can reverse registrations, not arbitrary top-level
   ;; effects or definition changes.  The receipt makes that limit explicit.
   (before-state :initform nil :accessor mutation-before-state)))

(defvar *mutations* (make-hash-table :test #'equal))
(defvar *mutation-sequence* 0)

(defun mutations-directory ()
  (merge-pathnames "state/mutations/" *config-directory*))
(defun mutation-journal-directory ()
  (merge-pathnames "state/mutation-journal/" *config-directory*))

(defun ensure-mutation-directories ()
  (ensure-directories-exist (merge-pathnames "placeholder" (mutations-directory)))
  (ensure-directories-exist (merge-pathnames "placeholder" (mutation-journal-directory))))

(defun normalized-extension-filename (filename)
  (unless (safe-scratch-filename-p filename)
    (error "Extension filename must be a non-empty basename, not a path: ~s" filename))
  (if (search ".lisp" filename :from-end t) filename (concatenate 'string filename ".lisp")))

(defun new-mutation-id ()
  (format nil "mutation-~d-~36r" (incf *mutation-sequence*) (random most-positive-fixnum)))

(defun mutation-receipt (transaction status &rest details)
  (let ((receipt (append (list :id (mutation-id transaction) :status status
                               :time (get-universal-time)) details)))
    (push receipt (mutation-receipts transaction))
    receipt))

(defun find-mutation (id)
  (gethash id *mutations*))

(defun list-mutations ()
  (sort (loop for transaction being the hash-values of *mutations* collect transaction)
        #'string< :key #'mutation-id))

(defun mutation->plist (transaction)
  (list :id (mutation-id transaction) :owner (mutation-owner transaction)
        :filename (mutation-filename transaction) :target (namestring (mutation-target transaction))
        :staged-source (namestring (mutation-staged-source transaction))
        :state (mutation-state transaction)
        :definition-changes (reverse (copy-tree (mutation-definition-changes transaction)))
        :receipts (reverse (copy-list (mutation-receipts transaction)))))
