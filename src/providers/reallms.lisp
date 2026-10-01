;;;; providers/reallms.lisp -- Indiana University's REALLMS gateway.
;;;; See https://servicenow.iu.edu/kb?id=kb_article_view&sysparm_article=KB0027272
;;;; for how to obtain an API key. REALLMS speaks the OpenAI chat/
;;;; completions format, so there is almost nothing to this file.

(in-package :cl-agent)

(defclass reallms-provider (openai-compatible-provider)
  ()
  (:default-initargs :base-url "https://reallms.rescloud.iu.edu/direct/v1")
  (:documentation "IU's REALLMS gateway. This is the provider the
original task.txt assignment anchors on, and the default if nothing
else is configured -- but it is in no way special in the code: it is
exactly as pluggable as every other provider in providers/, and
swapping it out is a one-line config change (see README.md)."))

(defmethod provider-default-model ((provider reallms-provider)) "Qwen3-Coder-Next")
(defmethod provider-display-name ((provider reallms-provider)) "REALLMS")
(defmethod provider-api-key-env-var ((provider reallms-provider)) "REALLMS_API_KEY")

(register-provider-class :reallms 'reallms-provider)
