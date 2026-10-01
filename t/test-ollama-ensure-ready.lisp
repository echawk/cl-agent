;;;; t/test-ollama-ensure-ready.lisp -- tests for providers/ollama.lisp's
;;;; "start `ollama serve` if it isn't running" logic. These stub out
;;;; OLLAMA-REACHABLE-P/START-OLLAMA-SERVER (temporarily replacing
;;;; their SYMBOL-FUNCTION, same technique t/test-clspec.lisp uses for
;;;; CLSPEC-DATA-PATHNAME) rather than depend on whether a real ollama
;;;; server or executable happens to be present on whatever machine
;;;; `make test` runs on -- this suite's offline/deterministic
;;;; guarantee shouldn't depend on that. The real thing is what `make
;;;; test-ollama` exercises.

(in-package :cl-agent)

(deftest ollama-api-root-strips-v1-suffix ()
  (let ((p (make-instance 'ollama-provider)))
    (check-equal (ollama-api-root p) "http://localhost:11434")))

(deftest ollama-api-root-leaves-non-v1-base-url-alone ()
  (let ((p (make-instance 'ollama-provider)))
    (setf (provider-base-url p) "http://localhost:9999")
    (check-equal (ollama-api-root p) "http://localhost:9999")))

(deftest find-executable-on-path-finds-a-real-binary ()
  (check (find-executable-on-path "sh") "sh is on PATH in any POSIX test environment"))

(deftest find-executable-on-path-nil-for-bogus-name ()
  (check-equal (find-executable-on-path "definitely-not-a-real-executable-xyz123") nil))

(deftest make-provider-without-ensure-ready-is-fast-and-network-free ()
  ;; No :ENSURE-READY => PROVIDER-ENSURE-READY must not run at all, so
  ;; this returns essentially instantly regardless of whether any
  ;; ollama server exists anywhere -- a generous 2-second budget still
  ;; clearly distinguishes "skipped" from "tried a real network call".
  (let ((start (get-internal-real-time)))
    (make-provider :ollama)
    (check (< (/ (- (get-internal-real-time) start) internal-time-units-per-second) 2))))

(defmacro with-stubbed-ollama-start ((&key (reachable 'nil) (start '(lambda () t))) &body body)
  "Temporarily replace OLLAMA-REACHABLE-P and START-OLLAMA-SERVER's
SYMBOL-FUNCTIONs for the extent of BODY, restoring both afterward even
if BODY signals. REACHABLE and START are forms evaluated once to
produce the replacement functions (REACHABLE's function takes a
provider arg and is ignored; START's takes none)."
  `(let ((.orig-reachable. (symbol-function 'ollama-reachable-p))
         (.orig-start. (symbol-function 'start-ollama-server)))
     (unwind-protect
          (progn
            (setf (symbol-function 'ollama-reachable-p) (lambda (p) (declare (ignore p)) ,reachable))
            (setf (symbol-function 'start-ollama-server) ,start)
            ,@body)
       (setf (symbol-function 'ollama-reachable-p) .orig-reachable.)
       (setf (symbol-function 'start-ollama-server) .orig-start.))))

(deftest provider-ensure-ready-skips-start-when-already-reachable ()
  (let ((start-calls 0))
    (with-stubbed-ollama-start (:reachable t :start (lambda () (incf start-calls) t))
      (provider-ensure-ready (make-instance 'ollama-provider)) ; must not signal
      (check-equal start-calls 0 "already reachable -> never tries to start a server"))))

(deftest provider-ensure-ready-starts-server-when-not-reachable-then-times-out ()
  ;; OLLAMA-REACHABLE-P stays stubbed to NIL throughout, simulating a
  ;; server that never comes up even after "starting" it, so this
  ;; exercises (and bounds, via a 1-second *OLLAMA-START-TIMEOUT*) the
  ;; timeout/error path.
  (let ((start-calls 0) (*ollama-start-timeout* 1))
    (with-stubbed-ollama-start (:reachable nil :start (lambda () (incf start-calls) t))
      (check-condition provider-error (provider-ensure-ready (make-instance 'ollama-provider)))
      (check-equal start-calls 1))))

(deftest provider-ensure-ready-reports-missing-executable ()
  (with-stubbed-ollama-start (:reachable nil :start (lambda () nil))
    (check-condition provider-error (provider-ensure-ready (make-instance 'ollama-provider)))))
