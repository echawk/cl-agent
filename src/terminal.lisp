;;;; terminal.lisp -- terminals next to your files: slt, a terminal emulator
;;;; in Common Lisp (third-party/slt, https://github.com/echawk/slt), run in
;;;; this image and shown in the web UI's Terminal tab by slt's own browser
;;;; client (slt-terminal.js, static/terminal.js).  Run programs on your
;;;; files there -- compile a scratch buffer and run it -- and ask the agent
;;;; about what they printed.
;;;;
;;;;   /term [dir]    at the main prompt: a terminal in DIR (the working
;;;;                  directory), in the Terminal tab
;;;;   /shell [file]  save FILE and run it in a terminal in its directory, by
;;;;                  its type (*TERMINAL-RUN-COMMANDS*)
;;;;   Ctrl-Shift-A   in a terminal: its last lines at the main prompt, to ask
;;;;                  about them (the tab's Ask button does the same)
;;;;
;;;; Each terminal is slt's LAUNCH-TERMINAL on a thread of its own, with
;;;; slt's pure-Lisp lispvt engine and slt's web frontend -- but where that
;;;; frontend starts a server per terminal, here every terminal's socket is
;;;; on one server (*TERMINAL-ACCEPTOR*, 127.0.0.1 on a free port), found
;;;; by its random token.  cl-agent's own server serves the client module.
;;;;
;;;; The terminal is the person's: the agent reads it (TERMINAL-OUTPUT) and
;;;; never types into it; its own shell tools keep their policy.
;;;;
;;;;   GET  /api/terminals                    the terminals, with their sockets
;;;;   POST /api/terminal                     open one {directory, new}, or run {file}
;;;;   POST /api/terminal/close               {id}
;;;;   GET  /api/terminal/transcript?id=      its last lines, as a question
;;;;   GET  /api/terminal/slt-terminal.js     slt's browser client

(in-package :cl-agent)

;;; --- the terminals ---

(defstruct (agent-terminal (:conc-name terminal-))
  (id 0 :type fixnum)
  directory
  token
  frontend
  emulator
  thread
  (state :starting)              ; :starting, :running, :exited
  problem                        ; why it could not start
  final-text                     ; the transcript, kept when the shell exits
  (used (get-universal-time))    ; opened, run in or asked about
  (kind :shell)                  ; :shell (the Terminal tab's) or :editor (emacs.lisp's frames)
  program)                       ; what it runs, if not the person's $SHELL

(defvar *terminals* '() "The open terminals, oldest first.")
(defvar *terminal-counter* 0)
(defvar *terminals-lock* (bt:make-recursive-lock "terminals"))
(defvar *terminal-acceptor* nil "The socket server every terminal's client connects to.")
(defvar *terminal-exit-functions* '()
  "Called with a terminal whose program has ended (emacs.lisp: an editor frame).")

(defparameter *terminal-engine* :lispvt
  "slt's engine for cl-agent's terminals: lispvt is pure Lisp, needing no
native build.")

(defun terminals-forget ()
  ;; A restarted image has no terminals and no server.
  (setf *terminals* '() *terminal-acceptor* nil))

(pushnew 'terminals-forget sb-ext:*init-hooks*)

(defun list-terminals (&key (kind :shell))
  "The terminals of KIND (:shell, the Terminal tab's; :editor; or :all)."
  (bt:with-recursive-lock-held (*terminals-lock*)
    (if (eq kind :all)
        (copy-list *terminals*)
        (remove kind *terminals* :key #'terminal-kind :test-not #'eq))))

(defun find-terminal (id)
  "The terminal ID (an integer or its digits), or with ID NIL the one most
recently opened, run in or asked about."
  (let ((terminals (list-terminals)))
    (if id
        (let ((id (if (stringp id) (parse-integer id :junk-allowed t) id)))
          (find id terminals :key #'terminal-id))
        (first (sort terminals #'> :key #'terminal-used)))))

(defun require-terminal (id)
  (or (find-terminal id)
      (error (if id "No terminal ~a." "No terminal is open: /term opens one.") id)))

(defun terminal-running-p (terminal)
  (eq (terminal-state terminal) :running))

(defun terminal-title (terminal)
  (let* ((frontend (terminal-frontend terminal))
         (view (and frontend (slt::headless-frontend-view frontend))))
    (or (and view (let ((title (slt:headless-view-title view)))
                    (and (plusp (length title)) title)))
        (format nil "Terminal ~d" (terminal-id terminal)))))

;;; --- slt's web frontend, on one shared socket server ---

(defclass agent-terminal-frontend (slt::web-frontend)
  ((terminal :initarg :terminal :reader frontend-terminal))
  (:documentation "slt's web frontend without a server of its own: its
clients reach it through *TERMINAL-ACCEPTOR*."))

(defmethod slt::frontend-call-with-event-loop ((frontend agent-terminal-frontend) thunk)
  (setf (slt::web-frontend-resource frontend) (make-instance 'slt::web-resource :frontend frontend))
  ;; The headless frontend's loop; slt's web frontend would wrap it in a
  ;; server of its own.
  (funcall thunk)
  (loop until (slt::headless-frontend-quit-p frontend)
        do (dolist (function (slt::take-headless-inbox frontend (min 0.25 (slt::headless-timeout frontend))))
             (funcall function))
           (slt::run-headless-timers frontend)))

(defclass terminal-socket-acceptor (hunchensocket:websocket-acceptor) ()
  (:documentation "Serves terminal sockets only (/ws?token=...)."))

(defmethod hunchentoot:acceptor-dispatch-request ((acceptor terminal-socket-acceptor) request)
  (if (string-equal "websocket" (or (hunchentoot:header-in :upgrade request) ""))
      (call-next-method)
      (progn (setf (hunchentoot:return-code*) hunchentoot:+http-not-found+)
             "not found")))

(defun local-origin-p (origin)
  "Whether ORIGIN, a request's Origin header, is a page on this machine (or none)."
  (or (null origin)
      (and (cl-ppcre:scan "^https?://(127\\.0\\.0\\.1|localhost|\\[::1\\])(:\\d+)?$" origin) t)))

(defun terminal-socket-dispatch (request)
  "hunchensocket's dispatcher: the socket of the terminal whose token REQUEST
carries, on the terminal server, from a local page."
  (and (eq hunchentoot:*acceptor* *terminal-acceptor*)
       (string= (hunchentoot:script-name request) "/ws")
       (local-origin-p (hunchentoot:header-in :origin request))
       (let* ((token (hunchentoot:get-parameter "token" request))
              (terminal (and token (find token (list-terminals :kind :all) :key #'terminal-token :test #'equal))))
         (and terminal (terminal-running-p terminal)
              (slt::web-frontend-resource (terminal-frontend terminal))))))

(defparameter *terminal-library-prefixes* '("/opt/homebrew" "/usr/local" "/opt/local")
  "Where slt's image libraries -- libpng for Kitty's PNG images, libsixel
for SIXEL -- are looked for besides the system's own places (Homebrew and
MacPorts).  slt itself bundles them beside its executable; in cl-agent the
system's are used.")

(defun add-terminal-library-directories ()
  "Let CFFI find slt's image libraries, which it loads by name on first use."
  (dolist (prefix (reverse (remove nil (cons (uiop:getenv "CL_AGENT_LIBRARY_PREFIX") *terminal-library-prefixes*))))
    (let ((directory (probe-file (format nil "~a/lib/" prefix))))
      (when directory
        (pushnew directory cffi:*foreign-library-directories* :test #'uiop:pathname-equal)))))

(defun ensure-terminal-server ()
  (bt:with-recursive-lock-held (*terminals-lock*)
    (or *terminal-acceptor*
        (as-agent-itself
          (add-terminal-library-directories)
          (let ((acceptor (make-instance 'terminal-socket-acceptor
                                         :address "127.0.0.1" :port (free-local-port)
                                         ;; A browser leaving drops its socket: no news.
                                         :access-log-destination nil :message-log-destination nil)))
            (pushnew 'terminal-socket-dispatch hunchensocket:*websocket-dispatch-table*)
            (hunchentoot:start acceptor)
            (setf *terminal-acceptor* acceptor))))))

(defun terminal-socket-url (terminal)
  (format nil "ws://127.0.0.1:~d/ws?token=~a"
          (hunchentoot:acceptor-port *terminal-acceptor*) (terminal-token terminal)))

;;; slt calls these on each terminal's own thread.

(defun emulator-agent-terminal (emulator)
  (let ((frontend (slt::terminal-emulator-frontend emulator)))
    (and (typep frontend 'agent-terminal-frontend) (frontend-terminal frontend))))

(defun note-terminal-started (emulator)
  (alexandria:when-let ((terminal (emulator-agent-terminal emulator)))
    (setf (terminal-emulator terminal) emulator
          (terminal-state terminal) :running)))

(defun note-terminal-exiting (emulator)
  ;; Its screen and history go with the engine: keep them to read and ask about.
  (alexandria:when-let ((terminal (emulator-agent-terminal emulator)))
    (setf (terminal-final-text terminal) (ignore-errors (emulator-transcript emulator)))))

(slt:add-hook 'slt:*after-init-hook* 'note-terminal-started)
(slt:add-hook 'slt:*exit-hook* 'note-terminal-exiting)

;;; --- opening one ---

(defun publish-terminals ()
  (editor-publish "terminals" (jobj "terminals" (jarray (mapcar #'terminal-json (list-terminals))))))

(defun terminal-json (terminal)
  (jobj "id" (terminal-id terminal)
        "title" (terminal-title terminal)
        "directory" (abbreviate-home (terminal-directory terminal))
        "state" (string-downcase (terminal-state terminal))
        "url" (if (and *terminal-acceptor* (terminal-running-p terminal)) (terminal-socket-url terminal) :null)
        "problem" (json-or-null (terminal-problem terminal))))

(defun run-terminal (terminal &key size)
  "The body of TERMINAL's thread: slt's terminal, until its shell exits or
it is closed."
  (unwind-protect
       (handler-case
           (apply #'slt:launch-terminal
                  :frontend (terminal-frontend terminal)
                                :engine *terminal-engine*
                                :rows (getf size :rows 24)
                                :columns (getf size :columns 80)
                                :directory (terminal-directory terminal)
                                :login-shell nil
                                :load-config nil
                                :title ""
                                ;; slt runs it as PROGRAM -i: an executable that ignores its arguments.
                                (and (terminal-program terminal) (list :shell (terminal-program terminal))))
         (error (condition)
           (setf (terminal-problem terminal) (princ-to-string condition))))
    (setf (terminal-state terminal) :exited)
    (ignore-errors (publish-terminals))
    (dolist (function *terminal-exit-functions*)
      (ignore-errors (funcall function terminal)))))

(defun terminal-directory-for (directory)
  "DIRECTORY (relative to the working directory), or the working directory,
as an existing directory's native namestring."
  (let ((directory (uiop:native-namestring
                    (uiop:ensure-directory-pathname
                     (if (and (stringp directory) (plusp (length (string-trim " " directory))))
                         (expand-user-path directory)
                         (current-directory))))))
    (unless (uiop:directory-exists-p directory)
      (error "No such directory: ~a" directory))
    directory))

(defun same-directory-p (a b)
  "Whether directories A and B are one (by truename: /var is /private/var)."
  (let ((a (and a (probe-file a))) (b (and b (probe-file b))))
    (and a b (uiop:pathname-equal a b))))

(defun open-terminal (&key directory new size)
  "A running terminal in DIRECTORY (the working directory): the one already
there unless NEW, else a new one of SIZE when given (TERMINAL-SIZE-FROM:
the page's, so what runs first is not wrapped at 80 columns).  Its shell is
the person's ($SHELL)."
  (let ((directory (terminal-directory-for directory)))
    (or (and (not new)
             (find-if (lambda (terminal)
                        (and (terminal-running-p terminal)
                             (same-directory-p (terminal-directory terminal) directory)))
                      (list-terminals)))
        (start-terminal directory :size size))))

(defun terminal-size-from (body)
  "A new terminal's size from a request's BODY, as the page measured it: a
plist of :ROWS and :COLUMNS, and :CELL-WIDTH and :CELL-HEIGHT in pixels.
slt's client sends its own once it connects; until then, what a program
prints is laid out in these (slt assumes 8x16 cells otherwise)."
  (flet ((sane (key low high)
           (let ((value (jget body key)))
             (and (integerp value) (< low value high) value))))
    (let ((rows (sane "rows" 1 1000)) (columns (sane "cols" 1 1000))
          (cell-width (sane "cellWidth" 2 200)) (cell-height (sane "cellHeight" 2 400)))
      (append (and rows columns (list :rows rows :columns columns))
              (and cell-width cell-height (list :cell-width cell-width :cell-height cell-height))))))

(defun start-terminal (directory &key size (timeout 10) (kind :shell) program)
  (ensure-terminal-server)
  (let* ((terminal (bt:with-recursive-lock-held (*terminals-lock*)
                     (let ((terminal (make-agent-terminal :id (incf *terminal-counter*)
                                                          :directory directory
                                                          :token (slt::random-token)
                                                          :kind kind :program program)))
                       (setf *terminals* (append *terminals* (list terminal)))
                       terminal))))
    (setf (terminal-frontend terminal)
          (make-instance 'agent-terminal-frontend :terminal terminal :token (terminal-token terminal)
                                                   :cell-width (getf size :cell-width 8)
                                                   :cell-height (getf size :cell-height 16)))
    (setf (terminal-thread terminal)
          (as-agent-itself
            (bt:make-thread (lambda () (run-terminal terminal :size size))
                            :name (format nil "terminal ~d" (terminal-id terminal)))))
    (loop with deadline = (+ (get-internal-real-time) (* timeout internal-time-units-per-second))
          while (and (eq (terminal-state terminal) :starting)
                     (< (get-internal-real-time) deadline))
          do (sleep 0.01))
    (unless (terminal-running-p terminal)
      (forget-terminal terminal)
      (error "The terminal did not start~@[: ~a~]." (terminal-problem terminal)))
    (publish-terminals)
    terminal))

(defun forget-terminal (terminal)
  (bt:with-recursive-lock-held (*terminals-lock*)
    (setf *terminals* (remove terminal *terminals*))))

(defun reap-terminal-shell (process)
  "Collect PROCESS's exit off this thread.  slt sends a closed terminal's
shell SIGTERM, which an interactive shell ignores; closing the pty hangs it
up, and then it is reaped here -- standalone slt quits, cl-agent lives on."
  (when process
    (as-agent-itself
      (bt:make-thread (lambda ()
                        (loop repeat 100
                              while (ignore-errors (slt::process-alive-p process))
                              do (sleep 0.05)))
                      :name "terminal reaper"))))

(defun close-terminal (terminal &key (timeout 5))
  "Close TERMINAL: its shell is hung up and reaped, and it leaves the list."
  (when (terminal-running-p terminal)
    (let ((view (slt::headless-frontend-view (terminal-frontend terminal)))
          (process (slt::terminal-emulator-process (terminal-emulator terminal))))
      (when view (slt:headless-close view))
      (let ((thread (terminal-thread terminal)))
        (loop with deadline = (+ (get-internal-real-time) (* timeout internal-time-units-per-second))
              while (and thread (bt:thread-alive-p thread) (< (get-internal-real-time) deadline))
              do (sleep 0.01)))
      (reap-terminal-shell process)))
  (forget-terminal terminal)
  (publish-terminals))

(defun terminal-call (terminal function &key (timeout 5))
  "FUNCTION's value, called on TERMINAL's own thread (slt's UI thread), or
NIL after TIMEOUT seconds."
  (let ((lock (bt:make-lock)) (done nil) (value nil))
    (slt:headless-call (terminal-frontend terminal)
                       (lambda ()
                         (let ((result (ignore-errors (funcall function))))
                           (bt:with-lock-held (lock) (setf value result done t)))))
    (loop with deadline = (+ (get-internal-real-time) (* timeout internal-time-units-per-second))
          until (or (bt:with-lock-held (lock) done) (>= (get-internal-real-time) deadline))
          do (sleep 0.005))
    value))

(defun terminal-send (terminal text)
  "Send TEXT to TERMINAL's program, as typed."
  (unless (terminal-running-p terminal) (error "Terminal ~d has exited." (terminal-id terminal)))
  (slt::send-to-process (terminal-emulator terminal) text))

(defun terminal-type-line (terminal line)
  "Type LINE and Return into TERMINAL (the person's own request)."
  (terminal-send terminal (concatenate 'string line (string #\Return))))

;;; --- running a file ---

(defun shell-quote (string)
  (format nil "'~a'" (cl-ppcre:regex-replace-all "'" string "'\\\\''")))

(defun shell-path (path)
  "PATH quoted for the shell, a path under home as ~/... (shorter to read)."
  (let* ((path (uiop:native-namestring path))
         (home (uiop:native-namestring (user-homedir-pathname))))
    (if (and (> (length path) (length home)) (string= home path :end2 (length home)))
        (format nil "~~/~a" (shell-quote (subseq path (length home))))
        (shell-quote path))))

(defparameter *terminal-run-commands*
  '(("c" . "cc -Wall -g -o {out} {file} && {out}")
    ("cc" . "c++ -Wall -g -o {out} {file} && {out}")
    ("cpp" . "c++ -Wall -g -o {out} {file} && {out}")
    ("rs" . "rustc -o {out} {file} && {out}")
    ("go" . "go run {file}")
    ("py" . "python3 {file}")
    ("rb" . "ruby {file}")
    ("rkt" . "racket {file}")
    ("js" . "node {file}")
    ("lua" . "lua {file}")
    ("pl" . "perl {file}")
    ("hs" . "runghc {file}")
    ("java" . "java {file}")
    ("lisp" . "sbcl --script {file}")
    ("sh" . "sh {file}")
    ("bash" . "bash {file}")
    ("zsh" . "zsh {file}"))
  "How /shell runs a file, by its type: {file} is the file's name (the
terminal is in its directory), {out} a place for a compiled program.")

(defun terminal-programs-directory ()
  (merge-pathnames "terminal/bin/" *config-directory*))

(defun terminal-run-command (path)
  "The command line /shell types for PATH, or an error naming the types it knows."
  (let* ((type (pathname-type path))
         (template (and type (cdr (assoc type *terminal-run-commands* :test #'string-equal)))))
    (unless template
      (error "/shell doesn't know how to run ~:[extension-less~;.~:*~a~] files: it knows ~{.~a~^, ~}."
             type (mapcar #'car *terminal-run-commands*)))
    (let ((out (merge-pathnames (pathname-name path) (terminal-programs-directory))))
      (ensure-directories-exist out)
      (cl-ppcre:regex-replace-all "\\{(file|out)\\}" template
                                  (lambda (match name)
                                    (declare (ignore match))
                                    (if (string= name "file")
                                        (shell-quote (file-namestring path))
                                        (shell-path out)))
                                  :simple-calls t))))

(defun run-file-in-terminal (path &key size)
  "Save PATH's editor buffer, then run it in a terminal in its directory."
  (let* ((path (expand-user-path path))
         (command (terminal-run-command path)))
    (unless (probe-file path) (error "No such file: ~a" path))
    (when (lem-call (lambda () (let ((buffer (editor-find-buffer path))) (and buffer (lem:buffer-modified-p buffer)))))
      (editor-save-file path))
    (let* ((directory (uiop:native-namestring (uiop:pathname-directory-pathname path)))
           (terminal (open-terminal :directory directory :size size)))
      (setf (terminal-used terminal) (get-universal-time))
      ;; A new shell: typed before its prompt, the line would show twice
      ;; (the pty echoes it, then the shell redraws it).
      (loop with deadline = (+ (get-internal-real-time) (* 3 internal-time-units-per-second))
            while (and (string= "" (terminal-transcript terminal :lines 5))
                       (< (get-internal-real-time) deadline))
            do (sleep 0.05))
      (terminal-type-line terminal (format nil "cd ~a && ~a" (shell-path directory) command))
      terminal)))

;;; --- reading it ---

(defun emulator-transcript (emulator &key (lines 500))
  "EMULATOR's last LINES lines, history and screen.  On its UI thread."
  (slt::with-engine (engine emulator)
    (let ((rows (slt::engine-rows engine)))
      (slt::screen-rows-text emulator engine (- rows lines) (1- rows)))))

(defun tidy-transcript (text lines)
  "TEXT's last LINES lines, right-trimmed, trailing blank lines dropped."
  (let ((all (mapcar (lambda (line) (string-right-trim " " line))
                     (uiop:split-string (or text "") :separator '(#\Newline)))))
    (loop while (and all (string= (car (last all)) "")) do (setf all (butlast all)))
    (format nil "~{~a~^~%~}" (last all lines))))

(defun terminal-transcript (terminal &key (lines 100))
  "TERMINAL's last LINES lines of history and screen; for one whose shell
has exited, what it showed then."
  (tidy-transcript
   (if (terminal-running-p terminal)
       (terminal-call terminal (lambda () (emulator-transcript (terminal-emulator terminal) :lines (+ lines 50))))
       (terminal-final-text terminal))
   lines))

(defun terminal-ask-prompt-text (terminal)
  "What asking about TERMINAL puts at the main prompt."
  (format nil "About my terminal in ~a~:[ (its shell has exited)~;~] (its last lines):~%```~%~a~%```~%"
          (abbreviate-home (terminal-directory terminal)) (terminal-running-p terminal)
          (terminal-transcript terminal :lines 60)))

(define-tool terminal-output (args)
    (:description "Read the person's terminal in cl-agent's Terminal tab (they open one with /term and run files with /shell): its scrollback and screen, newest last. Use it when they ask about a command they ran there -- a failing build, a crash, a test's output. Read-only: it never types into their terminal; run commands yourself with your own shell tool."
     :effects '(:read-workspace)
     :parameters (jobj "type" "object"
                       "properties" (jobj "lines" (jobj "type" "integer" "minimum" 1 "maximum" 2000
                                                        "description" "How many of the last lines (default 200).")
                                          "terminal" (jobj "type" "integer" "description" "A terminal's number; omitted, the one used last."))))
  (let* ((terminal (require-terminal (jget args "terminal")))
         (text (terminal-transcript terminal :lines (or (jget args "lines") 200))))
    (format nil "Terminal ~d, in ~a~:[ (its shell has exited)~;~]:~%~a"
            (terminal-id terminal) (terminal-directory terminal) (terminal-running-p terminal)
            (if (string= text "") "(nothing on screen yet)" text))))

;;; --- routes ---

(defmacro with-terminal-errors (&body body)
  `(handler-case (progn ,@body)
     (error (condition) (web-respond 400 (jobj "error" (princ-to-string condition))))))

(define-web-route terminals (:method :get :path "/api/terminals")
  (jobj "terminals" (jarray (mapcar #'terminal-json (list-terminals)))))

(define-web-route terminal-open (:method :post :path "/api/terminal")
  (let ((body (web-json-body)))
    (with-terminal-errors
      (let* ((size (terminal-size-from body))
             (terminal (if (jget body "file")
                           (run-file-in-terminal (jget body "file") :size size)
                           (open-terminal :directory (jget body "directory") :new (jget body "new") :size size))))
        (setf (terminal-used terminal) (get-universal-time))
        (terminal-json terminal)))))

(define-web-route terminal-close (:method :post :path "/api/terminal/close")
  (with-terminal-errors
    (close-terminal (require-terminal (jget (web-json-body) "id")))
    (jobj "closed" t)))

(define-web-route terminal-transcript (:method :get :path "/api/terminal/transcript")
  (with-terminal-errors
    (let ((terminal (require-terminal (web-param "id"))))
      (setf (terminal-used terminal) (get-universal-time))
      (jobj "prompt" (terminal-ask-prompt-text terminal) "id" (terminal-id terminal)))))

(define-web-route terminal-client (:method :get :path "/api/terminal/slt-terminal.js")
  (setf (hunchentoot:content-type*) "text/javascript; charset=utf-8")
  (slt::web-asset "slt-terminal.js"))

;;; --- doctor ---

(defun terminal-image-library-p (library)
  "Whether LIBRARY (\"png16\", \"sixel\") is where ADD-TERMINAL-LIBRARY-DIRECTORIES
looks, or where the system's loader finds it."
  (or (some (lambda (prefix) (directory (format nil "~a/lib/lib~a.*" prefix library)))
            (remove nil (cons (uiop:getenv "CL_AGENT_LIBRARY_PREFIX") *terminal-library-prefixes*)))
      (some (lambda (prefix) (directory (format nil "~a/lib*/**/lib~a.so*" prefix library))) '("/usr" "/lib"))))

(defun doctor-terminal-check (config)
  (declare (ignore config))
  (let ((missing (remove-if #'terminal-image-library-p '("png16" "sixel"))))
    (doctor-result "terminal" (if missing :warning :ok)
                   (format nil "slt ~a, the ~(~a~) engine; shells run as $SHELL (~a).~@[ Images: ~{lib~a~^ and ~} not found, so ~:*~{~/cl-agent::image-library-use/~^ and ~} will not show (brew install libpng libsixel, or your system's packages).~]"
                           (asdf:component-version (asdf:find-system "slt/core"))
                           *terminal-engine* (or (uiop:getenv "SHELL") "/bin/sh") missing))))

(defun image-library-use (stream library &rest arguments)
  (declare (ignore arguments))
  (write-string (if (string= library "png16") "Kitty's PNG images" "SIXEL images") stream))

(setf *doctor-checks*
      (append (remove "terminal" *doctor-checks* :key #'doctor-check-id :test #'string=)
              (list (make-doctor-check :id "terminal" :description "Terminal (slt)" :function #'doctor-terminal-check))))
