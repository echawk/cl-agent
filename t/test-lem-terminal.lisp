;;;; t/test-lem-terminal.lisp -- the terminal next to your files (lem/terminal.lisp):
;;;; Lem's terminal over libvterm, built on first use.  Its shell is /bin/sh
;;;; with no $ENV, never the person's shell or its startup files.  Skipped
;;;; where libvterm or a C compiler is missing.

(in-package :cl-agent)

(defun terminal-test-ready-p ()
  (and (libvterm-prefix)
       (ignore-errors (zerop (nth-value 2 (uiop:run-program '("cc" "--version") :ignore-error-status t))))))

(defun call-with-test-shell (function)
  "Call FUNCTION with terminals running /bin/sh, reading no startup file;
close every terminal afterwards."
  (let ((shell (uiop:getenv "SHELL")) (env (uiop:getenv "ENV")))
    (sb-posix:setenv "SHELL" "/bin/sh" 1)
    (sb-posix:unsetenv "ENV")
    (unwind-protect (funcall function)
      (ignore-errors (lem-call (lambda () (mapc #'lem:kill-buffer (lem-terminal-buffers)))))
      (if shell (sb-posix:setenv "SHELL" shell 1) (sb-posix:unsetenv "SHELL"))
      (when env (sb-posix:setenv "ENV" env 1)))))

(defmacro with-terminal-test ((directory) &body body)
  "Run BODY with DIRECTORY, a fresh directory whose name needs quoting."
  `(if (terminal-test-ready-p)
       (call-with-test-shell
        (lambda ()
          (let ((,directory (uiop:native-namestring
                             (merge-pathnames (format nil "it's a dir ~36r/" (random (expt 36 6))) *config-directory*))))
            (ensure-directories-exist ,directory)
            ,@body)))
       (check t "skipped: libvterm or cc is not installed")))

(defun terminal-test-type (line)
  (lem-call (lambda () (terminal-type-line (lem-terminal-buffer) line))))

(defun terminal-test-keys (&rest syms)
  "Press Ctrl- each of SYMS in the terminal, as from the Lem view."
  (lem-call (lambda () (lem:execute-key-sequence (mapcar (lambda (sym) (lem:make-key :ctrl t :sym sym)) syms)))))

(defun terminal-test-shows (text &key (seconds 5))
  (loop repeat (* seconds 50)
        when (search text (lem-terminal-transcript)) return t
        do (sleep 0.02)))

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
    (let ((opened (lem-open-terminal :directory directory)))
      (check-equal (jget opened "directory") directory)
      (terminal-test-type "pwd")
      (check (terminal-test-shows "it's a dir") "the shell is in the directory, its quote and space intact")
      (terminal-test-type "sleep 30; echo slept")
      (sleep 0.3)
      (sb-ext:gc :full t)                 ; the GC's signals wake its reader: not an exit
      (let ((start (get-internal-real-time)))
        (terminal-test-keys "c")
        (terminal-test-type "echo after-$((1+1))")
        (check (terminal-test-shows "after-2") "C-c goes to the program at once, not to a C-c prefix")
        (check (< (- (get-internal-real-time) start) (* 3 internal-time-units-per-second)) "sleep was interrupted"))
      (check-equal (lem-call (lambda () (lem-terminal/terminal::terminal-dead
                                         (lem-terminal/terminal-mode::buffer-terminal (lem-terminal-buffer)))))
                   nil "still running")
      (check-equal (jget (lem-open-terminal :directory directory) "name") (jget opened "name")
                   "the same directory's terminal is shown again, not another"))))

(deftest a-terminal-opens-in-the-working-directory-by-default ()
  (with-terminal-test (directory)
    (let ((session (make-session (make-instance 'ollama-provider :model "m")
                                 :working-directory (uiop:ensure-directory-pathname directory))))
      (let ((*current-session* session))
        (check (same-directory-p (jget (lem-open-terminal) "directory") directory) "/term with no directory")
        (check (same-directory-p (jget (lem-open-terminal :directory "") "directory") directory) "or an empty one")))))

(deftest c-x-c-a-in-a-terminal-asks-about-its-last-lines ()
  (with-terminal-test (directory)
    (lem-open-terminal :directory directory)
    (terminal-test-type "echo look-$((40+2))")
    (check (terminal-test-shows "look-42"))
    (let ((sent nil) (lock (bt:make-lock)))
      (sb-int:encapsulate 'web-ui-command 'terminal-test
                          (lambda (function &rest arguments)
                            (declare (ignore function))
                            (bt:with-lock-held (lock) (push arguments sent))))
      (unwind-protect
           (progn
             (terminal-test-keys "x" "a")
             (let ((insert (scratch-wait-until (lambda () (bt:with-lock-held (lock) (assoc "insert" sent :test #'equal))))))
               (check insert "C-x C-a puts it at the prompt")
               (let ((text (and insert (jget (second insert) "text"))))
                 (check (search "About my terminal in" text))
                 (check (search "look-42" text) "with what it shows"))))
        (sb-int:unencapsulate 'web-ui-command 'terminal-test)))
    (let ((tool (call-tool "terminal-output" (jobj "lines" 5))))
      (check (search "look-42" tool) "the agent reads it")
      (check (search "*Terminal*" tool) "and is told which terminal"))))

(deftest run-compiles-and-runs-a-c-file-in-the-terminal ()
  (with-terminal-test (directory)
    (let ((file (uiop:native-namestring (merge-pathnames "hello world.c" directory))))
      (with-open-file (out file :direction :output :if-exists :supersede)
        (format out "#include <stdio.h>~%int main(void) { printf(\"answer %d\\n\", 6 * 7); return 3; }~%"))
      (lem-run-file file)
      (check (terminal-test-shows "answer 42" :seconds 20) "compiled and ran")
      (terminal-test-type "echo status=$?")
      (check (terminal-test-shows "status=3") "its exit status is the program's"))))

(deftest a-terminals-shell-ends-with-it ()
  (with-terminal-test (directory)
    ;; Killing the buffer hangs up the shell.
    (lem-open-terminal :directory directory)
    (let ((pid (lem-call (lambda () (terminal-shell (lem-terminal/terminal-mode::buffer-terminal (lem-terminal-buffer)))))))
      (check (plusp pid))
      (lem-call (lambda () (lem:kill-buffer (lem-terminal-buffer))))
      (check (scratch-wait-until (lambda () (/= 0 (cffi:foreign-funcall "kill" :int pid :int 0 :int))))
             "the shell is gone, and reaped")
      (check-equal (lem-call #'lem-terminal-buffers) nil))
    ;; A shell that exits says so; its buffer then closes cleanly.
    (lem-open-terminal :directory directory)
    (terminal-test-type "exit")
    (check (scratch-wait-until (lambda () (lem-call (lambda () (search "The shell has exited" (lem:buffer-text (lem-terminal-buffer))))))
                               :tries 500))
    (let ((thread (lem-call (lambda () (lem-terminal/terminal::terminal-thread
                                        (lem-terminal/terminal-mode::buffer-terminal (lem-terminal-buffer)))))))
      (check (scratch-wait-until (lambda () (not (bt2:thread-alive-p thread)))) "its reading thread ends, not spins"))
    (check (null (nth-value 1 (ignore-errors (lem-call (lambda () (lem:kill-buffer (lem-terminal-buffer)))))))
           "killing an exited terminal's buffer is no error")
    (check-equal (lem-call #'lem-terminal-buffers) nil)))
