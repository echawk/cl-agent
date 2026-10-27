;;;; scripts/check-deps.lisp -- after updating dependencies: does cl-agent
;;;; still load, from inside this project, and is what it uses of slt's
;;;; internals still there?  Run by scripts/update-deps.sh (or on its own:
;;;; sbcl --non-interactive --no-userinit --load scripts/check-deps.lisp,
;;;; from the project directory).  Exits 1 on a problem, printing each.
;;;;
;;;; 1. cl-agent and its tests load.
;;;; 2. Every system loaded resolves inside the project (ocicl/, third-party/)
;;;;    or is one of SBCL's contribs: a dependency missing from ocicl.csv
;;;;    would otherwise be found in whatever the machine has elsewhere.
;;;; 3. Every slt::NAME and slt:NAME in src/ and t/ names something slt
;;;;    still defines (a function, macro, variable, class or structure):
;;;;    cl-agent reaches into slt's web frontend and emulator, which slt
;;;;    may change freely.
;;;; 4. slt's browser client still has what static/terminal.js and
;;;;    static/emacs-view.js call.

(load "boot.lisp")

(defvar *problems* '())

(defun problem (format &rest arguments)
  (push (apply #'format nil format arguments) *problems*)
  (format t "~&  PROBLEM: ~?~%" format arguments))

(format t "~&* Loading cl-agent and its tests~%")
(handler-case (progn (asdf:load-system "cl-agent") (asdf:load-system "cl-agent/tests"))
  (error (condition) (problem "cl-agent did not load: ~a" condition)))

(format t "~&* Where each system came from~%")
(let ((root (namestring (truename (uiop:getcwd))))
      (contrib (namestring (truename (sb-int:sbcl-homedir-pathname)))))
  (dolist (name (asdf:already-loaded-systems))
    (let ((file (ignore-errors (asdf:system-source-file name))))
      (when (and file
                 (not (uiop:string-prefix-p root (namestring (truename file))))
                 (not (uiop:string-prefix-p contrib (namestring (truename file)))))
        (problem "~a is loaded from outside the project (~a): pin it in ocicl.csv (ocicl install ~a)"
                 name (uiop:native-namestring file) name)))))

(format t "~&* What cl-agent uses of slt~%")
(let ((names '()))
  (dolist (file (append (directory "src/**/*.lisp") (directory "t/**/*.lisp")))
    (let ((text (uiop:read-file-string file)))
      (cl-ppcre:do-register-groups (name) ("(?i)\\bslt::?([a-z0-9*+%/<>=-]+)" text)
        (pushnew (string-upcase name) names :test #'string=))))
  (let ((package (find-package "SLT")))
    (if (not package)
        (problem "There is no SLT package.")
        (dolist (name (sort names #'string<))
          (let ((symbol (find-symbol name package)))
            (unless (and symbol
                         (or (fboundp symbol) (boundp symbol) (find-class symbol nil)
                             (ignore-errors (sb-kernel:specifier-type symbol))))
              (problem "slt no longer defines ~a, which cl-agent uses" name))))))
  (format t "  ~d names checked~%" (length names)))

(format t "~&* slt's browser client~%")
(let ((client (uiop:read-file-string "third-party/slt/web/slt-terminal.js")))
  (dolist (needed '("export class SltTerminal" "setTheme(" "fit(" "focus(" "dispose(" "text(" "\"exit\"" "\"title\""))
    (unless (search needed client)
      (problem "slt-terminal.js has no ~a, which the page uses" needed))))

(format t "~&~:[All checks passed.~;~:*~d problem~:p.~]~%" (and *problems* (length *problems*)))
(uiop:quit (if *problems* 1 0))
