;;;; ui/web/lisp-routes.lisp -- HTTP routes for the Lisp tab (lisp-repl.lisp,
;;;; lisp-introspect.lisp).  PACKAGE parameters are designators as written
;;;; in source (cl-agent, :cl-agent); without one the REPL's package is used.
;;;;
;;;;   GET  /api/lisp/state        transcript, prompt package, scratch buffer
;;;;   POST /api/lisp/eval         {text, mode?: eval|compile|compile-file, source?, package?}
;;;;   POST /api/lisp/interrupt    break into (or, in the debugger, abort) the evaluation
;;;;   POST /api/lisp/choose       {choice: restart index | "abort", input?}
;;;;   POST /api/lisp/clear        forget the transcript
;;;;   POST /api/lisp/scratch      {text, base, client?}: save; 409 {version, text} on conflict
;;;;   POST /api/lisp/macroexpand  {text, package?, all?}
;;;;   GET  /api/lisp/complete     ?text=&cursor=&package=
;;;;   GET  /api/lisp/autodoc      ?operator=&index=&keyword=&package=
;;;;   GET  /api/lisp/describe     ?symbol=&package=
;;;;   GET  /api/lisp/hyperspec    ?symbol=
;;;;   GET  /api/lisp/apropos      ?query=
;;;;   GET  /api/lisp/definition   ?symbol=&package=
;;;;   GET  /api/lisp/inspect      ?id=

(in-package :cl-agent)

(defun lisp-request-package (designator)
  "The package for a request: DESIGNATOR's, else the REPL's."
  (or (lisp-repl-find-package designator) (lisp-repl-package *lisp-repl*)))

(defun web-integer-param (name)
  (let ((text (web-param name)))
    (and text (parse-integer text :junk-allowed t))))

(define-web-route lisp-state (:path "/api/lisp/state")
  (lisp-repl-state-json))

(define-web-route lisp-eval (:method :post :path "/api/lisp/eval")
  (let* ((body (web-json-body))
         (text (or (jget body "text") ""))
         (mode (or (jget body "mode") "eval")))
    (cond ((not (member mode '("eval" "compile" "compile-file") :test #'equal))
           (web-respond 400 (jobj "error" "mode must be eval, compile or compile-file.")))
          ((and (not (equal mode "compile-file")) (zerop (length (string-trim '(#\Space #\Tab #\Newline) text))))
           (web-respond 400 (jobj "error" "Nothing to evaluate.")))
          (t
           (handler-case
               (jobj "id" (lisp-entry-id (lisp-repl-start text :mode mode
                                                               :source (or (jget body "source") "repl")
                                                               :package (jget body "package"))))
             (lisp-repl-busy (condition) (web-respond 409 (jobj "error" (princ-to-string condition))))
             (error (condition) (web-respond 400 (jobj "error" (princ-to-string condition)))))))))

(define-web-route lisp-interrupt (:method :post :path "/api/lisp/interrupt")
  (let ((result (lisp-repl-interrupt)))
    (jobj "status" (if result (string-downcase (symbol-name result)) "idle"))))

(define-web-route lisp-choose (:method :post :path "/api/lisp/choose")
  (let* ((body (web-json-body))
         (choice (jget body "choice")))
    (handler-case
        (progn (lisp-repl-choose (if (integerp choice) choice :abort) :input (jget body "input"))
               (jobj "status" "ok"))
      (error (condition) (web-respond 409 (jobj "error" (princ-to-string condition)))))))

(define-web-route lisp-clear (:method :post :path "/api/lisp/clear")
  (lisp-repl-clear)
  (jobj "status" "ok"))

(define-web-route lisp-scratch (:method :post :path "/api/lisp/scratch")
  (let* ((body (web-json-body))
         (text (jget body "text")))
    (if (not (stringp text))
        (web-respond 400 (jobj "error" "Give the buffer's text."))
        (multiple-value-bind (status version current)
            (lisp-scratch-save text :base (jget body "base") :client (jget body "client"))
          (if (eq status :conflict)
              (web-respond 409 (jobj "error" "The scratch buffer changed meanwhile."
                                     "version" version "text" current))
              (jobj "version" version))))))

(define-web-route lisp-macroexpand (:method :post :path "/api/lisp/macroexpand")
  (let ((body (web-json-body)))
    (handler-case
        (jobj "expansion" (lisp-repl-macroexpand (or (jget body "text") "")
                                                 (lisp-request-package (jget body "package"))
                                                 :all (jget body "all")))
      (error (condition) (web-respond 400 (jobj "error" (princ-to-string condition)))))))

(define-web-route lisp-complete (:path "/api/lisp/complete")
  (let* ((text (or (web-param "text") ""))
         (cursor (or (web-integer-param "cursor") (length text))))
    (completion-result-json (lisp-repl-complete text cursor (lisp-request-package (web-param "package"))))))

(define-web-route lisp-autodoc (:path "/api/lisp/autodoc")
  (or (lisp-repl-autodoc (or (web-param "operator") "") (web-integer-param "index")
                         (web-param "keyword") (lisp-request-package (web-param "package")))
      (jobj "operator" :null)))

(define-web-route lisp-describe (:path "/api/lisp/describe")
  (jobj "text" (lisp-repl-describe (or (web-param "symbol") "") (lisp-request-package (web-param "package")))))

(define-web-route lisp-hyperspec (:path "/api/lisp/hyperspec")
  (jobj "text" (lookup-cl-spec-text (string-left-trim "#':" (or (web-param "symbol") "")))))

(define-web-route lisp-apropos (:path "/api/lisp/apropos")
  (jobj "text" (lisp-apropos-text (or (web-param "query") ""))))

(define-web-route lisp-definition (:path "/api/lisp/definition")
  (jobj "definitions"
        (jarray (mapcar (lambda (definition)
                          (jobj "type" (getf definition :type) "file" (getf definition :file)
                                "line" (json-or-null (getf definition :line))
                                "snippet" (json-or-null (getf definition :snippet))))
                        (lisp-repl-definitions (or (web-param "symbol") "")
                                               (lisp-request-package (web-param "package")))))))

(define-web-route lisp-inspect (:path "/api/lisp/inspect")
  (handler-case (lisp-repl-inspect (or (web-integer-param "id") 0))
    (error (condition) (web-respond 404 (jobj "error" (princ-to-string condition))))))
