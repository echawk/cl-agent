;;;; t/test-lisp-repl.lisp -- the web UI's Lisp tab (ui/web/lisp-repl.lisp,
;;;; lisp-introspect.lisp, lisp-routes.lisp) and the agent's scratch tools
;;;; (tools/lisp-scratch-tool.lisp).  Each test evaluates on its own
;;;; LISP-REPL and, via RUN-ALL-TESTS, its own temporary config directory.

(in-package :cl-agent)

(defmacro with-test-lisp-repl ((var) &body body)
  `(let ((,var (make-lisp-repl))) ,@body))

(defun repl-eval-and-wait (repl text &rest options)
  (let ((entry (apply #'lisp-repl-start text :repl repl options)))
    (lisp-repl-wait entry :repl repl)
    entry))

(defun entry-value-texts (entry)
  (mapcar (lambda (value) (getf value :text)) (lisp-entry-values entry)))

(defun wait-until-settled (repl entry)
  "Wait until ENTRY leaves the state a debugger choice put it in."
  (sleep 0.05)
  (lisp-repl-wait entry :repl repl))

;;; --- evaluation ---

(deftest lisp-repl-evaluates-forms-with-output-and-values ()
  (with-test-lisp-repl (repl)
    (let ((entry (repl-eval-and-wait repl "(princ \"hi\") (values 1 :two)")))
      (check-equal (lisp-entry-state entry) :done)
      (check-equal (coerce (lisp-entry-output entry) 'simple-string) "hi")
      (check-equal (entry-value-texts entry) '("1" ":TWO"))
      (check (lisp-entry-elapsed entry))
      (check (not (lisp-repl-busy-p repl)) "the REPL is idle again"))))

(deftest lisp-repl-keeps-the-repl-variables ()
  (with-test-lisp-repl (repl)
    (repl-eval-and-wait repl "(+ 1 2)")
    (check-equal (entry-value-texts (repl-eval-and-wait repl "(* * 2)")) '("6"))
    (check-equal (entry-value-texts (repl-eval-and-wait repl "+")) '("(* * 2)"))))

(deftest lisp-repl-in-package-moves-the-prompt-but-explicit-packages-do-not ()
  (with-test-lisp-repl (repl)
    (repl-eval-and-wait repl "(in-package :cl-user)")
    (check-equal (package-name (lisp-repl-package repl)) "COMMON-LISP-USER")
    (check-equal (lisp-entry-package (repl-eval-and-wait repl "1")) "CL-USER")
    (repl-eval-and-wait repl "(in-package :keyword)" :package "cl-agent")
    (check-equal (package-name (lisp-repl-package repl)) "COMMON-LISP-USER"
                 "a form evaluated in an explicit package leaves the REPL's alone")))

(deftest lisp-repl-errors-enter-the-debugger-and-restarts-resume ()
  (with-test-lisp-repl (repl)
    (let ((entry (repl-eval-and-wait repl "(+ 1 (symbol-value 'test-lisp-repl-unbound-xyz))")))
      (check-equal (lisp-entry-state entry) :debugger)
      (let* ((debugger (lisp-entry-debugger entry))
             (names (mapcar #'first (getf debugger :restarts))))
        (check-equal (getf debugger :type) "UNBOUND-VARIABLE")
        (check (member "USE-VALUE" names :test #'string=))
        (check-equal (car (last (getf debugger :restarts))) '("ABORT" "Return to the Lisp REPL.")
                     "the thread's own restarts are not offered")
        (check (some (lambda (frame) (search "SYMBOL-VALUE" frame)) (getf debugger :backtrace)))
        (lisp-repl-choose (position "USE-VALUE" names :test #'string=) :input "41" :repl repl))
      (check-equal (wait-until-settled repl entry) :done)
      (check-equal (entry-value-texts entry) '("42")))))

(deftest lisp-repl-a-restart-that-needs-a-value-says-so ()
  (with-test-lisp-repl (repl)
    (let* ((entry (repl-eval-and-wait repl "(symbol-value 'test-lisp-repl-unbound-xyz)"))
           (names (mapcar #'first (getf (lisp-entry-debugger entry) :restarts))))
      (lisp-repl-choose (position "USE-VALUE" names :test #'string=) :repl repl)
      (check-equal (wait-until-settled repl entry) :debugger)
      (check (search "reads a value" (getf (lisp-entry-debugger entry) :note)))
      (lisp-repl-choose :abort :repl repl)
      (check-equal (wait-until-settled repl entry) :aborted))))

(deftest lisp-repl-abort-keeps-the-condition-and-frees-the-repl ()
  (with-test-lisp-repl (repl)
    (let ((entry (repl-eval-and-wait repl "(error \"boom ~a\" 7)")))
      (check-equal (lisp-entry-state entry) :debugger)
      (check-equal (getf (lisp-entry-debugger entry) :condition) "boom 7")
      (check-condition lisp-repl-busy (lisp-repl-start "1" :repl repl))
      (lisp-repl-choose :abort :repl repl)
      (check-equal (wait-until-settled repl entry) :aborted)
      (check (not (lisp-repl-busy-p repl)))
      (check-equal (entry-value-texts (repl-eval-and-wait repl "2")) '("2")))))

(deftest lisp-repl-interrupt-breaks-into-a-running-loop ()
  (with-test-lisp-repl (repl)
    (let ((entry (lisp-repl-start "(loop (sleep 0.01))" :repl repl)))
      (loop repeat 200 until (lisp-repl-thread repl) do (sleep 0.01))
      (check-equal (lisp-repl-interrupt repl) :interrupted)
      (check-equal (lisp-repl-wait entry :repl repl) :debugger)
      (check-equal (first (first (getf (lisp-entry-debugger entry) :restarts))) "CONTINUE")
      (check-equal (lisp-repl-interrupt repl) :aborted "interrupting the debugger aborts")
      (check-equal (wait-until-settled repl entry) :aborted))
    (check (null (lisp-repl-interrupt repl)) "nothing to interrupt")))

(deftest lisp-repl-warnings-become-notes-instead-of-noise ()
  (with-test-lisp-repl (repl)
    (unwind-protect
         (let ((entry (repl-eval-and-wait
                       repl "(defun test-lisp-repl-warner () (test-lisp-repl-no-such-function-xyz))")))
           (check-equal (lisp-entry-state entry) :done)
           (check (some (lambda (note) (search "undefined function" (getf note :message)))
                        (lisp-entry-notes entry)))
           (check (not (search "caught" (lisp-entry-output entry)))))
      (fmakunbound 'test-lisp-repl-warner))))

(deftest lisp-repl-compile-mode-and-compile-file ()
  (with-test-lisp-repl (repl)
    (check-equal (entry-value-texts (repl-eval-and-wait repl "(+ 1 2)" :mode "compile")) '("3"))
    (unwind-protect
         (progn
           (lisp-scratch-save (format nil "(in-package :cl-agent)~%(defparameter *test-lisp-scratch-loaded* 42)~%"))
           (let ((entry (repl-eval-and-wait repl "" :mode "compile-file")))
             (check-equal (lisp-entry-state entry) :done)
             (check (search "Compiled and loaded" (first (entry-value-texts entry))))
             (check-equal (symbol-value (find-symbol "*TEST-LISP-SCRATCH-LOADED*" :cl-agent)) 42)))
      (let ((symbol (find-symbol "*TEST-LISP-SCRATCH-LOADED*" :cl-agent)))
        (when symbol (makunbound symbol))))))

(deftest lisp-repl-transcript-text-tells-the-agent-what-happened ()
  (with-test-lisp-repl (repl)
    (repl-eval-and-wait repl "(print :hello) (+ 40 2)")
    (let ((entry (repl-eval-and-wait repl "(error \"kaboom\")")))
      (lisp-repl-choose :abort :repl repl)
      (wait-until-settled repl entry))
    (let ((text (lisp-repl-transcript-text :repl repl)))
      (check (search "CL-AGENT> (print :hello) (+ 40 2)" text))
      (check (search ":HELLO" text))
      (check (search "=> 42" text))
      (check (search "!! SIMPLE-ERROR: kaboom" text))
      (check (search "evaluation aborted" text)))))

;;; --- presentations and the inspector ---

(deftest lisp-repl-presentations-round-trip-and-inspect ()
  (with-test-lisp-repl (repl)
    (let* ((table (let ((h (make-hash-table))) (setf (gethash :a h) 1) h))
           (id (lisp-repl-present table repl))
           (view (lisp-repl-inspect id repl))
           (labels (mapcar (lambda (part) (gethash "label" part)) (gethash "parts" view))))
      (check (eq (lisp-repl-object id repl) table))
      (check-equal (gethash "type" view) "HASH-TABLE")
      (check (member ":A" labels :test #'string=))
      (check-condition error (lisp-repl-object 99999 repl)))))

(deftest lisp-inspector-lists-slots-of-objects ()
  (let ((labels (mapcar #'car (lisp-inspector-parts (make-condition 'simple-error :format-control "x")))))
    (check (member "format-control" labels :test #'string=))
    (check (member "report" labels :test #'string=))))

;;; --- introspection ---

(defun lisp-completion-values (text &optional (package (find-package :cl-agent)))
  (mapcar (lambda (c) (getf c :value)) (getf (lisp-repl-complete text (length text) package) :candidates)))

(deftest lisp-repl-completes-symbols-packages-keywords-and-abbreviations ()
  (check (member "multiple-value-bind" (lisp-completion-values "(multiple-value-b") :test #'string=))
  (check (member "uiop:split-string" (lisp-completion-values "uiop:split-str") :test #'string=))
  (check (member ":test" (lisp-completion-values "(make-hash-table :tes") :test #'string=))
  (check (member "multiple-value-bind" (lisp-completion-values "(m-v-b") :test #'string=))
  (check (member "uiop:" (lisp-completion-values "(uio") :test #'string=))
  (check-equal (getf (lisp-repl-complete "#'mapc" 6 (find-package :cl-agent)) :start) 2
               "#' stays in front of the completed name"))

;;; Like SLY: the form at point as SLYNK reads it, and the stages Tab tries.

(defun lisp-completion (text &optional (package (find-package :cl-agent)))
  (lisp-repl-complete text (length text) package))

(defclass completion-test-widget ()
  ((colour :initarg :colour) (size :initarg :size-in-pixels)))

(deftest lisp-form-at-point-reads-like-sly ()
  (check-equal (lisp-form-at-point "(foo (bar 1) \"s\" :ke" 20)
               (list "foo" (list "bar" "1") "\"s\"" ":ke" slynk::+cursor-marker+))
  (check-equal (lisp-form-at-point "(a (b c " 8) (list "a" (list "b" "c" "" slynk::+cursor-marker+))
               "an empty argument at point, inside the nested list")
  (check-equal (nth-value 1 (lisp-form-at-point "(load \"src/u" 12)) 7 "inside a string: where its text starts")
  (check (null (lisp-form-at-point "(a) b" 5)) "at toplevel")
  (check (null (lisp-form-at-point "(a ; (b :c" 10)) "in a comment")
  (check (null (lisp-form-at-point "'(make-hash-table :t" 20)) "inside a quoted list"))

(deftest lisp-completion-offers-the-calls-keyword-arguments ()
  (let ((result (lisp-completion "(make-hash-table :te")))
    (check-equal (getf result :source) "lisp-keywords")
    (check-equal (lisp-completion-values "(make-hash-table :te") '(":test")
                 "only MAKE-HASH-TABLE's, not every keyword starting :te"))
  (let ((values (lisp-completion-values "(make-hash-table :test 'equal :")))
    (check (member ":size" values :test #'string=))
    (check (not (member ":test" values :test #'string=)) "a keyword already given is not offered again"))
  (check-equal (sort (lisp-completion-values "(make-instance 'completion-test-widget :") #'string<)
               '(":colour" ":size-in-pixels") "MAKE-INSTANCE: the class's initargs")
  (check-equal (lisp-completion-values "(with-open-file (s \"x\" :dir") '(":direction")
               "a macro's nested lambda list")
  (check-equal (getf (lisp-completion "'(make-hash-table :tes") :source) "lisp" "data, not a call: every keyword"))

(deftest lisp-completion-falls-back-to-sly-flex-matching ()
  (let ((result (lisp-completion "(dstrbind")))
    (check-equal (getf result :source) "lisp-flex")
    (let ((candidate (first (getf result :candidates))))
      (check-equal (getf candidate :value) "destructuring-bind")
      (check-equal (getf candidate :match) '((0 1) (2 5) (14 18)) "the letters matched, for the menu")))
  (check (member "uiop:split-string" (lisp-completion-values "(spl-str") :test #'string=)
         "other packages' external symbols, qualified")
  (check-equal (getf (lisp-completion "(multiple-value-b") :source) "lisp" "a prefix match wins over flex")
  (check (null (lisp-completion-values "(zzqqxxjj"))))

(deftest lisp-completion-completes-file-names-in-strings ()
  (let ((directory (merge-pathnames "completion-files/" *config-directory*)))
    (ensure-directories-exist directory)
    (with-open-file (s (merge-pathnames "alpha-notes.lisp" directory) :direction :output :if-exists :supersede)
      (write-string "1" s))
    (let* ((text (format nil "(load \"~aalp" (namestring directory)))
           (result (lisp-completion text)))
      (check-equal (getf result :source) "lisp-files")
      (check-equal (getf result :start) 7)
      (check-equal (lisp-completion-values text)
                   (list (format nil "~aalpha-notes.lisp" (namestring directory)))))))

(deftest lisp-repl-autodoc-marks-the-current-argument ()
  (let ((positional (lisp-repl-autodoc "subseq" 1 nil (find-package :cl-agent)))
        (keyword (lisp-repl-autodoc "make-completion" 3 ":kind" (find-package :cl-agent)))
        (special (lisp-repl-autodoc "let" 0 nil (find-package :cl-agent))))
    (check-equal (nth (gethash "current" positional) (gethash "arglist" positional)) "start")
    (check-equal (nth (gethash "current" keyword) (gethash "arglist" keyword)) "kind")
    (check (search "let" (gethash "syntax" special)))
    (check (null (lisp-repl-autodoc "test-no-such-operator-xyz" 0 nil (find-package :cl-agent))))))

(deftest lisp-repl-finds-definitions-describes-and-macroexpands ()
  (let ((definition (first (lisp-repl-definitions "lisp-repl-start" (find-package :cl-agent)))))
    (check (search "lisp-repl.lisp" (getf definition :file)))
    (check (uiop:string-prefix-p "(defun lisp-repl-start" (getf definition :snippet)))
    (check (plusp (getf definition :line))))
  ;; UIOP defines inside a WITH-UPGRADABILITY wrapper: find the DEFUN within it.
  (check (uiop:string-prefix-p "(defun split-string"
                               (getf (first (lisp-repl-definitions "uiop:split-string" (find-package :cl-agent)))
                                     :snippet)))
  (check (search "lisp-repl-start" (lisp-repl-describe "lisp-repl-start" (find-package :cl-agent)) :test #'char-equal))
  (check (search "No symbol" (lisp-repl-describe "test-no-such-symbol-xyz" (find-package :cl-agent))))
  (check (search "(if a" (lisp-repl-macroexpand "(when a b)" (find-package :cl-agent)))))

(deftest lisp-token-symbol-never-interns ()
  (check (null (lisp-token-symbol "test-surely-not-interned-xyz" (find-package :cl-agent))))
  (check (null (find-symbol "TEST-SURELY-NOT-INTERNED-XYZ" :cl-agent)))
  (check (eq (lisp-token-symbol "cl:car" (find-package :cl-agent)) 'car))
  (check (eq (lisp-token-symbol ":test" (find-package :cl-agent)) :test)))

;;; --- the scratch buffer ---

(deftest lisp-scratch-saves-versions-and-detects-conflicts ()
  (multiple-value-bind (text version) (lisp-scratch-contents)
    (check (search "(in-package :cl-agent)" text) "starts from the default buffer")
    (multiple-value-bind (status new) (lisp-scratch-save "(+ 1 2)" :base version)
      (check-equal status :saved)
      (check-equal new (1+ version))
      (check-equal (read-text-file (lisp-scratch-pathname)) "(+ 1 2)")
      (multiple-value-bind (status current-version current) (lisp-scratch-save "(stale)" :base version)
        (check-equal status :conflict)
        (check-equal current-version new)
        (check-equal current "(+ 1 2)")))))

(deftest lisp-scratch-agent-writes-keep-a-backup ()
  (lisp-scratch-save "(mine)")
  (lisp-scratch-save "(agent's)" :by "agent")
  (let ((backups (uiop:directory-files (lisp-scratch-history-directory))))
    (check-equal (length backups) 1)
    (check-equal (read-text-file (first backups)) "(mine)")))

(deftest lisp-scratch-notices-edits-made-outside-cl-agent ()
  (lisp-scratch-save "(before)")
  (sleep 1.1)                           ; FILE-WRITE-DATE has one-second resolution
  (write-string-atomically (lisp-scratch-pathname) "(edited in emacs)")
  (check-equal (lisp-scratch-contents) "(edited in emacs)"))

;;; --- the agent's tools ---

(deftest lisp-scratch-tools-read-and-write-the-buffer ()
  (lisp-scratch-save (format nil "(defun f ()~%  1)~%"))
  (check (search "    1  (defun f ()" (call-tool "lisp-scratch" (jobj))))
  (check (search "Updated" (call-tool "lisp-scratch-write" (jobj "old" "  1)" "new" "  2)"))))
  (check-equal (lisp-scratch-contents) (format nil "(defun f ()~%  2)~%"))
  (call-tool "lisp-scratch-write" (jobj "append" "(f)"))
  (check-equal (lisp-scratch-contents) (format nil "(defun f ()~%  2)~%(f)"))
  (check (search "Unbalanced" (call-tool "lisp-scratch-write" (jobj "content" "(oops"))))
  (check-equal (lisp-scratch-contents) "(oops" "an unbalanced buffer is still written, with a warning")
  (check (search "not found" (call-tool "lisp-scratch-write" (jobj "old" "nope" "new" "x")))))

(deftest lisp-scratch-tool-reads-the-transcript ()
  (let ((*lisp-repl* (make-lisp-repl)))
    (repl-eval-and-wait *lisp-repl* "(* 6 7)")
    (check (search "=> 42" (call-tool "lisp-scratch" (jobj "action" "transcript"))))))

;;; --- HTTP ---

(defun wait-for-global-entry (id)
  (let ((entry (find id (lisp-repl-entries *lisp-repl*) :key #'lisp-entry-id)))
    (and entry (lisp-repl-wait entry))
    entry))

(deftest lisp-routes-evaluate-and-report-over-http ()
  (with-test-web-frontend (frontend)
    (let* ((id (gethash "id" (json-decode (web-post frontend "/api/lisp/eval" :json (jobj "text" "(+ 2 3)")))))
           (entry (wait-for-global-entry id)))
      (check-equal (entry-value-texts entry) '("5"))
      (sleep 0.05)
      (let* ((state (web-get-json frontend "/api/lisp/state"))
             (shown (find id (gethash "entries" state) :key (lambda (e) (gethash "id" e)))))
        (check-equal (gethash "text" (first (gethash "values" shown))) "5")
        (check (gethash "text" (gethash "scratch" state))))
      (check (some (lambda (event) (search "\"type\":\"lisp-entry\"" (cdr event)))
                   (web-frontend-events frontend))
             "pages hear about the entry"))
    (check-equal (nth-value 1 (web-post frontend "/api/lisp/eval" :json (jobj "text" "1") :trusted nil)) 403)
    (check-equal (nth-value 1 (web-post frontend "/api/lisp/eval" :json (jobj "text" "  "))) 400)))

(deftest lisp-routes-scratch-conflicts-are-409 ()
  (with-test-web-frontend (frontend)
    (let* ((base (gethash "version" (gethash "scratch" (web-get-json frontend "/api/lisp/state"))))
           (version (gethash "version" (json-decode (web-post frontend "/api/lisp/scratch"
                                                              :json (jobj "text" "(a)" "base" base))))))
      (check (integerp version))
      (multiple-value-bind (body status)
          (web-post frontend "/api/lisp/scratch" :json (jobj "text" "(b)" "base" (1- version)))
        (check-equal status 409)
        (check-equal (gethash "text" (json-decode body)) "(a)")))))

(deftest lisp-routes-introspection-over-http ()
  (with-test-web-frontend (frontend)
    (let ((candidate (find "multiple-value-bind"
                           (gethash "candidates" (web-get-json frontend "/api/lisp/complete?text=(multiple-value-b&cursor=17"))
                           :key (lambda (c) (gethash "value" c)) :test #'equal)))
      (check candidate)
      (check-equal (gethash "match" candidate) '((0 16)) "the matched letters reach the page"))
    (check-equal (gethash "operator" (web-get-json frontend "/api/lisp/autodoc?operator=subseq&index=1")) "subseq")
    (check (search "lisp-repl-start" (gethash "text" (web-get-json frontend "/api/lisp/describe?symbol=lisp-repl-start"))
                  :test #'char-equal))
    (check (plusp (length (gethash "definitions" (web-get-json frontend "/api/lisp/definition?symbol=lisp-repl-start")))))
    (check (search "(if a" (gethash "expansion" (json-decode (web-post frontend "/api/lisp/macroexpand"
                                                                       :json (jobj "text" "(when a b)"))))))
    (check-equal (nth-value 1 (web-get frontend "/api/lisp/inspect?id=999999")) 404)
    (check-equal (gethash "status" (json-decode (web-post frontend "/api/lisp/interrupt"))) "idle")))

(deftest lisp-tab-assets-are-served ()
  (with-test-web-frontend (frontend)
    (dolist (path '("/assets/lisp.js" "/assets/lisp-editor.js" "/assets/menu.js" "/assets/views.js"))
      (check-equal (nth-value 1 (web-get frontend path)) 200 path))
    (check (search "id=\"main-tabs\"" (web-get frontend "/")))))
