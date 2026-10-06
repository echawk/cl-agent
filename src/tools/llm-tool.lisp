;;;; llm-tool.lisp -- let the agent obtain an independent second opinion.
;;;;
;;;; This deliberately makes a fresh, tool-free request.  Its answer is fed
;;;; back only as a tool result, so it cannot alter the main conversation or
;;;; recursively execute tools.  MODEL is optional; when supplied the
;;;; provider is cloned with the same endpoint and credentials, but the main
;;;; session continues using its original model.

(in-package :cl-agent)

;; REPL.LISP defines and documents this dynamic session binding later in the
;; ASDF load order. Declare it here so tool compilation preserves special
;; binding semantics rather than treating it as an accidental global.
(defvar *current-session*)

(define-tool discover-tools (args)
    (:description "Search the full session tool catalog and enable a small matching set for later tool-call rounds. Use this in plan mode when the current tools do not cover the task. Search by a concise capability or name, such as \"git\", \"MCP\", \"Lisp\", or \"extension\"."
     :parameters (jobj "type" "object"
                       "properties" (jobj "query" (jobj "type" "string" "description" "Capability or tool-name fragment to search for.")
                                          "limit" (jobj "type" "integer" "description" "Maximum matching tools to enable; constrained by the remaining session tool budget."))
                       "required" (list "query")))
  (unless *current-session*
    (error "discover-tools is available only while an agent session is running"))
  (let* ((query (jget args "query"))
         (limit (jget args "limit" 5)))
    (unless (and (stringp query) (plusp (length (string-trim " " query))))
      (error "discover-tools requires a non-empty string query"))
    (unless (and (integerp limit) (plusp limit))
      (error "discover-tools limit must be a positive integer"))
    (let* ((remaining (max 0 (- (session-orchestration-tool-limit *current-session*)
                                (length (session-tools *current-session*)))))
           (needle (string-downcase query))
           (matches (loop for tool in (session-tool-catalog *current-session*)
                          when (or (search needle (string-downcase (tool-name tool)))
                                   (search needle (string-downcase (tool-description tool))))
                            collect tool))
           (selected (subseq matches 0 (min limit remaining (length matches))))
           (newly-enabled (session-enable-tools *current-session* (mapcar #'tool-name selected))))
      (if selected
          (progn
            (ui-system (session-frontend *current-session*)
                       (format nil "[tools] Discovery enabled: ~{~a~^, ~}." (mapcar #'tool-name newly-enabled)))
            (format nil "Enabled matching tools for the next request:~%~{~{~a — ~a~}~^~%~}"
                    (mapcar (lambda (tool) (list (tool-name tool) (tool-description tool))) selected)))
          (format nil "No tools in this session match ~s." query)))))

(define-tool list-models (args)
    (:description "List models available from the current provider by calling its /models endpoint. Use this before ask-llm when you need to choose a different model; pass an exact returned identifier as ask-llm's model argument."
     :parameters (jobj "type" "object" "properties" (jobj) "required" :empty-array))
  (unless *current-session*
    (error "list-models is available only while an agent session is running"))
  (let ((models (provider-list-models (session-provider *current-session*))))
    (if models
        (format nil "Available models:~%~{~a~^~%~}" models)
        "This provider does not expose a /models endpoint.")))

(define-tool ask-llm (args)
    (:description "Ask an independent, tool-free LLM instance for advice, research synthesis, planning, critique, or a draft. Required prompt is the question/task. Optional system_prompt gives that instance precise instructions. Optional model selects an exact model identifier from list-models; it does not change the main conversation's model."
     :parameters (jobj "type" "object"
                       "properties" (jobj "prompt" (jobj "type" "string" "description" "The independent request to make.")
                                          "system_prompt" (jobj "type" "string" "description" "Optional instructions for the independent instance.")
                                          "model" (jobj "type" "string" "description" "Optional exact model ID returned by list-models."))
                       "required" (list "prompt")))
  (unless *current-session*
    (error "ask-llm is available only while an agent session is running"))
  (let ((prompt (jget args "prompt"))
        (system (jget args "system_prompt"))
        (model (jget args "model")))
    (unless (and (stringp prompt) (plusp (length (string-trim " " prompt))))
      (error "ask-llm requires a non-empty string prompt"))
    (or (session-complete prompt :system system :model model)
        "The independent LLM returned no text.")))
