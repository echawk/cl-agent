(in-package :cl-agent)

(deftest define-tool-registers-and-calls ()
  (define-tool test-echo (args)
      (:description "echoes its 'text' argument")
    (jget args "text"))
  (check-equal (call-tool "test-echo" (jobj "text" "hello")) "hello")
  (unregister-tool "test-echo"))

(deftest call-tool-unknown-name-returns-actionable-feedback ()
  ;; A model can occasionally call a familiar but unadvertised tool such as
  ;; "readme". It must receive feedback instead of terminating the turn.
  (let ((result (call-tool "definitely-not-a-real-tool" (jobj))))
    (check (search "does not exist" result))
    (check (search "definitely-not-a-real-tool" result))))

(deftest call-tool-catches-handler-errors ()
  (define-tool test-boom (args) (:description "always errors")
    (error "kaboom"))
  (let ((result (call-tool "test-boom" (jobj))))
    (check (search "kaboom" result) "handler error text surfaces in the tool result")
    (check (search "test-boom" result) "tool name surfaces in the error text"))
  (unregister-tool "test-boom"))

(deftest non-string-return-is-coerced ()
  (define-tool test-number (args) (:description "returns a number")
    42)
  (check-equal (call-tool "test-number" (jobj)) "42")
  (unregister-tool "test-number"))

(deftest tool-json-schema-shape ()
  (define-tool test-schema (args) (:description "d"
                                    :parameters (jobj "type" "object"
                                                       "properties" (jobj "x" (jobj "type" "string"))
                                                       "required" (list "x")))
    "")
  (let ((schema (tool-json-schema (find-tool "test-schema"))))
    (check-equal (jget schema "type") "function")
    (check-equal (jget (jget schema "function") "name") "test-schema")
    (check-equal (jget (jget (jget schema "function") "parameters") "type") "object"))
  (unregister-tool "test-schema"))

(deftest default-tool-parameters-required-is-a-json-array-not-false ()
  ;; Regression test: a tool defined with no :PARAMETERS at all (e.g.
  ;; list-mcp-servers) used to get "required": false (NIL's JSON
  ;; encoding) instead of "required": [] in its schema -- valid enough
  ;; for most providers to shrug off, but Ollama's strict JSON-Schema
  ;; parsing rejects it with an HTTP 400 on the whole chat request, not
  ;; just that tool. See tools.lisp's TOOL class docstring.
  (define-tool test-no-params-tool (args) (:description "d") "")
  (let* ((schema (tool-parameters (find-tool "test-no-params-tool")))
         (encoded (json-encode schema)))
    ;; The distinguishing check has to be on the raw encoded text: both
    ;; JSON false and JSON [] decode back to Lisp NIL in our own
    ;; convention (see json-util.lisp), so a round-trip check alone
    ;; can't tell them apart the way Ollama's strict parser can.
    (check (search "\"required\":[]" (remove #\space encoded))
           "required is encoded as a JSON array, not a boolean"))
  (unregister-tool "test-no-params-tool"))

(deftest shell-tool-reports-exit-code-and-output ()
  (let ((result (call-tool "shell" (jobj "command" "echo cl-agent-test-marker"))))
    (check (search "Exit code: 0" result))
    (check (search "cl-agent-test-marker" result))))

(deftest shell-tool-reports-nonzero-exit ()
  (let ((result (call-tool "shell" (jobj "command" "exit 7"))))
    (check (search "Exit code: 7" result))))

(deftest shell-tool-rejects-non-string-command-clearly ()
  ;; A weak model occasionally sends a nested object instead of a
  ;; string; without an explicit check this reached the model as a
  ;; bare SBCL ETYPECASE message it had no way to act on -- see
  ;; tools/shell.lisp.
  (let ((result (call-tool "shell" (jobj "command" (jobj "foo" "bar")))))
    (check (search "must be a plain string" result))
    (check (not (search "ETYPECASE" result)) "no SBCL-internal jargon leaks through")))

(deftest shell-tool-rejects-missing-command-clearly ()
  (check (search "no \"command\" argument" (call-tool "shell" (jobj)))))

(deftest direct-file-tools-read-and-write-project-files ()
  (let ((path (merge-pathnames "cl-agent-file-tool-test.txt" (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (check (search "Wrote 17 characters" (call-tool "write-file" (jobj "path" (namestring path) "contents" "direct file write"))))
           (check-equal (call-tool "read-file" (jobj "path" (namestring path))) "direct file write"))
      (when (probe-file path) (delete-file path)))))

(deftest file-range-tools-read-replace-insert-and-guard-precise-text ()
  (let ((path (merge-pathnames "cl-agent-file-range-tool-test.txt" (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (call-tool "write-file" (jobj "path" (namestring path) "contents" (format nil "alpha~%beta~%gamma")))
           (check-equal (call-tool "read-file-range"
                                   (jobj "path" (namestring path)
                                         "start_line" 2 "start_column" 1
                                         "end_line" 2 "end_column" 5))
                        "beta")
           (check (search "replaced 4 characters"
                          (call-tool "edit-file"
                                     (jobj "path" (namestring path)
                                           "start_line" 2 "start_column" 1
                                           "end_line" 2 "end_column" 5
                                           "replacement" "BETA" "expected_text" "beta"))))
           ;; Equal endpoints are a precise insertion, with no special mode.
           (call-tool "edit-file"
                      (jobj "path" (namestring path)
                            "start_line" 3 "start_column" 1
                            "end_line" 3 "end_column" 1
                            "replacement" "new-" "expected_text" ""))
           (check-equal (call-tool "read-file" (jobj "path" (namestring path)))
                        (format nil "alpha~%BETA~%new-gamma"))
           (check (search "did not match"
                          (call-tool "edit-file"
                                     (jobj "path" (namestring path)
                                           "start_line" 1 "start_column" 1
                                           "end_line" 1 "end_column" 6
                                           "replacement" "wrong" "expected_text" "stale")))))
      (when (probe-file path) (delete-file path)))))

(deftest find-tool-returns-nil-not-error ()
  (check-equal (find-tool "no-such-tool-xyz") nil))
