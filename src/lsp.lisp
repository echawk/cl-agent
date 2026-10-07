;;;; lsp.lisp -- lazy, read-only Language Server Protocol access for agents.

(in-package :cl-agent)

(defparameter *lsp-manager* (make-instance 'cl-lsp:lsp-manager
                                            :client-name "cl-agent"
                                            :client-version "0.1.0")
  "The process-wide pool of lazy language-server clients.")

(defparameter *lsp-configuration-pathname* nil
  "Optional explicit path to the declarative cl-lsp configuration file.")

(defun lsp-configuration-path ()
  "Return the LSP configuration location, defaulting to config-dir/lsp.sexp."
  (or *lsp-configuration-pathname*
      (merge-pathnames "lsp.sexp" *config-directory*)))

(defun lsp-command-available-p (configuration)
  "Whether CONFIGURATION's executable can be found on PATH without launching it."
  (let ((command (cl-lsp:lsp-server-configuration-command configuration)))
    (or (probe-file command)
        (some (lambda (directory)
                (probe-file (merge-pathnames command
                                             (uiop:ensure-directory-pathname directory))))
              (uiop:split-string (or (uiop:getenv "PATH") "") :separator ":")))))

(defun initialize-lsp (&optional (path (lsp-configuration-path)) )
  "Read configured LSP servers and retain only executables available on PATH.

This deliberately does not start a server: LSP processes are launched only when
an agent asks a query about a matching file.  The returned values are the
available configurations and a list of unavailable server names."
  (cl-lsp:lsp-manager-close *lsp-manager*)
  (if (not (probe-file path))
      (progn
        (setf (cl-lsp:lsp-manager-configurations *lsp-manager*) nil
              (cl-lsp:lsp-manager-loaded-p *lsp-manager*) t)
        (values nil nil))
      (let* ((configured (cl-lsp:lsp-read-configurations path))
             (available (remove-if-not #'lsp-command-available-p configured))
             (unavailable (mapcar #'cl-lsp:lsp-server-configuration-name
                                  (remove-if #'lsp-command-available-p configured))))
        (setf (cl-lsp:lsp-manager-configurations *lsp-manager*) available
              (cl-lsp:lsp-manager-loaded-p *lsp-manager*) t)
        (values available unavailable))))

(defun ensure-lsp-initialized ()
  "Initialize the LSP catalog once, so tools can also be used outside MAIN."
  (unless (cl-lsp:lsp-manager-loaded-p *lsp-manager*)
    (initialize-lsp))
  *lsp-manager*)

(defun lsp-server-statuses ()
  "Return configured server status plists suitable for human/tool rendering."
  (ensure-lsp-initialized)
  (mapcar (lambda (configuration)
            (list :name (cl-lsp:lsp-server-configuration-name configuration)
                  :command (cl-lsp:lsp-server-configuration-command configuration)
                  :extensions (cl-lsp:lsp-server-configuration-extensions configuration)
                  :available (lsp-command-available-p configuration)))
          (cl-lsp:lsp-manager-configurations *lsp-manager*)))

(defun lsp-file-path (path)
  "Resolve PATH to an existing regular file for a language-server request."
  (file-tool-path path "LSP"))

(defun lsp-workspace-boundary (path)
  "Use the current project directory as LSP's root-search boundary.

For files outside it, fall back to the file's directory; this keeps a direct
agent request useful while never allowing a root walk above that directory."
  (let ((cwd (uiop:ensure-directory-pathname (truename (uiop:getcwd)))))
    (if (let ((root (namestring cwd)) (candidate (namestring path)))
          (and (<= (length root) (length candidate))
               (string= root candidate :end2 (length root))))
        cwd
        (uiop:pathname-directory-pathname path))))

(defun lsp-query-file (path operation &key line character query)
  "Synchronize PATH and run one capability-gated, read-only LSP query.
LINE and CHARACTER are zero-based UTF-16 coordinates; QUERY is required by
workspace-symbols.  Returns one independent result row per matching server."
  (let ((resolved (lsp-file-path path)))
    (cl-lsp:lsp-manager-map-file
     (ensure-lsp-initialized) resolved (lsp-workspace-boundary resolved)
     (lambda (client document)
       (cl-lsp:lsp-client-query
        client operation document
        :position (and (not (member operation '("document-symbols" "workspace-symbols")
                                   :test #'string=))
                       (cl-lsp:lsp-text-position (cl-lsp:lsp-document-text document) line character))
        :query query)))))

(defun lsp-file-diagnostics (path &key (wait-seconds 1))
  "Synchronize PATH and return push/pull diagnostic reports from matching servers."
  (let ((resolved (lsp-file-path path)))
    (cl-lsp:lsp-manager-map-file
     (ensure-lsp-initialized) resolved (lsp-workspace-boundary resolved)
     (lambda (client document)
       (cl-lsp:lsp-client-diagnostics client document :wait-seconds wait-seconds)))))

(defun close-lsp-servers ()
  "Shut down every lazy LSP subprocess and clear the live client pool."
  (cl-lsp:lsp-manager-close *lsp-manager*))
