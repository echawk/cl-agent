;;;; t/test-completion.lisp -- tab completion (src/completion.lisp).

(in-package :cl-agent)

(defun completion-values (text &key (cursor (length text)) session)
  (mapcar (lambda (c) (getf c :value)) (getf (complete-input text cursor :session session) :candidates)))

(deftest completion-offers-slash-commands-with-their-docstrings ()
  (let* ((result (complete-input "/he" 3))
         (help (find "/help" (getf result :candidates) :key (lambda (c) (getf c :value)) :test #'string=)))
    (check help)
    (check-equal (getf help :kind) "command")
    (check (search "slash command" (getf help :doc)))
    (check-equal (getf result :start) 0)
    (check-equal (getf result :source) "slash-commands"))
  (check (member "/theme" (completion-values "/th") :test #'string=))
  (check (member "/ui" (completion-values "/u") :test #'string=))
  (check (= (length (completion-values "/")) (length *slash-commands*)) "a bare / lists every command"))

(deftest completion-completes-call-tool-names-then-an-arguments-skeleton ()
  (check (member "shell" (completion-values "/call she") :test #'string=))
  (let ((skeleton (first (completion-values "/call shell "))))
    (check (and skeleton (char= (char skeleton 0) #\{)))
    (check (search "\"command\"" skeleton))
    (check (hash-table-p (json-decode skeleton)) "the skeleton is valid JSON")))

(deftest completion-completes-word-arguments ()
  (check-equal (sort (completion-values "/mode pl") #'string<) '("plan" "plan-review"))
  (check-equal (completion-values "/capabilities ins") '("inspect"))
  (check-equal (completion-values "/theme d") '("dark"))
  (check (member "deny" (completion-values "/policy d") :test #'string=))
  (check (member "shell" (completion-values "/policy deny sh") :test #'string=))
  (check-equal (completion-values "/mode plan ") nil "past the last argument there is nothing"))

(deftest completion-completes-file-paths ()
  (let ((directory (uiop:ensure-directory-pathname
                    (merge-pathnames (format nil "cl-agent-complete-~a" (random 1000000))
                                     (uiop:temporary-directory)))))
    (unwind-protect
         (progn
           (ensure-directories-exist (merge-pathnames "alpine/" directory))
           (write-string-atomically (merge-pathnames "alpha.txt" directory) "x")
           (write-string-atomically (merge-pathnames ".hidden" directory) "x")
           (let* ((base (namestring (truename directory)))
                  (values (completion-values (format nil "look at ~aal" base)))
                  (at-values (completion-values (format nil "@~a" base))))
             (check (member (format nil "~aalpha.txt" base) values :test #'string=))
             (check (member (format nil "~aalpine/" base) values :test #'string=) "directories end in /")
             (check (member (format nil "@~aalpha.txt" base) at-values :test #'string=) "@ is kept")
             (check (notany (lambda (v) (search ".hidden" v)) at-values) "dotfiles need an explicit dot")
             (check (some (lambda (v) (search ".hidden" v)) (completion-values (format nil "@~a." base))))))
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))

(deftest completion-completes-lisp-symbols ()
  (let* ((result (complete-input "(list-too" 9))
         (candidate (first (getf result :candidates))))
    (check-equal (getf candidate :value) "list-tools")
    (check-equal (getf candidate :kind) "function")
    (check (getf candidate :doc)))
  (check (member "cl-agent::make-completion" (completion-values "cl-agent::make-compl") :test #'string=))
  (check (member "#'make-completion" (completion-values "(mapcar #'make-compl") :test #'string=))
  (check (member ":web-ui-state" (completion-values "see :web-ui-st") :test #'string=))
  (check-equal (completion-values "plain words") nil "ordinary prose is left alone"))

(deftest completion-sources-are-extensible-and-ordered ()
  (unwind-protect
       (progn
         (define-command-completer "test-deploy" (context)
           (when (= (getf context :arg-index) 0)
             (completions-matching (getf context :token) '("staging" "production"))))
         (define-completion-source test-emoji (context :priority 5)
           (when (uiop:string-prefix-p "%sm" (getf context :token))
             (list (make-completion "🙂" :doc "smile"))))
         (check-equal (completion-values "/test-deploy st") '("staging"))
         (check-equal (completion-values "hi %sm") '("🙂"))
         (check-equal (completion-source-name (first *completion-sources*)) "test-emoji" "lower priority runs first"))
    (setf *completion-sources*
          (remove-if (lambda (s) (member (completion-source-name s) '("test-emoji" "command:test-deploy") :test #'string=))
                     *completion-sources*))))

(deftest completion-survives-a-failing-source ()
  (unwind-protect
       (progn
         (define-completion-source test-broken (context :priority 1) (error "boom ~a" context))
         (check (member "/help" (completion-values "/hel") :test #'string=)))
    (setf *completion-sources* (remove "test-broken" *completion-sources*
                                       :key #'completion-source-name :test #'string=))))

(deftest completion-result-json-reports-the-common-prefix ()
  (let ((json (completion-result-json (complete-input "/mode pl" 8))))
    (check-equal (jget json "common") "plan")
    (check-equal (jget json "start") 6)
    (check-equal (jget json "end") 8)))

(deftest web-complete-endpoint-serves-completions ()
  (with-test-web-frontend (frontend)
    (let ((result (web-get-json frontend "/api/complete?text=/hel&cursor=4")))
      (check (member "/help" (mapcar (lambda (c) (jget c "value")) (jget result "candidates")) :test #'string=))
      (check-equal (jget result "source") "slash-commands"))))
