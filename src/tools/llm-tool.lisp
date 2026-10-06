;;;; llm-tool.lisp -- let the agent obtain an independent second opinion.
;;;;
;;;; This deliberately makes a fresh, tool-free request.  Its answer is fed
;;;; back only as a tool result, so it cannot alter the main conversation or
;;;; recursively execute tools.  MODEL is optional; when supplied the
;;;; provider is cloned with the same endpoint and credentials, but the main
;;;; session continues using its original model.

(in-package :cl-agent)

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
