;;;; providers/ollama.lisp -- a local Ollama server. The shortest
;;;; provider in this project: Ollama exposes an OpenAI-compatible
;;;; /v1/chat/completions endpoint and needs no API key at all, so this
;;;; file is nothing but naming a default URL and model.
;;;;
;;;; This is also the provider t/test-ollama-integration.lisp exercises
;;;; end-to-end (real HTTP, real small model) via `make test-ollama`.

(in-package :cl-agent)

(defclass ollama-provider (openai-compatible-provider)
  ()
  (:default-initargs :base-url "http://localhost:11434/v1")
  (:documentation "A local Ollama server (https://ollama.com). No API
key required; CL_AGENT_OLLAMA_BASE_URL or :base-url in config can
point this at a non-default host/port."))

(defmethod provider-default-model ((provider ollama-provider)) "qwen2.5:0.5b")
(defmethod provider-display-name ((provider ollama-provider)) "Ollama")
;; Deliberately no PROVIDER-API-KEY-ENV-VAR method: the LLM-PROVIDER
;; default (NIL) is correct here, so MAKE-PROVIDER never demands a key.

(register-provider-class :ollama 'ollama-provider)
