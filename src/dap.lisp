;;;; dap.lisp -- owned Debug Adapter Protocol sessions via Daphne.

(in-package :cl-agent)

(defclass dap-connection ()
  ((name :initarg :name :reader dap-connection-name)
   (session :initarg :session :reader dap-connection-session)
   (transport :initarg :transport :reader dap-connection-transport)
   (command :initarg :command :reader dap-connection-command)))

(defvar *dap-connections* (make-hash-table :test #'equal))

(defun connect-dap-adapter (name program arguments &key directory environment)
  "Start, initialize, and own one Daphne DAP adapter connection."
  (when (gethash name *dap-connections*) (disconnect-dap-adapter name))
  (multiple-value-bind (session transport)
      (daphne:start-adapter program arguments :directory directory :environment environment)
    (handler-case
        (progn
          (daphne:session-initialize session)
          (setf (gethash name *dap-connections*)
                (make-instance 'dap-connection :name name :session session :transport transport
                               :command (cons program arguments)))
          (publish-component :dap-connection name :owner (format nil "dap:~a" name)
                             :origin (list :dap program) :metadata (list :command (cons program arguments)))
          session)
      (error (condition) (daphne:session-close session condition) (error condition)))))

(defun disconnect-dap-adapter (name)
  (let ((connection (gethash name *dap-connections*)))
    (when connection
      (daphne:session-close (dap-connection-session connection))
      (remhash name *dap-connections*)
      (unpublish-component :dap-connection name)
      t)))

(defun list-dap-connections ()
  (loop for name being the hash-keys of *dap-connections* using (hash-value connection)
        collect (list :name name :command (dap-connection-command connection)
                      :state (daphne:session-state (dap-connection-session connection)))))
