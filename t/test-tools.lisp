(in-package :cl-agent)

(deftest define-tool-registers-and-calls ()
  (define-tool test-echo (args)
      (:description "echoes its 'text' argument")
    (jget args "text"))
  (check-equal (call-tool "test-echo" (jobj "text" "hello")) "hello")
  (unregister-tool "test-echo"))

(deftest call-tool-unknown-name-signals ()
  (check-condition tool-not-found (call-tool "definitely-not-a-real-tool" (jobj))))

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

(deftest find-tool-returns-nil-not-error ()
  (check-equal (find-tool "no-such-tool-xyz") nil))
