;;;; systems.lisp -- ASDF systems in a saved cl-agent image, and where ocicl
;;;; puts the ones fetched at run time.
;;;;
;;;; A saved image forgets ASDF's source registry, so a library that asks
;;;; ASDF for itself when the image starts (tree-sitter-cl does, from
;;;; SB-EXT:*INIT-HOOKS*) found nothing, and the ocicl runtime's
;;;; missing-system hook then ran `ocicl install` in whatever directory
;;;; bin/cl-agent was started in -- leaving ocicl/ and ocicl.csv in the
;;;; user's repository.  So:
;;;;
;;;;   - when the image is saved, every loaded system's .asd is recorded, and
;;;;     an init hook is put first in SB-EXT:*INIT-HOOKS*: it finds those
;;;;     systems again by name and turns ocicl's fetching off, before any
;;;;     library's own init hook runs;
;;;;   - when the agent starts (MAIN), ocicl's run-time systems live in the
;;;;     config directory, systems/ocicl.csv and systems/ocicl/, never the
;;;;     working directory;
;;;;   - fetching happens only when the agent's load-asdf-system tool asks
;;;;     for a library (WITH-OCICL-FETCHING).
;;;;
;;;; Development is untouched: boot.lisp's ocicl runtime still installs a
;;;; build's dependencies into the repository's ocicl.csv.

(in-package :cl-agent)

(defvar *image-system-files* nil
  "System name -> its .asd file, recorded when the image was saved.")

(defun record-image-systems ()
  "Remember where every loaded system's .asd file is.  Run while dumping."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (name (asdf:already-loaded-systems))
      (let* ((system (ignore-errors (asdf:find-system name nil)))
             (file (and system (ignore-errors (asdf:system-source-file system)))))
        (when file (setf (gethash (string-downcase name) table) file))))
    (setf *image-system-files* table)))

(defun image-system-searcher (name)
  "ASDF search function: a system this image was built with, at its .asd."
  (let ((file (and *image-system-files* (gethash (string-downcase name) *image-system-files*))))
    (and file (probe-file file))))

(defun ocicl-runtime-symbol (name)
  (and (find-package "OCICL-RUNTIME") (find-symbol name "OCICL-RUNTIME")))

(defun set-ocicl-fetching (on)
  (let ((download (ocicl-runtime-symbol "*DOWNLOAD*")))
    (when download (setf (symbol-value download) on))))

(defun cl-agent-image-init ()
  "First of SB-EXT:*INIT-HOOKS* in a saved image: find the image's systems
again and stop ocicl fetching on its own."
  (setf asdf:*system-definition-search-functions*
        (cons 'image-system-searcher (remove 'image-system-searcher asdf:*system-definition-search-functions*)))
  (set-ocicl-fetching nil))

(defun prepare-image-systems ()
  "The image-dump hook: record the systems and run CL-AGENT-IMAGE-INIT first
when the image starts."
  (record-image-systems)
  (setf sb-ext:*init-hooks* (cons 'cl-agent-image-init (remove 'cl-agent-image-init sb-ext:*init-hooks*))))

(uiop:register-image-dump-hook 'prepare-image-systems)

;;; --- ocicl at run time: the config directory ---

(defvar *agent-systems-active* nil
  "True once the agent has started and ocicl's run-time systems live in
AGENT-SYSTEMS-DIRECTORY; before that (a development load) ocicl works as
boot.lisp set it up.")

(defun agent-systems-directory ()
  "Where systems ocicl fetches while the agent runs go: config/systems/,
holding ocicl.csv and ocicl/."
  (merge-pathnames "systems/" *config-directory*))

(defun use-agent-systems-directory ()
  "Point the ocicl runtime at AGENT-SYSTEMS-DIRECTORY, and stop it fetching
until asked (WITH-OCICL-FETCHING).  Called when the agent starts."
  (when (find-package "OCICL-RUNTIME")
    (let ((directory (agent-systems-directory)))
      (ensure-directories-exist directory)
      (setf (symbol-value (ocicl-runtime-symbol "*LOCAL-SYSTEMS-DIR*")) (merge-pathnames "ocicl/" directory)
            (symbol-value (ocicl-runtime-symbol "*LOCAL-SYSTEMS-CSV*")) (merge-pathnames "ocicl.csv" directory)
            (symbol-value (ocicl-runtime-symbol "*LOCAL-OCICL-SYSTEMS*")) nil
            (symbol-value (ocicl-runtime-symbol "*LOCAL-SYSTEMS-CSV-TIMESTAMP*")) 0)
      (set-ocicl-fetching nil)
      (setf *agent-systems-active* t)
      directory)))

(defun ocicl-install-in-agent-directory (install name)
  "Once the agent has started, run `ocicl install NAME` in
AGENT-SYSTEMS-DIRECTORY, not the process's working directory, where
INSTALL (the runtime's own) would run it."
  (if (not *agent-systems-active*)
      (funcall install name)
      (let ((directory (ensure-directories-exist (agent-systems-directory)))
            (sanitize (ocicl-runtime-symbol "SANITIZE-SYSTEM-NAME")))
        (uiop:run-program (list "ocicl" "install" (if sanitize (funcall sanitize name) name))
                          :directory directory :output '(:string) :error-output '(:string))
        (setf (symbol-value (ocicl-runtime-symbol "*LOCAL-SYSTEMS-CSV-TIMESTAMP*")) 0))))

(let ((install (ocicl-runtime-symbol "OCICL-INSTALL")))
  (when (and install (fboundp install))
    (sb-int:unencapsulate install 'cl-agent-systems-directory)
    (sb-int:encapsulate install 'cl-agent-systems-directory #'ocicl-install-in-agent-directory)))

(defmacro with-ocicl-fetching (() &body body)
  "Run BODY with ocicl allowed to fetch a missing system (into
AGENT-SYSTEMS-DIRECTORY once the agent has started)."
  (let ((download (gensym "DOWNLOAD")))
    `(let* ((,download (ocicl-runtime-symbol "*DOWNLOAD*"))
            (saved (and ,download (symbol-value ,download))))
       (unwind-protect (progn (set-ocicl-fetching t) ,@body)
         (when ,download (setf (symbol-value ,download) saved))))))
