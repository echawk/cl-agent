;;;; lem/commands.lisp -- the agent runs Lem's own editing commands (M-x
;;;; NAME) on a file's buffer, answering their prompts itself.
;;;;
;;;; A Lem command that asks something reads it in the minibuffer: run from
;;;; the agent, with no one at the keyboard, that prompt would wait forever
;;;; (the "recursive use of prompt window" the agent hit).  The minibuffer
;;;; bridge answers instead: while RUN-LEM-COMMAND runs, Lem's three prompt
;;;; entry points (%PROMPT-FOR-LINE, -CHARACTER, -FILE) and READ-KEY (once a
;;;; command's own pending keys are used up) take the next of the answers the
;;;; agent gave, and a prompt with none left aborts the command, saying what
;;;; it asked -- never blocking the editor thread, and never taking keys the
;;;; user types in the Lem view.  Outside RUN-LEM-COMMAND they behave as in Lem.
;;;;
;;;; The command runs as M-x would run it, in the buffer, shown in the current
;;;; window for the duration (and put back before Lem redraws, so the user's
;;;; view does not move); what it changed comes back as the changed lines.

(in-package :cl-agent)

(defvar *lem-bridge* nil
  "While RUN-LEM-COMMAND runs: a cons (ANSWERS . ASKED), the answers left and
the prompts asked so far.")

(define-condition lem-prompt-unanswered (error)
  ((prompt :initarg :prompt :reader lem-prompt-unanswered-prompt))
  (:report (lambda (condition stream)
             (format stream "The command asked ~s and no answer was left. Run it again with answers (one per prompt, in order)."
                     (string-trim " " (princ-to-string (lem-prompt-unanswered-prompt condition)))))))

(defun lem-bridge-answer (prompt)
  "The next answer for PROMPT, or signal LEM-PROMPT-UNANSWERED."
  (push (princ-to-string prompt) (cdr *lem-bridge*))
  (if (car *lem-bridge*)
      (princ-to-string (pop (car *lem-bridge*)))
      (error 'lem-prompt-unanswered :prompt prompt)))

(defun answer-character (answer)
  (cond ((member answer '("RET" "Enter" "Return") :test #'string-equal) #\Return)
        ((member answer '("SPC" "Space") :test #'string-equal) #\Space)
        ((zerop (length answer)) #\Return)
        (t (char answer 0))))

(defmacro define-lem-bridge (function (&rest arguments) &body answer)
  "Wrap Lem's FUNCTION so that, while the bridge is on, ANSWER (with
ARGUMENTS bound) replaces it."
  (let ((name (intern (format nil "CL-AGENT-BRIDGE-~a" (symbol-name function)))))
    `(progn
       (sb-int:unencapsulate ',function ',name)
       (sb-int:encapsulate ',function ',name
                           (lambda (original &rest args)
                             (if *lem-bridge*
                                 (destructuring-bind ,arguments args ,@answer)
                                 (apply original args)))))))

(define-lem-bridge lem-core::%prompt-for-line (prompt &key test-function &allow-other-keys)
  (let ((answer (lem-bridge-answer prompt)))
    (when (and test-function (not (funcall test-function answer)))
      (error "The answer ~s does not fit the prompt ~s." answer (string-trim " " prompt)))
    answer))

(define-lem-bridge lem-core::%prompt-for-character (prompt &key &allow-other-keys)
  (answer-character (lem-bridge-answer prompt)))

(define-lem-bridge lem-core::%prompt-for-file (prompt directory default existing gravity)
  (declare (ignore default existing gravity))
  (let ((answer (lem-bridge-answer prompt)))
    (lem:expand-file-name answer (or directory (lem:buffer-directory)))))

;; READ-KEY reads the command's own keys first (*UNREAD-KEYS*, as when
;; keys are given); only then does it take an answer, as a key.
(sb-int:unencapsulate 'lem:read-key 'cl-agent-bridge-read-key)
(sb-int:encapsulate 'lem:read-key 'cl-agent-bridge-read-key
                    (lambda (original)
                      (if (and *lem-bridge* (null lem-core::*unread-keys*))
                          (let ((answer (lem-bridge-answer "a key")))
                            (or (first (ignore-errors (lem:parse-keyspec answer)))
                                (lem:make-key :sym (string (answer-character answer)))))
                          (funcall original))))

;;; --- messages ---

(defvar *lem-messages* nil "While RUN-LEM-COMMAND runs: the messages shown, newest first.")

(sb-int:unencapsulate 'lem:message 'cl-agent-capture)
(sb-int:encapsulate 'lem:message 'cl-agent-capture
                    (lambda (original string &rest args)
                      (when (and *lem-bridge* string)
                        (push (ignore-errors (apply #'format nil string args)) *lem-messages*))
                      (apply original string args)))

;;; --- running a command ---

(defun lem-buffer-for (path)
  "Editor thread: the buffer visiting PATH, opening it; or the one shown."
  (if path
      (values (lem:find-file-buffer (expand-user-path path)))
      (let ((prompt (lem:active-prompt-window)))
        (lem:window-buffer (or (and prompt (ignore-errors (lem:caller-of-prompt-window prompt)))
                               (lem:current-window))))))

(defun place-point (buffer line column end-line end-column)
  "Put BUFFER's point at LINE:COLUMN (1-based), and with END-LINE mark the
region from there to END-LINE:END-COLUMN, as a selection would."
  (let ((point (lem:buffer-point buffer)))
    (flet ((goto (line column)
             (lem:move-to-line point line)
             (lem:line-start point)
             (lem:character-offset point (max 0 (1- (or column 1))))))
      (when line
        (goto line column)
        (when end-line
          (lem:set-current-mark point)
          (goto end-line end-column))))))

(defun changed-lines (before after &key (limit 80))
  "A short account of how AFTER differs from BEFORE: the changed range of
lines, numbered as they are now."
  (if (string= before after)
      "No change to the text."
      (let* ((old (uiop:split-string before :separator '(#\Newline)))
             (new (uiop:split-string after :separator '(#\Newline)))
             (head (or (mismatch old new :test #'string=) (min (length old) (length new))))
             (tail (loop for i from 0
                         while (and (< i (- (length old) head)) (< i (- (length new) head))
                                    (string= (nth (- (length old) 1 i) old) (nth (- (length new) 1 i) new)))
                         finally (return i)))
             (removed (- (length old) head tail))
             (shown (subseq new head (- (length new) tail))))
        (format nil "Lines ~d-~d changed (~d line~:p replaced by ~d):~%~a~@[~%... ~d more~]"
                (1+ head) (+ head (max 1 (length shown))) removed (length shown)
                (format nil "~{~a~^~%~}"
                        (loop for line in shown for n from (1+ head) repeat limit
                              collect (format nil "~5d  ~a" n line)))
                (and (> (length shown) limit) (- (length shown) limit))))))

(defun run-lem-command (command &key path answers keys line column end-line end-column argument)
  "Run Lem COMMAND (a command name, as M-x takes it) -- or KEYS, a key
sequence such as \"C-x h C-M-\\\\\" -- in the buffer visiting PATH (else the
current one), with point at LINE:COLUMN and the region to END-LINE:END-COLUMN
when given, and ANSWERS (strings) for its prompts.  ARGUMENT is the
universal argument (C-u N).  Returns a plist (:buffer :path :changes
:messages :point :modified :asked :error)."
  (lem-call
   (lambda ()
     (let* ((buffer (lem-buffer-for path))
            ;; Mid-prompt in the Lem view, the current window is the
            ;; minibuffer's: use the window it was asked from.
            (window (let ((prompt (lem:active-prompt-window)))
                      (or (and prompt (ignore-errors (lem:caller-of-prompt-window prompt)))
                          (lem:current-window))))
            (shown (lem:window-buffer window))
            (before (editor-buffer-text buffer))
            (*lem-bridge* (cons (mapcar #'princ-to-string answers) nil))
            (*lem-messages* nil)
            (failure nil))
       (lem:with-current-window window
         (unwind-protect
              (handler-case
                  (progn
                    (unless (eq shown buffer) (lem:switch-to-buffer buffer nil nil))
                    (place-point buffer line column end-line end-column)
                    (cond (keys
                           (lem:execute-key-sequence (lem:parse-keyspec keys)))
                          (t
                           (let ((found (lem:find-command command)))
                             (unless found (error "Lem has no command named ~s." command))
                             (lem:call-command found argument)))))
                (error (condition) (setf failure (princ-to-string condition))))
           (unless (or (eq shown buffer) (lem:deleted-buffer-p shown))
             (lem:switch-to-buffer shown nil nil))))
       (let ((after (editor-buffer-text buffer)))
         (when (string/= before after) (editor-bump-version buffer))
         (list :buffer (lem:buffer-name buffer)
               :path (lem:buffer-filename buffer)
               :changes (changed-lines before after)
               :changed (string/= before after)
               :text (and (string/= before after) after)
               :version (editor-version buffer)
               :messages (remove nil (reverse *lem-messages*))
               :point (let ((point (lem:buffer-point buffer)))
                        (list (lem:line-number-at-point point) (1+ (lem:point-charpos point))))
               :modified (and (lem:buffer-modified-p buffer) t)
               :asked (reverse (cdr *lem-bridge*))
               :unused (car *lem-bridge*)
               :error failure))))))

(defun lem-command-names (query &key (limit 60))
  "Lem's commands whose names contain QUERY, with the first line of each
one's documentation."
  (lem-call
   (lambda ()
     (let ((names (sort (remove-if-not (lambda (name) (search (string-downcase query) name))
                                       (mapcar #'string-downcase (lem:all-command-names)))
                        #'string<)))
       (list (length names)
             (loop for name in names repeat limit
                   collect (let* ((command (lem:find-command name))
                                  (symbol (and command (ignore-errors (lem/common/command:command-name command))))
                                  (doc (and symbol (symbolp symbol) (documentation symbol 'function))))
                             (cons name (first-line doc)))))))))

(defun run-lem-command-and-publish (command &rest options &key save &allow-other-keys)
  "RUN-LEM-COMMAND, then tell open pages about the changed buffer, and save
it through Lem when SAVE."
  (let ((result (apply #'run-lem-command command (alexandria:remove-from-plist options :save))))
    (when (and (getf result :changed) (getf result :path))
      (editor-publish "file-buffer" (jobj "path" (getf result :path) "version" (getf result :version)
                                          "text" (getf result :text) "modified" (getf result :modified)
                                          "by" "agent")))
    (when (and save (getf result :path) (not (getf result :error)))
      (setf (getf result :saved) (editor-save-file (getf result :path) :by "agent-editor"))
      (when (eq (getf result :saved) :saved) (setf (getf result :modified) nil)))
    result))

(define-tool lem-command (args)
    (:description "Run one of Lem's editing commands -- the same commands as M-x in Lem (query-replace, query-replace-regexp, indent-region, indent-current-buffer, comment-region, uncomment-region, uppercase-region, downcase-region, delete-trailing-whitespace, kill-line, kill-sexp, transpose-sexps, ...; action=search finds the rest) -- on a file's editor buffer, faster and more exact than shelling out to sed or rewriting the file. The file is opened in the hosted Lem (unsaved changes the user has are included); give line/column to place point, and end_line/end_column too to select a region for region commands. A command's minibuffer prompts are answered from answers, in order: e.g. query-replace with answers [\"old\", \"new\", \"!\"] replaces every match from point (or give \"y\"/\"n\" per match instead of \"!\"; start at line 1 for the whole buffer). A prompt with no answer left stops the command and says what it asked. Instead of command, keys runs a key sequence (\"C-x h C-M-\\\\\" to indent the whole buffer). The result shows the lines that changed and Lem's messages; changes stay unsaved in the editor unless save is true. action=\"search\" lists commands whose names contain query, with their documentation."
     :effects '(:write-workspace)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "action" (jobj "type" "string" "enum" (list "run" "search"))
                 "command" (jobj "type" "string" "description" "Command name, as M-x takes it.")
                 "keys" (jobj "type" "string" "description" "A key sequence instead of command, e.g. \"C-x h C-M-\\\\\".")
                 "path" (jobj "type" "string" "description" "The file to work on; omitted, the buffer shown in the Lem editor.")
                 "answers" (jobj "type" "array" "items" (jobj "type" "string")
                                 "description" "Answers to the command's prompts, in order.")
                 "line" (jobj "type" "integer" "minimum" 1)
                 "column" (jobj "type" "integer" "minimum" 1)
                 "end_line" (jobj "type" "integer" "minimum" 1)
                 "end_column" (jobj "type" "integer" "minimum" 1)
                 "argument" (jobj "type" "integer" "description" "The universal argument (C-u N).")
                 "save" (jobj "type" "boolean" "description" "Save the file through Lem afterwards.")
                 "query" (jobj "type" "string" "description" "For action=search."))))
  (if (equal (jget args "action") "search")
      (destructuring-bind (total names) (lem-command-names (or (jget args "query") ""))
        (format nil "~d command~:p~a:~%~{~a~^~%~}" total
                (if (> total (length names)) (format nil ", first ~d shown" (length names)) "")
                (mapcar (lambda (pair) (format nil "~a~@[ -- ~a~]" (car pair) (cdr pair))) names)))
      (let ((command (jget args "command")) (keys (jget args "keys")))
        (unless (or (stringp command) (stringp keys)) (error "Give command (a Lem command name) or keys."))
        (let ((result (run-lem-command-and-publish
                       command :keys keys :path (jget args "path")
                               :answers (let ((answers (jget args "answers"))) (if (vectorp answers) (coerce answers 'list) answers))
                               :line (jget args "line") :column (jget args "column")
                               :end-line (jget args "end_line") :end-column (jget args "end_column")
                               :argument (jget args "argument") :save (jget args "save"))))
          (format nil "~:[Ran~;Stopped~] ~a in ~a~@[ (~a)~]~@[: ~a~].~%~a~@[~%Lem said: ~{~a~^ / ~}~]~@[~%Prompts answered: ~{~s~^, ~}~]~@[~%Answers not used: ~{~s~^, ~}~]~%Point is at line ~d, column ~d; the buffer is ~:[saved~;modified (unsaved)~]~*."
                  (getf result :error) (or command keys) (getf result :buffer) (getf result :path)
                  (and (getf result :error) (string-right-trim "." (getf result :error)))
                  (getf result :changes) (getf result :messages) (getf result :asked) (getf result :unused)
                  (first (getf result :point)) (second (getf result :point))
                  (getf result :modified) (getf result :saved))))))
