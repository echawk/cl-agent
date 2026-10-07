;;;; doctor.lisp -- read-only configuration and capability diagnostics.

(in-package :cl-agent)

(defstruct doctor-check id description function)

(defun doctor-result (id status detail)
  (list :id id :status status :detail detail))

(defun doctor-config-result ()
  "Read config data without loading code, returning CONFIG and its result row."
  (let ((path (config-file-path)))
    (if (not (probe-file path))
        (values nil (doctor-result "config" :warning
                                   (format nil "No config file at ~a; built-in defaults will be used." path)))
        (handler-case
            (values (load-user-config path)
                    (doctor-result "config" :ok (format nil "Read ~a." path)))
          (error (condition)
            (values nil (doctor-result "config" :failed
                                       (format nil "Cannot read ~a: ~a" path condition))))))))

(defun doctor-directory-check (config)
  (declare (ignore config))
  (let ((directory (uiop:ensure-directory-pathname *config-directory*)))
    (cond ((not (probe-file directory))
           (doctor-result "state-directory" :warning
                          (format nil "State directory does not exist yet: ~a" directory)))
          ((not (uiop:directory-exists-p directory))
           (doctor-result "state-directory" :failed
                          (format nil "State path is not a directory: ~a" directory)))
          (t (doctor-result "state-directory" :ok
                            (format nil "State directory is present: ~a" directory))))))

(defun doctor-executables-check (config)
  (declare (ignore config))
  (let ((missing (remove-if #'find-executable-on-path '("sbcl" "ocicl"))))
    (if missing
        (doctor-result "executables" :warning
                       (format nil "Not found on PATH: ~{~a~^, ~}." missing))
        (doctor-result "executables" :ok "sbcl and ocicl are available on PATH."))))

(defun doctor-provider-check (config)
  (let* ((env-provider (env "CL_AGENT_PROVIDER"))
         (keyword (or (and env-provider (intern (string-upcase env-provider) :keyword))
                      (config-value config :provider) :reallms))
         (class (gethash keyword *provider-registry*)))
    (if (not class)
        (doctor-result "provider" :failed (format nil "Unknown provider ~s." keyword))
        (let* ((provider (make-instance class))
               (key-variable (or (config-value config :api-key-env)
                                 (provider-api-key-env-var provider))))
          (if (and key-variable (not (env key-variable)))
              (doctor-result "provider" :warning
                             (format nil "~a requires ~a, which is not set."
                                     (provider-display-name provider) key-variable))
              (doctor-result "provider" :ok
                             (format nil "~a is configured without making a provider request."
                                     (provider-display-name provider))))))))

(defun doctor-lsp-check (config)
  (declare (ignore config))
  (let ((path (lsp-configuration-path)))
    (if (not (probe-file path))
        (doctor-result "lsp" :ok "No LSP configuration is declared.")
        (handler-case
            (let* ((servers (cl-lsp:lsp-read-configurations path))
                   (missing (mapcar #'cl-lsp:lsp-server-configuration-name
                                    (remove-if #'lsp-command-available-p servers))))
              (if missing
                  (doctor-result "lsp" :warning
                                 (format nil "Configured server commands unavailable: ~{~a~^, ~}." missing))
                  (doctor-result "lsp" :ok
                                 (format nil "~d configured LSP server~:p available." (length servers)))))
          (error (condition)
            (doctor-result "lsp" :failed
                           (format nil "Cannot read ~a: ~a" path condition)))))))

(defun doctor-mcp-check (config)
  (let ((servers (config-value config :mcp-servers)))
    (handler-case
        (let ((problems
                (loop for spec in servers
                      for name = (getf spec :name)
                      for command = (getf spec :command)
                      unless (and (stringp name) (listp command) (stringp (first command))
                                  (or (probe-file (first command))
                                      (find-executable-on-path (first command))))
                        collect (or name "unnamed server"))))
          (if problems
              (doctor-result "mcp" :warning
                             (format nil "Invalid or unavailable MCP declarations: ~{~a~^, ~}." problems))
              (doctor-result "mcp" :ok
                             (format nil "~d MCP declaration~:p can be launched from PATH (not connected)."
                                     (length servers)))))
      (error (condition)
        (doctor-result "mcp" :failed (format nil "Invalid MCP configuration: ~a" condition))))))

(defun doctor-extensions-check (config)
  (declare (ignore config))
  (handler-case
      (let ((enabled (getf (read-enabled-config) :enabled)))
        (cond ((eq enabled :all)
               (doctor-result "extensions" :ok
                              (format nil "All ~d extension file~:p are enabled (not loaded by doctor)."
                                      (length (list-extension-files)))))
              ((every (lambda (name) (probe-file (merge-pathnames name (extensions-directory)))) enabled)
               (doctor-result "extensions" :ok
                              (format nil "~d configured extension~:p are present (not loaded by doctor)."
                                      (length enabled))))
              (t (doctor-result "extensions" :warning
                                "Some enabled extension files are missing; doctor does not load extensions."))))
    (error (condition)
      (doctor-result "extensions" :failed
                     (format nil "Cannot read extension enablement: ~a" condition)))))

(defparameter *doctor-checks*
  (list (make-doctor-check :id "state-directory" :description "State directory" :function #'doctor-directory-check)
        (make-doctor-check :id "executables" :description "Required executables" :function #'doctor-executables-check)
        (make-doctor-check :id "provider" :description "Provider configuration" :function #'doctor-provider-check)
        (make-doctor-check :id "lsp" :description "LSP declarations" :function #'doctor-lsp-check)
        (make-doctor-check :id "mcp" :description "MCP declarations" :function #'doctor-mcp-check)
        (make-doctor-check :id "extensions" :description "Extension enablement" :function #'doctor-extensions-check))
  "Read-only checks included in RUN-DOCTOR.")

(defun run-doctor ()
  "Return structured, local-only diagnostics without starting external services."
  (multiple-value-bind (config config-result) (doctor-config-result)
    (cons config-result
          (mapcar (lambda (check)
                    (handler-case
                        (funcall (doctor-check-function check) config)
                      (error (condition)
                        (doctor-result (doctor-check-id check) :failed
                                       (princ-to-string condition)))))
                  *doctor-checks*))))

(defun doctor-healthy-p (results)
  "Whether RESULTS has no failed checks; warnings remain actionable but non-fatal."
  (notany (lambda (result) (eq (getf result :status) :failed)) results))

(defun format-doctor-report (results)
  "Render structured RESULTS for a CLI or frontend without exposing secrets."
  (format nil "cl-agent doctor:~%~:{[~(~a~)] ~a — ~a~%~}Overall: ~a."
          (mapcar (lambda (result)
                    (list (getf result :status) (getf result :id) (getf result :detail)))
                  results)
          (if (doctor-healthy-p results) "healthy" "failed checks require attention")))
