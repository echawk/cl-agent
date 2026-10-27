;;; cl-agent.el --- cl-agent's side of the Emacs it runs  -*- lexical-binding: t -*-

;; cl-agent (src/emacs.lisp) starts Emacs as a daemon of its own and loads
;; this file into it.  The web UI shows the daemon's frames -- emacsclient
;; -t, in a terminal -- and the two talk both ways:
;;
;;   cl-agent -> Emacs   emacsclient --eval, calling the cl-agent-* functions
;;                       below; those that answer return a JSON string
;;   Emacs -> cl-agent   one event per line on stderr, which cl-agent reads:
;;                       "\037cl-agent " and a JSON object (CL-AGENT--EMIT)
;;
;; A frame says what it is for by its emacsclient's CL_AGENT_FRAME: "code"
;; (the Code tab's editor) or "lisp" (the Lisp tab's scratch buffer).
;; The daemon ends with cl-agent: a timer notices when Emacs's parent
;; process is no longer cl-agent, however cl-agent ended.
;;
;; In any buffer (CL-AGENT-MODE), C-c C-a puts the region (or the Lisp form at point) at
;; cl-agent's prompt, to ask the agent about it.  The Lisp tab's scratch
;; buffer has CL-AGENT-SCRATCH-MODE: C-c C-c, C-x C-e and C-c C-k evaluate
;; in cl-agent's image, and it saves as it is edited.

(require 'cl-lib)
(require 'subr-x)
(require 'server)
(require 'autorevert)
(require 'thingatpt)

(defvar cl-agent-parent-pid nil
  "cl-agent's process.  When Emacs's parent is another, cl-agent is gone.")

;;; Talking to cl-agent

(defun cl-agent--ascii (json)
  "JSON (a string) with every character beyond ASCII written \\uXXXX: what
leaves Emacs (stderr, emacsclient) then reads the same in any locale."
  (replace-regexp-in-string
   "[^[:ascii:]]"
   (lambda (match)
     (let ((char (string-to-char match)))
       (if (> char #xFFFF)
           (let ((offset (- char #x10000)))
             (format "\\u%04x\\u%04x" (+ #xD800 (ash offset -10)) (+ #xDC00 (logand offset #x3FF))))
         (format "\\u%04x" char))))
   (if (multibyte-string-p json) json (decode-coding-string json 'utf-8))
   t t))

(defun cl-agent--json (object)
  (cl-agent--ascii (json-serialize object :null-object nil :false-object :false)))

(defun cl-agent--emit (type &rest properties)
  "Tell cl-agent about TYPE, with PROPERTIES: keywords and JSON values."
  (princ (concat "\037cl-agent " (cl-agent--json (cl-list* :type type properties)) "\n")
         #'external-debugging-output))

;;; Frames, and what they show

(defun cl-agent--frame-role (frame)
  "The role of FRAME (\"code\", \"lisp\"), from its client's environment."
  (and (frame-live-p frame) (getenv "CL_AGENT_FRAME" frame)))

(defun cl-agent--frame (role)
  (cl-find-if (lambda (frame) (equal (cl-agent--frame-role frame) role)) (frame-list)))

(defun cl-agent--frame-window (frame)
  "FRAME's window for editing: its selected one, unless that is the minibuffer."
  (let ((window (frame-selected-window frame)))
    (if (window-minibuffer-p window) (frame-first-window frame) window)))

(defun cl-agent--buffer-object (buffer)
  (with-current-buffer buffer
    (list :path (and buffer-file-name (expand-file-name buffer-file-name))
          :directory (and buffer-file-name (file-name-directory (expand-file-name buffer-file-name)))
          :name (buffer-name)
          :mode (substring-no-properties (format-mode-line mode-name))
          :modified (if (buffer-modified-p) t :false))))

(defun cl-agent--file-buffers ()
  (cl-loop for buffer in (buffer-list)
           when (buffer-file-name buffer) collect (cl-agent--buffer-object buffer)))

(defvar cl-agent--reported nil "(ROLE . OBJECT): what cl-agent was last told each frame shows.")
(defvar cl-agent--reported-buffers 'unknown "The file buffers cl-agent was last told of.")

(defun cl-agent--report ()
  "Tell cl-agent what its frames show, and which files are open, when either changed."
  (condition-case nil
      (progn
        (dolist (frame (frame-list))
          (let ((role (cl-agent--frame-role frame)))
            (when role
              (let ((object (cl-agent--buffer-object (window-buffer (cl-agent--frame-window frame)))))
                (unless (equal object (alist-get role cl-agent--reported nil nil #'equal))
                  (setf (alist-get role cl-agent--reported nil nil #'equal) object)
                  (apply #'cl-agent--emit "shown" :role role object))))))
        (let ((buffers (cl-agent--file-buffers)))
          (unless (equal buffers cl-agent--reported-buffers)
            (setq cl-agent--reported-buffers buffers)
            (cl-agent--emit "buffers" :buffers (vconcat buffers)))))
    (error nil)))

(defun cl-agent--watchdog ()
  (when (and cl-agent-parent-pid
             (not (eql (alist-get 'ppid (process-attributes (emacs-pid))) cl-agent-parent-pid)))
    (kill-emacs 0)))

(defun cl-agent--saved ()
  (when buffer-file-name
    (cl-agent--emit "saved" :path (expand-file-name buffer-file-name))))

;;; What cl-agent calls

(defun cl-agent-visit (role file &optional line)
  "Show FILE in ROLE's frame (or only open it), at LINE.  Its JSON."
  (let ((buffer (find-file-noselect file))
        (frame (cl-agent--frame role)))
    (if frame
        (with-selected-frame frame
          (with-selected-window (cl-agent--frame-window frame)
            (switch-to-buffer buffer)
            (when line
              (goto-char (point-min))
              (forward-line (1- line))
              (set-window-point (selected-window) (point)))))
      (when line
        (with-current-buffer buffer (goto-char (point-min)) (forward-line (1- line)))))
    (cl-agent--report)
    (cl-agent--json (cl-agent--buffer-object buffer))))

(defun cl-agent-buffers ()
  "The file buffers, as JSON."
  (cl-agent--json (vconcat (cl-agent--file-buffers))))

(defun cl-agent-buffer-text (file)
  "FILE's buffer with its text (unsaved edits included), as JSON; null if not open."
  (let ((buffer (find-buffer-visiting file)))
    (if (not buffer)
        "null"
      (cl-agent--json (append (cl-agent--buffer-object buffer)
                              (list :text (with-current-buffer buffer
                                            (buffer-substring-no-properties (point-min) (point-max)))))))))

(defun cl-agent-file-written (file)
  "FILE was written outside Emacs: its buffer, without unsaved edits, reads it again."
  (let ((buffer (find-buffer-visiting file)))
    (when (and buffer (not (buffer-modified-p buffer)))
      (with-current-buffer buffer (revert-buffer t t t)))
    (cl-agent--report)
    (if buffer (cl-agent--json (cl-agent--buffer-object buffer)) "null")))

(defun cl-agent-background (mode)
  "Follow the page's theme: MODE is \"light\" or \"dark\"."
  (setq frame-background-mode (intern mode))
  (mapc #'frame-set-background-mode (frame-list))
  t)

(defun cl-agent-commands (prefix limit)
  "Up to LIMIT command names starting with PREFIX (else containing it), each
with its documentation's first line, as JSON: [[name, doc], ...]."
  (let* ((names (sort (all-completions prefix obarray #'commandp) #'string<))
         (names (or names
                    (let (found)
                      (mapatoms (lambda (symbol)
                                  (when (and (commandp symbol) (string-search prefix (symbol-name symbol)))
                                    (push (symbol-name symbol) found))))
                      (sort found #'string<)))))
    (cl-agent--json
     (vconcat
      (cl-loop for name in names
               for count from 0 below limit
               collect (vector name (let ((doc (ignore-errors (documentation (intern name) t))))
                                      (if doc (car (split-string doc "\n")) ""))))))))

;;; C-c C-a: ask the agent

(defun cl-agent-ask ()
  "Put the region (or the Lisp form at point) at cl-agent's prompt, to ask the agent about it."
  (interactive)
  (let* ((where (if buffer-file-name (abbreviate-file-name buffer-file-name) (buffer-name)))
         (bounds (cond ((use-region-p) (cons (region-beginning) (region-end)))
                       ((derived-mode-p 'lisp-data-mode 'lisp-mode) (bounds-of-thing-at-point 'defun))))
         (text (and bounds (string-trim-right (buffer-substring-no-properties (car bounds) (cdr bounds))))))
    (cl-agent--emit
     "ask" :text
     (if (and text (not (string-blank-p text)))
         (let ((first (line-number-at-pos (car bounds)))
               (last (line-number-at-pos (max (car bounds) (1- (cdr bounds))))))
           (format "About %s of %s (open in Emacs):\n```\n%s\n```\n"
                   (if (= first last) (format "line %d" first) (format "lines %d–%d" first last))
                   where text))
       (format "About %s (open in Emacs): " where)))
    (message "At cl-agent's prompt: finish your question there.")))

;;; The Lisp tab's scratch buffer

(defvar cl-agent-scratch-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'cl-agent-scratch-compile-form)
    (define-key map (kbd "C-x C-e") #'cl-agent-scratch-eval-last)
    (define-key map (kbd "C-c C-k") #'cl-agent-scratch-load-buffer)
    map)
  "Evaluation keys in cl-agent's image, over Lisp mode's own (SLY's, SLIME's).")

(defvar-local cl-agent--scratch-timer nil)

(define-minor-mode cl-agent-scratch-mode
  "The Lisp tab's scratch buffer: C-c C-c, C-x C-e and C-c C-k evaluate in
cl-agent's image, and it is saved as it is edited."
  :lighter " cl-agent"
  (if cl-agent-scratch-mode
      (progn
        ;; Ahead of every minor mode's keys, SLY's and SLIME's included.
        (setq-local minor-mode-overriding-map-alist
                    (cons (cons 'cl-agent-scratch-mode cl-agent-scratch-mode-map)
                          minor-mode-overriding-map-alist))
        (add-hook 'after-change-functions #'cl-agent--scratch-changed nil t))
    (remove-hook 'after-change-functions #'cl-agent--scratch-changed t)))

(defun cl-agent--scratch-changed (&rest _)
  (let ((buffer (current-buffer)))
    (when (timerp cl-agent--scratch-timer) (cancel-timer cl-agent--scratch-timer))
    (setq cl-agent--scratch-timer (run-with-idle-timer 0.4 nil #'cl-agent--scratch-save buffer))))

(defun cl-agent--scratch-save (buffer)
  (when (and (buffer-live-p buffer) (buffer-modified-p buffer))
    (with-current-buffer buffer
      (let ((save-silently t) (inhibit-message t))
        (basic-save-buffer))
      (cl-agent--emit "scratch-saved" :path (expand-file-name buffer-file-name)))))

(defun cl-agent--scratch-send (text mode)
  (cl-agent--emit "eval" :mode mode :text text)
  (message "Sent to the Lisp tab's REPL."))

(defun cl-agent-scratch-compile-form ()
  "Compile the top-level form at point in cl-agent's image (the Lisp tab's C-c C-c)."
  (interactive)
  (let ((bounds (bounds-of-thing-at-point 'defun)))
    (if bounds
        (cl-agent--scratch-send (buffer-substring-no-properties (car bounds) (cdr bounds)) "compile")
      (message "No form here."))))

(defun cl-agent-scratch-eval-last ()
  "Evaluate the form before point in cl-agent's image (the Lisp tab's C-x C-e)."
  (interactive)
  (let ((end (point))
        (start (save-excursion (ignore-errors (backward-sexp) (point)))))
    (if (and start (< start end))
        (cl-agent--scratch-send (buffer-substring-no-properties start end) "eval")
      (message "No form before point."))))

(defun cl-agent-scratch-load-buffer ()
  "Compile and load the scratch buffer in cl-agent's image (the Lisp tab's C-c C-k)."
  (interactive)
  (cl-agent--scratch-save (current-buffer))
  (cl-agent--scratch-send (buffer-substring-no-properties (point-min) (point-max)) "compile-file"))

(defun cl-agent-visit-scratch (role file)
  "Show the scratch buffer FILE in ROLE's frame, in Lisp mode with CL-AGENT-SCRATCH-MODE."
  (prog1 (cl-agent-visit role file)
    (with-current-buffer (find-buffer-visiting file)
      (unless (derived-mode-p 'lisp-mode) (lisp-mode))
      (cl-agent-scratch-mode 1))))

;;; Commands run for the agent, their prompts answered from its answers

(defvar cl-agent--answers nil "The answers left, while a command runs for the agent.")
(defvar cl-agent--asked nil "The prompts it asked, newest first.")
(defvar cl-agent--messages nil "What it said, newest first.")

(defun cl-agent--next-answer (prompt)
  "The next answer, for PROMPT.  None left: the command stops (a throw, which
no condition-case in the command can swallow)."
  (push (substring-no-properties (format "%s" (or prompt ""))) cl-agent--asked)
  (if cl-agent--answers
      (pop cl-agent--answers)
    (throw 'cl-agent-unanswered (car cl-agent--asked))))

(defun cl-agent--answer-line (_original prompt &optional _initial _keymap read &rest _)
  (let ((answer (cl-agent--next-answer prompt)))
    (if read (car (read-from-string answer)) answer)))

(defun cl-agent--answer-string (_original prompt &rest _)
  (cl-agent--next-answer prompt))

(defun cl-agent--answer-completion (_original prompt &rest _)
  (cl-agent--next-answer prompt))

(defun cl-agent--answer-yes (_original prompt &rest _)
  (and (member (downcase (cl-agent--next-answer prompt)) '("y" "yes")) t))

(defun cl-agent--answer-event (_original &optional prompt &rest _)
  (let ((keys (kbd (cl-agent--next-answer prompt))))
    (if (stringp keys) (aref keys 0) (aref keys 0))))

(defun cl-agent--answer-key (_original &optional prompt &rest _)
  (let ((keys (kbd (cl-agent--next-answer prompt))))
    (if (and (stringp keys) (= (length keys) 1)) (aref keys 0) keys)))

(defun cl-agent--note-message (original format-string &rest args)
  (let ((text (apply original format-string args)))
    (when (and text (not (string-empty-p text)))
      (push (substring-no-properties text) cl-agent--messages))
    text))

(defconst cl-agent--answering-advice
  '((read-from-minibuffer . cl-agent--answer-line)
    (read-string . cl-agent--answer-string)
    (completing-read . cl-agent--answer-completion)
    (read-file-name . cl-agent--answer-string)
    (read-buffer . cl-agent--answer-string)
    (yes-or-no-p . cl-agent--answer-yes)
    (y-or-n-p . cl-agent--answer-yes)
    (read-event . cl-agent--answer-event)
    (read-char . cl-agent--answer-event)
    (read-char-exclusive . cl-agent--answer-event)
    (read-key . cl-agent--answer-key)
    (message . cl-agent--note-message))
  "What answers prompts, and notes messages, while a command runs for the agent.")

(defun cl-agent--goto (line column)
  (goto-char (point-min))
  (forward-line (1- line))
  (when column (move-to-column (1- column))))

(defun cl-agent-run-command (spec)
  "Run a command (or keys) for the agent, on a file's buffer.  SPEC is a JSON
object: path, command or keys, answers, line, column, end_line, end_column,
argument, save.  Its prompts are answered from answers, in order; one with
none left stops it.  JSON: buffer, path, error, before, after, asked, unused,
messages, point, modified, saved."
  (let* ((spec (json-parse-string spec :object-type 'plist :null-object nil :false-object nil))
         (path (plist-get spec :path))
         (command (plist-get spec :command))
         (keys (plist-get spec :keys))
         (line (plist-get spec :line))
         (end-line (plist-get spec :end_line))
         (buffer (if path
                     (find-file-noselect (expand-file-name path))
                   (window-buffer (cl-agent--frame-window (or (cl-agent--frame "code") (selected-frame))))))
         (before (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))
         (cl-agent--answers (append (plist-get spec :answers) nil))
         (cl-agent--asked nil)
         (cl-agent--messages nil)
         (error nil)
         (saved :false)
         (final-point nil))
    (unwind-protect
        (progn
          (dolist (advice cl-agent--answering-advice)
            (advice-add (car advice) :around (cdr advice)))
          (save-window-excursion
            (switch-to-buffer buffer t t)
            (with-current-buffer buffer
              (when line (cl-agent--goto line (plist-get spec :column)))
              (if end-line
                  (progn (push-mark (point) t t)
                         (cl-agent--goto end-line (plist-get spec :end_column))
                         (exchange-point-and-mark)
                         (activate-mark))
                (deactivate-mark))
              ;; Keys run in the window, from its point.
              (set-window-point (selected-window) (point))
              (let* ((completed nil)
                     (prompt (catch 'cl-agent-unanswered
                               (condition-case condition
                                   (let ((current-prefix-arg (plist-get spec :argument)))
                                     (cond (keys (execute-kbd-macro (kbd keys)))
                                           ((and command (commandp (intern-soft command)))
                                            (call-interactively (intern-soft command)))
                                           (command (error "Emacs has no command named %s" command))
                                           (t (error "Give command (an Emacs command name) or keys")))
                                     (setq completed t))
                                 (error (setq error (error-message-string condition)) (setq completed t))))))
                (unless completed
                  (setq error (format "After %d answer%s, %s asked %S and no answer was left"
                                      (1- (length cl-agent--asked)) (if (= (length cl-agent--asked) 2) "" "s")
                                      (or command keys) prompt)))
                (with-current-buffer buffer
                  (setq final-point (vector (line-number-at-pos) (1+ (current-column)))))))))
      (dolist (advice cl-agent--answering-advice)
        (advice-remove (car advice) (cdr advice))))
    (when (and (plist-get spec :save) (not error))
      (with-current-buffer buffer (save-buffer) (setq saved t)))
    (cl-agent--report)
    (with-current-buffer buffer
      (cl-agent--json
       (list :buffer (buffer-name)
             :path (and buffer-file-name (expand-file-name buffer-file-name))
             :error error
             :before before
             :after (buffer-substring-no-properties (point-min) (point-max))
             :asked (vconcat (reverse cl-agent--asked))
             :unused (vconcat cl-agent--answers)
             :messages (vconcat (reverse cl-agent--messages))
             :point final-point
             :modified (if (buffer-modified-p) t :false)
             :saved saved)))))

;;; Starting

(defvar cl-agent-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-a") #'cl-agent-ask)
    map)
  "cl-agent's keys in every buffer: a minor mode's, so major modes' own
C-c C-a (cc-mode's c-toggle-auto-newline) does not hide it.")

(define-minor-mode cl-agent-mode
  "cl-agent's keys everywhere: C-c C-a asks the agent about the region or form."
  :global t :lighter nil :keymap cl-agent-mode-map)

(defun cl-agent-start ()
  "Set cl-agent up in this Emacs, then say it is ready."
  (cl-agent-mode 1)
  ;; The page closes frames itself: no "C-x 5 0" hint in every new one.
  (setq server-client-instructions nil)
  ;; The agent's writes, and edits elsewhere, reach unmodified buffers.
  (setq auto-revert-verbose nil)
  (global-auto-revert-mode 1)
  (add-hook 'post-command-hook #'cl-agent--report)
  (add-hook 'after-save-hook #'cl-agent--saved)
  (run-at-time 1 1 (lambda () (cl-agent--watchdog) (cl-agent--report)))
  ;; Once the command loop runs, the server is up.
  (run-at-time 0 nil (lambda () (cl-agent--emit "ready" :version emacs-version :pid (emacs-pid)))))

(provide 'cl-agent)
;;; cl-agent.el ends here
