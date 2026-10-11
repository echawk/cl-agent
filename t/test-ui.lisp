;;;; t/test-ui.lisp -- tests for the UI frontend protocol
;;;; (src/ui/frontend.lisp) and its three built-in implementations.
;;;;
;;;; The web frontend is tested in t/test-web.lisp. The TUI frontend is tested only at the model
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

;;; The web frontend has its own suite: t/test-web.lisp.
