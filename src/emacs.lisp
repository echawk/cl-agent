;;;; emacs.lisp -- Emacs as the editor, beside Lem: cl-agent runs an Emacs
;;;; daemon of its own and shows its frames (emacsclient -t, in a terminal,
;;;; terminal.lisp) in the Code tab's editor and the Lisp tab's scratch pane.
;;;; Lem stays: it highlights the conversation's code and serves the agent's
;;;; lem-command, and the page's Editor switch chooses Lem, Simple or Emacs.
;;;;
;;;; The daemon is Emacs's own, with the person's init file, and
;;;; src/emacs/cl-agent.el loaded into it.  The two talk both ways:
;;;;
;;;;   cl-agent -> Emacs   emacsclient --eval (EMACS-CALL); cl-agent.el's
;;;;                       functions answer with JSON strings
;;;;   Emacs -> cl-agent   events, one per line on the daemon's stderr
;;;;                       (EMACS-EVENT): what each frame shows, the open
;;;;                       files, saves, C-c C-a, the scratch buffer's keys
;;;;
;;;; Lifetime: the daemon is started when a page first shows Emacs, and is a
;;;; child of this process.  It ends with cl-agent either way -- an exit hook
;;;; stops it (SIGTERM: Emacs auto-saves), and if cl-agent dies without
;;;; running it (SIGKILL, a crash), cl-agent.el's watchdog sees Emacs's
;;;; parent change and exits within a second or two.  If Emacs ends first
;;;; (a crash, M-x kill-emacs), its frames close, the page says so, and the
;;;; next use starts it again.
;;;;
;;;;   GET  /api/emacs               its state: stopped, starting, running, failed
;;;;   POST /api/emacs/frame         {role, rows, cols, cellWidth, cellHeight}: a
;;;;                                 terminal showing ROLE's frame, started if need be
;;;;   POST /api/emacs/visit         {path, line}: show a file in the Code tab's frame
;;;;   GET  /api/emacs/buffers       the files open in Emacs
;;;;   POST /api/emacs/mx            {command}: M-x in the Code tab's frame
;;;;   POST /api/emacs/background    {mode}: light or dark, as the page
;;;;   POST /api/emacs/editor        {editor}: which editor the Code tab shows
;;;;   POST /api/emacs/lisp-scratch  show the scratch buffer in the Lisp tab's frame
;;;;   POST /api/emacs/stop          stop the daemon

(in-package :cl-agent)

;;; --- finding Emacs ---

(defparameter *emacs-elisp*
  (uiop:read-file-string (asdf:system-relative-pathname :cl-agent "src/emacs/cl-agent.el"))
  "cl-agent.el, as this image was built with it (written out for the daemon to load).")

(defvar *emacs-load-init* t
  "Whether the daemon loads the person's Emacs init file, as Lem loads its own.
Tests run it with -Q instead.")

(defvar *emacs-environment* '()
  "NAME=VALUE strings put first in the daemon's environment (tests: HOME).")

(defparameter *emacs-places* '("/opt/homebrew/bin" "/usr/local/bin" "/usr/bin" "/opt/local/bin"
                               "/Applications/Emacs.app/Contents/MacOS")
  "Where Emacs is looked for after $PATH: a program started from the Dock has
a short PATH.")

(defun find-program (name &optional (variable nil))
  "NAME's executable: $VARIABLE when set, else the first on $PATH or in *EMACS-PLACES*."
  (let ((given (and variable (uiop:getenv variable))))
    (if (and given (plusp (length given)))
        given
        (let ((found (or (find-executable-on-path name)
                         (some (lambda (directory) (probe-file (format nil "~a/~a" directory name))) *emacs-places*))))
          (and found (uiop:native-namestring found))))))

(defun emacs-program () (find-program "emacs" "CL_AGENT_EMACS"))

(defun emacsclient-program ()
  (or (let ((given (uiop:getenv "CL_AGENT_EMACSCLIENT"))) (and given (plusp (length given)) given))
      ;; Beside the Emacs in use, so the two are one version.
      (let* ((emacs (emacs-program))
             (sibling (and emacs (probe-file (merge-pathnames "emacsclient" (uiop:pathname-directory-pathname emacs))))))
        (and sibling (uiop:native-namestring sibling)))
      (find-program "emacsclient")))

;;; --- the daemon ---

(defvar *emacs-lock* (bt:make-recursive-lock "emacs"))
(defvar *emacs-process* nil)
(defvar *emacs-name* nil "The daemon's server name: emacsclient -s NAME.")
(defvar *emacs-state* :stopped "One of :stopped, :starting, :running, :failed.")
(defvar *emacs-problem* nil "Why it failed or stopped, for the page.")
(defvar *emacs-version* nil)
(defvar *emacs-log* '() "Its stderr lines that were not events, newest first (the last 40).")
(defvar *emacs-shown* (make-hash-table :test 'equal) "Role -> what that frame last showed (JSON).")
(defvar *emacs-buffers* '() "The file buffers Emacs last reported (JSON objects).")
(defvar *emacs-frames* (make-hash-table :test 'equal) "Role -> the terminal showing that frame.")
(defvar *emacs-background* nil "The page's light or dark, to give a new frame.")
(defvar *code-editor* "lem" "The Code tab's editor, as a page last chose it: lem, simple or emacs.")

(defparameter *emacs-event-marker* (format nil "~acl-agent " (code-char 31)))

(defun emacs-forget ()
  ;; A restarted image has no daemon.
  (setf *emacs-process* nil *emacs-name* nil *emacs-state* :stopped *emacs-problem* nil *emacs-log* '()
        *emacs-buffers* '())
  (clrhash *emacs-shown*)
  (clrhash *emacs-frames*))

(pushnew 'emacs-forget sb-ext:*init-hooks*)

(defun emacs-is-the-editor-p ()
  "Whether the Code tab's editor is Emacs, and it runs."
  (and (equal *code-editor* "emacs") (emacs-running-p)))

(defun emacs-open-buffers ()
  "The file buffers open in Emacs (JSON objects), when it runs."
  (and (emacs-running-p) *emacs-buffers*))

(defun emacs-running-p ()
  (and (eq *emacs-state* :running) *emacs-process* (sb-ext:process-alive-p *emacs-process*) t))

(defun emacs-elisp-file ()
  (let ((path (merge-pathnames "emacs/cl-agent.el" *config-directory*)))
    (ensure-directories-exist path)
    (unless (and (probe-file path) (string= (uiop:read-file-string path) *emacs-elisp*))
      (write-string-atomically path *emacs-elisp*))
    (uiop:native-namestring path)))

(defun emacs-daemon-environment ()
  (let* ((own (mapcar (lambda (entry) (subseq entry 0 (or (position #\= entry) (length entry)))) *emacs-environment*))
         (base (sb-ext:posix-environ))
         ;; A UTF-8 locale unless one is set (cl-agent started from the Dock
         ;; has none): file names and text keep their characters.
         (locale (unless (some (lambda (entry) (some (lambda (name) (uiop:string-prefix-p name entry))
                                                     '("LANG=" "LC_ALL=" "LC_CTYPE=")))
                               base)
                   (list "LANG=en_US.UTF-8"))))
    (append *emacs-environment* locale
            (remove-if (lambda (entry)
                         (let ((name (subseq entry 0 (or (position #\= entry) (length entry)))))
                           ;; A frame's role is its client's, never the daemon's.
                           (or (member name own :test #'string=) (string= name "CL_AGENT_FRAME"))))
                       base))))

(defun emacs-start (&key (timeout 60))
  "Start the daemon unless it runs; wait until it is ready."
  (bt:with-recursive-lock-held (*emacs-lock*)
    (unless (emacs-running-p)
      (let ((program (or (emacs-program)
                         (error "Emacs is not installed: brew install emacs (or your system's package), or set CL_AGENT_EMACS.")))
            (name (format nil "cl-agent-~d-~36r" (sb-posix:getpid) (random (expt 36 4))))
            (elisp (emacs-elisp-file)))
        (unless (emacsclient-program) (error "emacsclient was not found beside ~a." program))
        (setf *emacs-state* :starting *emacs-problem* nil *emacs-name* name *emacs-log* '() *emacs-buffers* '())
        (clrhash *emacs-shown*)
        (clrhash *emacs-frames*)
        (let ((process (sb-ext:run-program
                        program
                        (append (list (format nil "--fg-daemon=~a" name))
                                (unless *emacs-load-init* (list "-Q"))
                                (list "--eval" (format nil "(setq cl-agent-parent-pid ~d)" (sb-posix:getpid))
                                      "-l" elisp "-f" "cl-agent-start"))
                        :wait nil :input nil :output nil :error :stream :external-format :utf-8
                        :environment (emacs-daemon-environment))))
          (setf *emacs-process* process)
          (as-agent-itself
            (bt:make-thread (lambda () (emacs-read-events process)) :name "emacs events"))
          (publish-emacs-state)
          (loop with deadline = (+ (get-internal-real-time) (* timeout internal-time-units-per-second))
                while (and (eq *emacs-state* :starting) (< (get-internal-real-time) deadline))
                do (sleep 0.02))
          (case *emacs-state*
            (:running (when *emacs-background* (ignore-errors (emacs-call "cl-agent-background" *emacs-background*))))
            (:starting (emacs-stop)
             (setf *emacs-state* :failed
                   *emacs-problem* (format nil "Emacs did not start within ~d seconds~@[: ~a~]." timeout (emacs-log-tail)))
             (publish-emacs-state)))
          (unless (eq *emacs-state* :running)
            (error "~a" (or *emacs-problem* "Emacs did not start."))))))
    t))

(defun emacs-log-tail (&optional (lines 6))
  (let ((tail (reverse (subseq *emacs-log* 0 (min lines (length *emacs-log*))))))
    (and tail (format nil "~{~a~^ / ~}" tail))))

(defun emacs-read-events (process)
  "The body of the events thread: PROCESS's stderr, line by line, until it ends."
  (let ((stream (sb-ext:process-error process)))
    (handler-case
        (loop for line = (read-line stream nil)
              while line
              do (let ((at (search *emacs-event-marker* line)))
                   (if at
                       (let ((event (ignore-errors (json-decode (subseq line (+ at (length *emacs-event-marker*)))))))
                         (when (hash-table-p event)
                           (handler-case (emacs-event event)
                             (error (condition)
                               (push (format nil "cl-agent: event ~a failed: ~a" (jget event "type") condition) *emacs-log*)))))
                       (progn (push line *emacs-log*)
                              (when (> (length *emacs-log*) 40) (setf *emacs-log* (subseq *emacs-log* 0 40)))))))
      (error () nil))
    (ignore-errors (sb-ext:process-wait process))
    (emacs-exited process)))

(defun emacs-exited (process)
  (bt:with-recursive-lock-held (*emacs-lock*)
    (when (eq process *emacs-process*)
      (let ((status (sb-ext:process-exit-code process)))
        (setf *emacs-problem*
              (if (eq *emacs-state* :starting)
                  (format nil "Emacs exited while starting (status ~a)~@[: ~a~]." status (emacs-log-tail))
                  (format nil "Emacs exited (status ~a)." status))
              *emacs-state* (if (eq *emacs-state* :starting) :failed :stopped)
              *emacs-process* nil
              *emacs-buffers* '())
        (clrhash *emacs-shown*))))
  (publish-emacs-state))

(defun emacs-stop (&key (timeout 3))
  "Stop the daemon: SIGTERM, which Emacs takes as kill-emacs (auto-saving),
then SIGKILL if it lingers.  Its frames end with it."
  (let ((process (bt:with-recursive-lock-held (*emacs-lock*) *emacs-process*)))
    (when (and process (sb-ext:process-alive-p process))
      (ignore-errors (sb-ext:process-kill process 15))
      (loop with deadline = (+ (get-internal-real-time) (* timeout internal-time-units-per-second))
            while (and (sb-ext:process-alive-p process) (< (get-internal-real-time) deadline))
            do (sleep 0.02))
      (when (sb-ext:process-alive-p process)
        (ignore-errors (sb-ext:process-kill process 9))
        (ignore-errors (sb-ext:process-wait process))))
    (bt:with-recursive-lock-held (*emacs-lock*)
      (when (eq process *emacs-process*)
        (setf *emacs-process* nil *emacs-state* :stopped *emacs-problem* nil)))
    t))

;; cl-agent's own exit stops it; cl-agent.el's watchdog covers an exit that
;; runs no hooks.
(pushnew 'emacs-stop sb-ext:*exit-hooks*)

(defun publish-emacs-state ()
  (ignore-errors (editor-publish "emacs-state" (emacs-state-json))))

(defun emacs-state-json ()
  (jobj "state" (string-downcase *emacs-state*)
        "available" (and (emacs-program) t)
        "version" (json-or-null *emacs-version*)
        "problem" (json-or-null *emacs-problem*)
        "frames" (jarray (loop for role being the hash-keys of *emacs-frames* using (hash-value terminal)
                               when (terminal-running-p terminal) collect role))))

;;; --- talking to it ---

(defun elisp-string (string)
  "STRING as an Emacs Lisp string literal, in ASCII: characters beyond it as
\\uXXXX or \\U00XXXXXX, which Emacs reads the same in any locale."
  (with-output-to-string (out)
    (write-char #\" out)
    (loop for char across string
          for code = (char-code char)
          do (cond ((member char '(#\" #\\)) (write-char #\\ out) (write-char char out))
                   ((< code 128) (write-char char out))
                   ((< code #x10000) (format out "\\u~4,'0x" code))
                   (t (format out "\\U~8,'0x" code))))
    (write-char #\" out)))

(defun elisp-literal (value)
  (typecase value
    (string (elisp-string value))
    (integer (princ-to-string value))
    (null "nil")
    ((eql t) "t")
    (t (error "No Emacs Lisp literal for ~s." value))))

(defun emacs-eval (form &key (timeout 15))
  "Evaluate FORM (Emacs Lisp source) in the daemon; its value, read back
(strings, numbers, t and nil)."
  (unless (emacs-running-p) (error "Emacs is not running."))
  (multiple-value-bind (output error-output status)
      (uiop:run-program (list (emacsclient-program) "-s" *emacs-name* (format nil "--timeout=~d" timeout) "--eval" form)
                        :output :string :error-output :string :ignore-error-status t
                        :external-format :utf-8)
    (unless (zerop status)
      (error "Emacs: ~a" (string-trim '(#\Space #\Newline)
                                      (cl-ppcre:regex-replace-all "\\*ERROR\\*: ?" error-output ""))))
    (let ((*read-eval* nil))
      (values (ignore-errors (read-from-string output nil nil))))))

(defun emacs-call (function &rest arguments)
  "Call cl-agent.el's FUNCTION (a name) with ARGUMENTS (strings, integers, t, nil)."
  (emacs-eval (format nil "(~a~{ ~a~})" function (mapcar #'elisp-literal arguments))))

(defun emacs-call-json (function &rest arguments)
  "EMACS-CALL, for a function answering with JSON: its value decoded."
  (let ((result (apply #'emacs-call function arguments)))
    (and (stringp result) (let ((value (json-decode result))) (if (eq value :null) nil value)))))

(defun emacs-message (format &rest arguments)
  "Say something in Emacs's echo area."
  (ignore-errors (emacs-eval (format nil "(message \"%s\" ~a)" (elisp-string (apply #'format nil format arguments))) :timeout 3)))

;;; --- what Emacs tells us ---

(defun emacs-event (event)
  (let ((type (jget event "type")))
    (cond
      ((equal type "ready")
       (setf *emacs-version* (jget event "version")
             *emacs-state* :running)
       (publish-emacs-state))
      ((equal type "shown")
       (setf (gethash (jget event "role") *emacs-shown*) event)
       (editor-publish "emacs-buffer" event))
      ((equal type "buffers")
       (setf *emacs-buffers* (let ((buffers (jget event "buffers"))) (if (listp buffers) buffers '())))
       (editor-publish "emacs-buffers" (jobj "buffers" (jarray *emacs-buffers*))))
      ((equal type "saved")
       ;; As any write outside cl-agent: Lem's copy reads it again, and the rest hear of it.
       (run-hook :file-written (jget event "path") "emacs"))
      ((equal type "ask")
       (web-ui-command "insert" (jobj "text" (jget event "text"))))
      ((equal type "eval")
       (handler-case (lisp-repl-start (jget event "text") :source "emacs" :mode (or (jget event "mode") "eval"))
         (lisp-repl-busy () (emacs-message "The Lisp tab's REPL is busy: wait, or interrupt it there."))
         (error (condition) (emacs-message "~a" condition))))
      ((equal type "scratch-saved")
       ;; Emacs wrote the scratch file itself: cl-agent reads it again.
       (multiple-value-bind (text version) (lisp-scratch-contents)
         (lisp-repl-publish "lisp-scratch" (jobj "version" version "text" text "by" "emacs" "client" :null)))))))

(defun emacs-note-file-written (path &optional by)
  "A file was written outside Emacs: its buffer, without unsaved edits, reads it again."
  (when (and (emacs-running-p) (not (equal by "emacs")))
    (ignore-errors (emacs-call "cl-agent-file-written" (uiop:native-namestring path)))))

(add-hook :file-written 'refresh-emacs-buffers #'emacs-note-file-written)

;;; --- frames ---

(defun emacs-client-script (role)
  "An executable that runs ROLE's frame: slt starts a terminal's program with -i,
which this ignores."
  (let ((path (merge-pathnames (format nil "emacs/client-~a" role) *config-directory*)))
    (ensure-directories-exist path)
    (write-string-atomically
     path (format nil "#!/bin/sh~%# The ~a frame of cl-agent's Emacs (emacs.lisp).~%CL_AGENT_FRAME=~a exec ~a -t -s ~a~%"
                  role (shell-quote role) (shell-quote (emacsclient-program)) (shell-quote *emacs-name*)))
    (sb-posix:chmod (uiop:native-namestring path) #o755)
    (uiop:native-namestring path)))

(defun emacs-frame (role &key size (timeout 10))
  "The terminal showing ROLE's frame (emacsclient -t), started -- and the daemon
with it -- if need be."
  (unless (member role '("code" "lisp") :test #'equal) (error "No Emacs frame is called ~s." role))
  (emacs-start)
  (bt:with-recursive-lock-held (*emacs-lock*)
    (let ((terminal (gethash role *emacs-frames*)))
      (if (and terminal (terminal-running-p terminal))
          terminal
          (progn
            (remhash role *emacs-shown*)
            (let ((terminal (start-terminal (uiop:native-namestring (current-directory))
                                            :size size :kind :editor :program (emacs-client-script role))))
              (setf (gethash role *emacs-frames*) terminal)
              ;; Until Emacs reports the frame, a visit would not land in it.
              (loop with deadline = (+ (get-internal-real-time) (* timeout internal-time-units-per-second))
                    until (or (gethash role *emacs-shown*) (>= (get-internal-real-time) deadline)
                              (not (terminal-running-p terminal)))
                    do (sleep 0.02))
              (publish-emacs-state)
              terminal))))))

(defun emacs-frame-exited (terminal)
  (when (eq (terminal-kind terminal) :editor)
    (bt:with-recursive-lock-held (*emacs-lock*)
      (loop for role being the hash-keys of *emacs-frames* using (hash-value frame)
            when (eq frame terminal) do (remhash role *emacs-frames*) (remhash role *emacs-shown*)))
    (forget-terminal terminal)
    (publish-emacs-state)))

(pushnew 'emacs-frame-exited *terminal-exit-functions*)

(defun emacs-frame-json (role terminal)
  (jobj "role" role "id" (terminal-id terminal)
        "url" (terminal-socket-url terminal)
        "shown" (or (gethash role *emacs-shown*) :null)
        "state" (string-downcase *emacs-state*)))

;;; --- what the page and the agent ask of it ---

(defun emacs-visit (path &key line (role "code"))
  "Show PATH in ROLE's frame, at LINE."
  (let ((full (expand-user-path path)))
    (emacs-start)
    (prog1 (emacs-call-json "cl-agent-visit" role full line)
      (run-hook :file-opened full))))

(defun emacs-type (role keys)
  "Type KEYS into ROLE's frame, as the person would."
  (let ((terminal (gethash role *emacs-frames*)))
    (unless (and terminal (terminal-running-p terminal))
      (error "Emacs's ~a frame is not open." role))
    (terminal-send terminal keys)))

(defun emacs-mx (command)
  "M-x COMMAND in the Code tab's frame; with no COMMAND, M-x waits for one there."
  (emacs-type "code" (format nil "~cx~@[~a~c~]" (code-char 27) (and command (plusp (length command)) command)
                             (code-char 13))))

(defun emacs-command-names (prefix &key (limit 60))
  "(name . first line of its documentation) for Emacs's commands starting with
PREFIX (else containing it)."
  (mapcar (lambda (pair) (cons (first pair) (second pair)))
          (emacs-call-json "cl-agent-commands" prefix limit)))

(defun emacs-file-buffer (path)
  "PATH's Emacs buffer with its text (a JSON object), or NIL if it is not open there."
  (and (emacs-running-p) (emacs-call-json "cl-agent-buffer-text" (expand-user-path path))))

(defun run-emacs-command (command &key keys path answers line column end-line end-column argument save)
  "Run Emacs's COMMAND (or KEYS) on PATH's buffer (else the Code tab's), its
prompts answered from ANSWERS.  A plist like RUN-LEM-COMMAND's."
  (emacs-start)
  (let* ((spec (jobj "path" (if path (expand-user-path path) :null)
                     "command" (or command :null) "keys" (or keys :null)
                     "answers" (jarray answers)
                     "line" (or line :null) "column" (or column :null)
                     "end_line" (or end-line :null) "end_column" (or end-column :null)
                     "argument" (or argument :null) "save" (if save t :null)))
         (result (emacs-call-json "cl-agent-run-command" (json-encode spec)))
         (before (jget result "before")) (after (jget result "after")))
    (list :buffer (jget result "buffer") :path (json-null-to-nil (jget result "path"))
          :error (json-null-to-nil (jget result "error"))
          :changes (changed-lines before after)
          :changed (string/= before after)
          :asked (jget result "asked") :unused (jget result "unused") :messages (jget result "messages")
          :point (jget result "point") :modified (jget result "modified") :saved (jget result "saved"))))

(defun json-null-to-nil (value) (if (eq value :null) nil value))

(define-tool emacs-command (args)
    (:description "Run one of Emacs's commands -- as M-x in Emacs would -- on a file's buffer in the Emacs the user edits in (the Code tab's Emacs editor), with the user's own Emacs configuration: query-replace, indent-region, comment-region, upcase-region, sort-lines, whatever their packages add. Use it instead of lem-command when the user edits in Emacs: their unsaved edits are in Emacs's buffers. Give line/column to place point, and end_line/end_column to select a region. A command's prompts are answered from answers, in order (query-replace: [\"old\", \"new\", \"!\"]; \"y\"/\"n\" per match); a prompt with no answer left stops the command and says what it asked. Instead of command, keys runs a key sequence (\"C-x h TAB\"). The result shows the lines that changed and Emacs's messages; changes stay unsaved unless save is true. action=\"search\" lists commands whose names start with (or contain) query."
     :effects '(:write-workspace)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "action" (jobj "type" "string" "enum" (list "run" "search"))
                 "command" (jobj "type" "string" "description" "Command name, as M-x takes it.")
                 "keys" (jobj "type" "string" "description" "A key sequence instead of command, in Emacs's kbd notation.")
                 "path" (jobj "type" "string" "description" "The file; omitted, the buffer the Code tab's Emacs shows.")
                 "answers" (jobj "type" "array" "items" (jobj "type" "string"))
                 "line" (jobj "type" "integer" "minimum" 1)
                 "column" (jobj "type" "integer" "minimum" 1)
                 "end_line" (jobj "type" "integer" "minimum" 1)
                 "end_column" (jobj "type" "integer" "minimum" 1)
                 "argument" (jobj "type" "integer" "description" "The prefix argument (C-u N).")
                 "save" (jobj "type" "boolean")
                 "query" (jobj "type" "string" "description" "For action=search."))))
  (unless (emacs-running-p)
    (error "The user's Emacs is not running (the Code tab's editor is Lem or the simple editor): use lem-command."))
  (if (equal (jget args "action") "search")
      (let ((names (emacs-command-names (or (jget args "query") "") :limit 60)))
        (format nil "~d command~:p:~%~{~a~^~%~}" (length names)
                (mapcar (lambda (pair) (format nil "~a~@[ -- ~a~]" (car pair) (let ((doc (cdr pair))) (and (plusp (length doc)) doc))))
                        names)))
      (let* ((command (jget args "command")) (keys (jget args "keys"))
             (answers (jget args "answers"))
             (result (run-emacs-command command :keys keys :path (jget args "path")
                                                :answers (if (vectorp answers) (coerce answers 'list) answers)
                                                :line (jget args "line") :column (jget args "column")
                                                :end-line (jget args "end_line") :end-column (jget args "end_column")
                                                :argument (jget args "argument") :save (jget args "save"))))
        (format nil "~:[Ran~;Stopped~] ~a in ~a~@[ (~a)~]~@[: ~a~].~%~a~@[~%Emacs said: ~{~a~^ / ~}~]~@[~%Prompts answered: ~{~s~^, ~}~]~@[~%Answers not used: ~{~s~^, ~}~]~%Point is at line ~d, column ~d; the buffer is ~:[saved~;modified (unsaved)~]."
                (getf result :error) (or command keys) (getf result :buffer) (getf result :path)
                (and (getf result :error) (string-right-trim "." (getf result :error)))
                (getf result :changes)
                (getf result :messages) (getf result :asked) (getf result :unused)
                (first (getf result :point)) (second (getf result :point))
                (getf result :modified)))))

;;; --- routes ---

(defmacro with-emacs-errors (&body body)
  `(handler-case (progn ,@body)
     (error (condition) (web-respond 400 (jobj "error" (princ-to-string condition))))))

(define-web-route emacs-state (:method :get :path "/api/emacs")
  (emacs-state-json))

(define-web-route emacs-frame (:method :post :path "/api/emacs/frame")
  (let ((body (web-json-body)))
    (with-emacs-errors
      (let ((role (or (jget body "role") "code")))
        (emacs-frame-json role (emacs-frame role :size (terminal-size-from body)))))))

(define-web-route emacs-visit (:method :post :path "/api/emacs/visit")
  (let ((body (web-json-body)))
    (with-emacs-errors (emacs-visit (jget body "path") :line (jget body "line")))))

(define-web-route emacs-buffers (:method :get :path "/api/emacs/buffers")
  (jobj "buffers" (jarray (and (emacs-running-p) *emacs-buffers*))))

(define-web-route emacs-mx (:method :post :path "/api/emacs/mx")
  (with-emacs-errors (emacs-mx (jget (web-json-body) "command")) (jobj "typed" t)))

(define-web-route emacs-background (:method :post :path "/api/emacs/background")
  (let ((mode (jget (web-json-body) "mode")))
    (with-emacs-errors
      (unless (member mode '("light" "dark") :test #'equal) (error "Give light or dark."))
      (setf *emacs-background* mode)
      (when (emacs-running-p) (emacs-call "cl-agent-background" mode))
      (jobj "mode" mode))))

(define-web-route emacs-editor (:method :post :path "/api/emacs/editor")
  (let ((editor (jget (web-json-body) "editor")))
    (with-emacs-errors
      (unless (member editor '("lem" "simple" "emacs") :test #'equal) (error "Give lem, simple or emacs."))
      (setf *code-editor* editor)
      (jobj "editor" editor))))

(define-web-route emacs-lisp-scratch (:method :post :path "/api/emacs/lisp-scratch")
  (with-emacs-errors
    (let ((path (lisp-scratch-pathname)))
      (unless (probe-file path)
        (ensure-directories-exist path)
        (write-string-atomically path (lisp-scratch-contents)))
      (emacs-start)
      (emacs-call-json "cl-agent-visit-scratch" "lisp" (uiop:native-namestring path)))))

(define-web-route emacs-stop (:method :post :path "/api/emacs/stop")
  (emacs-stop)
  (emacs-state-json))

;;; --- doctor ---

(defun doctor-emacs-check (config)
  (declare (ignore config))
  (let ((program (emacs-program)))
    (doctor-result "emacs" :ok
                   (if program
                       (format nil "~a~:[; emacsclient not found beside it~;~], for the Code tab's Emacs editor~@[ (running: ~a)~]."
                               program (emacsclient-program) (and (emacs-running-p) *emacs-version*))
                       "Emacs is not installed; the Code tab's editor can be Lem or the simple editor (brew install emacs for Emacs)."))))

(setf *doctor-checks*
      (append (remove "emacs" *doctor-checks* :key #'doctor-check-id :test #'string=)
              (list (make-doctor-check :id "emacs" :description "Emacs (optional editor)" :function #'doctor-emacs-check))))
