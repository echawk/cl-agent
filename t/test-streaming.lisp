;;;; t/test-streaming.lisp -- tests for CHAT-STREAM (provider.lisp) and
;;;; its real implementation, PARSE-SSE-STREAM (providers/openai-
;;;; compatible.lisp). The SSE transcripts below are verbatim shapes
;;;; captured from a real Ollama server (see providers/openai-
;;;; compatible.lisp's header comment on PARSE-SSE-STREAM) fed through
;;;; MAKE-STRING-INPUT-STREAM -- no network needed, since PARSE-SSE-
;;;; STREAM only needs something READ-LINE works on.

(in-package :cl-agent)

(defun sse-stream (&rest lines)
  "A character input stream yielding LINES, each followed by a blank
line (as real SSE framing does), for feeding to PARSE-SSE-STREAM."
  (make-string-input-stream (format nil "~{~a~%~%~}" lines)))

(deftest parse-sse-stream-accumulates-plain-text-deltas ()
  (let ((chunks nil))
    (let ((message
            (parse-sse-stream
             (sse-stream
              "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"Sure\"},\"finish_reason\":null}]}"
              "data: {\"choices\":[{\"delta\":{\"content\":\"!\"},\"finish_reason\":null}]}"
              "data: {\"choices\":[{\"delta\":{\"content\":\" done.\"},\"finish_reason\":null}]}"
              "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"
              "data: [DONE]")
             (lambda (chunk) (push chunk chunks)))))
      (check-equal (getf message :content) "Sure! done.")
      (check-equal (getf message :tool-calls) nil)
      (check-equal (nreverse chunks) '("Sure" "!" " done.")
                   "on-delta fired once per non-empty content fragment, in order"))))

(deftest parse-sse-stream-single-chunk-tool-call ()
  ;; The shape actually observed from Ollama for a short argument
  ;; string: id/name/arguments all present in one delta.
  (let ((message
          (parse-sse-stream
           (sse-stream
            "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"call_1\",\"index\":0,\"type\":\"function\",\"function\":{\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":\\\"echo hi\\\"}\"}}]},\"finish_reason\":null}]}"
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}"
            "data: [DONE]")
           (lambda (chunk) (declare (ignore chunk))))))
    (check-equal (length (getf message :tool-calls)) 1)
    (let ((tc (first (getf message :tool-calls))))
      (check-equal (getf tc :id) "call_1")
      (check-equal (getf tc :name) "shell")
      (check-equal (jget (getf tc :arguments) "command") "echo hi"))))

(deftest parse-sse-stream-multi-chunk-tool-call-arguments-concatenate ()
  ;; OpenAI's own API commonly splits a tool call's arguments across
  ;; many small chunks -- id/name only on the first one for that index.
  (let ((message
          (parse-sse-stream
           (sse-stream
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_9\",\"type\":\"function\",\"function\":{\"name\":\"shell\",\"arguments\":\"\"}}]}}]}"
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"comm\"}}]}}]}"
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"and\\\":\\\"ls\\\"}\"}}]}}]}"
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}"
            "data: [DONE]")
           (lambda (chunk) (declare (ignore chunk))))))
    (let ((tc (first (getf message :tool-calls))))
      (check-equal (getf tc :id) "call_9")
      (check-equal (getf tc :name) "shell")
      (check-equal (jget (getf tc :arguments) "command") "ls"))))

(deftest parse-sse-stream-multiple-parallel-tool-calls-keyed-by-index ()
  (let ((message
          (parse-sse-stream
           (sse-stream
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"type\":\"function\",\"function\":{\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":\\\"a\\\"}\"}},{\"index\":1,\"id\":\"b\",\"type\":\"function\",\"function\":{\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":\\\"b\\\"}\"}}]}}]}"
            "data: [DONE]")
           (lambda (chunk) (declare (ignore chunk))))))
    (check-equal (length (getf message :tool-calls)) 2)
    (check-equal (mapcar (lambda (tc) (jget (getf tc :arguments) "command")) (getf message :tool-calls))
                 '("a" "b")
                 "returned in index order, not hash-table iteration order")))

(deftest parse-sse-stream-captures-usage-when-present ()
  (let ((message
          (parse-sse-stream
           (sse-stream
            "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}"
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"
            "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":31,\"completion_tokens\":10,\"total_tokens\":41}}"
            "data: [DONE]")
           (lambda (chunk) (declare (ignore chunk))))))
    (check-equal (getf (getf message :usage) :prompt-tokens) 31)
    (check-equal (getf (getf message :usage) :completion-tokens) 10)
    (check-equal (getf (getf message :usage) :total-tokens) 41)))

(deftest parse-sse-stream-no-usage-chunk-leaves-usage-nil ()
  (let ((message (parse-sse-stream (sse-stream "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}" "data: [DONE]")
                                    (lambda (chunk) (declare (ignore chunk))))))
    (check-equal (getf message :usage) nil)))

(deftest parse-sse-stream-no-content-at-all-is-nil-not-empty-string ()
  ;; A pure tool-call turn has no text content -- :CONTENT should be
  ;; NIL (consistent with the non-streaming parser), not "".
  (let ((message (parse-sse-stream (sse-stream "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}" "data: [DONE]")
                                    (lambda (chunk) (declare (ignore chunk))))))
    (check-equal (getf message :content) nil)))

(deftest sse-data-line-payload-strips-prefix-and-cr ()
  (check-equal (sse-data-line-payload (format nil "data: hello~a" #\return)) "hello")
  (check-equal (sse-data-line-payload "data: hello") "hello")
  (check-equal (sse-data-line-payload "") nil)
  (check-equal (sse-data-line-payload ": keep-alive comment") nil))

(deftest build-stream-request-body-sets-stream-true-and-nothing-else-new ()
  (let* ((p (make-provider :ollama))
         (streaming (build-stream-request-body p (list (list :role "user" :content "hi")) nil))
         (plain (build-request-body p (list (list :role "user" :content "hi")) nil)))
    (check-equal (jget streaming "stream") t)
    (check-equal (jget plain "stream" :absent) :absent)
    (check-equal (jget streaming "model") (jget plain "model"))))

;;; --- CHAT-STREAM's default (non-streaming-provider) fallback ---

(deftest chat-stream-default-method-calls-on-delta-once-with-full-text ()
  (let ((chunks nil))
    ;; ANTHROPIC-PROVIDER doesn't override CHAT-STREAM, so this
    ;; exercises LLM-PROVIDER's default method for real, via CHAT --
    ;; stub CHAT itself rather than hit the network.
    (let ((p (make-instance 'anthropic-provider :api-key "x")))
      (let ((orig (symbol-function 'chat)))
        (unwind-protect
             (progn
               (setf (symbol-function 'chat)
                     (lambda (provider messages tools)
                       (declare (ignore provider messages tools))
                       (list :role "assistant" :content "whole thing at once" :tool-calls nil)))
               (let ((message (chat-stream p nil nil (lambda (chunk) (push chunk chunks)))))
                 (check-equal (getf message :content) "whole thing at once")
                 (check-equal chunks '("whole thing at once"))))
          (setf (symbol-function 'chat) orig))))))

(deftest chat-stream-default-method-does-not-call-on-delta-when-content-nil ()
  (let ((p (make-instance 'anthropic-provider :api-key "x"))
        (calls 0)
        (orig (symbol-function 'chat)))
    (unwind-protect
         (progn
           (setf (symbol-function 'chat)
                 (lambda (provider messages tools)
                   (declare (ignore provider messages tools))
                   (list :role "assistant" :content nil :tool-calls (list (list :id "1" :name "x" :arguments (jobj))))))
           (chat-stream p nil nil (lambda (chunk) (declare (ignore chunk)) (incf calls)))
           (check-equal calls 0))
      (setf (symbol-function 'chat) orig))))
