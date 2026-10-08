;;;; tools/generations-tool.lisp -- model-facing checkpoint and recovery controls.

(in-package :cl-agent)

(define-tool list-generations (args)
    (:description "List retained, runtime-compatible SBCL image generations. Each entry shows its ID, publication status, creation time, and committed mutation IDs. The selected entry is the one recorded for recovery boot."
     :parameters (jobj "type" "object" "properties" (jobj) "required" :empty-array))
  (let ((selected (selected-agent-generation))
        (generations (list-agent-generations)))
    (if generations
        (format nil "Selected: ~a~%~{~a~^~%~}"
                (if selected (sbcl-generations:generation-identifier selected) "none")
                (mapcar #'generation-summary generations))
        "No retained image generations.")))

(define-tool checkpoint-generation (args)
    (:description "Create a retained SBCL image checkpoint of the current agent. This is a whole-heap snapshot and is refused unless the caller is the only live Lisp thread; do not retry after that refusal while a UI, shell job, or worker is active. On success it returns a pending ID; the library verifies the saved core before selecting it for recovery."
     :effects (list :self-modify)
     :parameters (jobj "type" "object" "properties" (jobj) "required" :empty-array))
  (let ((generation (checkpoint-agent-generation)))
    (format nil "Checkpoint ~a is ~(~a~). It will be selected only after its saved core is verified."
            (sbcl-generations:generation-identifier generation)
            (sbcl-generations:generation-status generation))))

(define-tool rollback-generation (args)
    (:description "Select a retained, compatible image generation for recovery boot. This changes only the durable generation pointer; the current process is not replaced. Restart through the selected saved core after confirmation."
     :effects (list :self-modify)
     :parameters (jobj "type" "object"
                       "properties" (jobj "id" (jobj "type" "string"))
                       "required" (list "id")))
  (let ((id (jget args "id")))
    (handler-case
        (request-generation-rollback id)
      (sbcl-generations:rollback-requested ()
        (format nil "Generation ~a is selected for recovery boot; the current process remains unchanged." id)))))
