;;;; environments.lisp -- development environments in containers (podman):
;;;; "set up a modern Haskell environment on Alpine and use it for our work".
;;;;
;;;; An environment is a name, a Containerfile and a check command, kept in
;;;; config/environments/<name>/ so it can always be rebuilt.  The model
;;;; writes the Containerfile, builds it (ENVIRONMENT-BUILD), sees the check
;;;; pass or the build log fail, and fixes and rebuilds until it works.
;;;;
;;;; A project then uses one (ENVIRONMENT-USE), remembered per project (the
;;;; git repository, as memory.lisp names it), in one of two modes:
;;;;   :persistent  one container per project, kept running with the project
;;;;                mounted at its own path; commands run in it by exec, so
;;;;                what they install or cache stays (labels say whose it is);
;;;;   :throwaway   a fresh container for every command (run --rm).
;;;; While a project uses one, the shell tools run their commands in it
;;;; (ENVIRONMENT-WRAP-COMMAND), in the same directory.
;;;;
;;;; podman is driven through its command line with JSON output.  On macOS
;;;; it runs in a VM ("machine"): PODMAN-CONNECTION picks a running one, the
;;;; default when it runs, or CL_AGENT_PODMAN_CONNECTION; on Linux, none.

(in-package :cl-agent)

(setinka:define-setting :environment-build-seconds (setinka:integer-setting :registry *agent-setting-registry*)
  :label "Environment build limit" :group :tools :scope :durable
  :documentation "The longest an environment's image build may take, in seconds."
  :environment "CL_AGENT_ENVIRONMENT_BUILD_SECONDS" :minimum 60 :maximum 21600 :default 2400)

;;; --- podman ---

(defun podman-program ()
  (or (structural-program-on-path "podman")
      (error "podman is not installed: brew install podman (or your distribution's podman), then podman machine init && podman machine start.")))

(defvar *podman-connection* :unknown
  "The podman connection to use (a machine name), NIL for the local one;
:UNKNOWN until first looked up.")

(defun podman-machines ()
  "podman's machines (macOS, Windows) as plists (:name :running :default)."
  (multiple-value-bind (out err status)
      (uiop:run-program (list (namestring (podman-program)) "machine" "list" "--format" "json")
                        :output :string :error-output :string :ignore-error-status t)
    (declare (ignore err))
    (when (zerop status)
      (mapcar (lambda (machine)
                (list :name (jget machine "Name") :running (and (jget machine "Running") t)
                      :default (and (jget machine "Default") t)))
              (let ((decoded (ignore-errors (json-decode out)))) (and (listp decoded) decoded))))))

(defun podman-connection ()
  "The connection podman commands use: CL_AGENT_PODMAN_CONNECTION; else on a
machine-based host the default machine when it runs, else any running one."
  (when (eq *podman-connection* :unknown)
    (setf *podman-connection*
          (let ((configured (uiop:getenv "CL_AGENT_PODMAN_CONNECTION")))
            (if (and configured (plusp (length configured)))
                configured
                (let ((machines (podman-machines)))
                  (when machines
                    (let ((running (remove-if-not (lambda (m) (getf m :running)) machines)))
                      (unless running
                        (setf *podman-connection* :unknown)
                        (error "No podman machine is running: podman machine start ~a"
                               (getf (or (find-if (lambda (m) (getf m :default)) machines) (first machines)) :name)))
                      ;; The default machine's connection is the machine's name.
                      (getf (or (find-if (lambda (m) (getf m :default)) running) (first running)) :name))))))))
  *podman-connection*)

(defun podman-command (arguments)
  "The podman command line for ARGUMENTS, on the right connection."
  (append (list (namestring (podman-program)))
          (let ((connection (podman-connection))) (and connection (list "--connection" connection)))
          arguments))

(defun run-with-deadline (argv seconds &key input)
  "Run ARGV, stopping it after SECONDS.  Its output is read as it comes (a
build's long log never fills the pipe).  Returns (values output
error-output status), status 124 when it ran out of time."
  (let* ((process (uiop:launch-program argv :output :stream :error-output :stream
                                            :input (if input :stream nil)))
         (out "") (err "") (timed-out nil)
         ;; Unreadable output (not UTF-8) is noted, not the reader thread's end.
         (readers (flet ((reader (stream setter name)
                           (bt:make-thread (lambda ()
                                             (funcall setter
                                                      (handler-case (uiop:slurp-stream-string stream)
                                                        (serious-condition (c) (format nil "[unreadable output: ~a]" c)))))
                                           :name name)))
                    (list (reader (uiop:process-info-output process) (lambda (text) (setf out text)) "run-with-deadline output")
                          (reader (uiop:process-info-error-output process) (lambda (text) (setf err text)) "run-with-deadline errors")))))
    (when input
      (let ((stream (uiop:process-info-input process)))
        (write-string input stream)
        (close stream)))
    (loop with deadline = (+ (get-internal-real-time) (* seconds internal-time-units-per-second))
          while (uiop:process-alive-p process)
          do (when (> (get-internal-real-time) deadline)
               (setf timed-out t)
               (uiop:terminate-process process :urgent t))
             (sleep 0.1))
    (let ((status (uiop:wait-process process)))
      (mapc #'bt:join-thread readers)
      (values out err (if timed-out 124 (or status 0))))))

(defun podman (arguments &key (timeout 600) input)
  "Run podman with ARGUMENTS, for at most TIMEOUT seconds.  Returns (values
output error-output status)."
  (run-with-deadline (podman-command arguments) timeout :input input))

(defun podman-json (arguments)
  (multiple-value-bind (out err status) (podman arguments)
    (unless (zerop status) (error "podman ~a failed: ~a" (first arguments) (string-trim '(#\Newline) err)))
    (let ((decoded (json-decode out))) (if (listp decoded) decoded (list decoded)))))

;;; --- environments: their definitions ---

(defun environment-directory (name)
  (merge-pathnames (format nil "environments/~a/" name) *config-directory*))

(defun normalize-environment-name (name)
  (let ((name (and (stringp name) (string-downcase (string-trim " " name)))))
    (unless (and name (plusp (length name)) (<= (length name) 48)
                 (alpha-char-p (char name 0))
                 (every (lambda (c) (or (alphanumericp c) (member c '(#\- #\_)))) name))
      (error "An environment's name is a letter, then letters, digits, - and _ (at most 48)."))
    name))

(defun environment-image (name) (format nil "localhost/cl-agent-env-~a:latest" name))

(defun environment-definition (name)
  "NAME's definition: (:name :containerfile :check :built :check-output), or NIL."
  (let* ((name (normalize-environment-name name))
         (directory (environment-directory name))
         (containerfile (merge-pathnames "Containerfile" directory)))
    (when (probe-file containerfile)
      (let ((meta (ignore-errors (with-standard-io-syntax
                                   (let ((*read-eval* nil))
                                     (read-from-string (uiop:read-file-string (merge-pathnames "environment.sexp" directory))))))))
        (list* :name name :containerfile (uiop:read-file-string containerfile)
               (and (listp meta) meta))))))

(defun list-environments ()
  (sort (remove nil (mapcar (lambda (directory)
                              (ignore-errors (environment-definition (car (last (pathname-directory directory))))))
                            (uiop:subdirectories (merge-pathnames "environments/" *config-directory*))))
        #'string< :key (lambda (environment) (getf environment :name))))

(defun save-environment-meta (name meta)
  (let ((path (merge-pathnames "environment.sexp" (environment-directory name))))
    (ensure-directories-exist path)
    (write-string-atomically path (with-standard-io-syntax (prin1-to-string meta)))))

(defun tail-lines (text n)
  (let ((lines (uiop:split-string (string-right-trim '(#\Newline) text) :separator '(#\Newline))))
    (format nil "~{~a~^~%~}" (last lines n))))

(defun environment-build (name containerfile &key check)
  "Define environment NAME by CONTAINERFILE and build its image; then run
CHECK (a shell command) in it.  Returns (values ok-p report)."
  (let* ((name (normalize-environment-name name))
         (directory (environment-directory name))
         (file (merge-pathnames "Containerfile" directory)))
    (unless (and (stringp containerfile) (search "FROM" containerfile :test #'char-equal))
      (error "Give a Containerfile (it starts FROM an image, e.g. FROM docker.io/library/alpine:3.20)."))
    (ensure-directories-exist file)
    (write-string-atomically file containerfile)
    (let ((started (get-universal-time)))
      (multiple-value-bind (out err status)
          (podman (list "build" "--tag" (environment-image name) "--file" (uiop:native-namestring file)
                        "--label" (format nil "cl-agent.environment=~a" name)
                        (uiop:native-namestring directory))
                  :timeout (current-agent-setting :environment-build-seconds 2400))
        (if (not (zerop status))
            (progn
              (save-environment-meta name (list :check check :built nil :error (tail-lines err 40)))
              (values nil (format nil "The build of ~a failed (podman exited ~d). The end of its log:~%~a~%~%Fix the Containerfile and build again."
                                  name status (tail-lines (concatenate 'string out err) 40))))
            (multiple-value-bind (check-out check-status)
                (if (and (stringp check) (plusp (length check)))
                    (multiple-value-bind (o e s) (podman (list "run" "--rm" (environment-image name) "sh" "-lc" check))
                      (values (concatenate 'string o e) s))
                    (values "" 0))
              (save-environment-meta name (list :check check :built (get-universal-time)
                                                :check-output (tail-lines check-out 20) :check-status check-status))
              (values (zerop check-status)
                      (format nil "Built ~a (~,1f minutes).~@[~%Check: ~a~%~a~]~:[~%~%The check failed (exit ~d): fix the Containerfile and build again.~;~]"
                              name (/ (- (get-universal-time) started) 60.0)
                              (and (plusp (length (or check ""))) check) (tail-lines check-out 20)
                              (zerop check-status) check-status))))))))

;;; --- which environment a project uses ---

(defun environment-uses-path () (merge-pathnames "environments/projects.sexp" *config-directory*))

(defun environment-uses ()
  "Each project's environment: an alist project-root -> (:name :mode)."
  (let ((path (environment-uses-path)))
    (and (probe-file path)
         (ignore-errors (with-standard-io-syntax
                          (let ((*read-eval* nil)) (read-from-string (uiop:read-file-string path))))))))

(defun project-environment (&optional (root (memory-project-root)))
  "The environment the project at ROOT uses: (:name :mode), or NIL."
  (cdr (assoc root (environment-uses) :test #'string=)))

(defun environment-use (name &key (mode :persistent) (root (memory-project-root)))
  "Make the project at ROOT run its commands in environment NAME (NIL:
none again).  Returns the new choice."
  (let ((choice (and name (list :name (normalize-environment-name name) :mode mode))))
    (when choice
      (unless (environment-definition name) (error "There is no environment ~a: define it first." name)))
    (let ((uses (remove root (environment-uses) :key #'car :test #'string=)))
      (when choice (push (cons root choice) uses))
      (let ((path (environment-uses-path)))
        (ensure-directories-exist path)
        (write-string-atomically path (with-standard-io-syntax (prin1-to-string uses)))))
    choice))

;;; --- containers ---

(defun environment-container-name (name root)
  (format nil "cl-agent-~a-~a" name (subseq (structural-file-revision root) 0 8)))

(defun environment-container-status (container)
  (multiple-value-bind (out err status) (podman (list "inspect" "--format" "{{.State.Status}}" container))
    (declare (ignore err))
    (and (zerop status) (string-trim '(#\Newline #\Space) out))))

(defun ensure-environment-container (name root)
  "The running persistent container of environment NAME for the project at
ROOT, started (with ROOT mounted at its own path) if need be."
  (let ((container (environment-container-name name root)))
    (let ((state (environment-container-status container)))
      (cond ((equal state "running"))
            (state (multiple-value-bind (out err status) (podman (list "start" container))
                     (declare (ignore out))
                     (unless (zerop status) (error "Could not start ~a: ~a" container err))))
            (t (multiple-value-bind (out err status)
                   (podman (list "run" "--detach" "--name" container
                                 "--label" (format nil "cl-agent.environment=~a" name)
                                 "--label" (format nil "cl-agent.project=~a" root)
                                 "--volume" (format nil "~a:~a" (string-right-trim "/" root) (string-right-trim "/" root))
                                 "--workdir" root
                                 (environment-image name) "sleep" "infinity"))
                 (declare (ignore out))
                 (unless (zerop status) (error "Could not start environment ~a: ~a" name (string-trim '(#\Newline) err)))))))
    container))

(defun environment-wrap-command (command &key (directory (uiop:native-namestring (uiop:getcwd)))
                                              (root (memory-project-root)))
  "COMMAND (a shell command) as the command line that runs it in the
project's environment, in DIRECTORY, or NIL when the project uses none."
  (let ((choice (project-environment root)))
    (when choice
      (destructuring-bind (&key name mode) choice
        (if (eq mode :throwaway)
            (podman-command (list "run" "--rm" "--interactive"
                                  "--volume" (format nil "~a:~a" (string-right-trim "/" root) (string-right-trim "/" root))
                                  "--workdir" directory
                                  (environment-image name) "sh" "-lc" command))
            (podman-command (list "exec" "--interactive" "--workdir" directory
                                  (ensure-environment-container name root) "sh" "-lc" command)))))))

(defun environment-containers ()
  "cl-agent's environment containers: plists (:name :environment :project :state)."
  (mapcar (lambda (container)
            (let ((labels (jget container "Labels")))
              (list :name (first (jget container "Names"))
                    :environment (and (hash-table-p labels) (jget labels "cl-agent.environment"))
                    :project (and (hash-table-p labels) (jget labels "cl-agent.project"))
                    :state (jget container "State"))))
          (ignore-errors (podman-json (list "ps" "--all" "--format" "json" "--filter" "label=cl-agent.environment")))))

(defun environment-remove-container (name root)
  (podman (list "rm" "--force" (environment-container-name name root))))

;;; --- the tool ---

(defun describe-environments ()
  (let* ((root (memory-project-root))
         (choice (project-environment root))
         (containers (ignore-errors (environment-containers))))
    (format nil "This project (~a) uses: ~:[the host~;~:*~a~]~%Environments:~:[ none~;~:*~{~%  ~a~}~]~@[~%Containers:~{~%  ~a~}~]"
            root
            (and choice (format nil "~a (~(~a~))" (getf choice :name) (getf choice :mode)))
            (mapcar (lambda (environment)
                      (format nil "~a -- ~:[not built~;built~]~@[; check: ~a~]~@[ (failed)~]"
                              (getf environment :name) (getf environment :built) (getf environment :check)
                              (and (getf environment :check-status) (/= 0 (getf environment :check-status)))))
                    (list-environments))
            (mapcar (lambda (container)
                      (format nil "~a: ~a, ~a, for ~a" (getf container :name) (getf container :environment)
                              (getf container :state) (getf container :project)))
                    containers))))

(define-tool environment (args)
    (:description "Development environments in containers (podman), so work can happen in a toolchain the host lacks -- \"set up a modern Haskell environment on Alpine and use it\".
- define: name, containerfile (FROM an image; RUN the installs; e.g. FROM docker.io/library/alpine:3.20 + RUN apk add --no-cache ghc cabal), check (a command proving it works, e.g. \"ghc --version && cabal --version\"). Builds the image and runs the check; on failure shows the build log's end -- fix the Containerfile and define again until the check passes.
- use: name and mode -- persistent (default: one container for this project, kept running with the project mounted at its own path, so installs and caches stay) or throwaway (a fresh container per command). From then on the shell tools run every command in it, in the same directory. name \"none\" goes back to the host. Remembered for the project across sessions.
- run: command, in name (default: the project's environment) -- once, without switching.
- list: environments, the project's choice, the containers. show: an environment's Containerfile.
- stop: remove the project's persistent container (a fresh one starts on next use). delete: an environment and its image."
     :effects '(:process :write-workspace)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "action" (jobj "type" "string" "enum" (list "define" "use" "run" "list" "show" "stop" "delete"))
                 "name" (jobj "type" "string")
                 "containerfile" (jobj "type" "string" "description" "For define: the Containerfile text.")
                 "check" (jobj "type" "string" "description" "For define: a shell command that proves the environment works.")
                 "mode" (jobj "type" "string" "enum" (list "persistent" "throwaway"))
                 "command" (jobj "type" "string" "description" "For run: the shell command."))
           "required" (list "action")))
  (let ((action (or (jget args "action") "list"))
        (name (jget args "name")))
    (cond
      ((string= action "list") (describe-environments))
      ((string= action "define")
       (nth-value 1 (environment-build name (jget args "containerfile") :check (jget args "check"))))
      ((string= action "use")
       (if (member name '(nil "" "none" "host") :test #'equal)
           (progn (environment-use nil) "This project's commands run on the host again.")
           (let* ((mode (if (equal (jget args "mode") "throwaway") :throwaway :persistent))
                  (definition (or (environment-definition name) (error "There is no environment ~a: define it first." name))))
             (unless (getf definition :built) (error "~a is not built yet: define it (and see its check pass) first." name))
             (environment-use name :mode mode)
             (when (eq mode :persistent) (ensure-environment-container (getf definition :name) (memory-project-root)))
             (format nil "This project's commands now run in ~a (~(~a~)), the project mounted at ~a."
                     (getf definition :name) mode (memory-project-root)))))
      ((string= action "run")
       (let ((command (jget args "command")))
         (unless (stringp command) (error "Give the command."))
         (let* ((root (memory-project-root))
                (directory (uiop:native-namestring (uiop:getcwd)))
                (environment (or (and (stringp name) (plusp (length name)) (normalize-environment-name name))
                                 (getf (project-environment root) :name)
                                 (error "Give the environment's name (this project uses none)."))))
           (multiple-value-bind (out err status)
               (podman (if (equal environment (getf (project-environment root) :name))
                           (rest (environment-wrap-command command :directory directory :root root))
                           (list "run" "--rm" "--volume" (format nil "~a:~a" (string-right-trim "/" root) (string-right-trim "/" root))
                                 "--workdir" directory (environment-image environment) "sh" "-lc" command))
                       :timeout (current-agent-setting :shell-maximum-seconds 300))
             (format nil "Exit code: ~d~%~a~a" status out err)))))
      ((string= action "show")
       (let ((definition (or (environment-definition name) (error "There is no environment ~a." name))))
         (format nil "~a~@[~%Check: ~a~]" (getf definition :containerfile) (getf definition :check))))
      ((string= action "stop")
       (let ((choice (or (project-environment) (error "This project uses no environment."))))
         (environment-remove-container (getf choice :name) (memory-project-root))
         (format nil "Removed this project's ~a container; the next command starts a fresh one." (getf choice :name))))
      ((string= action "delete")
       (let ((name (normalize-environment-name name)))
         (dolist (root (mapcar #'car (remove name (environment-uses) :key (lambda (use) (getf (cdr use) :name)) :test-not #'equal)))
           (environment-use nil :root root)
           (ignore-errors (environment-remove-container name root)))
         (podman (list "rmi" "--force" (environment-image name)))
         (uiop:delete-directory-tree (environment-directory name) :validate t :if-does-not-exist :ignore)
         (format nil "Deleted environment ~a and its image." name)))
      (t (error "Unknown action ~s." action)))))
