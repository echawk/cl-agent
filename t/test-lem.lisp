;;;; t/test-lem.lisp -- the hosted Lem (src/lem/): its editor thread, the
;;;; user's Lem init file, and syntax highlighting by Lem's language modes.
;;;; The test framework points LEM_HOME into the run's temporary directory.

(in-package :cl-agent)

(defun html-text (html)
  "HTML with its tags removed and the entities this code emits decoded."
  (let ((text (with-output-to-string (out)
                (loop with in-tag = nil
                      for c across html
                      do (cond ((char= c #\<) (setf in-tag t))
                               ((char= c #\>) (setf in-tag nil))
                               ((not in-tag) (write-char c out)))))))
    (dolist (pair '(("&lt;" . "<") ("&gt;" . ">") ("&quot;" . "\"") ("&#39;" . "'") ("&amp;" . "&")) text)
      (setf text (replace-all-substrings text (car pair) (cdr pair))))))

(defun run-text (text runs class)
  "The pieces of TEXT that RUNS mark with CLASS."
  (loop for (start end run-class) in runs
        when (string= run-class class) collect (subseq text start end)))

(deftest lem-host-runs-lem-without-a-display-and-stops ()
  (let ((format sb-impl::*default-external-format*))
    (check (lem-host-available-p) "starts on first use")
    (check-equal (getf (lem-host-status) :state) :running)
    (check-equal (bordeaux-threads:thread-name (lem-call (lambda () (bordeaux-threads:current-thread))))
                 "editor" "LEM-CALL runs on Lem's editor thread")
    (check-equal sb-impl::*default-external-format* format "never LEM:LAUNCH's global changes")
    (check (notany (lambda (function)
                     (let ((*package* (find-package :keyword)))
                       (search "LEM-CORE::" (prin1-to-string (nth-value 2 (function-lambda-expression function))))))
                   sb-ext:*ed-functions*)
           "(ed) does not start a Lem frontend")
    (check (uiop:pathname-equal (lem-core::lem-home)
                                (uiop:ensure-directory-pathname (uiop:getenv "LEM_HOME")))
           "Lem's home is the test's, never the user's")
    (check-condition error (lem-call (lambda () (error "boom"))) "errors reach the caller")
    (lem-host-stop)
    (check-equal (getf (lem-host-status) :state) :stopped)
    (check (lem-host-available-p) "and starts again")))

(deftest every-request-waiting-for-lem-to-start-is-woken ()
  ;; A page's first requests arrive together and all wait while Lem starts.
  ;; LEM-HOST-MARK once woke only one of them; the rest slept until their
  ;; 30-second timeout, and the page's Lem view stayed blank.
  (lem-host-stop)
  (let ((slow (lambda () (sleep 0.3))))       ; widen the window: all four are waiting
    (lem:add-hook lem:*before-init-hook* slow)
    (unwind-protect
         (let* ((start (get-internal-real-time))
                (threads (loop repeat 4
                               collect (bt:make-thread
                                        (lambda ()
                                          (list (lem-host-available-p)
                                                (/ (- (get-internal-real-time) start) internal-time-units-per-second)))
                                        :name "test-lem-start")))
                (results (mapcar #'bt:join-thread threads)))
           (check (every #'first results) "all of them see Lem running")
           (check (every (lambda (r) (< (second r) 5)) results)
                  (format nil "promptly, not after a timeout: ~{~,2fs~^ ~}" (mapcar #'second results))))
      (lem:remove-hook lem:*before-init-hook* slow))))

(deftest lem-host-loads-the-users-lem-init-file ()
  (let ((home (uiop:ensure-directory-pathname (uiop:getenv "LEM_HOME"))))
    (lem-host-stop)
    (with-open-file (out (merge-pathnames "init.lisp" home) :direction :output :if-exists :supersede)
      (write-string "(defparameter cl-user::*test-lem-init* (list *package* :loaded))" out))
    (with-open-file (out (merge-pathnames "cl-agent.lisp" home) :direction :output :if-exists :supersede)
      (write-string "(defparameter cl-user::*test-lem-cl-agent-init* :loaded)" out))
    (unwind-protect
         (progn
           (check (lem-host-available-p))
           (check-equal (second (symbol-value (find-symbol "*TEST-LEM-INIT*" :cl-user))) :loaded)
           (check-equal (package-name (first (symbol-value (find-symbol "*TEST-LEM-INIT*" :cl-user)))) "LEM-USER"
                        "read in LEM-USER, as Lem does")
           (check-equal (symbol-value (find-symbol "*TEST-LEM-CL-AGENT-INIT*" :cl-user)) :loaded)
           (check (null (getf (lem-host-status) :problem)))
           ;; A broken init file is reported, and Lem still runs.
           (lem-host-stop)
           (with-open-file (out (merge-pathnames "init.lisp" home) :direction :output :if-exists :supersede)
             (write-string "(error \"broken init\")" out))
           (check (lem-host-available-p))
           (check (search "broken init" (getf (lem-host-status) :problem))))
      (lem-host-stop)
      (delete-file (merge-pathnames "init.lisp" home))
      (delete-file (merge-pathnames "cl-agent.lisp" home)))))

(deftest lem-highlights-code-with-the-languages-own-mode ()
  (let* ((c "int main(void) { /* hi */ return 0; }")
         (runs (lem-highlight-runs c :language "c")))
    (check (member "return" (run-text c runs "sx-keyword") :test #'string=))
    (check (member "int" (run-text c runs "sx-type") :test #'string=))
    (check (member "/* hi */" (run-text c runs "sx-comment") :test #'string=)))
  (let ((python (format nil "def f(x):~%    return 'a'  # note")))
    (dolist (language '("python" "py"))
      (let ((runs (lem-highlight-runs python :language language)))
        (check (member "def" (run-text python runs "sx-keyword") :test #'string=) language)
        (check (member "'a'" (run-text python runs "sx-string") :test #'string=) language))))
  (let* ((ruby (format nil "class Foo~%  # c~%end"))
         (runs (lem-highlight-runs ruby :pathname "scratch.rb")))
    (check (member "class" (run-text ruby runs "sx-keyword") :test #'string=) "by file name"))
  (check-equal (nth-value 1 (lem-highlight-runs "x = 1" :language "ruby")) "Ruby" "and says which mode")
  (check (null (lem-highlight-runs "qapla'" :language "klingon")) "a language Lem lacks: plain"))

(deftest markdown-code-blocks-are-highlighted-by-lem ()
  (let ((html (web-markdown-html (format nil "Look:~%```c~%if (a < b) return 1; // less~%```~%Done."))))
    (check (search "<span class=\"sx-keyword\">return</span>" html))
    (check (search "<span class=\"sx-comment\">// less</span>" html))
    (check (and (search "&lt;" html) (not (search "a < b" html))) "text inside spans is still escaped")
    (check (search "language-c" html))
    (check (search "if (a < b) return 1; // less" (html-text html))))
  (let ((html (web-markdown-html (format nil "```klingon~%<qapla'>~%```"))))
    (check (not (search "<span" html)) "unknown languages stay plain")
    (check (search "&lt;qapla&#39;&gt;" html))))

(deftest code-blocks-stay-plain-when-lem-is-unavailable ()
  (let ((state *lem-host-state*))
    (lem-host-stop)
    (setf *lem-host-state* :failed)
    (unwind-protect
         (let ((html (web-markdown-html (format nil "```c~%int y = 2;~%```"))))
           (check (not (search "<span" html)))
           (check (search "int y = 2;" html)))
      (setf *lem-host-state* (if (eq state :running) :stopped state)))))
