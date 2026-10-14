;;;; t/test-tool-analytics.lisp -- tool analytics (tool-analytics.lisp), from
;;;; the durable logs real tool calls leave.

(in-package :cl-agent)

(deftest tool-calls-are-timed-judged-and-reported ()
  (with-temp-config-dir ()
    (register-tool (make-instance 'tool :name "test-flaky" :description "flaky"
                                        :handler (lambda (args)
                                                   (if (jget args "fail")
                                                       (error "disk ~a is full" (jget args "n"))
                                                       "fine"))))
    (unwind-protect
         (let ((session (make-session (make-instance 'ollama-provider))))
           (flet ((call (fail n)
                    (run-tool-call session (list :id (format nil "c~d" n) :name "test-flaky"
                                                 :arguments (jobj "fail" fail "n" n)))))
             (call nil 1) (call t 2) (call t 3) (call t 4) (call nil 5))
           (let ((calls (session-tool-calls (session-id session))))
             (check-equal (length calls) 5)
             (check-equal (mapcar (lambda (c) (getf c :outcome)) calls) '(:ok :error :error :error :ok)
                          "each call's outcome is recorded")
             (check (every (lambda (c) (integerp (getf c :elapsed-ms))) calls) "and its time, in ms"))
           (let ((report (tool-analytics-report :days 1)))
             (check (search "5 tool calls" report) report)
             (check (search "60.0% did not succeed" report))
             (check (search "3x test-flaky (error): Error running test-flaky: disk # is full" report)
                    "the same failure grouped, its particulars blurred")
             (check (search "test-flaky 5x (3 failed)" report) "a stuck run")
             (check (search "4x test-flaky -> test-flaky" report) "what follows what"))
           (check (search "No tool calls to nothing" (tool-analytics-report :days 1 :tool "nothing"))))
      (unregister-tool "test-flaky"))))

(deftest old-results-have-their-outcome-read ()
  (check-equal (infer-tool-outcome "Error running shell: no such file") :error)
  (check-equal (infer-tool-outcome "Tool \"shell\" is denied by capability mode inspect (rule x; effects: process).") :denied)
  (check-equal (infer-tool-outcome "Tool call vetoed by a :before-tool-call hook: no") :vetoed)
  (check-equal (infer-tool-outcome "All good") :ok))
