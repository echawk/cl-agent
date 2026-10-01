;;;; t/test-apfel-ensure-ready.lisp -- tests for providers/apfel.lisp,
;;;; mirroring t/test-ollama-ensure-ready.lisp's approach exactly:
;;;; APFEL-HEALTH/START-APFEL-SERVER are stubbed (temporarily replacing
;;;; their SYMBOL-FUNCTION) so this suite's offline/deterministic
;;;; guarantee doesn't depend on whether `apfel` is actually installed
;;;; or Apple Intelligence is enabled on whatever machine `make test`
;;;; runs on -- including non-macOS machines, where it never will be.

(in-package :cl-agent)

(deftest apple-and-apfel-are-the-same-provider ()
  (check-equal (cdr (assoc :apple (list-providers))) (cdr (assoc :apfel (list-providers)))))

(deftest apfel-root-strips-v1-suffix ()
  (let ((p (make-instance 'apfel-provider)))
    (check-equal (apfel-root p) "http://127.0.0.1:11535")))

(deftest apfel-port-extracts-port-number ()
  (let ((p (make-instance 'apfel-provider)))
    (check-equal (apfel-port p) 11535)
    (setf (provider-base-url p) "http://127.0.0.1:9999/v1")
    (check-equal (apfel-port p) 9999)))

(deftest make-provider-apfel-resolves-default-model ()
  (check-equal (provider-model (make-provider :apfel)) "apple-foundationmodel")
  (check-equal (provider-model (make-provider :apple)) "apple-foundationmodel"))

(deftest make-provider-apfel-without-ensure-ready-is-fast-and-network-free ()
  (let ((start (get-internal-real-time)))
    (make-provider :apfel)
    (check (< (/ (- (get-internal-real-time) start) internal-time-units-per-second) 2))))

(defmacro with-stubbed-apfel-start ((&key (health nil) (start '(lambda (p) (declare (ignore p)) t)))
                                     &body body)
  "Same pattern as WITH-STUBBED-OLLAMA-START (t/test-ollama-ensure-
ready.lisp): HEALTH is a form for APFEL-HEALTH's replacement return
value (NIL = unreachable, or a hash table like a real /health body);
START replaces START-APFEL-SERVER -- unlike START-OLLAMA-SERVER, this
one takes a PROVIDER argument (to know which port to launch on), so a
caller-supplied :START replacement must accept one too."
  `(let ((.orig-health. (symbol-function 'apfel-health))
         (.orig-start. (symbol-function 'start-apfel-server)))
     (unwind-protect
          (progn
            (setf (symbol-function 'apfel-health) (lambda (p) (declare (ignore p)) ,health))
            (setf (symbol-function 'start-apfel-server) ,start)
            ,@body)
       (setf (symbol-function 'apfel-health) .orig-health.)
       (setf (symbol-function 'start-apfel-server) .orig-start.))))

(deftest provider-ensure-ready-skips-start-when-already-healthy ()
  (let ((start-calls 0))
    (with-stubbed-apfel-start (:health (jobj "status" "ok" "model_available" t)
                                :start (lambda (p) (declare (ignore p)) (incf start-calls) t))
      (provider-ensure-ready (make-instance 'apfel-provider)) ; must not signal
      (check-equal start-calls 0 "already healthy -> never tries to start a server"))))

(deftest provider-ensure-ready-warns-when-model-unavailable-but-does-not-signal ()
  (let ((output (make-string-output-stream)))
    (with-stubbed-apfel-start (:health (jobj "status" "ok" "model_available" nil))
      (let ((*error-output* output))
        (provider-ensure-ready (make-instance 'apfel-provider))))
    (check (search "model_available" (get-output-stream-string output)))))

(deftest provider-ensure-ready-starts-server-when-not-reachable-then-times-out ()
  (let ((start-calls 0) (*apfel-start-timeout* 1))
    (with-stubbed-apfel-start (:health nil :start (lambda (p) (declare (ignore p)) (incf start-calls) t))
      (check-condition provider-error (provider-ensure-ready (make-instance 'apfel-provider)))
      (check-equal start-calls 1))))

(deftest provider-ensure-ready-reports-missing-executable ()
  (with-stubbed-apfel-start (:health nil :start (lambda (p) (declare (ignore p)) nil))
    (check-condition provider-error (provider-ensure-ready (make-instance 'apfel-provider)))))
