;;;; t/test-components.lisp -- reflection kernel coverage.

(in-package :cl-agent)

(deftest components-have-stable-ids-and-replacement-versions ()
  (let ((name "test-component-version"))
    (unregister-tool name)
    (register-tool (make-instance 'tool :name name :description "first"
                                  :effects '(:read-test) :handler (lambda (args) (declare (ignore args)) "ok")))
    (let ((first (describe-component "tool:test-component-version")))
      (check first)
      (check-equal (component-descriptor-version first) 1)
      (check-equal (component-descriptor-effects first) '(:read-test)))
    (register-tool (make-instance 'tool :name name :description "second"
                                  :handler (lambda (args) (declare (ignore args)) "ok")))
    (check-equal (component-descriptor-version
                  (describe-component "tool:test-component-version")) 2)
    (unregister-tool name)
    (check-equal (describe-component "tool:test-component-version") nil)))

(deftest component-origin-owner-and-serialization-are-data-only ()
  (let ((name "test-component-origin"))
    (unregister-tool name)
    (let ((*registration-origin* '(:extension "example.lisp"))
          (*registration-owner* "extension:example.lisp"))
      (register-tool (make-instance 'tool :name name :description "origin"
                                    :handler (lambda (args) (declare (ignore args)) "ok"))))
    (let ((data (component->plist (describe-component "tool:test-component-origin"))))
      (check-equal (getf data :origin) '(:extension "example.lisp"))
      (check-equal (getf data :owner) "extension:example.lisp")
      (check (notany #'functionp (getf data :metadata))))
    (unregister-tool name)))

(deftest component-owner-retirement-removes-only-owned-descriptors ()
  (let ((*registration-owner* "extension:retire-test"))
    (register-tool (make-instance 'tool :name "test-retire-owned" :description "x"
                                  :handler (lambda (args) (declare (ignore args)) "ok"))))
  (check (describe-component "tool:test-retire-owned"))
  (retire-components-owned-by "extension:retire-test")
  (check-equal (describe-component "tool:test-retire-owned") nil)
  ;; The test only retires reflection data; remove the behaviour explicitly,
  ;; matching the lifecycle contract of RETIRE-COMPONENTS-OWNED-BY.
  (remhash "test-retire-owned" *tools*))

(deftest component-adapters-cover-built-in-registries ()
  (dolist (tool (list-tools))
    (check (describe-component (component-id :tool (tool-name tool)))))
  (dolist (provider (list-providers))
    (check (describe-component (component-id :provider (car provider)))))
  (dolist (frontend (list-frontends))
    (check (describe-component (component-id :frontend (car frontend)))))
  (dolist (hook-point *hook-points*)
    (check (describe-component (component-id :hook-point (car hook-point)))))
  (dolist (command *slash-commands*)
    (check (describe-component (component-id :slash-command (car command))))))

(deftest component-events-observe-registration-and-removal ()
  (let ((seen nil) (subscriber nil))
    (setf subscriber (lambda (event) (push (agent-event-kind event) seen)))
    (subscribe-events subscriber)
    (unwind-protect
         (progn
           (register-tool (make-instance 'tool :name "test-component-event" :description "x"
                                         :handler (lambda (args) (declare (ignore args)) "ok")))
           (unregister-tool "test-component-event")
           (check (member :component-registered seen))
           (check (member :component-unregistered seen)))
      (unsubscribe-events subscriber))))

(deftest slash-components-lists-and-describes-through-the-common-api ()
  (let ((session (make-session (make-instance 'ollama-provider)))
        (output (make-string-output-stream)))
    (let ((*standard-output* output))
      (dispatch-slash-command session "/components tool")
      (dispatch-slash-command session "/components tool:read-file"))
    (let ((text (get-output-stream-string output)))
      (check (search "tool:read-file" text))
      (check (search ":ID \"tool:read-file\"" text)))))
