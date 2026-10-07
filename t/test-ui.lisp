;;;; t/test-ui.lisp -- tests for the UI frontend protocol
;;;; (src/ui/frontend.lisp) and its three built-in implementations.
;;;;
;;;; The web frontend is tested with real HTTP requests against a real
;;;; (ephemeral-port, loopback-only) hunchentoot instance -- safe and
;;;; deterministic for CI, same reasoning as t/test-mcp.lisp's real
;;;; subprocess tests. The TUI frontend is tested only at the model
;;;; level (TUI:INIT/TUI:UPDATE on a TUI-CHAT-MODEL directly): actually
;;;; running TUI:RUN needs a real TTY, which isn't available (or
;;;; desirable to block on) under a test harness -- see UI-START's
;;;; graceful-failure handling in ui/tui.lisp, which is exactly what
;;;; lets this suite run under such a harness instead of hanging.

(in-package :cl-agent)

(deftest frontend-registry-knows-built-ins ()
  (dolist (name '(:cli :tui :web))
    (check (assoc name (list-frontends)) (format nil "~a is registered" name))))

(deftest make-frontend-unknown-name-signals ()
  (check-condition frontend-not-found (make-frontend :definitely-not-a-real-frontend)))

(deftest tool-call-summary-single-argument ()
  (check-equal (tool-call-summary "shell" (jobj "command" "echo hi")) "shell: echo hi"))

(deftest tool-call-summary-multiple-arguments ()
  (check-equal (tool-call-summary "connect-mcp-server" (jobj "name" "fs" "command" (list "npx" "-y")))
               (format nil "connect-mcp-server ~a" (json-encode (jobj "name" "fs" "command" (list "npx" "-y"))))))

(deftest agent-frontend-default-methods-print-to-stdout ()
  ;; AGENT-FRONTEND itself is documented as abstract, but its default
  ;; methods are what CLI-FRONTEND and a minimal from-scratch frontend
  ;; both lean on -- verify they actually do something reasonable.
  (let ((frontend (make-instance 'agent-frontend))
        (output (make-string-output-stream)))
    (let ((*standard-output* output))
      (ui-assistant-text frontend "hello")
      (ui-system frontend "a notice")
      (ui-error frontend "boom"))
    (let ((text (get-output-stream-string output)))
      (check (search "hello" text))
      (check (search "a notice" text))
      (check (search "boom" text)))))

(deftest cli-frontend-prompt-input-reads-stdin ()
  (let ((frontend (make-frontend :cli))
        (output (make-string-output-stream)))
    (with-input-from-string (*standard-input* (format nil "hello there~%"))
      (let ((*standard-output* output))
        (check-equal (ui-prompt-input frontend) "hello there"))
      (check (search ">" (get-output-stream-string output))))))

(deftest cli-frontend-prompt-input-eof-returns-nil ()
  (let ((frontend (make-frontend :cli))
        (output (make-string-output-stream)))
    (with-input-from-string (*standard-input* "")
      (let ((*standard-output* output))
        (check-equal (ui-prompt-input frontend) nil)))))

;;; --- TUI, model level only (see header comment) ---

(deftest tui-chat-model-init-creates-widgets ()
  (let ((model (make-instance 'tui-chat-model :input-channel (trivial-channels:make-channel))))
    (tui:init model)
    (check (tui-chat-textarea model))
    (check (tui-chat-viewport model))))

(deftest tui-chat-model-line-msg-appends-to-transcript ()
  (let ((model (make-instance 'tui-chat-model :input-channel (trivial-channels:make-channel))))
    (tui:init model)
    (tui:update model (make-instance 'tui-line-msg :text "first"))
    (tui:update model (make-instance 'tui-line-msg :text "second"))
    (check-equal (reverse (tui-chat-lines model)) '("first" "second"))))

(deftest tui-chat-model-delta-msg-accumulates-pending-text ()
  (let ((model (make-instance 'tui-chat-model :input-channel (trivial-channels:make-channel))))
    (tui:init model)
    (tui:update model (make-instance 'tui-delta-msg :chunk "hel"))
    (tui:update model (make-instance 'tui-delta-msg :chunk "lo"))
    (check-equal (tui-chat-pending model) "hello")
    (check-equal (tui-chat-lines model) nil "deltas don't become transcript lines on their own")))

(deftest tui-chat-model-line-msg-clears-pending-after-deltas ()
  ;; The complete text (from UI-ASSISTANT-TEXT) supersedes whatever
  ;; partial text was streamed in -- the viewport shouldn't show both.
  (let ((model (make-instance 'tui-chat-model :input-channel (trivial-channels:make-channel))))
    (tui:init model)
    (tui:update model (make-instance 'tui-delta-msg :chunk "hel"))
    (tui:update model (make-instance 'tui-delta-msg :chunk "lo"))
    (tui:update model (make-instance 'tui-line-msg :text "hello"))
    (check-equal (tui-chat-pending model) "")
    (check-equal (reverse (tui-chat-lines model)) '("hello"))))

(deftest tui-chat-model-status-msg-sets-status-line ()
  (let ((model (make-instance 'tui-chat-model :input-channel (trivial-channels:make-channel))))
    (tui:init model)
    (check-equal (tui-chat-status-line model) "")
    (tui:update model (make-instance 'tui-status-msg :text "⋯ thinking"))
    (check-equal (tui-chat-status-line model) "⋯ thinking")
    (tui:update model (make-instance 'tui-status-msg :text ""))
    (check-equal (tui-chat-status-line model) "")))

(deftest tui-chat-model-view-includes-status-line-only-when-non-empty ()
  (let ((model (make-instance 'tui-chat-model :input-channel (trivial-channels:make-channel))))
    (tui:init model)
    (check (not (search "thinking" (tui:view-state-content (tui:view model)))))
    (tui:update model (make-instance 'tui-status-msg :text "⋯ thinking"))
    (check (search "thinking" (tui:view-state-content (tui:view model))))))

;;; --- Web: real HTTP against a real (ephemeral, loopback) instance ---

(defparameter *test-web-port* 14599
  "A fixed high port for the web-frontend tests. Not dynamically
allocated since hunchentoot's easy-acceptor doesn't hand back which
port :port 0 resolved to; a collision is unlikely enough for a test
suite that only ever runs one of these at a time.")

(defmacro with-test-web-frontend ((var) &body body)
  `(let ((,var (make-frontend :web :port *test-web-port*)))
     (unwind-protect (progn (ui-start ,var) (sleep 0.2) ,@body)
       (ui-stop ,var))))

(defun web-test-url (path) (format nil "http://127.0.0.1:~d~a" *test-web-port* path))

(deftest web-frontend-serves-index-page ()
  (with-test-web-frontend (frontend)
    (multiple-value-bind (body status) (drakma:http-request (web-test-url "/"))
      (check-equal status 200)
      (check (search "cl-agent" body))
      (check (search "copy-all" body))
      (check (search "Agent activity" body))
      (check (search "MathJax-script" body))
      (check (search "typesetMath" body)))))

(deftest web-frontend-renders-assistant-markdown-in-status-payload ()
  (with-test-web-frontend (frontend)
    (ui-assistant-text frontend (format nil "# Heading~%~%A **formatted** reply."))
    (let* ((status (json-decode (drakma:http-request (web-test-url "/api/messages"))))
           (message (first (jget status "messages"))))
      (check (search "<h1>Heading</h1>" (jget message "html")))
      (check (search "<strong>formatted</strong>" (jget message "html"))))))

(deftest web-copy-controls-preserve-original-markdown ()
  ;; The card receives rendered HTML separately from COPY-VALUE, so copying an
  ;; assistant response returns its Markdown source rather than rendered text.
  (check (search "copyValue=content" *web-page-html*))
  (check (search "m.html||m.text,m.role==='assistant','',m.text" *web-page-html*))
  (check (not (search "querySelectorAll('.card,.activity-line')" *web-page-html*))))

(deftest web-frontend-renders-normal-and-compact-markdown-tables ()
  (dolist (table (list (format nil "| Tool | Purpose |~%|------|---------|~%| shell | Execute commands |")
                       "| Tool | Purpose | |------|---------| | shell | Execute commands |"))
    (let ((html (web-markdown-html table)))
      (check (search "<table" html))
      (check (search "Tool</th>" html))
      (check (search "shell</td>" html)))))

(deftest web-frontend-renders-bullets-and-github-style-code-fences ()
  (let ((list-html (web-markdown-html "- first - second - third"))
        (code-html (web-markdown-html (format nil "```lisp~%(defun hello () 42)~%```")))
        (inline-fence-html (web-markdown-html "```lisp (let ((answer 42)) answer) ```")))
    (check (search "<ul" list-html))
    (check (search "<li>first</li>" list-html))
    (check (search "<li>second</li>" list-html))
    (check (search "<pre" code-html))
    (check (search "(defun hello () 42)" code-html))
    (check (search "<pre" inline-fence-html))
    (check (search "(let ((answer 42)) answer)" inline-fence-html))))

(deftest web-frontend-does-not-leak-code-block-markers-between-prose ()
  ;; The renderer replaces fences with private markers before 3BMD parses the
  ;; surrounding Markdown.  A marker must remain its own paragraph even when
  ;; prose immediately follows a closing fence, or it becomes visible to the
  ;; user as "CLAGENT-CODE-BLOCK-1".
  (let ((html (web-markdown-html
               (format nil "An excerpt:~%```lisp~%(defun answer () 42)~%```~%It returns the answer."))))
    (check (search "<pre" html))
    (check (search "(defun answer () 42)" html))
    (check (search "It returns the answer" html))
    (check (not (search "CLAGENT-CODE-BLOCK" html)))))

(deftest web-frontend-messages-reflects-ui-calls ()
  (with-test-web-frontend (frontend)
    (ui-system frontend "system notice")
    (ui-assistant-text frontend "assistant reply")
    (ui-tool-started frontend "shell" (jobj "command" "ls"))
    (ui-tool-finished frontend "shell" (jobj "command" "ls") "a.txt")
    (multiple-value-bind (body status) (drakma:http-request (web-test-url "/api/messages"))
      (check-equal status 200)
      (let ((messages (jget (json-decode body) "messages")))
        (check-equal (length messages) 4)
        (check-equal (jget (first messages) "role") "system")
        (check-equal (jget (second messages) "role") "assistant")
        (check-equal (jget (third messages) "role") "tool")))))

(deftest web-frontend-hides-tool-call-narration-and-clears-pending ()
  (let ((frontend (make-frontend :web)))
    (ui-assistant-delta frontend "I will inspect this first.")
    (check (not (ui-show-tool-call-assistant-text-p frontend)))
    (ui-discard-assistant-pending frontend)
    (let ((status (json-decode (web-frontend-status-json frontend))))
      (check-equal (jget status "pending") ""))))

(deftest web-frontend-status-json-is-well-formed-json-array-when-empty ()
  ;; Regression test for the same NIL-vs-[] JSON ambiguity fixed
  ;; elsewhere (see tools.lisp's TOOL class docstring) -- an empty
  ;; transcript must serialize as "messages":[], not "messages":false.
  (with-test-web-frontend (frontend)
    (multiple-value-bind (body status) (drakma:http-request (web-test-url "/api/messages"))
      (check-equal status 200)
      (check (search "\"messages\":[]" (remove #\space body))))))

(deftest web-frontend-pending-and-thinking-reflect-streaming-state ()
  (with-test-web-frontend (frontend)
    (ui-thinking-started frontend)
    (let ((status (json-decode (drakma:http-request (web-test-url "/api/messages")))))
      (check-equal (jget status "thinking") t)
      (check-equal (jget status "pending") ""))
    (ui-assistant-delta frontend "Sure")
    (ui-assistant-delta frontend "!")
    (let ((status (json-decode (drakma:http-request (web-test-url "/api/messages")))))
      (check-equal (jget status "pending") "Sure!"))
    (ui-thinking-stopped frontend)
    (ui-assistant-text frontend "Sure!")
    (let* ((status (json-decode (drakma:http-request (web-test-url "/api/messages"))))
           (messages (jget status "messages")))
      (check-equal (jget status "pending") "" "the complete text clears PENDING")
      (check-equal (jget status "thinking") nil)
      (check-equal (length messages) 1)
      (check-equal (jget (first messages) "text") "Sure!"))))

(deftest web-frontend-stats-reflects-ui-stats-updated ()
  (with-test-web-frontend (frontend)
    (let ((status (json-decode (drakma:http-request (web-test-url "/api/messages")))))
      (check-equal (jget status "stats") nil "no stats yet"))
    (ui-stats-updated frontend (list :provider "ollama" :model "m" :elapsed-seconds 3
                                      :requests 2 :tool-calls 1 :total-tokens 50))
    (let* ((status (json-decode (drakma:http-request (web-test-url "/api/messages"))))
           (stats (jget status "stats")))
      (check-equal (jget stats "provider") "ollama")
      (check-equal (jget stats "requests") 2)
      (check-equal (jget stats "total_tokens") 50))))

(deftest web-frontend-send-reaches-ui-prompt-input ()
  (with-test-web-frontend (frontend)
    (bt:make-thread
     (lambda ()
       (sleep 0.2)
       (drakma:http-request (web-test-url "/api/send") :method :post
                             :content-type "application/x-www-form-urlencoded"
                             :content "text=hello+from+test")))
    (check-equal (ui-prompt-input frontend) "hello from test")))

(deftest web-frontend-quit-endpoint-unblocks-prompt-input ()
  (with-test-web-frontend (frontend)
    (bt:make-thread (lambda () (sleep 0.2) (drakma:http-request (web-test-url "/api/quit") :method :post)))
    (check-equal (ui-prompt-input frontend) nil)))
