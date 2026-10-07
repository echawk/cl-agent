;;;; tools/components-tool.lisp -- model-facing read-only reflection tools.

(in-package :cl-agent)

(define-tool list-components (args)
    (:description "List active cl-agent components (tools, providers, frontends, hooks, commands, skills, and MCP connections). Optionally filter by component kind such as tool or provider. This only inspects the local agent."
     :parameters (jobj "type" "object"
                        "properties" (jobj "kind" (jobj "type" "string"))
                        "required" :empty-array))
  (let* ((kind-text (jget args "kind"))
         (kind (and (stringp kind-text) (intern (string-upcase kind-text) :keyword)))
         (components (list-components :kind kind)))
    (if components
        (format nil "~{~a~^~%~}" (mapcar #'component-summary components))
        (if kind-text
            (format nil "No active components of kind ~a." kind-text)
            "No active components."))))

(define-tool describe-component (args)
    (:description "Describe one active component by its stable ID, for example tool:read-file or provider:ollama. Returns provenance, owner, version, declared effects, dependencies, and metadata."
     :parameters (jobj "type" "object"
                        "properties" (jobj "id" (jobj "type" "string"))
                        "required" (list "id")))
  (let ((descriptor (describe-component (jget args "id"))))
    (if descriptor
        (with-output-to-string (out)
          (let ((*print-pretty* t)) (pprint (component->plist descriptor) out)))
        (format nil "No active component named ~s." (jget args "id")))))
