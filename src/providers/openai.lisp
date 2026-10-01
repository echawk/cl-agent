;;;; providers/openai.lisp -- api.openai.com, the reference
;;;; implementation of the wire format openai-compatible.lisp targets.

(in-package :cl-agent)

(defclass openai-provider (openai-compatible-provider)
  ()
  (:default-initargs :base-url "https://api.openai.com/v1")
  (:documentation "OpenAI's own API. Use CL_AGENT_OPENAI_MODEL or
:model in config to pick a specific model; see
https://platform.openai.com/docs/models for current names."))

(defmethod provider-default-model ((provider openai-provider)) "gpt-4.1-mini")
(defmethod provider-display-name ((provider openai-provider)) "OpenAI")
(defmethod provider-api-key-env-var ((provider openai-provider)) "OPENAI_API_KEY")

(register-provider-class :openai 'openai-provider)
