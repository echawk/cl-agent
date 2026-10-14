;;;; copilot.lisp -- the editor's copilot: as you type in Lem, the model
;;;; suggests the code that comes next, shown at the cursor in a faint
;;;; colour; Tab takes it, any other key leaves it.  A comment saying what
;;;; to write gets the code that does it.
;;;;
;;;; It is not the agent: a separate, tool-free request (the file around
;;;; the cursor, nothing of the conversation) to its own provider -- the
;;;; session's, with the session's model unless :COPILOT-MODEL names
;;;; another -- so it is quick and never touches the session's history.
;;;;
;;;;   - :COPILOT-AUTO (a setting): suggest after every pause in typing of
;;;;     :COPILOT-DELAY-MS; off, C-c Tab (M-x copilot-complete) still asks.
;;;;   - The suggestion is real text in the buffer while shown (Lem draws it
;;;;     in COPILOT-SUGGESTION-ATTRIBUTE), kept out of the undo history and
;;;;     the modified flag, and taken out again before anything else uses
;;;;     the buffer: the next command, a save, or cl-agent itself reading
;;;;     or changing it (LEM-BEFORE-BUFFER-ACCESS).  So no one else ever
;;;;     sees it: not the file, the agent, nor the simple editor.
;;;;   - Its keys live in COPILOT-SUGGESTION-MODE, a minor mode on only while
;;;;     a suggestion is shown: Tab takes it, M-Right takes its first line.
;;;;   - A request is answered only if nothing changed meanwhile: any edit or
;;;;     cursor move since makes its answer stale, and it is dropped.

(in-package :cl-agent)

;;; --- settings and the provider ---

(defvar *copilot-provider* nil
  "When set, the provider every copilot request uses (tests); otherwise
COPILOT-PROVIDER makes one from the session's.")

(defun copilot-session ()
  (or (and (boundp '*current-session*) *current-session*)
      (and *web-frontend* (web-frontend-session *web-frontend*))))

(defun copilot-setting (name default)
  (let ((session (copilot-session)))
    (if session
        (or (ignore-errors (session-setting-value session name)) default)
        default)))

(defun copilot-auto-p () (and (copilot-setting :copilot-auto nil) t))

(defun copilot-delay () (/ (copilot-setting :copilot-delay-ms 700) 1000.0))

(defun copilot-chosen-model ()
  "The model named by :COPILOT-MODEL, or NIL for the session's own."
  (let ((model (copilot-setting :copilot-model "session")))
    (and (stringp model) (plusp (length model)) (string/= model "session") model)))

(defun copilot-model ()
  "The model the copilot asks."
  (or (copilot-chosen-model)
      (let ((session (copilot-session)))
        (and session (provider-model (session-provider session))))))

(defun copilot-provider ()
  "A provider of the copilot's own: the session's, asking COPILOT-MODEL,
independent of the session's (which is busy with the conversation)."
  (or *copilot-provider*
      (let ((session (copilot-session)))
        (unless session
          (error "The copilot uses the session's provider, and no session is running yet."))
        (let ((provider (session-provider session)))
          (or (ignore-errors (provider-for-model provider (copilot-model)))
              provider)))))

;;; --- asking the model ---

(defparameter *copilot-system-prompt*
  "You are the code completion engine in a text editor. You are shown a file with the marker <CURSOR> where the cursor is. Reply with exactly the text to insert at <CURSOR> and nothing else: no explanation, no markdown fences, and none of the text already before or after the cursor. Complete the current line, statement or block; when the line before the cursor is a comment saying what to write, write that code. Match the file's language, indentation and style. Keep it short (at most about 20 lines). If nothing sensible comes next, reply with nothing.")

(defparameter *copilot-context-before* 6000
  "Characters of the file before the cursor that the model sees.")

(defparameter *copilot-context-after* 2000
  "Characters of the file after the cursor that the model sees.")

(defun copilot-prompt (context)
  (destructuring-bind (&key before after path language &allow-other-keys) context
    (format nil "File: ~a~@[ (~a)~]~%~%~a<CURSOR>~a"
            (or path "untitled") language before after)))

(defun strip-thinking (text)
  "TEXT without a reasoning model's <think>...</think>."
  (let ((end (search "</think>" text)))
    (if (and end (search "<think>" text :end2 end))
        (subseq text (+ end (length "</think>")))
        text)))

(defun strip-code-fence (text)
  "The inside of TEXT's first ``` fence, if it has one."
  (let ((open (search "```" text)))
    (if (null open)
        text
        (let* ((body (or (position #\Newline text :start open) (length text)))
               (close (search "```" text :start2 (min (length text) (1+ body)))))
          (subseq text (min (length text) (1+ body)) (or close (length text)))))))

(defun line-before-cursor (before)
  (subseq before (1+ (or (position #\Newline before :from-end t) -1))))

(defun copilot-clean (reply context)
  "The text to show from the model's REPLY: without thinking, fences or
the cursor marker; without what it repeated of the line before the
cursor, or of the text after it; at most 40 lines."
  (destructuring-bind (&key before after &allow-other-keys) context
    (let* ((text (strip-code-fence (strip-thinking (or reply ""))))
           (text (let ((at (search "<CURSOR>" text)))
                   (if at (concatenate 'string (subseq text 0 at) (subseq text (+ at 8))) text)))
           (line (string-left-trim '(#\Space #\Tab) (line-before-cursor before))))
      ;; The model wrote out the whole line again.
      (let ((trimmed (string-left-trim '(#\Space #\Tab) text)))
        (when (and (plusp (length line)) (uiop:string-prefix-p line trimmed))
          (setf text (subseq trimmed (length line)))))
      ;; ... or indented a line the cursor is already indented on.
      (let ((indent (line-before-cursor before)))
        (when (and (plusp (length indent)) (every (lambda (c) (member c '(#\Space #\Tab))) indent))
          (let ((own (or (position-if-not (lambda (c) (member c '(#\Space #\Tab))) text) (length text))))
            (setf text (subseq text (min own (length indent)))))))
      ;; ... or ran on into what follows the cursor.
      (let ((next (or (find-if (lambda (line) (plusp (length line)))
                               (mapcar (lambda (line) (string-trim '(#\Space #\Tab #\Return) line))
                                       (uiop:split-string after :separator '(#\Newline))))
                      "")))
        (when (plusp (length next))
          (let ((at (search next text :from-end t)))
            (when (and at (string= "" (string-trim '(#\Space #\Tab #\Newline) (subseq text (+ at (length next))))))
              (setf text (subseq text 0 at))))))
      (let ((lines (uiop:split-string (string-right-trim '(#\Space #\Tab #\Newline #\Return) text)
                                      :separator '(#\Newline))))
        (format nil "~{~a~^~%~}" (subseq lines 0 (min 40 (length lines))))))))

(defun copilot-ask (context)
  "The suggestion for CONTEXT (COPILOT-CONTEXT), from the model: a string,
maybe empty."
  (let ((message (chat (copilot-provider)
                       (list (list :role "system" :content *copilot-system-prompt*)
                             (list :role "user" :content (copilot-prompt context)))
                       nil)))
    (copilot-clean (getf message :content) context)))

;;; --- the suggestion, in the buffer ---

(lem:define-attribute copilot-suggestion-attribute
  (:light :foreground "#8a86a2")
  (:dark :foreground "#7a74a2"))

(lem:define-minor-mode copilot-suggestion-mode
    (:name "Copilot" :keymap *copilot-suggestion-keymap*))

(defvar *copilot-shown* nil
  "The suggestion shown: (:buffer :start :text :modified), or NIL.")

(defvar *copilot-status* (list :state "idle")
  "What the copilot last did, for the page: :state, :model, :error, :when.")

(defun copilot-note (&rest status)
  (setf *copilot-status* (list* :when (get-universal-time) status)))

(defun copilot-dismiss ()
  "Take the shown suggestion out of its buffer.  Editor thread."
  (let ((shown *copilot-shown*))
    (when shown
      (setf *copilot-shown* nil)
      (destructuring-bind (&key buffer start text modified) shown
        (unless (lem:deleted-buffer-p buffer)
          (lem:with-point ((from (lem:buffer-point buffer)) (to (lem:buffer-point buffer)))
            (lem:move-to-position from start)
            (lem:move-to-position to start)
            (when (and (lem:character-offset to (length text))
                       (string= (lem:points-to-string from to) text))
              (lem/buffer/internal::with-inhibit-undo ()
                (lem:delete-between-points from to))))
          (unless modified (lem:buffer-unmark buffer))
          (when (lem:mode-active-p buffer 'copilot-suggestion-mode)
            (lem:with-current-buffer buffer (copilot-suggestion-mode nil)))
          (lem:redraw-display))))))

(pushnew 'copilot-dismiss *lem-before-buffer-access*)

(defun copilot-show (buffer start text)
  "Show TEXT in BUFFER at START, the cursor staying before it.  Editor thread."
  (copilot-dismiss)
  (when (plusp (length text))
    (let ((point (lem:buffer-point buffer))
          (modified (lem:buffer-modified-p buffer)))
      (lem:with-point ((at point))
        (lem:move-to-position at start)
        (lem/buffer/internal::with-inhibit-undo ()
          (lem:insert-string at text :attribute 'copilot-suggestion-attribute)))
      (unless modified (lem:buffer-unmark buffer))
      (lem:move-to-position point start)
      (setf *copilot-shown* (list :buffer buffer :start start :text text :modified modified))
      (lem:with-current-buffer buffer (copilot-suggestion-mode t))
      (lem:redraw-display))))

(defun copilot-take (&key first-line)
  "Put the shown suggestion (or its first line) in for real, as typed."
  (let ((shown *copilot-shown*))
    (when shown
      (copilot-dismiss)
      (destructuring-bind (&key buffer text &allow-other-keys) shown
        (let ((text (if first-line
                        (let ((end (position #\Newline text :start (min 1 (length text)))))
                          (if end (subseq text 0 end) text))
                        text)))
          (lem:insert-string (lem:buffer-point buffer) text)
          (copilot-note :state "taken" :model (copilot-model))
          text)))))

(lem:define-command copilot-accept () ()
  "Take the copilot's suggestion."
  (copilot-take))

(lem:define-command copilot-accept-line () ()
  "Take the first line of the copilot's suggestion."
  (copilot-take :first-line t))

(lem:define-key *copilot-suggestion-keymap* "Tab" 'copilot-accept)
(lem:define-key *copilot-suggestion-keymap* "M-Right" 'copilot-accept-line)

(defun copilot-before-command ()
  ;; Every command but taking it leaves the suggestion: typing, moving,
  ;; C-g, saving.
  (when (and *copilot-shown*
             (not (member (lem:this-command)
                          (list (lem:find-command "copilot-accept") (lem:find-command "copilot-accept-line")))))
    (copilot-dismiss)))

(defun copilot-before-save (buffer)
  (declare (ignore buffer))
  (copilot-dismiss))

;;; --- when to ask ---

(defvar *copilot-generation* 0
  "Counts edits and requests: an answer for an older generation is stale.")

(defun copilot-buffer-p (buffer)
  "Whether the copilot works in BUFFER: one visiting a file (or a scratch
buffer), not Lem's own (the minibuffer, *tmp*, dired)."
  (and (lem:buffer-filename buffer)
       (not (lem:buffer-read-only-p buffer))))

(defun copilot-context (buffer)
  "What the model sees of BUFFER, around its cursor.  Editor thread."
  (let* ((point (lem:buffer-point buffer))
         (position (lem:position-at-point point)))
    (lem:with-point ((from point) (to point))
      (lem:character-offset from (- (min *copilot-context-before* (1- position))))
      (lem:character-offset to (min *copilot-context-after*
                                    (lem:count-characters point (lem:buffer-end-point buffer))))
      (list :buffer buffer :position position
            :tick (lem:buffer-modified-tick buffer)
            :before (lem:points-to-string from point)
            :after (lem:points-to-string point to)
            :path (lem:buffer-filename buffer)
            :language (ignore-errors (string-downcase (lem:mode-name (lem:buffer-major-mode buffer))))))))

(defun copilot-still-p (context)
  "Whether CONTEXT still describes its buffer: nothing typed, nothing moved."
  (let ((buffer (getf context :buffer)))
    (and (not (lem:deleted-buffer-p buffer))
         (null *copilot-shown*)
         (eq buffer (lem:current-buffer))
         (eql (lem:buffer-modified-tick buffer) (getf context :tick))
         (eql (lem:position-at-point (lem:buffer-point buffer)) (getf context :position)))))

(defun copilot-request (buffer generation &key manual)
  "Ask for a suggestion at BUFFER's cursor, on a thread of its own, and
show it if it is still wanted when it comes.  Editor thread."
  (when (and (= generation *copilot-generation*)
             (eq buffer (lem:current-buffer))
             (null *copilot-shown*)
             (copilot-buffer-p buffer))
    (let ((context (copilot-context buffer))
          (spinner (ignore-errors
                    (lem/loading-spinner:start-loading-spinner :modeline :buffer buffer :loading-message "Copilot"))))
      (copilot-note :state "asking" :model (copilot-model))
      (bt:make-thread
       (lambda ()
        (with-turn-guard (:where "A copilot request")
          (multiple-value-bind (text problem)
              (handler-case (values (copilot-ask context) nil)
                (error (condition) (values nil (princ-to-string condition))))
            (lem:send-event
             (lambda ()
               (when spinner (ignore-errors (lem/loading-spinner:stop-loading-spinner spinner)))
               (cond (problem
                      (copilot-note :state "error" :error problem :model (copilot-model))
                      (when manual (lem:message "Copilot: ~a" problem)))
                     ((and (= generation *copilot-generation*) (copilot-still-p context))
                      (if (plusp (length text))
                          (progn (copilot-show buffer (getf context :position) text)
                                 (copilot-note :state "shown" :model (copilot-model)))
                          (progn (copilot-note :state "nothing" :model (copilot-model))
                                 (when manual (lem:message "Copilot: nothing to suggest here.")))))
                     (t (copilot-note :state "stale" :model (copilot-model)))))))))
       :name "copilot-request"))))

(defvar *copilot-last-tick* (make-hash-table :test #'eq :weakness :key)
  "Each buffer's text version when the copilot last looked.")

(defun copilot-after-command ()
  ;; Typing changed the text: ask again once it pauses.
  (let ((buffer (lem:current-buffer)))
    (when (and (null *copilot-shown*) (copilot-buffer-p buffer))
      (let ((tick (lem:buffer-modified-tick buffer)))
        (unless (eql tick (gethash buffer *copilot-last-tick*))
          (setf (gethash buffer *copilot-last-tick*) tick)
          (let ((generation (incf *copilot-generation*)))
            (when (copilot-auto-p)
              (let ((delay (copilot-delay)))
                (bt:make-thread (lambda ()
                                  (with-turn-guard (:where "The copilot's pause")
                                    (sleep delay)
                                    (when (= generation *copilot-generation*)
                                      (lem:send-event (lambda () (copilot-request buffer generation))))))
                                :name "copilot-pause")))))))))

(lem:define-command copilot-complete () ()
  "Ask the copilot for a suggestion here, now."
  (let ((buffer (lem:current-buffer)))
    (unless (copilot-buffer-p buffer)
      (lem:editor-error "The copilot works in buffers visiting a file."))
    (copilot-dismiss)
    ;; Seen as it is now: the hook after this command must not take the
    ;; buffer for changed and drop the answer as stale.
    (setf (gethash buffer *copilot-last-tick*) (lem:buffer-modified-tick buffer))
    (copilot-request buffer (incf *copilot-generation*) :manual t)))

(lem:define-key lem:*global-keymap* "C-c Tab" 'copilot-complete)

(lem:add-hook lem:*pre-command-hook* 'copilot-before-command)
(lem:add-hook lem:*post-command-hook* 'copilot-after-command)
(lem:add-hook (lem:variable-value 'lem:before-save-hook :global) 'copilot-before-save)

;;; --- for the page ---

(defun copilot-status-json ()
  (let ((session (copilot-session)))
    (jobj "auto" (copilot-auto-p)
          "model" (json-or-null (copilot-chosen-model))
          "sessionModel" (json-or-null (and session (provider-model (session-provider session))))
          "delayMs" (copilot-setting :copilot-delay-ms 700)
          "state" (getf *copilot-status* :state)
          "error" (json-or-null (getf *copilot-status* :error))
          "shown" (and *copilot-shown* t))))

(defun copilot-configure (&key (auto nil auto-p) (model nil model-p))
  "Change the copilot's settings (durable, like /settings set)."
  (let ((session (copilot-session)))
    (unless session (error "No session is running yet."))
    (let ((settings (session-settings session)))
      (when auto-p (setf (setinka:config :copilot-auto settings) (if auto "on" "off")))
      (when model-p
        (setf (setinka:config :copilot-model settings)
              (if (and (stringp model) (plusp (length model))) model "session"))))
    (copilot-status-json)))

;;; --- the simple editor's text ---

(defun copilot-suggest-text (path before after)
  "The copilot's suggestion for the simple editor's unsaved text: BEFORE
and AFTER the cursor in the file at PATH (which names its language)."
  (let ((context (list :before (subseq before (max 0 (- (length before) *copilot-context-before*)))
                       :after (subseq after 0 (min (length after) *copilot-context-after*))
                       :path path
                       :language (and path (pathname-type path)))))
    (copilot-note :state "asking" :model (copilot-model))
    (handler-case
        (let ((text (copilot-ask context)))
          (copilot-note :state (if (plusp (length text)) "shown" "nothing") :model (copilot-model))
          text)
      (error (condition)
        (copilot-note :state "error" :error (princ-to-string condition) :model (copilot-model))
        (error condition)))))
