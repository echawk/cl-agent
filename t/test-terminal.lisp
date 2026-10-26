;;;; t/test-terminal.lisp -- the Terminal tab's terminals (terminal.lisp):
;;;; slt in this image, one socket server for every terminal.  Their shell
;;;; is /bin/sh with no $ENV, never the person's shell or its startup files.

(in-package :cl-agent)

(defun call-with-test-shell (function)
  "Call FUNCTION with terminals running /bin/sh, reading no startup file;
close every terminal afterwards."
  (let ((shell (uiop:getenv "SHELL")) (env (uiop:getenv "ENV")))
    (sb-posix:setenv "SHELL" "/bin/sh" 1)
    (sb-posix:unsetenv "ENV")
    (unwind-protect (funcall function)
      (mapc (lambda (terminal) (ignore-errors (close-terminal terminal))) (list-terminals))
      (if shell (sb-posix:setenv "SHELL" shell 1) (sb-posix:unsetenv "SHELL"))
      (when env (sb-posix:setenv "ENV" env 1)))))

(defmacro with-terminal-test ((directory) &body body)
  "Run BODY with DIRECTORY, a fresh directory whose name needs quoting."
  `(call-with-test-shell
    (lambda ()
      (let ((,directory (uiop:native-namestring
                         (merge-pathnames (format nil "it's a dir ~36r/" (random (expt 36 6))) *config-directory*))))
        (ensure-directories-exist ,directory)
        ,@body))))

(defun terminal-test-shows (terminal text &key (seconds 5))
  (loop repeat (* seconds 50)
        when (search text (terminal-transcript terminal)) return t
        do (sleep 0.02)))

(defun terminal-test-ctrl (terminal char)
  "Press Ctrl-CHAR in TERMINAL, as its browser client sends it."
  (slt:headless-key (slt::headless-frontend-view (terminal-frontend terminal)) char char 4))

(deftest the-run-command-quotes-the-file-and-knows-its-types ()
  (let ((line (terminal-run-command "/x/it's me.c")))
    (check (search "cc -Wall -g -o '" line))
    (check (search "'it'\\''s me.c'" line) "the file's name is quoted for the shell")
    (check (search "/terminal/bin/it's me'" (cl-ppcre:regex-replace-all "'\\\\''" line "'")) "compiled into the config directory"))
  (check-equal (terminal-run-command "/x/a.py") "python3 'a.py'")
  (check-equal (shell-path (merge-pathnames "a b/it's" (user-homedir-pathname))) "~/'a b/it'\\''s'"
               "a path under home reads ~/..., quoted after the ~")
  (check (search "doesn't know how to run .xyz files" (handler-case (terminal-run-command "/x/a.xyz") (error (e) (princ-to-string e)))))
  (check (search "extension-less" (handler-case (terminal-run-command "/x/Makefile") (error (e) (princ-to-string e))))))

(deftest a-terminal-runs-commands-and-ctrl-c-interrupts-them ()
  (with-terminal-test (directory)
    (let ((terminal (open-terminal :directory directory)))
      (check (terminal-running-p terminal))
      (terminal-type-line terminal "pwd")
      (check (terminal-test-shows terminal "it's a dir") "the shell is in the directory, its quote and space intact")
      (terminal-type-line terminal "sleep 30; echo slept-$((1+1))")
      (sleep 0.3)
      (sb-ext:gc :full t)
      (let ((start (get-internal-real-time)))
        (terminal-test-ctrl terminal "c")
        (check (terminal-test-shows terminal "slept-2") "Ctrl-C reaches the program")
        (check (< (- (get-internal-real-time) start) (* 3 internal-time-units-per-second)) "sleep was interrupted"))
      (check (eq (open-terminal :directory directory) terminal) "the same directory's terminal, not another")
      (check (not (eq (open-terminal :directory directory :new t) terminal)) "unless a new one is asked for"))))

(deftest a-terminal-opens-in-the-working-directory-by-default ()
  (with-terminal-test (directory)
    (let ((*current-session* (make-session (make-instance 'ollama-provider :model "m")
                                           :working-directory (uiop:ensure-directory-pathname directory))))
      (check (same-directory-p (terminal-directory (open-terminal)) directory) "/term with no directory")
      (check (same-directory-p (terminal-directory (open-terminal :directory "")) directory) "or an empty one")))
  (check-equal (expand-user-path "~") (uiop:native-namestring (user-homedir-pathname)) "/term ~ is home"))

(deftest asking-about-a-terminal-puts-its-last-lines-at-the-prompt ()
  (with-terminal-test (directory)
    (let ((terminal (open-terminal :directory directory)))
      (terminal-type-line terminal "echo look-$((40+2))")
      (check (terminal-test-shows terminal "look-42"))
      (let ((text (terminal-ask-prompt-text terminal)))
        (check (search "About my terminal in" text))
        (check (search "look-42" text) "with what it shows"))
      (let ((tool (call-tool "terminal-output" (jobj "lines" 5))))
        (check (search "look-42" tool) "the agent reads it")
        (check (search (format nil "Terminal ~d" (terminal-id terminal)) tool) "and is told which terminal")))))

(deftest run-compiles-and-runs-a-c-file-in-a-terminal ()
  (with-terminal-test (directory)
    (if (not (ignore-errors (zerop (nth-value 2 (uiop:run-program '("cc" "--version") :ignore-error-status t)))))
        (check t "skipped: no C compiler")
        (let ((file (uiop:native-namestring (merge-pathnames "hello world.c" directory))))
          (with-open-file (out file :direction :output :if-exists :supersede)
            (format out "#include <stdio.h>~%int main(void) { printf(\"answer %d\\n\", 6 * 7); return 3; }~%"))
          (let ((terminal (run-file-in-terminal file)))
            (check (terminal-test-shows terminal "answer 42" :seconds 20) "compiled and ran")
            (terminal-type-line terminal "echo status=$?")
            (check (terminal-test-shows terminal "status=3") "its exit status is the program's"))))))

(deftest a-terminals-shell-ends-with-it ()
  (with-terminal-test (directory)
    ;; Closing it hangs up the shell.
    (let* ((terminal (open-terminal :directory directory))
           (process (slt::terminal-emulator-process (terminal-emulator terminal)))
           (pid #+darwin (slt::forkpty-process-pid process) #-darwin (sb-ext:process-pid process)))
      (check (plusp pid))
      (close-terminal terminal)
      (check (scratch-wait-until (lambda () (/= 0 (cffi:foreign-funcall "kill" :int pid :int 0 :int))))
             "the shell is gone")
      (check (not (bt:thread-alive-p (terminal-thread terminal))) "and its thread")
      (check-equal (list-terminals) nil))
    ;; A shell that exits keeps what it showed, to read and ask about.
    (let ((terminal (open-terminal :directory directory)))
      (terminal-type-line terminal "echo last-$((1+1)); exit")
      (check (scratch-wait-until (lambda () (eq (terminal-state terminal) :exited)) :tries 500))
      (check (search "last-2" (terminal-transcript terminal)) "its last screen is kept")
      (check (search "its shell has exited" (terminal-ask-prompt-text terminal)))
      (close-terminal terminal)
      (check-equal (list-terminals) nil))))

(defun terminal-socket-messages (url &key origin (seconds 2))
  "The JSON messages a client at URL receives in SECONDS, or :REFUSED."
  (let ((client (wsd:make-client url :additional-headers (and origin (list (cons "Origin" origin)))))
        (messages '()) (lock (bt:make-lock)))
    (wsd:on :message client (lambda (message) (bt:with-lock-held (lock) (push message messages))))
    (handler-case (wsd:start-connection client)
      (error () (return-from terminal-socket-messages :refused)))
    (unwind-protect (progn (sleep seconds)
                           (if (eq (wsd:ready-state client) :open)
                               (bt:with-lock-held (lock) (mapcar #'decode-json-object (reverse messages)))
                               :refused))
      (ignore-errors (wsd:close-connection client)))))

(deftest a-terminals-socket-needs-its-token-and-a-local-page ()
  (with-terminal-test (directory)
    (let* ((terminal (open-terminal :directory directory))
           (url (terminal-socket-url terminal))
           (messages (terminal-socket-messages url :origin "http://127.0.0.1:4567")))
      (check (listp messages) "a local page connects")
      (check (find "hello" messages :key (lambda (m) (jget m "t")) :test #'equal) "and slt greets it")
      (check (find "frame" messages :key (lambda (m) (jget m "t")) :test #'equal) "with the screen")
      (check-equal (terminal-socket-messages (cl-ppcre:regex-replace "token=.*" url "token=wrong")) :refused
                   "a wrong token is refused")
      (check-equal (terminal-socket-messages url :origin "https://evil.example") :refused
                   "a page elsewhere is refused"))))
