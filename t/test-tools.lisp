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

(deftest shell-tool-reports-exit-code-and-output ()
  (let ((result (call-tool "shell" (jobj "command" "echo cl-agent-test-marker"))))
    (check (search "Exit code: 0" result))
    (check (search "cl-agent-test-marker" result))))

(deftest shell-tool-reports-nonzero-exit ()
  (let ((result (call-tool "shell" (jobj "command" "exit 7"))))
    (check (search "Exit code: 7" result))))

(deftest find-tool-returns-nil-not-error ()
  (check-equal (find-tool "no-such-tool-xyz") nil))
