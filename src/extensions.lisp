;;;; extensions.lisp -- the self-modification subsystem.
;;;;
;;;; This is the headline feature of cl-agent: because Common Lisp is
;;;; image-based, the running agent process can LOAD new source code
;;;; into itself at any time -- redefine functions, add CLOS methods,
;;;; register new tools (tools.lisp) or providers (providers/registry.lisp),
;;;; hang new behavior off any hook (hooks.lisp) -- without restarting.
;;;; This file is the machinery for doing that safely and persistently;
;;;; tools/extensions-tool.lisp exposes it to the model as the
;;;; `write-extension` and `eval-lisp` tools, so the agent itself can
;;;; drive it mid-conversation ("add a tool that...", "I noticed X is
;;;; annoying, fix yourself so that...").
;;;;
;;;; LAYOUT ON DISK (under *CONFIG-DIRECTORY*, see config.lisp):
;;;;
;;;;   ~/.config/cl-agent/extensions/*.lisp   one file per extension
;;;;   ~/.config/cl-agent/extensions/enabled.lisp
;;;;       a plist (:enabled (list "foo.lisp" "bar.lisp")) written by
;;;;       SET-EXTENSION-ENABLED, read at startup by
;;;;       LOAD-ENABLED-EXTENSIONS -- or (:enabled :all) to load every
;;;;       *.lisp file present (this is the implicit default if the
;;;;       file itself doesn't exist, i.e. a brand new install with no
;;;;       opinions yet loads everything that shows up).
;;;;
;;;; This design directly answers "the user might want some files
;;;; loaded and others not": writing a file to the extensions directory
;;;; and ENABLING it are two separate, independently reversible steps.
;;;; An extension that turns out to be broken or unwanted can be
;;;; disabled (SET-EXTENSION-ENABLED ... NIL) without deleting it, or
;;;; deleted outright; either way it stops being loaded on the next
;;;; start, and nothing about the core agent had to change.

(in-package :cl-agent)

(defun extensions-directory ()
  (merge-pathnames "extensions/" *config-directory*))

(defun enabled-file-path ()
  (merge-pathnames "enabled.lisp" (extensions-directory)))

(defun list-extension-files ()
  "Return every *.lisp file physically present in the extensions
directory, as pathnames, sorted by name for reproducible ordering."
  (sort (directory (merge-pathnames "*.lisp" (extensions-directory)))
        #'string< :key #'namestring))

(defun read-enabled-config ()
  "Return the enabled-list plist from enabled.lisp, or (:enabled :all)
if that file doesn't exist yet (fresh install: load everything)."
  (let ((path (enabled-file-path)))
    (if (probe-file path)
        (with-open-file (in path)
          (let ((*read-eval* nil)) (or (read in nil nil) (list :enabled :all))))
        (list :enabled :all))))

(defun write-enabled-config (config)
  (ensure-config-directory)
  (with-open-file (out (enabled-file-path) :direction :output
                        :if-exists :supersede :if-does-not-exist :create)
    (let ((*print-pretty* t) (*package* (find-package :keyword)))
      (prin1 config out)))
  (values))

(defun extension-enabled-p (filename)
  "FILENAME is a bare name like \"foo.lisp\" (not a full pathname)."
  (let ((enabled (getf (read-enabled-config) :enabled)))
    (or (eq enabled :all) (member filename enabled :test #'string=))))

(defun set-extension-enabled (filename enabled-p)
  "Persistently enable or disable the extension named FILENAME (a bare
name like \"foo.lisp\") for future startups. Converts an :ALL
configuration to an explicit list the first time something is
disabled, so disabling one extension doesn't silently disable every
extension that comes after it."
  (let* ((config (read-enabled-config))
         (current (getf config :enabled)))
    (let ((as-list (if (eq current :all)
                        (mapcar (lambda (p) (file-namestring p)) (list-extension-files))
                        current)))
      (setf (getf config :enabled)
            (if enabled-p
                (adjoin filename as-list :test #'string=)
                (remove filename as-list :test #'string=)))
      (write-enabled-config config))))

(defun load-extension-file (path)
  "LOAD PATH into the running image, firing :BEFORE-EXTENSION-LOAD and
:AFTER-EXTENSION-LOAD around it. Any error during compilation/loading
is caught and re-signalled as EXTENSION-ERROR rather than propagating
raw -- the intent is that a single broken extension (including one the
agent just wrote and is about to try loading) is reported clearly
without taking down the whole process."
  (run-hook :before-extension-load path)
  (handler-case
      (progn (load path) (run-hook :after-extension-load path) t)
    (error (c)
      (error 'extension-error :path path :original-condition c))))

(defun load-enabled-extensions (&key (report-stream *error-output*))
  "Load every enabled extension file, in sorted order. Returns two
values: the list of pathnames successfully loaded, and an alist of
(pathname . condition) for ones that failed. A failure is reported to
REPORT-STREAM and does not stop the remaining extensions from being
tried -- an extension author (the agent, mid-self-modification) needs
feedback, but one typo should not prevent the agent from starting up
at all."
  (ensure-config-directory)
  (let ((loaded nil) (failed nil))
    (dolist (path (list-extension-files))
      (if (extension-enabled-p (file-namestring path))
          (handler-case (progn (load-extension-file path) (push path loaded))
            (extension-error (c)
              (push (cons path c) failed)
              (format report-stream "~&[extensions] ~a~%" c)))
          nil))
    (values (nreverse loaded) (nreverse failed))))

(defun write-extension-file (filename source &key (if-exists :supersede))
  "Write SOURCE (a string of Lisp code) to FILENAME (a bare name;
coerced to end in .lisp if it doesn't already) under the extensions
directory. Does not load or enable it -- see LOAD-EXTENSION-FILE /
SET-EXTENSION-ENABLED, or just use the write-extension TOOL
(tools/extensions-tool.lisp), which does all three in one call for the
model's convenience. Returns the pathname written."
  (ensure-config-directory)
  (let* ((name (if (search ".lisp" filename :from-end t) filename (concatenate 'string filename ".lisp")))
         (path (merge-pathnames name (extensions-directory))))
    (with-open-file (out path :direction :output :if-exists if-exists :if-does-not-exist :create)
      (write-string source out))
    path))
