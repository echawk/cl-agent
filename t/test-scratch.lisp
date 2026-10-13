;;;; t/test-scratch.lisp -- scratch buffers in other languages (scratch.lisp),
;;;; their tools and routes, Lem's highlighting route, and their language
;;;; server (t/fixtures/fake-lsp-server.py stands in for a real one).

(in-package :cl-agent)

(deftest scratch-buffers-are-files-in-their-language ()
  (let ((ruby (scratch-buffer-create "hello" "Ruby" :text "puts 1"))
        (c (scratch-buffer-create "main-1" "c"))
        (python (scratch-buffer-create "tool_2" "py"))
        (text (scratch-buffer-create "notes" "Text")))
    (check (uiop:pathname-equal (uiop:pathname-directory-pathname ruby) (scratch-directory)))
    (check-equal (mapcar #'pathname-type (list ruby c python text)) '("rb" "c" "py" "txt"))
    (check-equal (scratch-buffer-language ruby) "Ruby" "the language is Lem's mode for the file")
    (check-equal (scratch-buffer-language c) "C")
    (check-equal (mapcar #'pathname-name (scratch-buffer-files)) '("hello" "main-1" "notes" "tool_2"))
    (check-equal (scratch-buffer-contents "hello") "puts 1")
    (check (assoc "Ruby" (scratch-languages) :test #'string=) "Lem's languages are offered")
    (check-condition error (scratch-buffer-create "hello" "Ruby") "names are unique")
    (check-condition error (scratch-buffer-create "../evil" "c") "names are plain file names")
    (check-condition error (scratch-buffer-create "x" "") "a language is required")
    (check (scratch-buffer-delete "notes"))
    (check (null (find-scratch-buffer "notes")))
    (check (scratch-history-files "notes") "deleting keeps a copy")))

(deftest scratch-saves-are-versioned-and-refuse-stale-writes ()
  (scratch-buffer-create "versions" "c" :text "int a;")
  (multiple-value-bind (text version) (scratch-buffer-contents "versions")
    (check-equal text "int a;")
    (check-equal (scratch-buffer-save "versions" "int b;" :base version) :saved)
    (multiple-value-bind (status current-version current)
        (scratch-buffer-save "versions" "int c;" :base version :by "agent")
      (check-equal status :conflict "written against an old version")
      (check-equal current "int b;")
      (check-equal (scratch-buffer-save "versions" "int c;" :base current-version :by "agent") :saved)))
  (check (scratch-history-files "versions") "the agent's write backed up the old text")
  (with-open-file (out (find-scratch-buffer "versions") :direction :output :if-exists :supersede)
    (write-string "int edited_elsewhere;" out))
  (check-equal (scratch-buffer-contents "versions") "int edited_elsewhere;" "edits made outside are seen"))

(deftest scratch-tools-create-read-and-edit-buffers ()
  (check (search "no scratch buffers" (call-tool "scratch-buffers" (jobj))))
  (check (search "Created scratch buffer greet (Ruby)"
                 (call-tool "scratch-buffer-write" (jobj "name" "greet" "language" "ruby"
                                                         "content" (format nil "def greet~%  puts 'hi'~%end")))))
  (check (search "greet (Ruby)" (call-tool "scratch-buffers" (jobj))))
  (check (search "    2    puts 'hi'" (call-tool "scratch-buffers" (jobj "name" "greet"))))
  (check (search "Updated scratch buffer greet"
                 (call-tool "scratch-buffer-write" (jobj "name" "greet" "old" "'hi'" "new" "'hello'"))))
  (check (search "puts 'hello'" (scratch-buffer-contents "greet")))
  (check (search "Not written" (call-tool "scratch-buffer-write" (jobj "name" "greet" "old" "absent" "new" "x"))))
  (check (search "also give language" (call-tool "scratch-buffer-write" (jobj "name" "nope" "content" "x")))))

(deftest scratch-and-highlight-routes-over-http ()
  (with-test-web-frontend (frontend)
    (let ((list (web-get-json frontend "/api/scratch")))
      (check (find "Ruby" (gethash "languages" list) :key (lambda (l) (gethash "name" l)) :test #'equal))
      (check-equal (gethash "state" (gethash "lem" list)) "running"))
    (check-equal (gethash "name" (json-decode (web-post frontend "/api/scratch/create"
                                                         :json (jobj "name" "web" "language" "C" "text" "int x;"))))
                 "web")
    (let ((buffer (web-get-json frontend "/api/scratch/buffer?name=web")))
      (check-equal (gethash "text" buffer) "int x;")
      (check-equal (gethash "language" buffer) "C")
      (multiple-value-bind (body status)
          (web-post frontend "/api/scratch/save" :json (jobj "name" "web" "text" "int y;" "base" (gethash "version" buffer)))
        (check-equal status 200 body))
      (multiple-value-bind (body status)
          (web-post frontend "/api/scratch/save" :json (jobj "name" "web" "text" "int z;" "base" (gethash "version" buffer)))
        (check-equal status 409)
        (check-equal (gethash "text" (json-decode body)) "int y;")))
    (let ((unicode (format nil "/* h~cllo ~c ~c */" (code-char #xE9) (code-char #x2713) (code-char #x1F600))))
      (web-post frontend "/api/scratch/save" :json (jobj "name" "web" "text" unicode))
      (check-equal (scratch-buffer-contents "web") unicode "request bodies are UTF-8, as JSON is"))
    (multiple-value-bind (body status) (web-post frontend "/api/scratch/save" :json (jobj "name" "absent" "text" "x"))
      (declare (ignore body))
      (check-equal status 404))
    ;; Runs are in the browser's UTF-16 offsets: the emoji counts twice.
    (let* ((reply (json-decode (web-post frontend "/api/highlight"
                                         :json (jobj "text" (format nil "/* ~a */ return 1;" (code-char #x1F600))
                                                     "language" "c"))))
           (keyword (find "sx-keyword" (gethash "runs" reply) :key #'third :test #'equal)))
      (check-equal (gethash "mode" reply) "C")
      (check-equal (subseq keyword 0 2) '(9 15)))
    (check (null (gethash "runs" (json-decode (web-post frontend "/api/highlight" :json (jobj "text" "x" "language" "klingon")))))
           "nothing to colour in a language Lem lacks")
    (check-equal (nth-value 1 (web-post frontend "/api/scratch/delete" :json (jobj "name" "web"))) 200)))

;;; --- the language server ---

(defun fake-lsp-server-command ()
  "(COMMAND . ARGUMENTS) running the fake server, or NIL without python3."
  (let ((python (ignore-errors (string-trim '(#\Newline) (uiop:run-program '("which" "python3") :output :string)))))
    (when (and python (plusp (length python)))
      (list python (uiop:native-namestring
                    (asdf:system-relative-pathname "cl-agent" "t/fixtures/fake-lsp-server.py"))))))

(defmacro with-fake-lsp-server ((&key (extension ".fakelang")) &body body)
  "Run BODY with lsp.sexp configuring the fake server for EXTENSION files,
or skip it (passing) when python3 is not installed."
  `(let ((command (fake-lsp-server-command)))
     (if (null command)
         (format t "~&  (skipped: python3 is needed for the fake language server)~%")
         (let ((*lsp-configuration-pathname* (merge-pathnames "lsp.sexp" *config-directory*)))
           (ensure-directories-exist *lsp-configuration-pathname*)
           (with-open-file (out *lsp-configuration-pathname* :direction :output :if-exists :supersede)
             (let ((*print-case* :downcase))
               (prin1 (list :version 1
                            :servers (list (list :name "fake" :command (first command) :arguments (rest command)
                                                 :extensions (list ,extension) :language-id "fake")))
                      out)))
           (initialize-lsp)
           (unwind-protect (progn ,@body)
             (close-lsp-servers)
             (initialize-lsp (merge-pathnames "absent-lsp.sexp" *config-directory*)))))))

(deftest scratch-buffers-talk-to-their-language-server ()
  (with-fake-lsp-server ()
    (scratch-buffer-create "served" "fakelang" :text (format nil "one~%two FIXME~%greeting"))
    (check-equal (scratch-buffer-lsp-servers (find-scratch-buffer "served")) '("fake"))
    (let ((diagnostics (scratch-buffer-diagnostics "served")))
      (check-equal (length diagnostics) 1)
      (check-equal (getf (first diagnostics) :line) 1)
      (check-equal (getf (first diagnostics) :character) 4)
      (check-equal (getf (first diagnostics) :severity) "warning")
      (check-equal (getf (first diagnostics) :message) "fake: fix this"))
    (multiple-value-bind (status version) (scratch-buffer-save "served" "all fine now")
      (declare (ignore status version))
      (check (null (scratch-buffer-diagnostics "served")) "the saved text is what the server sees"))
    (check-equal (scratch-buffer-hover "served" 0 5) "fake hover: fine")
    (scratch-buffer-create "unserved" "rb")
    (check-condition error (scratch-buffer-diagnostics "unserved") "no server for .rb here")
    ;; The agent reaches the same server through the buffer's path.
    (check (search "fake: fix this"
                   (progn (scratch-buffer-save "served" "FIXME")
                          (call-tool "lsp-diagnostics"
                                     (jobj "path" (uiop:native-namestring (find-scratch-buffer "served")))))))))

(deftest scratch-diagnostics-over-http ()
  (with-fake-lsp-server ()
    (with-test-web-frontend (frontend)
      (scratch-buffer-create "web-served" "fakelang" :text "x FIXME")
      (check-equal (gethash "servers" (web-get-json frontend "/api/scratch/buffer?name=web-served")) '("fake"))
      (let ((diagnostic (first (gethash "diagnostics"
                                        (json-decode (web-post frontend "/api/scratch/diagnostics"
                                                               :json (jobj "name" "web-served")))))))
        (check-equal (gethash "character" diagnostic) 2)
        (check-equal (gethash "server" diagnostic) "fake"))
      (check-equal (gethash "text" (json-decode (web-post frontend "/api/scratch/hover"
                                                          :json (jobj "name" "web-served" "line" 0 "character" 3))))
                   "fake hover: FIXME"))))

(deftest default-language-servers-apply-without-lsp-sexp ()
  (let ((command (fake-lsp-server-command)))
    (when command
      (let ((*lsp-configuration-pathname* (merge-pathnames "no-such-lsp.sexp" *config-directory*))
            (*default-lsp-configuration*
              (let ((*print-case* :downcase))
                (prin1-to-string (list :version 1
                                       :servers (list (list :name "builtin-fake" :command (first command)
                                                            :arguments (rest command) :extensions '(".fakelang")
                                                            :language-id "fake")
                                                      (list :name "missing" :command "cl-agent-no-such-server"
                                                            :extensions '(".nope") :language-id "nope")))))))
        (unwind-protect
             (multiple-value-bind (available unavailable) (initialize-lsp)
               (check-equal (mapcar #'cl-lsp:lsp-server-configuration-name available) '("builtin-fake"))
               (check-equal unavailable '("missing") "servers that are not installed are left out"))
          (close-lsp-servers))))))
