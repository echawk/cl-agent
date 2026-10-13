;;;; completion.lisp -- tab completion for whatever the user is typing,
;;;; independent of any particular frontend (the web UI asks for it over
;;;; GET /api/complete; a TUI could call COMPLETE-INPUT directly).
;;;;
;;;; COMPLETE-INPUT parses the line into a context plist and asks each
;;;; COMPLETION SOURCE in priority order; the first to return candidates
;;;; wins.  Built in, in that order:
;;;;
;;;;   10  slash-commands   "/he"          -> /help, with each command's docstring
;;;;   20  command args     "/call sh"     -> shell; "/call shell " -> {"command": ""}
;;;;                         (one DEFINE-COMMAND-COMPLETER per command)
;;;;   30  paths            "@src/ui/w"    -> @src/ui/web/  (also ./ ../ ~/ /)
;;;;   40  lisp symbols     "(list-to"     -> list-tools, with its docstring
;;;;                         (also pkg:sym, #'sym, and :keyword tokens)
;;;;
;;;; Both macros are extension surfaces, and both are recognised by
;;;; write-extension's integration check:
;;;;
;;;;   (define-command-completer "deploy" (context)
;;;;     (when (= (getf context :arg-index) 0)
;;;;       (list (make-completion "staging") (make-completion "production"))))
;;;;
;;;;   (define-completion-source emoji (context :priority 35)
;;;;     (when (uiop:string-prefix-p ":" (getf context :token)) ...))
;;;;
;;;; A source returns a list of MAKE-COMPLETION plists, or NIL to let the
;;;; next source try.  It must be quick: it runs on every Tab press.

(in-package :cl-agent)

(defstruct completion-source name priority function owner)

(defvar *completion-sources* nil
  "COMPLETION-SOURCE structs, kept sorted by ascending priority.")

(defparameter *completion-limit* 200
  "Most candidates returned for one request.")

(defun register-completion-source (name priority function)
  (let ((name (string-downcase (string name))))
    (setf *completion-sources*
          (stable-sort (cons (make-completion-source :name name :priority priority :function function
                                                     :owner (or *registration-owner* "core"))
                             (remove name *completion-sources* :key #'completion-source-name
                                                               :test #'string=))
                       #'< :key #'completion-source-priority))
    (publish-component :completion-source name :owner (or *registration-owner* "core")
                       :metadata (list :priority priority))
    name))

(defmacro define-completion-source (name (context-var &key (priority 50)) &body body)
  "Register a completion source NAME.  BODY sees CONTEXT-VAR, a plist:
  :TEXT :CURSOR   the whole input and the caret position
  :TOKEN :START   the word being completed and where it starts
  :COMMAND        the slash command's name (\"call\") when the line is one
  :COMMAND-TOKEN-P  true while the command name itself is being typed
  :ARGS :ARG-INDEX  the command's finished arguments and the current one's index
  :SESSION        the AGENT-SESSION, or NIL
Return MAKE-COMPLETION plists to answer, or NIL to defer to later sources."
  `(register-completion-source ',name ,priority (lambda (,context-var) ,@body)))

(defmacro define-command-completer (command (context-var) &body body)
  "Complete the arguments of slash command COMMAND (a string, without /).
BODY is a completion source that only runs on lines starting with /COMMAND
followed by a space; use (getf CONTEXT-VAR :ARG-INDEX) and :ARGS to tell which
argument is being typed."
  (let ((name (format nil "command:~a" (string-downcase command))))
    `(register-completion-source
      ,name 20
      (lambda (,context-var)
        (when (and (equal (getf ,context-var :command) ,(string-downcase command))
                   (not (getf ,context-var :command-token-p)))
          ,@body)))))

(defun make-completion (value &key doc kind display match)
  "One candidate: VALUE replaces the token; DISPLAY (default VALUE) is what the
menu shows; DOC is a one-line description; KIND a short category string;
MATCH the (START END) ranges of DISPLAY the typed text matched, highlighted."
  (list :value value :display (or display value) :doc doc :kind kind :match match))

(defun first-line (text &optional (limit 110))
  (when (stringp text)
    (let* ((trimmed (string-trim '(#\Space #\Newline #\Tab) text))
           (line (subseq trimmed 0 (or (position #\Newline trimmed) (length trimmed)))))
      (if (> (length line) limit) (concatenate 'string (subseq line 0 (1- limit)) "…") line))))

(defun completions-matching (prefix items &key (key #'identity) doc kind (value key))
  "MAKE-COMPLETION for each of ITEMS whose KEY starts with PREFIX (any case)."
  (loop for item in items
        for name = (funcall key item)
        when (and (stringp name) (<= (length prefix) (length name))
                  (string-equal prefix name :end2 (length prefix)))
          collect (make-completion (funcall value item)
                                   :doc (and doc (funcall doc item))
                                   :kind kind)))

;;; --- Parsing the line ---

(defparameter *completion-token-delimiters* '(#\Space #\Tab #\Newline #\( #\) #\' #\" #\` #\,))

(defun completion-context (text cursor &key session)
  (let* ((before (subseq text 0 cursor))
         (start (let* ((p (position-if (lambda (c) (member c *completion-token-delimiters*))
                                       before :from-end t))
                       (start (if p (1+ p) 0)))
                  ;; #'NAME is one token even though ' delimits words.
                  (if (and (>= start 2) (string= "#'" before :start2 (- start 2) :end2 start))
                      (- start 2)
                      start)))
         (token (subseq before start))
         (command-line-p (and (plusp (length text)) (char= (char text 0) #\/)))
         (words (and command-line-p (uiop:split-string before :separator '(#\Space))))
         (command (and command-line-p (string-downcase (subseq (first words) 1))))
         (args (and command-line-p (remove "" (butlast (rest words)) :test #'string=))))
    (list :text text :cursor cursor :before before :start start :token token
          :command command :command-token-p (and command-line-p (= (length words) 1))
          :args args :arg-index (length args) :session session
          :preceding (and (plusp start) (char before (1- start))))))

(defun common-completion-prefix (values)
  (when values
    (reduce (lambda (a b)
              (subseq a 0 (or (mismatch a b :test #'char-equal) (min (length a) (length b)))))
            values)))

(defun complete-input (text cursor &key session)
  "Return a plist (:START :END :TOKEN :CANDIDATES :SOURCE :TOTAL) completing
TEXT at CURSOR: replace TEXT[START, END) with a candidate's :VALUE."
  (let ((context (completion-context text cursor :session session)))
    (dolist (source *completion-sources*
                    (list :start (getf context :start) :end cursor :token (getf context :token)
                          :candidates nil :source nil :total 0))
      (let ((candidates (handler-case (funcall (completion-source-function source) context)
                          (error () nil))))
        (when candidates
          (return (list :start (getf context :start) :end cursor :token (getf context :token)
                        :candidates (subseq candidates 0 (min (length candidates) *completion-limit*))
                        :total (length candidates)
                        :source (completion-source-name source))))))))

(defun completion-result-json (result)
  (let ((candidates (getf result :candidates)))
    (jobj "start" (getf result :start) "end" (getf result :end) "token" (getf result :token)
          "source" (json-or-null (getf result :source)) "total" (getf result :total)
          "common" (or (common-completion-prefix (mapcar (lambda (c) (getf c :value)) candidates)) "")
          "candidates" (jarray (mapcar (lambda (c)
                                         (jobj "value" (getf c :value) "display" (getf c :display)
                                               "doc" (json-or-null (getf c :doc))
                                               "kind" (json-or-null (getf c :kind))
                                               "match" (jarray (mapcar #'jarray (getf c :match)))
                                               ;; Where this one replaces from, when not the result's start.
                                               "start" (json-or-null (getf c :start))))
                                       candidates)))))

;;; --- 10: slash command names ---

(defun slash-command-doc (name)
  (let ((function (cdr (assoc name *slash-commands* :test #'string=))))
    (and function (first-line (documentation function t)))))

(define-completion-source slash-commands (context :priority 10)
  (when (getf context :command-token-p)
    (let ((token (getf context :token)))
      (completions-matching (if (plusp (length token)) (subseq token 1) "")
                            (sort (mapcar #'car *slash-commands*) #'string<)
                            :value (lambda (name) (concatenate 'string "/" name))
                            :doc #'slash-command-doc :kind "command"))))

;;; --- 20: command arguments ---

(defun context-session-tools (context)
  (let ((session (getf context :session)))
    (when session (sync-session-tools session))
    (sort (copy-list (if session (session-tools session) (list-tools))) #'string< :key #'tool-name)))

(defun tool-argument-skeleton (tool)
  "A JSON object with every required parameter of TOOL (all if none are
required) set to an empty value of its type: a starting point for /call."
  (let* ((schema (tool-parameters tool))
         (properties (jget schema "properties"))
         (required (let ((r (jget schema "required"))) (and (listp r) r)))
         (names (or required (and (hash-table-p properties)
                                  (sort (loop for k being the hash-keys of properties collect k)
                                        #'string<)))))
    (json-encode
     (apply #'jobj
            (loop for name in names
                  for type = (jget (jget properties name) "type")
                  append (list name (cond ((equal type "string") "")
                                          ((equal type "boolean") nil)
                                          ((member type '("integer" "number") :test #'equal) 0)
                                          ((equal type "array") :empty-array)
                                          (t :empty-object))))))))

(define-command-completer "call" (context)
  (case (getf context :arg-index)
    (0 (completions-matching (getf context :token) (context-session-tools context)
                             :key #'tool-name :doc (lambda (tool) (first-line (tool-description tool)))
                             :kind "tool"))
    (1 (let ((tool (find-tool (first (getf context :args)))))
         (when (and tool (zerop (length (getf context :token))))
           (list (make-completion (tool-argument-skeleton tool) :kind "json"
                                  :doc "Arguments object for this tool")))))))

(defun keyword-names (keywords)
  (mapcar (lambda (k) (string-downcase (string k))) keywords))

(defmacro define-word-completer (command &rest positions)
  "Complete COMMAND's Nth argument from the Nth form of POSITIONS, each
evaluated (with CONTEXT bound) to a list of strings or (name . doc) conses."
  `(define-command-completer ,command (context)
     (let ((choices (case (getf context :arg-index)
                      ,@(loop for form in positions for i from 0 collect `(,i ,form)))))
       (completions-matching (getf context :token) choices
                             :key (lambda (c) (if (consp c) (car c) c))
                             :doc (lambda (c) (and (consp c) (cdr c)))
                             :kind ,(format nil "~(~a~)" command)))))

(define-word-completer "mode"
  (keyword-names *orchestration-modes*))

(define-word-completer "capabilities"
  (keyword-names *capability-modes*))

(define-word-completer "policy"
  '("list" "clear" "allow" "ask" "deny")
  (when (member (first (getf context :args)) '("allow" "ask" "deny") :test #'string-equal)
    (mapcar #'tool-name (context-session-tools context))))

(define-word-completer "agents"
  '(("cancel" . "Stop a running subagent"))
  (when (string-equal (first (getf context :args)) "cancel")
    (loop for task in (list-subagent-tasks)
          unless (subagent-task-terminal-p task)
            collect (cons (subagent-task-id task)
                          (getf (subagent-task-snapshot task) :description)))))

(define-word-completer "session"
  '("save" "restore" "list" "durable-list" "resume" "replay" "rename" "delete" "timeline" "branch" "export" "rewind")
  (let ((action (first (getf context :args))))
    (cond ((string-equal action "restore")
           (remove nil (mapcar (lambda (s) (getf s :name)) (list-saved-sessions))))
          ((member action '("resume" "replay" "delete") :test #'string-equal)
           ;; Sessions with more than their creation event, named ones described.
           (loop for manifest in (list-durable-sessions)
                 when (> (or (getf manifest :last-sequence) 0) 1)
                   collect (cons (getf manifest :id) (or (getf manifest :name) "")))))))

(define-word-completer "settings"
  '("list" "get" "set")
  (when (member (first (getf context :args)) '("get" "set") :test #'string-equal)
    (mapcar (lambda (setting)
              (cons (string-downcase (string (setinka:setting-name setting)))
                    (first-line (setinka:setting-documentation setting))))
            (setinka:settings-list *agent-setting-registry*))))

(define-word-completer "components"
  (let ((token (getf context :token)))
    (if (find #\: token)
        (mapcar #'component-descriptor-id (list-components))
        (remove-duplicates (mapcar (lambda (d) (string-downcase (string (component-descriptor-kind d))))
                                   (list-components))
                           :test #'string=))))

(define-word-completer "mcp"
  '("connect" "disconnect")
  (when (string-equal (first (getf context :args)) "disconnect")
    (mapcar (lambda (c) (getf c :name)) (list-mcp-connections))))

(defvar *completion-model-cache* (make-hash-table :test 'eq :weakness :key)
  "Provider -> model ID list, so /model completion asks the provider once.")

(define-word-completer "model"
  (let ((session (getf context :session)))
    (when session
      (let ((provider (session-provider session)))
        (multiple-value-bind (models found) (gethash provider *completion-model-cache*)
          (if found models
              (setf (gethash provider *completion-model-cache*)
                    (ignore-errors (mapcar #'princ-to-string (provider-list-models provider))))))))))

;;; --- 30: file paths ---

(defun path-completions (token)
  "Complete TOKEN (\"@src/ui\", \"./t\", \"~/Doc\", \"/usr/lo\") against the
filesystem, relative to the working directory."
  (let* ((at (and (plusp (length token)) (char= (char token 0) #\@)))
         (raw (if at (subseq token 1) token))
         (slash (position #\/ raw :from-end t))
         (dir-part (if slash (subseq raw 0 (1+ slash)) ""))
         (name-part (if slash (subseq raw (1+ slash)) raw))
         (directory (cond ((uiop:string-prefix-p "~/" dir-part)
                           (merge-pathnames (subseq dir-part 2) (user-homedir-pathname)))
                          ((string= dir-part "") (uiop:getcwd))
                          (t (uiop:ensure-directory-pathname
                              (merge-pathnames dir-part (uiop:getcwd)))))))
    (when (probe-file directory)
      (flet ((entry (name dir-p)
               (when (and (or (plusp (length name-part)) (char/= (char name 0) #\.))
                          (<= (length name-part) (length name))
                          (string= name-part name :end2 (length name-part)))
                 (make-completion (format nil "~:[~;@~]~a~a~:[~;/~]" at dir-part name dir-p)
                                  :display (format nil "~a~:[~;/~]" name dir-p)
                                  :kind (if dir-p "dir" "file")))))
        (append
         (loop for sub in (ignore-errors (uiop:subdirectories directory))
               for entry = (entry (car (last (pathname-directory sub))) t)
               when entry collect entry)
         (loop for file in (ignore-errors (uiop:directory-files directory))
               for entry = (entry (file-namestring file) nil)
               when entry collect entry))))))

(define-completion-source paths (context :priority 30)
  (let ((token (getf context :token)))
    (when (or (uiop:string-prefix-p "@" token) (uiop:string-prefix-p "./" token)
              (uiop:string-prefix-p "../" token) (uiop:string-prefix-p "~/" token)
              (and (uiop:string-prefix-p "/" token) (not (getf context :command-token-p))))
      (path-completions token))))

;;; --- 40: Lisp symbols ---

(defun symbol-completion-kind (symbol)
  (cond ((macro-function symbol) "macro")
        ((fboundp symbol) "function")
        ((boundp symbol) "variable")
        ((find-class symbol nil) "class")
        (t "symbol")))

(defun symbol-completion-doc (symbol)
  (first-line (or (and (fboundp symbol) (documentation symbol 'function))
                  (documentation symbol 'variable)
                  (documentation symbol 'type))))

(defun lisp-symbol-completions (token)
  (let* ((quote-prefix (if (uiop:string-prefix-p "#'" token) "#'" ""))
         (token (subseq token (length quote-prefix)))
         (colon (position #\: token))
         (package-name (and colon (if (zerop colon) "KEYWORD" (subseq token 0 colon))))
         (internal-p (and colon (< (1+ colon) (length token)) (char= (char token (1+ colon)) #\:)))
         (name (if colon (subseq token (+ colon (if internal-p 2 1))) token))
         (package (if colon (find-package (string-upcase package-name)) (find-package :cl-agent)))
         (prefix (if colon (subseq token 0 (+ colon (if internal-p 2 1))) ""))
         (seen (make-hash-table :test 'eq))
         (results nil))
    (when (and package (or colon (plusp (length name))))
      (flet ((consider (symbol)
               (let ((sname (symbol-name symbol)))
                 (when (and (not (gethash symbol seen))
                            (<= (length name) (length sname))
                            (string-equal name sname :end2 (length name))
                            (or colon (fboundp symbol) (boundp symbol) (find-class symbol nil)))
                   (setf (gethash symbol seen) t)
                   (push symbol results)))))
        (if (and colon (not internal-p) (string/= package-name "KEYWORD"))
            (do-external-symbols (symbol package) (consider symbol))
            (do-symbols (symbol package) (consider symbol)))))
    (mapcar (lambda (symbol)
              (make-completion (format nil "~a~a~(~a~)" quote-prefix prefix (symbol-name symbol))
                               :display (string-downcase (symbol-name symbol))
                               :doc (symbol-completion-doc symbol)
                               :kind (symbol-completion-kind symbol)))
            (sort results (lambda (a b)
                            (let ((fa (fboundp a)) (fb (fboundp b)))
                              (if (eq (and fa t) (and fb t))
                                  (string< (symbol-name a) (symbol-name b))
                                  fa)))))))

(define-completion-source lisp-symbols (context :priority 40)
  (let ((token (getf context :token)))
    (when (and (plusp (length token))
               (or (eql (getf context :preceding) #\()
                   (uiop:string-prefix-p "#'" token)
                   (find #\: token)))
      (lisp-symbol-completions token))))
