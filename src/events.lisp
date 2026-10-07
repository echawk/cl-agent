;;;; events.lisp -- small, in-memory observation stream.

(in-package :cl-agent)

(defstruct agent-event
  "A typed observation emitted by the running agent.  Events deliberately do
not control execution; hooks remain the interception mechanism."
  id time kind component payload)

(defvar *event-sequence* 0)
(defvar *event-subscribers* nil
  "Functions called with each AGENT-EVENT.  Subscribers are observers only.")

(defun emit-event (kind &key component payload)
  "Publish a small in-memory event and return it.

Subscriber failures are isolated: observability must not change agent control
flow.  Durable event storage is intentionally a later layer."
  (let ((event (make-agent-event :id (incf *event-sequence*)
                                 :time (get-universal-time)
                                 :kind kind :component component :payload payload)))
    (dolist (subscriber *event-subscribers*)
      (handler-case (funcall subscriber event)
        (error (condition)
          (format *error-output* "~&[event subscriber] error: ~a~%" condition))))
    event))

(defun subscribe-events (function)
  "Add FUNCTION to the in-memory event subscribers and return it."
  (pushnew function *event-subscribers* :test #'eq)
  function)

(defun unsubscribe-events (function)
  "Remove FUNCTION from the in-memory event subscribers."
  (setf *event-subscribers* (remove function *event-subscribers* :test #'eq))
  function)
