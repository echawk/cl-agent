;;;; providers/xai.lisp -- xAI's Grok models, via their OpenAI-compatible
;;;; endpoint (https://docs.x.ai).

(in-package :cl-agent)

(defclass xai-provider (openai-compatible-provider)
  ()
  (:default-initargs :base-url "https://api.x.ai/v1")
  (:documentation "xAI (Grok). OpenAI-compatible wire format."))

(defmethod provider-default-model ((provider xai-provider)) "grok-4-fast")
(defmethod provider-display-name ((provider xai-provider)) "xAI")
(defmethod provider-api-key-env-var ((provider xai-provider)) "XAI_API_KEY")

(defmethod provider-context-window ((provider xai-provider))
  (let ((model (provider-model provider)))
    (cond
      ((and (stringp model) (search "grok-4" model)) 256000)
      ((and (stringp model) (search "grok-3" model)) 131072)
      ((and (stringp model) (search "grok-2" model)) 131072)
      (t nil))))

(register-provider-class :xai 'xai-provider)
