;;;; mutation/exercises.lisp -- focused, owned verification for staged changes.

(in-package :cl-agent)

(defclass mutation-exercise ()
  ((id :initarg :id :reader mutation-exercise-id)
   (description :initarg :description :initform "" :reader mutation-exercise-description)
   (owner :initarg :owner :reader mutation-exercise-owner)
   (runner :initarg :runner :reader mutation-exercise-runner))
  (:documentation "A named, transaction-owned smoke check.

The runner receives no arguments and must return normally to pass.  It may
signal a condition to fail its mutation.  Exercises deliberately run after
the staged source has loaded into the live image, so they can invoke a newly
registered tool or inspect a newly installed hook/provider."))

(defvar *mutation-exercises* (make-hash-table :test #'equal)
  "Qualified exercise ID -> MUTATION-EXERCISE.")

(defun mutation-exercise-key (owner id)
  (format nil "~a/~a" owner (string-downcase (string id))))

(defun register-mutation-exercise (exercise)
  "Register EXERCISE under its owner, replacing an earlier exercise of that name."
  (setf (gethash (mutation-exercise-key (mutation-exercise-owner exercise)
                                         (mutation-exercise-id exercise))
                 *mutation-exercises*)
        exercise)
  exercise)

(defmacro define-mutation-exercise (name (&key description) &body body)
  "Define a focused verification check owned by the loading mutation.

Use this in an extension after its registrations.  BODY should signal an
error when its assertion fails.  For example:

  (define-mutation-exercise my-tool-smoke ()
    (unless (search \"ready\" (call-tool \"my-tool\" (jobj)))
      (error \"my-tool did not return its expected result\")))"
  `(register-mutation-exercise
    (make-instance 'mutation-exercise
                   :id ',name
                   :description ,description
                   :owner (or *registration-owner* "runtime")
                   :runner (lambda () ,@body))))

(defun mutation-exercises-owned-by (owner)
  (sort (loop for exercise being the hash-values of *mutation-exercises*
              when (equal owner (mutation-exercise-owner exercise))
              collect exercise)
        #'string< :key (lambda (exercise) (string-downcase (string (mutation-exercise-id exercise))))))

(defun mutation-component-exercise-evidence (transaction)
  "Return data-only evidence of components now owned by TRANSACTION.

This baseline observation makes every exercise receipt useful even for an
extension which declares no custom smoke test.  It intentionally does not
require a component: a DEFMETHOD-only extension is a supported integration."
  (mapcar #'component->plist
          (list-components :owner (mutation-owner transaction))))

;;; --- the extension's hooks, called with sample values ---
;;;
;;; A chain hook first runs in a real turn, on every tool call or request --
;;; so before an extension is committed, each chain hook it adds is called
;;; with realistic sample values (tool arguments are a hash table, empty
;;; ones too) and must return a value of the kind it was given, without
;;; error, within a time limit.  A hook that would have broken every turn
;;; fails the mutation instead, saying why.  (Veto points may refuse: an
;;; error there is how a hook vetoes.)

(defun sample-hook-values (hook-point)
  "Realistic values HOOK-POINT's chain hooks receive, or NIL to skip it."
  (case hook-point
    (:after-tool-call
     (list (list :tool-name "read-file" :arguments (jobj "path" "/no/such/dir/notes.txt")
                 :result "Error running read-file: The file #P\"/no/such/dir/notes.txt\" does not exist")
           (list :tool-name "recall" :arguments (make-hash-table :test 'equal)
                 :result "Nothing remembered matches.")))
    (:before-request
     (list (list :messages (list (list :role "system" :content "You are an agent.")
                                 (list :role "user" :content "Hello."))
                 :tools (list-tools))))
    (:after-response
     (list (list :role "assistant" :content "Done." :tool-calls nil)
           (list :role "assistant" :content nil
                 :tool-calls (list (list :id "c1" :name "recall" :arguments (make-hash-table :test 'equal))))))
    (:user-message (list (list :text "Hello.")))
    (:web-ui-page (list (list :html "<!doctype html><html><head></head><body></body></html>" :safe nil)))
    (:web-ui-state (list (jobj "messages" (list))))
    (:before-file-save (list (list :path "/no/such/dir/x.txt" :text "x")))
    (t nil)))

(defun mutation-owned-chain-hooks (transaction)
  "TRANSACTION's chain hooks: (hook-point name function)."
  (loop for descriptor in (list-components :kind :hook :owner (mutation-owner transaction))
        append (loop for (hook-point . entries) in (alexandria:hash-table-alist *hooks*)
                     append (loop for (name . function) in entries
                                  when (string-equal (format nil "~(~a~)/~(~a~)" hook-point name)
                                                     (component-descriptor-name descriptor))
                                    collect (list hook-point name function)))))

(defun exercise-mutation-hooks (transaction)
  "Call TRANSACTION's chain hooks with sample values; signal when one fails."
  (loop for (hook-point name function) in (mutation-owned-chain-hooks transaction)
        unless (member hook-point *veto-hook-points*)
          do (dolist (sample (sample-hook-values hook-point))
               (let* ((kind (hook-value-kind sample))
                      (problem
                        (handler-case
                            (let ((result (with-agent-code ()
                                            (sb-ext:with-timeout 20
                                              (funcall function (if (eq kind :plist) (copy-list sample) sample))))))
                              (unless (eq (hook-value-kind result) kind)
                                (format nil "it returned ~a, not the ~(~a~) it was given (a chain hook returns its argument, changed or not)"
                                        (let ((*print-length* 4) (*print-level* 2)) (prin1-to-string result)) kind)))
                          (serious-condition (condition)
                            (format nil "it signalled ~a: ~a" (type-of condition)
                                    (one-line (princ-to-string condition)))))))
                 (when problem
                   (mutation-receipt transaction :exercise
                                     :exercise-id (format nil "hook ~(~a~)/~(~a~)" hook-point name)
                                     :result :failed :detail problem)
                   (error "Its ~(~s~) hook ~(~a~) failed on a sample call -- ~a.~@[~%Tool arguments are a JSON object, a hash table: read them with (jget (getf ctx :arguments) \"path\"), not GETF.~]~%The sample was: ~a"
                          hook-point name problem
                          ;; GETF on the arguments: compiled, a TYPE-ERROR (not a
                          ;; LIST); interpreted, "malformed property list".
                          (and (search "HASH-TABLE" problem)
                               (or (search "property list" problem) (search "LIST" problem))
                               t)
                          (let ((*print-length* 8) (*print-level* 3)) (prin1-to-string sample))))))
             (mutation-receipt transaction :exercise
                               :exercise-id (format nil "hook ~(~a~)/~(~a~)" hook-point name)
                               :result :passed)))

(defun run-mutation-exercises (transaction)
  "Run TRANSACTION's owned checks and append a receipt for each result.

Signals on the first failed exercise.  The caller owns rollback, allowing the
same failure path to restore all behavioral registries before any source is
published."
  (let ((exercises (mutation-exercises-owned-by (mutation-owner transaction))))
    (mutation-receipt transaction :exercise
                       :exercise-id :component-inventory
                       :result :passed
                       :components (mutation-component-exercise-evidence transaction))
    (exercise-mutation-hooks transaction)
    (dolist (exercise exercises)
      (handler-case
          (progn
            (funcall (mutation-exercise-runner exercise))
            (mutation-receipt transaction :exercise
                               :exercise-id (mutation-exercise-id exercise)
                               :description (mutation-exercise-description exercise)
                               :result :passed))
        (serious-condition (condition)
          (mutation-receipt transaction :exercise
                             :exercise-id (mutation-exercise-id exercise)
                             :description (mutation-exercise-description exercise)
                             :result :failed
                             :detail (princ-to-string condition))
          (error "Mutation exercise ~a failed: ~a"
                 (mutation-exercise-id exercise) condition))))
    exercises))
