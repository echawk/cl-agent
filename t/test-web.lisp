;;;; t/test-web.lisp -- the web frontend (src/ui/web/), tested with real
;;;; HTTP against real loopback hunchentoot instances, the same reasoning
;;;; as t/test-mcp.lisp's real subprocesses.  Each test runs with its own
;;;; temporary *CONFIG-DIRECTORY* (see RUN-ALL-TESTS), so asset overrides
;;;; written here never touch the user's ~/.config/cl-agent/web/.

(in-package :cl-agent)

(defparameter *test-web-port* 14599
  "Preferred port for web tests; START-WEB-ACCEPTOR moves up if it is taken.")

(defmacro with-test-web-frontend ((var) &body body)
  `(let ((,var (make-frontend :web :port *test-web-port*)))
     (unwind-protect (progn (ui-start ,var) (sleep 0.1) ,@body)
       (ui-stop ,var))))

(defun web-test-url (frontend path)
  (format nil "http://127.0.0.1:~d~a" (web-frontend-port frontend) path))

(defun web-get (frontend path)
  "(values BODY STATUS HEADERS) for a GET of PATH."
  (multiple-value-bind (body status headers)
      (drakma:http-request (web-test-url frontend path))
    (values (if (stringp body) body (and body (babel:octets-to-string body :encoding :utf-8)))
            status headers)))

(defun web-get-json (frontend path)
  (json-decode (web-get frontend path)))

(defun web-post (frontend path &key json form (trusted t))
  "(values BODY STATUS) for a POST, with the CSRF header unless TRUSTED is NIL."
  (multiple-value-bind (body status)
      (drakma:http-request (web-test-url frontend path) :method :post
                           :additional-headers (and trusted '(("X-CL-Agent" . "1")))
                           :content-type (if form "application/x-www-form-urlencoded" "application/json")
                           :content (or form (and json (json-encode json)) ""))
    (values (if (stringp body) body (and body (babel:octets-to-string body :encoding :utf-8)))
            status)))

(defun raw-http-status-line (port request)
  "Send REQUEST verbatim to PORT and return the response's status line."
  (let ((socket (usocket:socket-connect "127.0.0.1" port :element-type 'character)))
    (unwind-protect
         (let ((stream (usocket:socket-stream socket)))
           (write-string request stream)
           (force-output stream)
           (read-line stream nil ""))
      (usocket:socket-close socket))))

;;; --- the page and its assets ---

(deftest web-index-fills-every-placeholder ()
  (with-test-web-frontend (frontend)
    (multiple-value-bind (body status) (web-get frontend "/")
      (check-equal status 200)
      (check (search "cl-agent" body))
      (check (search "/assets/main.js" body))
      (check (search "/assets/theme.css" body))
      (check (search "CL_AGENT_BOOT = {" body))
      (check (search "MathJax-script" body))
      (check (not (search "{{" body)) "no placeholder is left unfilled"))))

(deftest web-safe-index-serves-built-in-assets-only ()
  (with-test-web-frontend (frontend)
    (write-web-asset "patches/loud.css" "body { color: red; }")
    (let ((normal (web-get frontend "/"))
          (safe (web-get frontend "/safe")))
      (check (search "data-patch=\"patches/loud.css\"" normal))
      (check (search "/safe/assets/main.js" safe))
      (check (search "\"safe\":true" safe))
      (check (not (search "patches/loud.css" safe))))))

(deftest web-assets-are-served-with-their-content-types ()
  (with-test-web-frontend (frontend)
    (dolist (case '(("/assets/app.css" "text/css") ("/assets/core.js" "text/javascript")
                    ("/assets/index.html" "text/html") ("/assets/EXTENDING.md" "text/markdown")))
      (multiple-value-bind (body status headers) (web-get frontend (first case))
        (check-equal status 200 (first case))
        (check (plusp (length body)))
        (check (search (second case) (cdr (assoc :content-type headers))) (first case))))
    (check-equal (nth-value 1 (web-get frontend "/assets/no-such-file.css")) 404)
    (check-equal (nth-value 1 (web-get frontend "/assets/..%2Fcl-agent.asd")) 404)))

(deftest web-every-built-in-client-file-is-in-the-image ()
  (dolist (path '("index.html" "theme.css" "app.css" "core.js" "render.js" "composer.js"
                  "agents.js" "panels.js" "main.js" "EXTENDING.md"))
    (check (builtin-web-asset-content path) path)))

(deftest web-asset-paths-are-validated ()
  (dolist (good '("app.css" "patches/x.js" "my-panel.js" "notes.md"))
    (check (valid-web-asset-path-p good) good))
  (dolist (bad '("" "../x.css" "/etc/passwd" ".history/x.css" "a/b/c.css" "x.exe" "patches/.x.js" "a b.css"))
    (check (not (valid-web-asset-path-p bad)) bad))
  (check-condition error (write-web-asset "../escape.css" "x")))

;;; --- layers: override, extension, builtin; history and reset ---

(deftest web-override-wins-and-reset-restores-the-built-in ()
  (with-test-web-frontend (frontend)
    (let ((builtin (builtin-web-asset-content "theme.css")))
      (write-web-asset "theme.css" "/* first */")
      (write-web-asset "theme.css" "/* second */")
      (check (search "second" (web-get frontend "/assets/theme.css")))
      (check (search "--paper" (web-get frontend "/safe/assets/theme.css")) "safe mode ignores the override")
      (check-equal (nth-value 1 (find-web-asset "theme.css")) :override)
      (check-equal (length (web-asset-history "theme.css")) 1)
      (reset-web-asset "theme.css" :to :previous)
      (check (search "first" (find-web-asset "theme.css")))
      (reset-web-asset "theme.css")
      (check-equal (find-web-asset "theme.css") builtin)
      (check-equal (nth-value 1 (find-web-asset "theme.css")) :builtin)
      (check (web-asset-history "theme.css") "the removed override is kept in history"))))

(deftest web-reset-all-removes-every-override ()
  (write-web-asset "app.css" "/* a */")
  (write-web-asset "patches/p.js" "export {};")
  (check-equal (sort (reset-all-web-assets) #'string<) '("app.css" "patches/p.js"))
  (check-equal (web-asset-override-paths) nil))

(deftest define-web-patch-registers-an-extension-layer-patch ()
  (unwind-protect
       (progn
         (define-web-patch test-patch :css ".x { color: red; }" :js "export const x = 1;")
         (check-equal (nth-value 1 (find-web-asset "patches/test-patch.js")) :extension)
         (check (member "patches/test-patch.css" (web-ui-patch-paths) :test #'string=))
         (check (not (web-ui-patch-paths :safe t)))
         (check (search "patches/test-patch.js" (web-index-html)))
         (check (not (find-web-asset "patches/test-patch.js" :safe t))))
    (remove-web-patch 'test-patch))
  (check (not (find-web-asset "patches/test-patch.js"))))

(deftest web-asset-change-reaches-open-pages-as-an-event ()
  (with-test-web-frontend (frontend)
    (let ((before (web-frontend-seq frontend)))
      (write-web-asset "app.css" "/* restyled */")
      (let ((event (json-decode (cdr (first (web-frontend-events frontend))))))
        (check (> (web-frontend-seq frontend) before))
        (check-equal (jget event "type") "asset")
        (check-equal (jget event "paths") '("app.css"))
        (check-equal (jget event "reload") nil "CSS restyles in place")))
    (write-web-asset "patches/x.js" "export {};")
    (check-equal (jget (json-decode (cdr (first (web-frontend-events frontend)))) "reload") t)))

;;; --- safety ---

(deftest web-mutating-requests-need-the-csrf-header ()
  (with-test-web-frontend (frontend)
    (check-equal (nth-value 1 (web-post frontend "/api/interrupt" :trusted nil)) 403)
    (check-equal (nth-value 1 (web-post frontend "/api/ui/reset" :json (jobj "all" t) :trusted nil)) 403)
    (check-equal (nth-value 1 (web-post frontend "/api/interrupt")) 200)))

(deftest web-rejects-requests-for-foreign-hosts ()
  (with-test-web-frontend (frontend)
    (let ((port (web-frontend-port frontend)))
      (check (search "403" (raw-http-status-line
                            port (format nil "GET /api/state HTTP/1.1~c~cHost: evil.example~c~cConnection: close~c~c~c~c"
                                         #\Return #\Newline #\Return #\Newline #\Return #\Newline #\Return #\Newline))))
      (check (search "200" (raw-http-status-line
                            port (format nil "GET /api/state HTTP/1.1~c~cHost: localhost:~d~c~cConnection: close~c~c~c~c"
                                         #\Return #\Newline port #\Return #\Newline #\Return #\Newline #\Return #\Newline)))))))

(deftest loopback-host-p-accepts-only-loopback-names ()
  (dolist (host '("127.0.0.1:4567" "localhost:4567" "localhost" "[::1]:4567"))
    (check (loopback-host-p host) host))
  (dolist (host '("evil.example" "127.0.0.1.evil.example" "" "10.0.0.1:4567"))
    (check (not (loopback-host-p host)) host)))

;;; --- routes ---

(deftest define-web-route-serves-an-extension-endpoint ()
  (unwind-protect
       (progn
         (define-web-route test-echo (:path "/api/ext/test-echo")
           (jobj "echo" (web-param "x")))
         (define-web-route test-prefix (:prefix "/api/ext/files/")
           (jobj "rest" (subseq (web-request-path) (length "/api/ext/files/"))))
         (with-test-web-frontend (frontend)
           (check-equal (jget (web-get-json frontend "/api/ext/test-echo?x=hi") "echo") "hi")
           (check-equal (jget (web-get-json frontend "/api/ext/files/a/b.txt") "rest") "a/b.txt")
           (check-equal (nth-value 1 (web-get frontend "/api/ext/missing")) 404)))
    (unregister-web-route 'test-echo)
    (unregister-web-route 'test-prefix)))

(deftest web-route-errors-become-json-500s ()
  (unwind-protect
       (progn
         (define-web-route test-boom (:path "/api/ext/boom") (error "kaboom"))
         (with-test-web-frontend (frontend)
           (multiple-value-bind (body status) (web-get frontend "/api/ext/boom")
             (check-equal status 500)
             (check (search "kaboom" body)))))
    (unregister-web-route 'test-boom)))

(deftest web-ui-extension-forms-count-as-integrations-and-roll-back ()
  (dolist (form '("(define-web-route r (:path \"/api/ext/r\") nil)"
                  "(define-web-patch p :css \"\")"
                  "(define-command-completer \"x\" (c) nil)"
                  "(define-completion-source s (c) nil)"))
    (check (extension-source-integrates-p (format nil "(in-package :cl-agent)~%~a" form)) form))
  (let ((snapshot (snapshot-mutation-state)))
    (unwind-protect
         (progn
           (define-web-route rolled-back (:path "/api/ext/rolled-back") nil)
           (define-web-patch rolled-back :css "x{}")
           (check (gethash "rolled-back" *web-routes*))
           (restore-mutation-state snapshot)
           (check (not (gethash "rolled-back" *web-routes*)) "routes are restored")
           (check (not (gethash "patches/rolled-back.css" *web-assets*)) "image patches are restored"))
      (unregister-web-route 'rolled-back)
      (remove-web-patch 'rolled-back))))

;;; --- state, events, and the UI protocol ---

(deftest web-state-snapshot-has-the-documented-shape ()
  (with-test-web-frontend (frontend)
    (multiple-value-bind (body status) (web-get frontend "/api/state")
      (check-equal status 200)
      (check (search "\"messages\":[]" (remove #\Space body)) "an empty transcript is [], not false")
      (let ((state (json-decode body)))
        (dolist (key '("seq" "instance" "messages" "pending" "thinking" "planning" "queued"
                       "activity" "subagents" "session" "ui"))
          (check (nth-value 1 (gethash key state)) key))
        (check-equal (jget (jget state "session") "port") (web-frontend-port frontend))
        (check-equal (jget (jget state "ui") "safe") nil)))
    (check (search "\"messages\"" (web-get frontend "/api/messages")) "the older endpoint name still works")))

(deftest web-state-passes-through-the-web-ui-state-hook ()
  (unwind-protect
       (progn
         (add-hook :web-ui-state 'test-extra (lambda (state) (setf (gethash "extra" state) 42) state))
         (with-test-web-frontend (frontend)
           (check-equal (jget (web-get-json frontend "/api/state") "extra") 42)))
    (remove-hook :web-ui-state 'test-extra)))

(deftest web-page-passes-through-the-web-ui-page-hook ()
  (unwind-protect
       (progn
         (add-hook :web-ui-page 'test-banner
                   (lambda (page) (list* :html (replace-all-substrings (getf page :html) "</body>" "<!--hooked--></body>") page)))
         (check (search "<!--hooked-->" (web-index-html))))
    (remove-hook :web-ui-page 'test-banner)))

(deftest web-frontend-messages-and-activity-reflect-ui-calls ()
  (with-test-web-frontend (frontend)
    (ui-system frontend "system notice")
    (ui-assistant-text frontend "assistant reply")
    (ui-tool-started frontend "shell" (jobj "command" "ls"))
    (ui-tool-finished frontend "shell" (jobj "command" "ls") "a.txt")
    (let* ((state (web-get-json frontend "/api/state"))
           (messages (jget state "messages"))
           (activity (jget state "activity"))
           (call (find "tool-call" activity :key (lambda (a) (jget a "kind")) :test #'equal))
           (output (find "tool-output" activity :key (lambda (a) (jget a "kind")) :test #'equal)))
      (check-equal (mapcar (lambda (m) (jget m "role")) messages) '("system" "assistant" "tool" "tool"))
      (check-equal (jget (first messages) "inline") t "idle output is shown in the listener")
      (check-equal (jget call "text") "shell: ls")
      (check-equal (jget call "tool") "shell")
      (check-equal (jget output "ref") (jget call "id") "the output points at its call")
      (check-equal (jget output "text") "a.txt"))))

(deftest web-system-output-during-a-turn-stays-out-of-the-listener ()
  (let ((frontend (make-frontend :web)))
    (ui-thinking-started frontend)
    (ui-system frontend "progress")
    (ui-thinking-stopped frontend)
    (check-equal (getf (first (web-frontend-transcript frontend)) :inline) nil)))

(deftest web-frontend-renders-assistant-markdown-in-the-snapshot ()
  (with-test-web-frontend (frontend)
    (ui-assistant-text frontend (format nil "# Heading~%~%A **formatted** reply."))
    (let ((message (first (jget (web-get-json frontend "/api/state") "messages"))))
      (check (search "<h1>Heading</h1>" (jget message "html")))
      (check (search "<strong>formatted</strong>" (jget message "html"))))))

(deftest web-frontend-hides-compaction-summary-behind-its-own-role ()
  (with-test-web-frontend (frontend)
    (ui-context-compacted frontend "Keep the test result." 120 40)
    (let ((message (first (jget (web-get-json frontend "/api/state") "messages"))))
      (check-equal (jget message "role") "compaction")
      (check (search "Keep the test result" (jget message "text")))))
  (check (search "view continuity summary" (builtin-web-asset-content "render.js"))))

(deftest web-frontend-hides-tool-call-narration-and-clears-pending ()
  (let ((frontend (make-frontend :web)))
    (ui-assistant-delta frontend "I will inspect this first.")
    (check (not (ui-show-tool-call-assistant-text-p frontend)))
    (ui-discard-assistant-pending frontend)
    (check-equal (jget (json-decode (web-frontend-status-json frontend)) "pending") "")))

(deftest web-frontend-pending-and-thinking-reflect-streaming-state ()
  (with-test-web-frontend (frontend)
    (ui-thinking-started frontend)
    (let ((state (web-get-json frontend "/api/state")))
      (check-equal (jget state "thinking") t)
      (check-equal (jget state "pending") ""))
    (ui-assistant-delta frontend "Sure")
    (ui-assistant-delta frontend "!")
    (check-equal (jget (web-get-json frontend "/api/state") "pending") "Sure!")
    (ui-thinking-stopped frontend)
    (ui-assistant-text frontend "Sure!")
    (let ((state (web-get-json frontend "/api/state")))
      (check-equal (jget state "pending") "" "the complete text clears PENDING")
      (check-equal (jget state "thinking") nil)
      (check-equal (length (jget state "messages")) 1)
      (check-equal (jget (first (jget state "messages")) "text") "Sure!"))))

(deftest web-frontend-stats-reflect-ui-stats-updated ()
  (with-test-web-frontend (frontend)
    (check-equal (jget (web-get-json frontend "/api/state") "stats") nil "no stats yet")
    (ui-stats-updated frontend (list :provider "ollama" :model "m" :elapsed-seconds 3
                                     :requests 2 :tool-calls 1 :total-tokens 50))
    (let ((stats (jget (web-get-json frontend "/api/state") "stats")))
      (check-equal (jget stats "provider") "ollama")
      (check-equal (jget stats "requests") 2)
      (check-equal (jget stats "total_tokens") 50))))

(deftest web-subagent-snapshots-become-json ()
  (let ((json (web-subagent-json (list :id "sa-1" :state :running :role "explore" :tools '("shell")
                                       :tool-calls 2 :tokens 900 :created-at 3900000000 :started-at 3900000001))))
    (check-equal (jget json "state") "running")
    (check-equal (jget json "tools") '("shell"))
    (check-equal (jget json "tool_calls") 2)
    (check-equal (jget json "started") (- 3900000001 2208988800))
    (check-equal (gethash "finished" json) :null)))

(deftest web-event-log-asks-a-page-that-fell-behind-to-resync ()
  (let ((frontend (make-frontend :web))
        (*web-event-log-size* 5))
    (dotimes (i 20) (ui-assistant-delta frontend "x"))
    (check-equal (web-frontend-events-after frontend 0) :resync)
    (let ((recent (web-frontend-events-after frontend 18)))
      (check-equal (mapcar #'car recent) '(19 20) "oldest first"))
    (check-equal (web-frontend-events-after frontend 20) nil)))

(deftest web-event-stream-delivers-events-after-since ()
  (with-test-web-frontend (frontend)
    (ui-system frontend "before")
    (let ((since (web-frontend-seq frontend)))
      (ui-system frontend "after the cursor")
      ;; Stop the frontend shortly so the stream ends even if a check fails.
      (bt:make-thread (lambda () (sleep 3) (ui-stop frontend)))
      (let ((stream (drakma:http-request (web-test-url frontend (format nil "/api/events?since=~d" since))
                                         :want-stream t))
            (lines nil))
        (unwind-protect
             (loop for line = (ignore-errors (read-line stream nil nil))
                   while line
                   do (push line lines)
                   until (search "after the cursor" line))
          (ignore-errors (close stream)))
        (let ((text (format nil "~{~a~%~}" (reverse lines))))
          (check (search "event: hello" text))
          (check (search "after the cursor" text))
          (check (not (search "\"before\"" text)) "nothing at or before SINCE is resent")
          (check (search (format nil "id: ~d" (1+ since)) text)))))))

;;; --- input ---

(deftest web-frontend-send-reaches-ui-prompt-input ()
  (with-test-web-frontend (frontend)
    (bt:make-thread (lambda () (sleep 0.2) (web-post frontend "/api/send" :json (jobj "text" "hello from test"))))
    (check-equal (ui-prompt-input frontend) "hello from test")
    (check-equal (getf (first (web-frontend-transcript frontend)) :turn) 1 "a user line starts turn 1")))

(deftest web-frontend-send-accepts-form-encoding ()
  (with-test-web-frontend (frontend)
    (bt:make-thread (lambda () (sleep 0.2) (web-post frontend "/api/send" :form "text=hello+form")))
    (check-equal (ui-prompt-input frontend) "hello form")))

(deftest web-frontend-send-rejects-empty-text ()
  (with-test-web-frontend (frontend)
    (check-equal (nth-value 1 (web-post frontend "/api/send" :json (jobj "text" "   "))) 400)))

(deftest web-frontend-quit-endpoint-unblocks-prompt-input ()
  (with-test-web-frontend (frontend)
    (bt:make-thread (lambda () (sleep 0.2) (web-post frontend "/api/quit")))
    (check-equal (ui-prompt-input frontend) nil)))

(deftest web-frontend-uses-next-port-when-preferred-port-is-occupied ()
  (let* ((port 14699)
         (first (make-frontend :web :port port))
         (second nil))
    (unwind-protect
         (progn
           (ui-start first)
           (setf second (make-frontend :web :port (web-frontend-port first)))
           (ui-start second)
           (check-equal (web-frontend-port second) (1+ (web-frontend-port first))))
      (when second (ui-stop second))
      (ui-stop first))))

;;; --- input ordering ---

(deftest web-input-queues-while-a-line-is-still-running ()
  ;; A line handed to the REPL keeps the frontend busy until it prompts
  ;; again, so a second line (even during a slash command) queues behind it.
  (let ((frontend (make-frontend :web)))
    (check-equal (web-frontend-submit frontend "/first") :immediate)
    (check-equal (web-frontend-submit frontend "/second") :queued)
    (check-equal (trivial-channels:recvmsg (web-frontend-input-channel frontend)) "/first")
    (ui-system frontend "output of /first")
    (check-equal (getf (first (web-frontend-transcript frontend)) :inline) t
                 "slash command output is inline even though the frontend is busy")
    (check-equal (ui-poll-input frontend) '("/second"))
    (check-equal (mapcar (lambda (e) (getf e :role)) (reverse (web-frontend-transcript frontend)))
                 '("user" "system" "user") "the queued line is shown when it is delivered")))

(deftest web-prompting-clears-a-stale-interrupt ()
  (let ((frontend (make-frontend :web)))
    (setf (frontend-busy-p frontend) t)
    (frontend-request-interrupt frontend)
    (trivial-channels:sendmsg (web-frontend-input-channel frontend) "next")
    (check-equal (ui-prompt-input frontend) "next")
    (check (not (ui-interrupt-requested-p frontend)))))

;;; --- the agent's tools ---

(deftest web-ui-write-asset-tool-writes-edits-and-validates ()
  (check (search "Wrote patches/t.css" (call-tool "web-ui-write-asset" (jobj "path" "patches/t.css" "content" ".a { color: red; }"))))
  (check (search "Wrote" (call-tool "web-ui-write-asset" (jobj "path" "patches/t.css" "old" "red" "new" "blue"))))
  (check-equal (find-web-asset "patches/t.css") ".a { color: blue; }")
  (check (search "not found" (call-tool "web-ui-write-asset" (jobj "path" "patches/t.css" "old" "green" "new" "x"))))
  (check (search "failed its syntax check" (call-tool "web-ui-write-asset" (jobj "path" "broken.css" "content" ".a { color: red;"))))
  (check (not (find-web-asset "broken.css")) "a failing check writes nothing")
  (check (search "Not written" (call-tool "web-ui-write-asset" (jobj "path" "../x.css" "content" ""))))
  (when (node-available-p)
    (let ((report (call-tool "web-ui-write-asset" (jobj "path" "patches/bad.js" "content" "const = ;"))))
      (check (search "syntax check" report))
      (check (search "<asset>" report) "the temporary file's path is hidden"))
    (check (search "Wrote" (call-tool "web-ui-write-asset" (jobj "path" "patches/good.js" "content" "export const ok = 1;"))))))

(deftest web-ui-assets-and-reset-tools ()
  (check (search "CLAgent" (call-tool "web-ui-assets" (jobj "action" "guide"))))
  (check (search "theme.css" (call-tool "web-ui-assets" (jobj "action" "list"))))
  (check (search "    1  " (call-tool "web-ui-assets" (jobj "action" "read" "path" "theme.css" "start_line" 1 "end_line" 3))))
  (write-web-asset "app.css" "/* mine */")
  (check (search "Removed the override" (call-tool "web-ui-reset-asset" (jobj "path" "app.css"))))
  (check (search "No web page is open" (call-tool "web-ui-command" (jobj "command" "toast" "args" (jobj "text" "hi"))))))

(deftest web-ui-command-reaches-open-pages ()
  (with-test-web-frontend (frontend)
    (check (search "Sent toast" (call-tool "web-ui-command" (jobj "command" "toast" "args" (jobj "text" "hi")))))
    (let ((event (json-decode (cdr (first (web-frontend-events frontend))))))
      (check-equal (jget event "type") "ui")
      (check-equal (jget event "command") "toast")
      (check-equal (jget (jget event "args") "text") "hi"))))

(deftest check-css-balance-ignores-braces-in-strings-and-comments ()
  (check-equal (check-css-balance ".a::before { content: \"}\"; } /* { */") nil)
  (check (check-css-balance ".a {"))
  (check (check-css-balance "}")))

;;; --- markdown rendering (ui/web/markdown.lisp) ---

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
    (check (search "language-lisp" code-html))
    (check (search "(defun hello () 42)" code-html))
    (check (search "<pre" inline-fence-html))
    (check (search "(let ((answer 42)) answer)" inline-fence-html))))

(deftest web-frontend-does-not-leak-code-block-markers-between-prose ()
  (let ((html (web-markdown-html
               (format nil "An excerpt:~%```lisp~%(defun answer () 42)~%```~%It returns the answer."))))
    (check (search "<pre" html))
    (check (search "(defun answer () 42)" html))
    (check (search "It returns the answer" html))
    (check (not (search "CLAGENT-CODE-BLOCK" html)))))

(deftest web-acceptor-does-not-log-dropped-connections ()
  (let* ((log (make-string-output-stream))
         (acceptor (make-instance 'web-ui-acceptor :port 0 :message-log-destination log)))
    (hunchentoot:acceptor-log-message acceptor :error "Error while processing connection: ~A"
                                      (make-condition 'usocket:connection-aborted-error))
    (check-equal (get-output-stream-string log) "" "a browser hanging up is routine")
    (hunchentoot:acceptor-log-message acceptor :error "Error while processing connection: ~A"
                                      (make-condition 'simple-error :format-control "real trouble"))
    (check (search "real trouble" (get-output-stream-string log)) "real errors are still logged")))
