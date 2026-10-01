;;;; main.lisp -- CLI entry point. This is cl-agent.asd's :entry-point,
;;;; so it's what `bin/cl-agent` (after `make build`) and
;;;; `sbcl --script run.lisp` both end up calling.

(in-package :cl-agent)

(defun parse-args (argv)
  "ARGV is a list of strings (already excluding argv[0]). Returns a
plist (:provider KEYWORD-OR-NIL :model STRING-OR-NIL :config-dir
STRING-OR-NIL :task STRING) where :task is every remaining,
non-flag argument joined with spaces (an optional first message, same
convention as class-ref/agent-repl.rhm)."
  (let ((provider nil) (model nil) (config-dir nil) (rest nil))
    (loop while argv
          do (let ((arg (pop argv)))
               (cond
                 ((string= arg "--provider") (setf provider (intern (string-upcase (pop argv)) :keyword)))
                 ((string= arg "--model") (setf model (pop argv)))
                 ((string= arg "--config-dir") (setf config-dir (pop argv)))
                 ((or (string= arg "--help") (string= arg "-h"))
                  (format t "~&Usage: cl-agent [--provider NAME] [--model NAME] [--config-dir PATH] [\"initial task\"]~%~
                               ~%Providers: ~{~a~^, ~}~%"
                          (mapcar #'car (list-providers)))
                  (uiop:quit 0))
                 (t (push arg rest)))))
    (list :provider provider :model model :config-dir config-dir
          :task (format nil "~{~a~^ ~}" (nreverse rest)))))

(defun resolve-provider-keyword (cli-provider config)
  (or cli-provider
      (let ((env-provider (env "CL_AGENT_PROVIDER")))
        (and env-provider (intern (string-upcase env-provider) :keyword)))
      (config-value config :provider)
      :reallms))

(defun main ()
  "Entry point. Resolution order for every setting is: CLI flag >
environment variable (where one exists) > config.lisp > a documented
default -- see RESOLVE-PROVIDER-KEYWORD and the inline uses below.
Never signals out to the top level on an ordinary configuration
mistake (missing API key, unknown provider name): those are reported
with a readable message and a non-zero exit, not a Lisp backtrace."
  (let* ((parsed (parse-args (uiop:command-line-arguments))))
    (when (getf parsed :config-dir)
      (setf *config-directory* (uiop:ensure-directory-pathname (getf parsed :config-dir))))
    (ensure-config-directory)
    (let ((config (load-user-config)))
      (handler-case
          (let* ((provider-keyword (resolve-provider-keyword (getf parsed :provider) config))
                 (provider (make-provider provider-keyword
                                           :model (or (getf parsed :model) (config-value config :model))
                                           :base-url (config-value config :base-url)
                                           :api-key-env (config-value config :api-key-env))))
            (multiple-value-bind (loaded failed) (load-enabled-extensions)
              (declare (ignore loaded))
              (when failed
                (format *error-output* "~&~d extension(s) failed to load; see above.~%" (length failed))))
            (format t "~&cl-agent -- ~a (~a)~%Type /help for commands, Ctrl-D to exit.~%"
                    (provider-display-name provider) (provider-model provider))
            (run-repl (make-session provider
                                     :system-prompt (config-value config :system-prompt)
                                     :max-tool-iterations (config-value config :max-tool-iterations))
                      :initial-task (getf parsed :task)))
        (provider-not-found (c)
          (format *error-output* "~&~a~%" c) (uiop:quit 1))
        (missing-api-key (c)
          (format *error-output* "~&~a~%" c) (uiop:quit 1))))))
