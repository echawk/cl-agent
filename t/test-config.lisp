(in-package :cl-agent)

(defmacro with-temp-config-dir ((&optional (var '*config-directory*)) &body body)
  "Rebind *CONFIG-DIRECTORY* to a fresh temp directory for the extent
of BODY, so config/extensions tests never touch the user's real
~/.config/cl-agent/."
  `(let ((,var (merge-pathnames (format nil "cl-agent-test-~a/" (gensym)) (uiop:temporary-directory))))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree ,var :validate t)))))

(deftest load-user-config-missing-file-returns-nil ()
  (with-temp-config-dir ()
    (check-equal (load-user-config) nil)))

(deftest load-user-config-reads-plist ()
  (with-temp-config-dir ()
    (ensure-config-directory)
    (with-open-file (out (config-file-path) :direction :output :if-exists :supersede)
      (prin1 '(:provider :ollama :model "m1") out))
    (let ((config (load-user-config)))
      (check-equal (config-value config :provider) :ollama)
      (check-equal (config-value config :model) "m1")
      (check-equal (config-value config :missing-key "fallback") "fallback"))))

(deftest mcp-server-specs-accepts-one-server-plist-for-backward-compatibility ()
  (let ((spec '(:name "demo" :command ("demo-server" "--stdio"))))
    (check-equal (mcp-server-specs spec) (list spec))
    (check-equal (mcp-server-specs (list spec)) (list spec))))

(deftest load-user-config-does-not-eval-reader-macros ()
  (with-temp-config-dir ()
    (ensure-config-directory)
    (with-open-file (out (config-file-path) :direction :output :if-exists :supersede)
      (write-string "(:model #.(error \"should never run\"))" out))
    (check-condition error (load-user-config)
                      "#. is rejected (as a read error, with *read-eval* nil) rather than executed")))

(deftest ensure-config-directory-creates-agent-state-subdirs ()
  (with-temp-config-dir ()
    (ensure-config-directory)
    (check (probe-file (extensions-directory)))
    (check (probe-file (scratch-directory)))))

(deftest context-compaction-threshold-config-default-and-override ()
  (check-equal (config-value '(:provider :ollama) :context-compaction-threshold 0.8) 0.8)
  (check-equal (config-value '(:context-compaction-threshold 0.5)
                             :context-compaction-threshold 0.8)
               0.5))
