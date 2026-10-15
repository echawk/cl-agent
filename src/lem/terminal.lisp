;;;; lem/terminal.lisp -- a terminal next to your files: Lem's own terminal
;;;; (lem-terminal, libvterm) in the Code tab's editor, to run programs on
;;;; your files -- compile a scratch buffer and run it -- and ask the agent
;;;; about what they printed.
;;;;
;;;;   /term [dir]   at the main prompt: a terminal in DIR (the working
;;;;                 directory), below the file Lem shows
;;;;   /run [file]   save FILE (the Code tab's) and run it in the terminal,
;;;;                 by its type (*TERMINAL-RUN-COMMANDS*)
;;;;   C-x C-a       in the terminal: its last lines at the main prompt, to
;;;;                 ask about them (C-c C-a elsewhere; lem/listener.lisp).
;;;;                 C-c is the program's: Ctrl-C interrupts it
;;;;   C-x [         Lem's copy mode: move and mark in the terminal's text
;;;;
;;;; The terminal is the person's: the agent reads it (TERMINAL-OUTPUT) and
;;;; never types into it; its own shell tools keep their policy.
;;;;
;;;; Lem's C shim (extensions/terminal/terminal.c) is compiled here against
;;;; the system's libvterm the first time a terminal opens, into the config
;;;; directory, as tree-sitter's wrapper is (syntax-tree.lisp).  Without
;;;; libvterm the terminal says how to install it.  Two things Lem's
;;;; terminal leaves to its host are done here: a shell that exits ends its
;;;; terminal's reading thread (which would otherwise spin), and killing the
;;;; buffer hangs up the shell and reaps it.
;;;;
;;;;   POST /api/lem/terminal              open one: {directory, new, run}
;;;;   GET  /api/lem/terminal/transcript   its last lines, for "ask about it"

(in-package :cl-agent)

;;; --- the native side ---

(defparameter *terminal-c-patches*
  '(;; The shell starts with no signal blocked or ignored.  It is forked from
    ;; a Lisp thread, whose mask and dispositions it would keep across exec
    ;; -- and then Ctrl-C would not interrupt its programs.
    ("setenv(\"TERM\", \"xterm-256color\", 1);" :after "
    { sigset_t none; sigemptyset(&none); sigprocmask(SIG_SETMASK, &none, NULL);
      for (int s = 1; s < NSIG; s++) if (s != SIGKILL && s != SIGSTOP) signal(s, SIG_DFL); }")
    ;; Text in the default colour takes the page's: libvterm's default is
    ;; light grey, for a dark terminal, and unreadable on a light page.
    ("#include <vterm.h>" :after "
static VTermColor cl_agent_default_fg;
static int cl_agent_default_fg_set = 0;
void cl_agent_terminal_set_default_fg(int red, int green, int blue)
{
  vterm_color_rgb(&cl_agent_default_fg, red, green, blue);
  cl_agent_default_fg_set = 1;
}")
    ("    out[col].ch          = cell.chars[0];" :before "    if (cl_agent_default_fg_set && VTERM_COLOR_IS_DEFAULT_FG(&cell.fg)) cell.fg = cl_agent_default_fg;
    if (VTERM_COLOR_IS_DEFAULT_BG(&cell.bg)) vterm_color_rgb(&cell.bg, 0, 0, 0);  /* black: Lem's \"no background\" */
"))
  "Our changes to Lem's terminal.c: (ANCHOR :before|:after TEXT).")

(defun patch-terminal-c-source (source)
  (loop for (anchor where text) in *terminal-c-patches*
        for at = (search anchor source)
        do (unless at
             (error "Lem's terminal.c has changed: lem/terminal.lisp can't find ~s in it." anchor))
           (let ((split (if (eq where :after) (+ at (length anchor)) at)))
             (setf source (concatenate 'string (subseq source 0 split) text (subseq source split)))))
  source)

(defparameter *terminal-c-source*
  (patch-terminal-c-source
   #.(uiop:read-file-string (asdf:system-relative-pathname :lem-terminal "terminal.c")))
  "Lem's terminal shim, as this image was built with it, with our changes.")

(defparameter *terminal-c-extra*
  "
#include <sys/wait.h>
int cl_agent_terminal_pid(struct terminal *terminal) { return terminal->pid; }
int cl_agent_terminal_fd(struct terminal *terminal) { return terminal->fd; }
"
  "Our addition to the shim: the shell's process and pty, to hang it up.")

(defvar *terminal-ready* nil)
(defvar *terminal-lock* (bt:make-recursive-lock "terminal"))

(defun terminal-forget ()
  ;; A restarted image has none of the libraries it had.
  (setf *terminal-ready* nil))

(pushnew 'terminal-forget sb-ext:*init-hooks*)

(defun libvterm-prefix ()
  "The installation prefix of the system's libvterm, or NIL.
CL_AGENT_LIBVTERM_PREFIX names one."
  (find-if (lambda (prefix)
             (and (probe-file (format nil "~a/include/vterm.h" prefix))
                  (or (probe-file (format nil "~a/lib/libvterm.dylib" prefix))
                      (probe-file (format nil "~a/lib/libvterm.so" prefix))
                      (first (directory (format nil "~a/lib/*/libvterm.so" prefix))))))
           (remove nil (list (uiop:getenv "CL_AGENT_LIBVTERM_PREFIX")
                             "/opt/homebrew" "/usr/local" "/usr" "/opt/local"))))

(defun terminal-directory ()
  (merge-pathnames "terminal/" *config-directory*))

(defun terminal-library-path ()
  (merge-pathnames (format nil "lib/terminal.~a" (if (uiop:os-macosx-p) "dylib" "so")) (terminal-directory)))

(defun build-terminal-library (prefix)
  (let ((source (merge-pathnames "build/terminal.c" (terminal-directory))))
    (ensure-directories-exist source)
    (with-open-file (out source :direction :output :if-exists :supersede)
      (write-string *terminal-c-source* out)
      (write-string *terminal-c-extra* out))
    (compile-shared-library (terminal-library-path) (list source)
                            :includes (list (format nil "~a/include" prefix))
                            :prefix prefix
                            :libraries (if (uiop:os-macosx-p) '("vterm") '("vterm" "util")))))

(defun terminal-library-current-p ()
  "Whether the built library is this image's shim (a newer Lem rebuilds it)."
  (let ((library (probe-file (terminal-library-path)))
        (source (probe-file (merge-pathnames "build/terminal.c" (terminal-directory)))))
    (and library source
         (string= (uiop:read-file-string source)
                  (concatenate 'string *terminal-c-source* *terminal-c-extra*)))))

(defun ensure-terminal ()
  "Load Lem's terminal shim, building it against libvterm if need be."
  (bt:with-recursive-lock-held (*terminal-lock*)
    (unless *terminal-ready*
      (let ((prefix (libvterm-prefix)))
        (unless prefix
          (error "The terminal needs libvterm: brew install libvterm (Debian/Ubuntu: apt install libvterm-dev), then try again."))
        (unless (terminal-library-current-p)
          (build-terminal-library prefix))
        (cffi:load-foreign-library (terminal-library-path))
        (setf *terminal-ready* t)))))

(defun terminal-available-p ()
  (or *terminal-ready* (and (libvterm-prefix) t)))

;;; --- what Lem's terminal leaves to its host ---

(defun terminal-shell (terminal)
  "(values PID FD) of TERMINAL's shell."
  (let ((viscus (lem-terminal/terminal::terminal-viscus terminal)))
    (values (cffi:foreign-funcall "cl_agent_terminal_pid" :pointer viscus :int)
            (cffi:foreign-funcall "cl_agent_terminal_fd" :pointer viscus :int))))

(defun reap-process (pid)
  "Collect PID's exit off the editor thread, so no zombie is left."
  (lem-in-background
   (lambda () (loop repeat 50 until (process-exited-p pid) do (sleep 0.1)))))

(defun terminal-note-exit (terminal)
  "Editor thread: TERMINAL's shell has exited.  Show its last output and say so."
  (let ((buffer (lem-terminal/terminal::terminal-buffer terminal)))
    (unless (lem:deleted-buffer-p buffer)
      (bt2:with-lock-held ((lem-terminal/terminal::terminal-io-lock terminal))
        (lem-terminal/terminal::mark-all-rows-dirty terminal)
        (lem-terminal/terminal::render terminal))
      (lem:with-buffer-read-only buffer nil
        (let ((point (lem:buffer-point buffer)))
          (lem:buffer-end point)
          (lem:skip-whitespace-backward point)
          (lem:delete-between-points point (lem:buffer-end-point buffer))
          (lem:insert-string point (format nil "~%~%[The shell has exited. C-x k closes this buffer.]~%"))))
      (setf (lem:buffer-value buffer 'terminal-exited) t)
      (lem:redraw-display))))

(defvar *exited-terminals* (make-hash-table :test 'eq :weakness :key :synchronized t)
  "Terminals whose shell has exited (and been reaped: its pid is no longer theirs).")

(defun process-exited-p (pid)
  "Whether PID, a child, has exited (and then reap it): waitpid says so,
or that it is no child any more."
  (/= 0 (cffi:foreign-funcall "waitpid" :int pid :pointer (cffi:null-pointer) :int 1 :int))) ; WNOHANG

(defmethod lem-terminal/terminal::process-input :around ((terminal lem-terminal/terminal::terminal) &optional budget-ms)
  (declare (ignore budget-ms))
  (let ((bytes (call-next-method)))
    ;; Nothing read on a wake-up is either a signal (the GC's) or the end
    ;; of the pty: the shell has exited when its process has.  Ending the
    ;; reading thread (DEAD) stops it waking on the closed pty forever.
    (when (and (eql bytes 0)
               (eq (bt2:current-thread) (lem-terminal/terminal::terminal-thread terminal))
               (not (lem-terminal/terminal::terminal-dead terminal))
               (process-exited-p (terminal-shell terminal)))
      (setf (lem-terminal/terminal::terminal-dead terminal) t
            (gethash terminal *exited-terminals*) t)
      (lem:send-event (lambda () (terminal-note-exit terminal))))
    bytes))

(defmethod lem-terminal/terminal:destroy :around ((terminal lem-terminal/terminal::terminal))
  ;; Lem's DESTROY, done here: its reading thread may have ended already
  ;; (the shell exited, or it woke and saw DEAD), which Lem's would fail
  ;; on, and it leaves the shell running.
  (multiple-value-bind (pid fd) (terminal-shell terminal)
    (bt2:with-lock-held ((lem-terminal/terminal::terminal-io-lock terminal))
      (setf (lem-terminal/terminal::terminal-dead terminal) t))
    ;; DEAD is set under the lock: the thread touches the terminal no more.
    (let ((thread (lem-terminal/terminal::terminal-thread terminal)))
      (when (bt2:thread-alive-p thread)
        (ignore-errors (bt2:destroy-thread thread))))
    (alexandria:when-let ((timer (lem-terminal/terminal::terminal-render-timer terminal)))
      (ignore-errors (lem:stop-timer timer)))
    (lem-terminal/terminal::remove-terminal terminal)
    ;; Hang up, as closing a terminal window does: the pty closes and a
    ;; shell still running has SIGHUP.
    (cffi:foreign-funcall "close" :int fd :int)
    (unless (gethash terminal *exited-terminals*)
      (cffi:foreign-funcall "kill" :int pid :int 1 :int)
      (reap-process pid))
    (lem-terminal/ffi::terminal-delete (lem-terminal/terminal::terminal-viscus terminal))))

;;; --- the page's colours ---

(defun terminal-follow-theme ()
  "Editor thread: text in the terminals' default colour takes the theme's
foreground, redrawn now -- and again whenever a theme loads."
  (when *terminal-ready*
    (let ((color (let ((theme (lem:foreground-color)))
                   (if (page-color-p theme)
                       theme
                       (if (eq (lem:display-background-mode) :dark) "#e0e0e0" "#000000")))))
      (cffi:foreign-funcall "cl_agent_terminal_set_default_fg"
                            :int (parse-integer color :start 1 :end 3 :radix 16)
                            :int (parse-integer color :start 3 :end 5 :radix 16)
                            :int (parse-integer color :start 5 :end 7 :radix 16) :void)
      (dolist (terminal lem-terminal/terminal::*terminals*)
        (bt2:with-lock-held ((lem-terminal/terminal::terminal-io-lock terminal))
          (clrhash (lem-terminal/terminal::terminal-attribute-cache terminal))
          (lem-terminal/terminal::mark-all-rows-dirty terminal))
        (lem-terminal/terminal::arm-render-timer terminal)))))

(lem:add-hook lem:*after-load-theme-hook* 'terminal-follow-theme)

;;; --- opening one ---

(defun shell-quote (string)
  (format nil "'~a'" (cl-ppcre:regex-replace-all "'" string "'\\\\''")))

(defun shell-path (path)
  "PATH quoted for the shell, a path under home as ~/... (shorter to read)."
  (let* ((path (uiop:native-namestring path))
         (home (uiop:native-namestring (user-homedir-pathname))))
    (if (and (> (length path) (length home)) (string= home path :end2 (length home)))
        (format nil "~~/~a" (shell-quote (subseq path (length home))))
        (shell-quote path))))

(defun lem-terminal-buffers ()
  "Lem's terminal buffers, most recently shown first."
  (remove-if-not (lambda (buffer) (lem-terminal/terminal-mode::buffer-terminal buffer)) (lem:buffer-list)))

(defun lem-terminal-buffer (&optional name)
  "The terminal buffer NAME, or the one most recently shown."
  (let ((buffers (lem-terminal-buffers)))
    (if name (find name buffers :key #'lem:buffer-name :test #'string=) (first buffers))))

(defun terminal-type-line (buffer line)
  "Type LINE and Return into BUFFER's terminal (the person's own request)."
  (let ((terminal (lem-terminal/terminal-mode::buffer-terminal buffer)))
    (loop for character across line
          do (lem-terminal/terminal:input-character terminal character))
    (lem-terminal/terminal:input-key terminal lem-terminal/ffi::vterm_key_enter)))

(defun same-directory-p (a b)
  "Whether directories A and B are one (by truename: /var is /private/var)."
  (let ((a (and a (probe-file a))) (b (and b (probe-file b))))
    (and a b (uiop:pathname-equal a b))))

(defun lem-open-terminal (&key directory new run)
  "Show a terminal in DIRECTORY (the working directory) in Lem's window --
the one already there unless NEW -- and type RUN into it when given."
  (ensure-terminal)
  (let ((directory (uiop:native-namestring
                    (uiop:ensure-directory-pathname
                     (if (and (stringp directory) (plusp (length (string-trim " " directory))))
                         (expand-user-path directory)
                         (current-directory))))))
    (unless (uiop:directory-exists-p directory)
      (error "No such directory: ~a" directory))
    (lem-call
     (lambda ()
       (terminal-follow-theme)
       (let ((buffer (and (not new)
                          (find-if (lambda (buffer)
                                     (and (not (lem:buffer-value buffer 'terminal-exited))
                                          (same-directory-p (lem:buffer-directory buffer) directory)))
                                   (lem-terminal-buffers)))))
         (if buffer
             (setf (lem:current-window) (lem:pop-to-buffer buffer))
             ;; Lem's own M-x terminal, in DIRECTORY quoted for the shell.
             (progn
               (lem-terminal/terminal-mode::create-terminal (shell-quote directory))
               (setf buffer (lem:current-buffer))
               (setf (lem:buffer-directory buffer) directory)))
         (when run (terminal-type-line buffer run))
         (lem:redraw-display :force t)
         (lem-note-shown-buffer)
         (jobj "name" (lem:buffer-name buffer) "directory" directory))))))

;;; --- running a file ---

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
  "How /run runs a file, by its type: {file} is the file's name (the
terminal is in its directory), {out} a place for a compiled program.")

(defun terminal-run-command (path)
  "The command line /run types for PATH, or an error naming the types it knows."
  (let* ((type (pathname-type path))
         (template (and type (cdr (assoc type *terminal-run-commands* :test #'string-equal)))))
    (unless template
      (error "/run doesn't know how to run ~:[extension-less~;.~:*~a~] files: it knows ~{.~a~^, ~}."
             type (mapcar #'car *terminal-run-commands*)))
    (let ((out (merge-pathnames (format nil "bin/~a" (pathname-name path)) (terminal-directory))))
      (ensure-directories-exist out)
      (cl-ppcre:regex-replace-all "\\{(file|out)\\}" template
                                  (lambda (match name)
                                    (declare (ignore match))
                                    (if (string= name "file")
                                        (shell-quote (file-namestring path))
                                        (shell-path out)))
                                  :simple-calls t))))

(defun lem-run-file (path)
  "Save PATH's editor buffer, then run it in a terminal in its directory."
  (let* ((path (expand-user-path path))
         (command (terminal-run-command path)))
    (unless (probe-file path) (error "No such file: ~a" path))
    (when (lem-call (lambda () (let ((buffer (editor-find-buffer path))) (and buffer (lem:buffer-modified-p buffer)))))
      (editor-save-file path))
    (let ((directory (uiop:native-namestring (uiop:pathname-directory-pathname path))))
      (lem-open-terminal :directory directory
                         :run (format nil "cd ~a && ~a" (shell-path directory) command)))))

;;; --- reading it ---

(defun terminal-transcript (buffer &key (lines 100))
  "BUFFER's terminal as text: its scrollback and screen, the last LINES
lines, trailing blank lines dropped."
  (let* ((terminal (lem-terminal/terminal-mode::buffer-terminal buffer))
         (scrollback
           (and terminal
                (not (lem-terminal/terminal::terminal-scrollback-active terminal))
                (bt2:with-lock-held ((lem-terminal/terminal::terminal-io-lock terminal))
                  (let* ((ring (lem-terminal/terminal::terminal-scrollback-ring terminal))
                         (head (lem-terminal/terminal::terminal-scrollback-head terminal))
                         (count (lem-terminal/terminal:scrollback-count terminal)))
                    (loop for i from 0 below count
                          collect (or (aref ring (mod (+ (- head count) i) (length ring))) ""))))))
         (all (append scrollback (uiop:split-string (lem:buffer-text buffer) :separator '(#\Newline))))
         (all (mapcar (lambda (line) (string-right-trim " " line)) all)))
    (loop while (and all (string= (car (last all)) "")) do (setf all (butlast all)))
    (format nil "~{~a~^~%~}" (last all lines))))

(defun lem-terminal-transcript (&key name (lines 100))
  "(values TEXT BUFFER-NAME DIRECTORY) of the terminal NAME or the latest one."
  (values-list
   (lem-call
    (lambda ()
      (let ((buffer (lem-terminal-buffer name)))
        (unless buffer
          (error (if name "No terminal named ~a." "No terminal is open: /term opens one.") name))
        (list (terminal-transcript buffer :lines lines) (lem:buffer-name buffer) (lem:buffer-directory buffer)))))))

(defun terminal-ask-prompt-text (buffer)
  "What C-x C-a in a terminal puts at the main prompt."
  (format nil "About my terminal in ~a (its last lines):~%```~%~a~%```~%"
          (abbreviate-home (or (lem:buffer-directory buffer) "")) (terminal-transcript buffer :lines 60)))

;;; Keys: the terminal takes them all, but for Lem's window and buffer
;;; commands (its *BYPASS-COMMANDS*) and C-x C-a, to ask about it.  C-c is
;;; the program's at once (Ctrl-C interrupts it): elsewhere it begins keys
;;; such as C-c C-a, and Lem would wait for the rest.
(lem:define-key lem-terminal/terminal-mode::*terminal-mode-keymap* "C-c" 'lem-terminal/terminal-mode::terminal-input)
(lem:define-key lem-terminal/terminal-mode::*terminal-mode-keymap* "C-x C-a" 'cl-agent-ask)
(pushnew 'cl-agent-ask lem-terminal/terminal-mode::*bypass-commands*)

(define-tool terminal-output (args)
    (:description "Read the person's terminal in cl-agent's editor (the Code tab; they open it with /term and run files with /run): its scrollback and screen, newest last. Use it when they ask about a command they ran there -- a failing build, a crash, a test's output. Read-only: it never types into their terminal; run commands yourself with your own shell tool."
     :effects '(:read-workspace)
     :parameters (jobj "type" "object"
                       "properties" (jobj "lines" (jobj "type" "integer" "minimum" 1 "maximum" 2000
                                                        "description" "How many of the last lines (default 200).")
                                          "name" (jobj "type" "string" "description" "A terminal's buffer name, e.g. \"*Terminal*<2>\"; omitted, the latest one."))))
  (multiple-value-bind (text name directory)
      (lem-terminal-transcript :name (jget args "name") :lines (or (jget args "lines") 200))
    (format nil "~a, in ~a:~%~a" name directory (if (string= text "") "(nothing on screen yet)" text))))

;;; --- routes ---

(define-web-route lem-terminal (:method :post :path "/api/lem/terminal")
  (let ((body (web-json-body)))
    (handler-case
        (if (jget body "file")
            (lem-run-file (jget body "file"))
            (lem-open-terminal :directory (jget body "directory") :new (jget body "new")))
      (error (condition) (web-respond 400 (jobj "error" (princ-to-string condition)))))))

(define-web-route lem-terminal-transcript (:method :get :path "/api/lem/terminal/transcript")
  (let ((name (web-param "name")))
    (handler-case
        (lem-call
         (lambda ()
           (let ((buffer (lem-terminal-buffer name)))
             (unless buffer (error "No terminal is open: /term opens one."))
             (jobj "prompt" (terminal-ask-prompt-text buffer) "name" (lem:buffer-name buffer)))))
      (error (condition) (web-respond 400 (jobj "error" (princ-to-string condition)))))))

;;; --- doctor ---

(defun doctor-terminal-check (config)
  (declare (ignore config))
  (let ((prefix (libvterm-prefix)))
    (cond ((not prefix)
           (doctor-result "terminal" :warning
                          "libvterm is not installed, so /term and /run cannot open a terminal: brew install libvterm (Debian/Ubuntu: apt install libvterm-dev)."))
          ((not (ignore-errors (zerop (nth-value 2 (uiop:run-program '("cc" "--version") :ignore-error-status t)))))
           (doctor-result "terminal" :warning "libvterm is installed but there is no C compiler (cc) to build the terminal's shim with."))
          (t (doctor-result "terminal" :ok
                            (format nil "libvterm is in ~a; the terminal's shim ~:[is built on first use~;is built~]."
                                    prefix (terminal-library-current-p)))))))

(setf *doctor-checks*
      (append (remove "terminal" *doctor-checks* :key #'doctor-check-id :test #'string=)
              (list (make-doctor-check :id "terminal" :description "Terminal (libvterm)" :function #'doctor-terminal-check))))
