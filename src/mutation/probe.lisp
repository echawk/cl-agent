;;;; mutation/probe.lisp -- clean-image validation for staged extensions.

(in-package :cl-agent)

(defparameter *mutation-probe-timeout-seconds* 30
  "Maximum wall time reserved for a clean extension probe (documented for the
process backend; UIOP's portable process API has no universal timeout knob).")

(defun mutation-project-root ()
  (asdf:system-source-directory "cl-agent"))

(defun clean-probe-eval-form (transaction isolated-config-directory)
  "Build a data-only command form for a fresh SBCL process."
  (format nil
          "(let ((cl-agent::*config-directory* ~s)) (cl-agent::ensure-config-directory) (handler-case (progn (cl-agent::load-extension-file ~s :owner ~s :origin '(:clean-probe ~s)) (format t \"CL-AGENT-CLEAN-PROBE-OK~%\") (uiop:quit 0)) (error (condition) (format *error-output* \"CL-AGENT-CLEAN-PROBE-FAILED: ~~a~%\" condition) (uiop:quit 1))))"
          (namestring isolated-config-directory)
          (namestring (mutation-staged-source transaction))
          (mutation-owner transaction) (mutation-id transaction)))

(defun clean-probe-command (transaction isolated-config-directory)
  "Return an argv list which loads the locked project then only the proposal."
  (let ((sbcl (or (find-executable-on-path "sbcl") "sbcl"))
        (boot (merge-pathnames "boot.lisp" (mutation-project-root))))
    (list (namestring sbcl) "--non-interactive" "--load" (namestring boot)
          "--eval" "(asdf:load-system \"cl-agent\")"
          "--eval" (clean-probe-eval-form transaction isolated-config-directory))))

(defun run-clean-process-probe (transaction)
  "Load TRANSACTION's staged source in a fresh, isolated SBCL process.

The parent image is untouched regardless of result.  This does not promise to
sandbox a malicious extension; it is a correctness/recovery boundary which
prevents a partially loaded proposal from becoming the parent image's state."
  (let* ((directory (merge-pathnames (format nil "~a/probe-config/" (mutation-id transaction))
                                     (mutations-directory)))
         (command (clean-probe-command transaction directory)))
    (ensure-directories-exist (merge-pathnames "placeholder" directory))
    (handler-case
        (multiple-value-bind (output error-output exit-code)
            (uiop:run-program command :output :string :error-output :string
                               :ignore-error-status t)
          (let ((passed (and (or (null exit-code) (zerop exit-code))
                             (search "CL-AGENT-CLEAN-PROBE-OK" output))))
            (list :status (if passed :passed :failed)
                  :command command :exit-code exit-code
                  :output output :error-output error-output)))
      (error (condition)
        (list :status :failed :command command :detail (princ-to-string condition))))))
