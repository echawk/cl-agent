;;;; tool-analytics.lisp -- how the agent's tools actually go: which fail and
;;;; how, how long they take, where the agent gets stuck repeating a failing
;;;; call, and what usually follows what.  Read from the durable session
;;;; logs (events.lisp), so it covers every session, subagents included.
;;;;
;;;; Each tool call is a :tool-call-started event and its :tool-result-recorded
;;;; event (linked by parent id).  Results record :elapsed-ms and :outcome
;;;; (:ok :error :denied :vetoed :invalid) since run-tool-call began saving
;;;; them; for older ones the outcome is read from the result's text and the
;;;; time from the two events' (whole-second) times.

(in-package :cl-agent)

(defparameter *stuck-run-length* 3
  "Calls in a row to one tool, most of them failing, that count as stuck.")

(defun infer-tool-outcome (content)
  (let ((text (or content "")))
    (cond ((uiop:string-prefix-p "Error running " text) :error)
          ((uiop:string-prefix-p "Tool call vetoed" text) :vetoed)
          ((uiop:string-prefix-p "Tool call was not run because its JSON" text) :invalid)
          ((and (uiop:string-prefix-p "Tool " text)
                (or (search "is denied by capability mode" text) (search "requires approval under" text)))
           :denied)
          (t :ok))))

(defun session-tool-calls (session-id)
  "SESSION-ID's tool calls, in order: plists (:session :turn :tool :time
:elapsed-ms :outcome :text)."
  (let ((started (make-hash-table :test 'equal))
        (calls '()))
    (dolist (event (ignore-errors (read-session-events session-id)))
      (case (getf event :kind)
        (:tool-call-started (setf (gethash (getf event :id) started) event))
        (:tool-result-recorded
         (let* ((payload (getf event :payload))
                (start (gethash (getf event :parent-id) started))
                (content (getf (getf payload :message) :content)))
           (push (list :session session-id
                       :turn (getf event :turn-id)
                       :tool (getf event :component)
                       :time (getf event :time)
                       :elapsed-ms (or (getf payload :elapsed-ms)
                                       (and start (* 1000 (- (getf event :time) (getf start :time)))))
                       :outcome (or (getf payload :outcome) (infer-tool-outcome content))
                       :text (and (stringp content) (first-line content 400)))
                 calls)))))
    (nreverse calls)))

(defun recent-tool-calls (&key (days 30) (max-sessions 400))
  "Tool calls in the durable sessions active in the last DAYS days."
  (let ((since (- (get-universal-time) (* days 86400))))
    (loop for manifest in (list-durable-sessions)
          for count from 0
          while (< count max-sessions)
          when (>= (or (getf manifest :created-at) 0) (- since (* 7 86400)))
            append (remove-if (lambda (call) (< (or (getf call :time) 0) since))
                              (session-tool-calls (getf manifest :id))))))

(defun percentile (numbers fraction)
  (let ((sorted (sort (copy-list (remove nil numbers)) #'<)))
    (and sorted (nth (min (1- (length sorted)) (floor (* fraction (length sorted)))) sorted))))

(defun normalize-error-text (text)
  "TEXT, an error's first line, with its particulars blurred -- quoted
strings become \"…\", runs of digits #  -- so the same failure groups together."
  (with-output-to-string (out)
    (let ((in-quote nil) (in-number nil))
      (loop for c across (or text "")
            do (cond ((char= c #\")
                      (setf in-quote (not in-quote))
                      (unless in-quote (write-string "\"…\"" out)))
                     (in-quote)
                     ((digit-char-p c) (unless in-number (write-char #\# out)) (setf in-number t))
                     (t (setf in-number nil) (write-char c out)))))))

(defun stuck-runs (calls)
  "Runs of *STUCK-RUN-LENGTH* or more calls in a row, in one turn, to one
tool, more than half of them failing: (tool length failures session turn)."
  (let ((runs '()))
    (loop with i = 0
          while (< i (length calls))
          do (let* ((call (nth i calls))
                    (j (or (position-if-not (lambda (other)
                                              (and (equal (getf other :tool) (getf call :tool))
                                                   (equal (getf other :turn) (getf call :turn))
                                                   (equal (getf other :session) (getf call :session))))
                                            calls :start i)
                           (length calls)))
                    (run (subseq calls i j))
                    (failures (count-if (lambda (c) (not (eq (getf c :outcome) :ok))) run)))
               (when (and (>= (length run) *stuck-run-length*) (> failures (/ (length run) 2)))
                 (push (list (getf call :tool) (length run) failures (getf call :session) (getf call :turn)) runs))
               (setf i j)))
    (sort runs #'> :key #'second)))

(defun tool-analytics-report (&key (days 30) tool (limit 12))
  "A report on the tool calls of the last DAYS days (just TOOL's, when given)."
  (let* ((all (recent-tool-calls :days days))
         (calls (if tool (remove tool all :key (lambda (call) (getf call :tool)) :test-not #'equal) all))
         (by-tool (make-hash-table :test 'equal)))
    (dolist (call calls) (push call (gethash (getf call :tool) by-tool)))
    (if (null calls)
        (format nil "No tool calls~@[ to ~a~] in the last ~d days." tool days)
        (with-output-to-string (out)
          (format out "~d tool call~:p~@[ to ~a~] in ~d session~:p, last ~d days; ~,1f% did not succeed.~%"
                  (length calls) tool (length (remove-duplicates (mapcar (lambda (c) (getf c :session)) calls) :test #'equal))
                  days (* 100 (/ (count-if-not (lambda (c) (eq (getf c :outcome) :ok)) calls) (length calls))))
          (format out "~%~24a ~6@a ~7@a ~9@a ~9@a~%" "tool" "calls" "failed" "median" "p90")
          (loop for (name . tool-calls) in (sort (alexandria:hash-table-alist by-tool) #'> :key (lambda (entry) (length (cdr entry))))
                repeat (if tool 1 limit)
                do (let ((failed (count-if-not (lambda (c) (eq (getf c :outcome) :ok)) tool-calls))
                         (times (mapcar (lambda (c) (getf c :elapsed-ms)) tool-calls)))
                     (format out "~24a ~6d ~6,1f% ~9a ~9a~%" (first-line name 24) (length tool-calls)
                             (* 100 (/ failed (length tool-calls)))
                             (let ((ms (percentile times 0.5))) (if ms (format nil "~,2fs" (/ ms 1000)) "-"))
                             (let ((ms (percentile times 0.9))) (if ms (format nil "~,2fs" (/ ms 1000)) "-")))))
          ;; What goes wrong, grouped.
          (let ((errors (make-hash-table :test 'equal)))
            (dolist (call calls)
              (unless (eq (getf call :outcome) :ok)
                ;; Blurred before it is cut short, so one failure is one group.
                (incf (gethash (list (getf call :tool) (getf call :outcome)
                                     (first-line (normalize-error-text (getf call :text)) 120))
                               errors 0))))
            (when (plusp (hash-table-count errors))
              (format out "~%Most common failures:~%")
              (loop for ((name outcome text) . count) in (sort (alexandria:hash-table-alist errors) #'> :key #'cdr)
                    repeat limit
                    do (format out "  ~3dx ~a (~(~a~)): ~a~%" count name outcome text))))
          ;; Where the agent got stuck.
          (let ((stuck (stuck-runs calls)))
            (when stuck
              (format out "~%Stuck: the same tool, mostly failing, ~d+ times in a row in one turn:~%" *stuck-run-length*)
              (loop for (name length failures session turn) in stuck
                    repeat limit
                    do (format out "  ~a ~dx (~d failed) -- ~a~@[ turn ~a~]~%" name length failures session turn))))
          ;; What follows what.
          (unless tool
            (let ((pairs (make-hash-table :test 'equal)))
              (loop for (a b) on all
                    while b
                    when (and (equal (getf a :turn) (getf b :turn)) (equal (getf a :session) (getf b :session)))
                      do (incf (gethash (list (getf a :tool) (getf b :tool)) pairs 0)))
              (when (plusp (hash-table-count pairs))
                (format out "~%Usually followed by:~%")
                (loop for ((a b) . count) in (sort (alexandria:hash-table-alist pairs) #'> :key #'cdr)
                      repeat limit
                      do (format out "  ~3dx ~a -> ~a~%" count a b)))))))))

(define-tool tool-stats (args)
    (:description "How your tools actually go, from every session's log: calls, failure rates and durations per tool; the most common failures (grouped); where you got stuck calling one tool over and over while it failed; and which tool usually follows which. Use it to notice a tool you misuse, a failure you keep repeating, or a sequence worth turning into one step. tool narrows it to one tool; days sets how far back (default 30)."
     :effects '(:read-workspace)
     :parameters
     (jobj "type" "object"
           "properties" (jobj "tool" (jobj "type" "string") "days" (jobj "type" "integer"))
           "required" :empty-array))
  (let ((days (let ((days (jget args "days"))) (if (and (integerp days) (plusp days)) days 30))))
    (tool-analytics-report :days days :tool (jget args "tool"))))

(define-slash-command tool-stats (session arg)
  "Usage: /tool-stats [TOOL]: how the tools have gone over the last 30 days --
failure rates, durations, common failures, stuck loops, what follows what."
  (ui-system (session-frontend session)
             (tool-analytics-report :tool (let ((name (string-trim " " (or arg "")))) (and (plusp (length name)) name))))
  t)
