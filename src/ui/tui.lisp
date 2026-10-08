;;;; ui/tui.lisp -- a full-screen terminal UI frontend, via `tuition`
;;;; (https://github.com/atgreen/cl-tuition, ocicl system name
;;;; "tuition", package nicknamed TUI), in the style of Claude Code /
;;;; Codex: a scrollable transcript viewport above a persistent input
;;;; box, with a status line above that showing a live "thinking"
;;;; indicator while waiting on the model and a running stats summary
;;;; (requests/tool calls/tokens/elapsed time) once a turn completes --
;;;; see TUI-STATUS-MSG. The model's reply itself appears incrementally
;;;; as it streams in (TUI-DELTA-MSG), not all at once at the end.
;;;; Structurally a close port of tuition's own bundled chat example
;;;; (examples/chat.lisp) -- textarea + viewport joined vertically --
;;;; wired into cl-agent's UI protocol (ui/frontend.lisp) instead of
;;;; that example's own ad-hoc message list.
;;;;
;;;; Threading: tuition owns its own event loop (`tui:run`, called
;;;; here in a dedicated thread) and its own terminal-input thread;
;;;; cl-agent's actual conversation loop (repl.lisp's RUN-REPL, which
;;;; blocks on network calls to the LLM provider) runs on the ORIGINAL
;;;; calling thread. The two meet at a `trivial-channels` channel each
;;;; direction:
;;;;   user input (TUI thread -> conversation thread): the textarea's
;;;;     Enter handler below pushes the submitted line onto
;;;;     TUI-FRONTEND-INPUT-CHANNEL; UI-PROMPT-INPUT just blocks
;;;;     reading it.
;;;;   display (conversation thread -> TUI thread): UI-ASSISTANT-TEXT
;;;;     and friends call `tui:send`, which is itself safe to call from
;;;;     any thread (it just posts to tuition's own internal message
;;;;     channel) -- see that function's docstring in tuition's
;;;;     src/program.lisp.
;;;; This keeps the LLM call from ever blocking the TUI's redraw/input
;;;; handling, at the cost of the TUI being a thin, mostly format-nil
;;;; presentation layer with no business logic of its own -- exactly
;;;; the separation UI/FRONTEND.LISP's protocol is meant to enforce.

(in-package :cl-agent)

(defclass tui-line-msg ()
  ((text :initarg :text :reader tui-line-msg-text))
  (:documentation "A tuition message wrapping one complete line (or
block) of text to append to the transcript. Sent via TUI:SEND from
whichever thread has something to show; handled in TUI-CHAT-MODEL's
UPDATE method below."))

(defclass tui-delta-msg ()
  ((chunk :initarg :chunk :reader tui-delta-msg-chunk))
  (:documentation "One incremental chunk of the model's reply as it
streams in (see UI-ASSISTANT-DELTA, ui/frontend.lisp): appended to
TUI-CHAT-MODEL's PENDING text, shown as a trailing in-progress line in
the viewport until the matching TUI-LINE-MSG (the complete text, from
UI-ASSISTANT-TEXT) arrives and supersedes it."))

(defclass tui-status-msg ()
  ((text :initarg :text :reader tui-status-msg-text))
  (:documentation "Replaces TUI-CHAT-MODEL's status line, shown above
the viewport -- used for both the \"thinking\" indicator
(UI-THINKING-STARTED/STOPPED) and the live stats summary
(UI-STATS-UPDATED), whichever was sent most recently."))

(defclass tui-subagents-msg ()
  ((snapshots :initarg :snapshots :reader tui-subagents-msg-snapshots))
  (:documentation "The current set of visible subagent snapshots (see
UI-SUBAGENTS-UPDATED), replacing the panel shown above the status line."))

(defclass tui-chat-model ()
  ((viewport :accessor tui-chat-viewport)
   (textarea :accessor tui-chat-textarea)
   (lines :initform nil :accessor tui-chat-lines
          :documentation "Transcript lines, NEWEST FIRST (cheap to push to).")
   (pending :initform "" :accessor tui-chat-pending
            :documentation "Accumulated TUI-DELTA-MSG chunks for the
reply currently streaming in; see that class's docstring.")
   (subagents :initform nil :accessor tui-chat-subagents
              :documentation "Latest subagent snapshots; finished ones age out at view time.")
   (height :initform nil :accessor tui-chat-height
           :documentation "Last known terminal height, for fitting the viewport.")
   (status-line :initform "" :accessor tui-chat-status-line
                :documentation "See TUI-STATUS-MSG's docstring.")
   (input-channel :initarg :input-channel :reader tui-chat-input-channel))
  (:documentation "tuition model for cl-agent's TUI. See this file's
header comment for the threading story; TUI-FRONTEND below is the
AGENT-FRONTEND that owns one of these."))

(defmethod tui:init ((model tui-chat-model))
  (let ((ta (tui.textarea:make-textarea
             :width 78 :height 3
             :placeholder "Message cl-agent... (Enter to send, Esc or Ctrl-C to quit)")))
    (setf (tui.textarea:textarea-prompt ta) "> ")
    (tui.textarea:textarea-focus ta)
    (setf (tui-chat-textarea model) ta))
  (setf (tui-chat-viewport model)
        (tui.viewport:make-viewport :width 78 :height 20
                                     :content "cl-agent -- type a message below."))
  (tui:tick 0.5))

(defparameter *tui-subagent-panel-rows* 6
  "Most subagent rows shown above the status line; extra rows collapse to a count.")

(defun tui-subagent-panel-lines (model)
  "Rendered panel rows for MODEL's subagents, newest activity first, aged by view time."
  (let* ((now (get-universal-time))
         (visible (remove-if (lambda (snapshot)
                               (let ((finished (getf snapshot :finished-at)))
                                 (and finished (> (- now finished) *subagent-panel-linger-seconds*))))
                             (tui-chat-subagents model)))
         (shown (subseq visible 0 (min (length visible) *tui-subagent-panel-rows*))))
    (when visible
      (append (list (format nil "Subagents (~d)" (length visible)))
              (mapcar (lambda (snapshot) (concatenate 'string "  " (format-subagent-line snapshot now))) shown)
              (when (> (length visible) (length shown))
                (list (format nil "  … ~d more" (- (length visible) (length shown)))))))))

(defun tui-chat-fit-viewport (model)
  "Size the viewport to the terminal minus the textarea, status and subagent panel."
  (when (tui-chat-height model)
    (let ((panel (tui-subagent-panel-lines model)))
      (setf (tui.viewport:viewport-height (tui-chat-viewport model))
            (max 3 (- (tui-chat-height model) (tui.textarea:textarea-height (tui-chat-textarea model)) 2
                      (if panel (1+ (length panel)) 0)))))))

(defun tui-chat-refresh-viewport (model)
  (let ((lines (reverse (tui-chat-lines model))))
    (tui.viewport:viewport-set-content
     (tui-chat-viewport model)
     (format nil "~{~a~^~%~}"
             (if (plusp (length (tui-chat-pending model))) (append lines (list (tui-chat-pending model))) lines))))
  (tui.viewport:viewport-goto-bottom (tui-chat-viewport model)))

(defmethod tui:update ((model tui-chat-model) msg)
  (let (ta-cmd vp-cmd (pass-to-textarea t))
    (cond
      ((typep msg 'tui-line-msg)
       (setf (tui-chat-pending model) "") ; the complete text supersedes any partial deltas shown so far
       (push (tui-line-msg-text msg) (tui-chat-lines model))
       (tui-chat-refresh-viewport model))
      ((typep msg 'tui-delta-msg)
       (setf (tui-chat-pending model) (concatenate 'string (tui-chat-pending model) (tui-delta-msg-chunk msg)))
       (tui-chat-refresh-viewport model))
      ((typep msg 'tui-status-msg)
       (setf (tui-chat-status-line model) (tui-status-msg-text msg)))
      ((typep msg 'tui-subagents-msg)
       (setf (tui-chat-subagents model) (tui-subagents-msg-snapshots msg))
       (tui-chat-fit-viewport model))
      ((tui:key-press-msg-p msg)
       (let ((key (tui:key-event-code msg))
             (ctrl (tui:mod-contains (tui:key-event-mod msg) tui:+mod-ctrl+)))
         (cond
           ((or (and ctrl (characterp key) (char= key #\c)) (eq key :escape))
            (trivial-channels:sendmsg (tui-chat-input-channel model) nil)
            (return-from tui:update (values model (tui:quit-cmd))))
           ((eq key :enter)
            (let ((text (tui.textarea:textarea-value (tui-chat-textarea model))))
              (when (plusp (length (string-trim '(#\space #\tab #\newline) text)))
                (push (format nil "> ~a" text) (tui-chat-lines model))
                (tui-chat-refresh-viewport model)
                (tui.textarea:textarea-reset (tui-chat-textarea model))
                (trivial-channels:sendmsg (tui-chat-input-channel model) text)))
            (setf pass-to-textarea nil)))))
      ((tui:window-size-msg-p msg)
       (let ((width (tui:window-size-msg-width msg)) (height (tui:window-size-msg-height msg)))
         (setf (tui.viewport:viewport-width (tui-chat-viewport model)) width)
         (setf (tui.textarea:textarea-width (tui-chat-textarea model)) width)
         (setf (tui-chat-height model) height)
         (tui-chat-fit-viewport model)
         (tui-chat-refresh-viewport model)))
      ((tui:tick-msg-p msg)
       (tui-chat-fit-viewport model) ; finished subagents age out of the panel
       (setf ta-cmd (tui:tick 0.5))))
    (when pass-to-textarea
      (multiple-value-bind (new-ta cmd) (tui.textarea:textarea-update (tui-chat-textarea model) msg)
        (setf (tui-chat-textarea model) new-ta ta-cmd cmd)))
    (multiple-value-bind (new-vp cmd) (tui.viewport:viewport-update (tui-chat-viewport model) msg)
      (setf (tui-chat-viewport model) new-vp vp-cmd cmd))
    (values model (tui:batch ta-cmd vp-cmd))))

(defmethod tui:view ((model tui-chat-model))
  (tui:make-view (format nil "~@[~a~%~]~@[~a~%~%~]~a~%~%~a"
                          (let ((panel (tui-subagent-panel-lines model)))
                            (and panel (format nil "~{~a~^~%~}" panel)))
                          (and (plusp (length (tui-chat-status-line model))) (tui-chat-status-line model))
                          (tui.viewport:viewport-view (tui-chat-viewport model))
                          (tui.textarea:textarea-view (tui-chat-textarea model)))))

(defclass tui-frontend (agent-frontend)
  ((model :accessor tui-frontend-model)
   (program :accessor tui-frontend-program)
   (thread :initform nil :accessor tui-frontend-thread)
   (input-channel :initform (trivial-channels:make-channel) :accessor tui-frontend-input-channel))
  (:documentation "Full-screen terminal UI. See this file's header
comment for the threading model."))

(defmethod ui-start ((frontend tui-frontend))
  (let* ((model (make-instance 'tui-chat-model :input-channel (tui-frontend-input-channel frontend)))
         (program (tui:make-program model)))
    (setf (tui-frontend-model frontend) model
          (tui-frontend-program frontend) program
          (tui-frontend-thread frontend)
          (bt:make-thread
           (lambda ()
             (handler-case (tui:run program)
               (error (c)
                 ;; TUI:RUN runs in its own thread and can't signal
                 ;; back to the thread that called UI-START (e.g. no
                 ;; TTY is available -- this happens running under a
                 ;; non-interactive harness/CI). Without this, a dead
                 ;; TUI thread would leave UI-PROMPT-INPUT blocked on
                 ;; TUI-FRONTEND-INPUT-CHANNEL forever, with no visible
                 ;; error -- push NIL so RUN-REPL's loop sees it as
                 ;; end-of-input and exits instead of hanging.
                 (format *error-output* "~&cl-agent TUI failed to start: ~a~%" c)
                 (trivial-channels:sendmsg (tui-frontend-input-channel frontend) nil))))
           :name "cl-agent-tui"))))

(defmethod ui-stop ((frontend tui-frontend))
  (when (tui-frontend-thread frontend)
    (ignore-errors (tui:quit (tui-frontend-program frontend)))
    (ignore-errors (bt:join-thread (tui-frontend-thread frontend)))))

(defmethod ui-prompt-input ((frontend tui-frontend))
  (trivial-channels:recvmsg (tui-frontend-input-channel frontend)))

(defmethod ui-assistant-text ((frontend tui-frontend) text)
  (tui:send (tui-frontend-program frontend) (make-instance 'tui-line-msg :text (format nil "~a" text))))

(defmethod ui-tool-started ((frontend tui-frontend) tool-name arguments)
  (tui:send (tui-frontend-program frontend)
            (make-instance 'tui-line-msg :text (format nil "~~ ~a" (tool-call-summary tool-name arguments)))))

(defmethod ui-tool-finished ((frontend tui-frontend) tool-name arguments result)
  (declare (ignore tool-name arguments))
  (tui:send (tui-frontend-program frontend) (make-instance 'tui-line-msg :text result)))

(defmethod ui-system ((frontend tui-frontend) text)
  (tui:send (tui-frontend-program frontend) (make-instance 'tui-line-msg :text (format nil "[*] ~a" text))))

(defmethod ui-assistant-delta ((frontend tui-frontend) chunk)
  (tui:send (tui-frontend-program frontend) (make-instance 'tui-delta-msg :chunk chunk)))

(defmethod ui-thinking-started ((frontend tui-frontend))
  (tui:send (tui-frontend-program frontend) (make-instance 'tui-status-msg :text "⋯ thinking")))

(defmethod ui-thinking-stopped ((frontend tui-frontend))
  (tui:send (tui-frontend-program frontend) (make-instance 'tui-status-msg :text "")))

(defmethod ui-planning-started ((frontend tui-frontend))
  (tui:send (tui-frontend-program frontend)
            (make-instance 'tui-status-msg :text "⋯ planning next steps")))

(defmethod ui-planning-stopped ((frontend tui-frontend))
  (tui:send (tui-frontend-program frontend) (make-instance 'tui-status-msg :text "")))

(defmethod ui-stats-updated ((frontend tui-frontend) stats)
  (tui:send (tui-frontend-program frontend) (make-instance 'tui-status-msg :text (format-stats stats))))

(defmethod ui-subagents-updated ((frontend tui-frontend) snapshots)
  (tui:send (tui-frontend-program frontend) (make-instance 'tui-subagents-msg :snapshots snapshots)))

(defmethod ui-subagent-event ((frontend tui-frontend) snapshot)
  ;; The live panel already shows state; keep only the terminal outcomes in the transcript.
  (when (member (getf snapshot :state) '(:succeeded :failed :cancelled))
    (ui-system frontend (format-subagent-event snapshot))))

(register-frontend-class :tui 'tui-frontend)
