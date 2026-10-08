;;;; ui/web.lisp -- a browser-based chat frontend, via hunchentoot, as
;;;; a proof of concept that cl-agent's UI protocol (ui/frontend.lisp)
;;;; is not CLI-shaped: the same RUN-REPL loop that drives a terminal
;;;; session or the TUI (ui/tui.lisp) drives a browser tab here too,
;;;; none of them aware of each other.
;;;;
;;;; Deliberately minimal, as a PoC should be: one static HTML+JS page
;;;; (inline, no build step, vanilla JS) and two JSON endpoints, polled
;;;; rather than pushed (no WebSocket/SSE) -- simple enough to read in
;;;; one sitting, which matters more here than scalability. A real
;;;; product version would want SSE for push updates, multiple
;;;; concurrent sessions (this one assumes a single browser tab talking
;;;; to a single cl-agent process, via the *WEB-FRONTEND* special
;;;; variable bound in UI-START -- hunchentoot's easy-handlers are
;;;; global functions, not methods on a particular acceptor, so they
;;;; reach the active session through that variable), and auth (this
;;;; binds to 127.0.0.1 only, by design, and that's the only safety
;;;; measure it has).
;;;;
;;;; Threading: the same shape as ui/tui.lisp -- hunchentoot runs its
;;;; own worker threads per request; user input crosses from an HTTP
;;;; handler thread to the conversation thread via a `trivial-channels`
;;;; channel, same as the TUI frontend. All other mutable state --
;;;; the transcript, the in-progress streamed reply, the "thinking"
;;;; flag, the stats summary -- lives under one lock, and /api/messages
;;;; serves all of it in one JSON object for the page's poll loop to
;;;; render (transcript as a done list, PENDING as a live, still-
;;;; growing line below it, THINKING as a status indicator while
;;;; PENDING is still empty).

(in-package :cl-agent)

(defvar *web-frontend* nil
  "The currently active WEB-FRONTEND, bound by UI-START so the (global,
hunchentoot-style) easy-handlers below can reach its state. Single-
session PoC simplification -- see this file's header comment.")

(defclass web-frontend (agent-frontend)
  ((port :initarg :port :initform 4567 :accessor web-frontend-port)
   (acceptor :accessor web-frontend-acceptor)
   (transcript :initform nil :accessor web-frontend-transcript
               :documentation "Plists (:role STRING :text STRING), newest first.")
   (pending :initform "" :accessor web-frontend-pending
            :documentation "Accumulated UI-ASSISTANT-DELTA chunks for
the reply currently streaming in; cleared once UI-ASSISTANT-TEXT
delivers the complete, final text for the same turn.")
   (thinking :initform nil :accessor web-frontend-thinking-p
             :documentation "True between UI-THINKING-STARTED and
UI-THINKING-STOPPED -- shown by the page while PENDING is still empty
(once text starts streaming in, PENDING itself is the live indicator).")
   (activity :initform nil :accessor web-frontend-activity
             :documentation "Inspectable agent lifecycle and tool events, newest
first. These remain available in the activity pane while the main transcript
is reserved for the user-visible conversation.")
   (stats :initform nil :accessor web-frontend-stats
          :documentation "Latest SESSION-STATS-SNAPSHOT plist, or NIL
before the first turn completes.")
   (state-lock :initform (bt:make-lock "cl-agent-web-state") :accessor web-frontend-state-lock
               :documentation "Guards TRANSCRIPT/PENDING/THINKING/STATS
together -- one lock, since the page always reads/renders all four as
one consistent snapshot (see WEB-FRONTEND-STATUS-JSON).")
   (input-channel :initform (trivial-channels:make-channel) :accessor web-frontend-input-channel))
  (:documentation "Browser chat UI at http://127.0.0.1:PORT/. See this
file's header comment for scope and the threading model."))

(defun web-frontend-push (frontend role text)
  (bt:with-lock-held ((web-frontend-state-lock frontend))
    (push (list :role role :text text) (web-frontend-transcript frontend))))

(defun web-frontend-push-activity (frontend kind label text)
  "Append one labelled, inspectable agent event without cluttering chat."
  (bt:with-lock-held ((web-frontend-state-lock frontend))
    (push (list :kind kind :label label :text text) (web-frontend-activity frontend))))

(defun normalize-compact-markdown-table (text)
  "Recover the common one-line table form emitted by some chat models.

Markdown tables need line boundaries, but models occasionally collapse rows
into `| cell | | next cell |`.  Only normalize a single-line string that
contains a Markdown separator row, keeping ordinary prose untouched."
  (if (and (stringp text) (search "|---" text) (not (find #\Newline text)))
      (with-output-to-string (out)
        (loop with start = 0
              for boundary = (search "| |" text :start2 start)
              while boundary
              do (write-string text out :start start :end (1+ boundary))
                 (terpri out)
                 ;; Preserve the trailing pipe, skip the separating space,
                 ;; and begin the next line at its opening pipe.
                 (setf start (+ boundary 2))
              finally (write-string text out :start start)))
      text))

(defun normalize-compact-markdown-list (text)
  "Recover one-line bullet lists such as `- one - two - three`.

Only a line that begins with a Markdown bullet is transformed, avoiding
accidental changes to ordinary prose containing a dash or multiplication sign."
  (if (and (stringp text) (not (find #\Newline text))
           (or (and (>= (length text) 2)
                    (member (char text 0) '(#\- #\*))
                    (char= (char text 1) #\Space))))
      (with-output-to-string (out)
        (loop with start = 0
              for dash = (search " - " text :start2 (+ start 2))
              for star = (search " * " text :start2 (+ start 2))
              for boundary = (cond ((and dash star) (min dash star)) (dash dash) (star star))
              while boundary
              do (write-string text out :start start :end boundary)
                 (terpri out)
                 (setf start (1+ boundary))
              finally (write-string text out :start start)))
      text))

(defun last-substring-position (needle text start)
  "Return the last occurrence of NEEDLE in TEXT at or after START."
  (loop with position = nil
        with cursor = start
        for found = (search needle text :start2 cursor)
        while found
        do (setf position found
                 cursor (+ found (length needle)))
        finally (return position)))

(defun normalize-inline-fenced-code (text)
  "Repair a frequent near-Markdown fence emitted by chat models.

`\`\`\`lisp (code) \`\`\`` is not legal GitHub-flavored Markdown because
the opening fence's info string and the code share a line.  When a whole
message has that unambiguous shape, insert the two missing line boundaries
without attempting to reinterpret ordinary inline backticks."
  (if (and (stringp text) (uiop:string-prefix-p "```" text))
      (let* ((opening-end (position-if (lambda (character)
                                         (member character '(#\Space #\Tab #\Newline)))
                                       text :start 3))
             (closing-start (last-substring-position "```" text 3)))
        (if (and opening-end closing-start
                 (> closing-start (1+ opening-end))
                 (not (char= (char text opening-end) #\Newline)))
            (with-output-to-string (out)
              (write-string text out :end opening-end)
              (terpri out)
              (write-string text out :start (1+ opening-end) :end closing-start)
              (terpri out)
              (write-string text out :start closing-start))
            text))
      text))

(defun html-escape (text)
  "Escape TEXT for insertion into the small raw-HTML code-block shim."
  (with-output-to-string (out)
    (loop for character across text
          do (write-string (case character
                             (#\& "&amp;") (#\< "&lt;") (#\> "&gt;")
                             (#\" "&quot;") (#\' "&#39;")
                             (t (string character)))
                           out))))

(defun render-fenced-code-blocks (text)
  "Turn valid triple-backtick blocks into safe raw HTML before 3BMD parses.

3BMD's optional code-block extension is not CommonMark-compatible enough for
agent output and can fail to terminate on malformed fence shapes. This narrow,
linear preprocessor handles the GitHub-style form we need and leaves all other
Markdown to 3BMD."
  (let ((text (normalize-inline-fenced-code text)))
    (with-output-to-string (out)
      (loop with cursor = 0
            for opening = (search "```" text :start2 cursor)
            while opening
            for opening-end = (position #\Newline text :start (+ opening 3))
            for closing = (and opening-end (search (format nil "~%```") text :start2 (1+ opening-end)))
            do (if (and opening-end closing)
                   (let* ((language (string-trim " " (subseq text (+ opening 3) opening-end)))
                          (code (subseq text (1+ opening-end) closing))
                          (closing-line-end (or (position #\Newline text :start (+ closing 4))
                                                (length text))))
                     (write-string text out :start cursor :end opening)
                     (format out "<pre><code~@[ class=\"language-~a\"~]>~a</code></pre>"
                             (and (plusp (length language)) (html-escape language))
                             (html-escape code))
                     (setf cursor (if (< closing-line-end (length text))
                                      (1+ closing-line-end) closing-line-end)))
                   (progn
                     (write-string text out :start cursor)
                     (setf cursor (length text))
                     (loop-finish)))
            finally (when (< cursor (length text)) (write-string text out :start cursor))))))

(defun extract-fenced-code-blocks (text)
  "Return Markdown with fence blocks replaced by inert markers, plus HTML.
Markers prevent 3BMD from parsing either backticks or raw PRE markup."
  (let ((text (normalize-inline-fenced-code text)) (blocks nil) (number 0))
    (values
     (with-output-to-string (out)
       (loop with cursor = 0
             do (let ((opening (search "```" text :start2 cursor)))
                  (unless opening
                    (write-string text out :start cursor)
                    (return))
                  (let* ((opening-end (position #\Newline text :start (+ opening 3)))
                         (closing (and opening-end
                                       (search (format nil "~%```") text :start2 (1+ opening-end)))))
                    (unless (and opening-end closing)
                      (write-string text out :start cursor)
                      (return))
                    (let* ((language (string-trim " " (subseq text (+ opening 3) opening-end)))
                           (code (subseq text (1+ opening-end) closing))
                           (closing-line-end (or (position #\Newline text :start (+ closing 4))
                                                 (length text)))
                           (marker (format nil "CLAGENT-CODE-BLOCK-~d" (incf number)))
                           (html (format nil "<pre><code~@[ class=\"language-~a\"~]>~a</code></pre>"
                                         (and (plusp (length language)) (html-escape language))
                                         (html-escape code))))
                      ;; Keep the marker in its own Markdown paragraph.  If
                      ;; prose follows the closing fence, merely replacing the
                      ;; fence with MARKER joins them into one <p>; the exact
                      ;; <p>MARKER</p> substitution below then misses and the
                      ;; browser exposes our implementation detail.
                      (write-string text out :start cursor :end opening)
                      (format out "~%~%~a~%~%" marker)
                      (push (cons marker html) blocks)
                      (setf cursor (if (< closing-line-end (length text))
                                       (1+ closing-line-end) closing-line-end)))))))
     (nreverse blocks))))

(defun replace-all-substrings (text needle replacement)
  "Replace every literal NEEDLE in TEXT without introducing another dependency."
  (with-output-to-string (out)
    (loop with start = 0
          for position = (search needle text :start2 start)
          while position
          do (write-string text out :start start :end position)
             (write-string replacement out)
             (setf start (+ position (length needle)))
          finally (write-string text out :start start))))

(defun web-markdown-html (text)
  "Render assistant Markdown for the web client.

3BMD intentionally supports raw HTML, so the browser applies its allowlist
before inserting this output into the document.  Keeping the Markdown source
  in the API as well makes that sanitization auditable and provides a graceful
plain-text fallback if rendering fails."
  (handler-case
      (multiple-value-bind (markdown blocks)
          (extract-fenced-code-blocks
           (normalize-compact-markdown-list
            (normalize-compact-markdown-table (or text ""))))
        (let* ((3bmd-tables:*tables* t)
               (html (with-output-to-string (stream)
                       (3bmd:parse-string-and-print-to-stream markdown stream))))
          (dolist (block blocks html)
            (setf html (replace-all-substrings html
                                               (format nil "<p>~a</p>" (car block))
                                               (cdr block))))))
    (error () "")))

(defun universal-to-unix-time (universal)
  (and universal (- universal 2208988800)))

(defun web-subagent-json (snapshot)
  "JSON view of one subagent snapshot; times are Unix seconds for the page's clock."
  (flet ((or-null (value) (if (null value) :null value)))
    (jobj "id" (getf snapshot :id)
          "state" (string-downcase (symbol-name (getf snapshot :state)))
          "role" (or-null (getf snapshot :role))
          "model" (or-null (getf snapshot :model))
          "description" (or-null (getf snapshot :description))
          "activity" (or-null (getf snapshot :activity))
          "note" (or-null (getf snapshot :note))
          "tools" (or (getf snapshot :tools) :empty-array)
          "requests" (or (getf snapshot :requests) 0)
          "tool_calls" (or (getf snapshot :tool-calls) 0)
          "tokens" (or (getf snapshot :tokens) 0)
          "started" (or-null (universal-to-unix-time (getf snapshot :started-at)))
          "finished" (or-null (universal-to-unix-time (getf snapshot :finished-at))))))

(defun web-frontend-status-json (frontend)
  "The single JSON object /api/messages serves: the transcript so far,
the in-progress streamed reply (if any), whether a request is
currently in flight, and the latest stats snapshot."
  (bt:with-lock-held ((web-frontend-state-lock frontend))
    (json-encode
     (jobj "messages" (or (mapcar (lambda (entry)
                                     (let ((role (getf entry :role))
                                           (text (getf entry :text)))
                                       (jobj "role" role "text" text
                                             "html" (if (string= role "assistant")
                                                        (web-markdown-html text)
                                                        :null))))
                                   (reverse (web-frontend-transcript frontend)))
                          ;; An empty Lisp list is indistinguishable from
                          ;; JSON false in our convention (see json-util.lisp's
                          ;; JOBJ docstring) -- :EMPTY-ARRAY forces "[]".
                          :empty-array)
           "pending" (web-frontend-pending frontend)
           "thinking" (web-frontend-thinking-p frontend)
           "activity" (or (mapcar (lambda (entry)
                                      (jobj "kind" (getf entry :kind)
                                            "label" (getf entry :label)
                                            "text" (getf entry :text)))
                                    (reverse (web-frontend-activity frontend)))
                          :empty-array)
           "subagents" (or (mapcar #'web-subagent-json (subagent-panel-snapshots frontend))
                           :empty-array)
           "stats" (let ((s (web-frontend-stats frontend)))
                     (if s
                         (jobj "provider" (getf s :provider) "model" (getf s :model)
                               "requests" (getf s :requests) "tool_calls" (getf s :tool-calls)
                               "elapsed_seconds" (getf s :elapsed-seconds)
                               "total_tokens" (getf s :total-tokens))
                         :null))))))

(defparameter *web-page-html*
  "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
<title>cl-agent</title><script>window.MathJax={tex:{inlineMath:{'[+]':[['$','$']]},displayMath:[['$$','$$'],['\\[','\\]']]},options:{skipHtmlTags:['script','noscript','style','textarea','pre','code']}};</script><script id=\"MathJax-script\" defer src=\"https://cdn.jsdelivr.net/npm/mathjax@4/tex-chtml.js\"></script><style>
:root{color-scheme:dark;--bg:#0b1020;--panel:#121a2d;--panel-2:#19233a;--line:#2b3855;--text:#e7edf8;--muted:#9aa8c2;--accent:#7dd3fc;--accent-2:#a78bfa;--user:#17395a;--tool:#302846;--danger:#fb7185}*{box-sizing:border-box}body{margin:0;min-width:320px;background:radial-gradient(circle at 8% 0%,#1b3152 0,transparent 30rem),var(--bg);color:var(--text);font:15px/1.55 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif}.app{width:min(1120px,100%);height:100dvh;margin:auto;display:grid;grid-template-rows:auto minmax(0,1fr) auto;padding:18px 22px 16px;gap:14px}.topbar{display:flex;align-items:center;justify-content:space-between;gap:16px}.brand{display:flex;align-items:center;gap:11px;font-weight:720;letter-spacing:-.02em}.mark{display:grid;place-items:center;width:34px;height:34px;border-radius:11px;background:linear-gradient(135deg,var(--accent),var(--accent-2));color:#0b1020;font:800 19px ui-monospace,monospace}.status{color:var(--muted);font-size:12px;text-align:right}.status strong{color:var(--text);font-weight:650}.chat{position:relative;min-height:0;background:color-mix(in srgb,var(--panel) 90%,transparent);border:1px solid var(--line);border-radius:18px;box-shadow:0 24px 70px #0005;overflow:hidden}.messages{height:100%;overflow-y:auto;padding:25px clamp(16px,4vw,48px) 38px;scroll-behavior:smooth}.message{display:grid;grid-template-columns:30px minmax(0,1fr);gap:10px;margin:0 auto 20px;max-width:820px}.badge{display:grid;place-items:center;width:28px;height:28px;border-radius:9px;background:#24314d;color:var(--accent);font:700 12px ui-monospace,monospace}.card{min-width:0;padding:13px 16px;border:1px solid transparent;border-radius:4px 15px 15px 15px;background:var(--panel-2);box-shadow:0 4px 12px #0002}.meta{margin-bottom:7px;color:var(--muted);font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase}.role-user{grid-template-columns:minmax(0,1fr) 30px}.role-user .badge{grid-column:2;background:var(--user);color:#b8e3ff}.role-user .card{grid-column:1;grid-row:1;justify-self:end;border-top-right-radius:4px;border-top-left-radius:15px;background:var(--user);max-width:88%}.role-tool .badge{background:var(--tool);color:#d8c0ff}.role-tool .card{background:#1d2034;border-color:#393251}.role-system{opacity:.9}.role-system .card{background:transparent;border-color:#34405b;color:var(--muted);font-size:13px}.plain{white-space:pre-wrap;overflow-wrap:anywhere}.markdown{overflow-wrap:anywhere}.markdown>*:first-child{margin-top:0}.markdown>*:last-child{margin-bottom:0}.markdown h1,.markdown h2,.markdown h3{line-height:1.2;letter-spacing:-.025em;margin:1.15em 0 .5em}.markdown h1{font-size:1.55em}.markdown h2{font-size:1.3em}.markdown h3{font-size:1.12em}.markdown p,.markdown ul,.markdown ol,.markdown blockquote{margin:.7em 0}.markdown ul,.markdown ol{padding-left:1.45em}.markdown blockquote{padding:.15em 0 .15em .9em;border-left:3px solid var(--accent-2);color:#c7d0e4}.markdown code,.plain{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}.markdown :not(pre)>code{padding:.12em .35em;border-radius:5px;background:#0d1527;color:#c5e7ff;font-size:.9em}.markdown pre{overflow:auto;padding:13px;border:1px solid #303d5a;border-radius:10px;background:#090f1d}.markdown pre code{font-size:.88em}.markdown a{color:var(--accent);text-decoration-thickness:1px}.markdown table{display:block;max-width:100%;overflow:auto;border-collapse:collapse}.markdown th,.markdown td{padding:.45em .65em;border:1px solid #34405b;text-align:left}.markdown hr{border:0;border-top:1px solid var(--line);margin:1.2em 0}.pending .card{border-color:#3a5475}.thinking .card{color:var(--muted);font-style:italic}.jump{position:absolute;right:24px;bottom:20px;border:1px solid #426184;border-radius:999px;padding:8px 12px;background:#152946ee;color:#d9efff;box-shadow:0 5px 18px #0007;cursor:pointer;font:600 12px inherit}.jump[hidden]{display:none}.composer{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:10px;align-items:end;background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:10px 11px;box-shadow:0 10px 34px #0003}.composer textarea{resize:none;min-height:44px;max-height:180px;border:0;outline:0;background:transparent;color:var(--text);font:inherit;line-height:1.45;padding:10px}.composer textarea::placeholder{color:#73819c}.send{border:0;border-radius:11px;padding:11px 16px;background:linear-gradient(135deg,var(--accent),#8bbcff);color:#07111e;font:700 14px inherit;cursor:pointer}.send:disabled{opacity:.55;cursor:wait}.hint{grid-column:1/-1;margin:-4px 10px 0;color:var(--muted);font-size:11px}@media(max-width:600px){.app{padding:12px;gap:10px}.status{display:none}.messages{padding:18px 14px 30px}.role-user .card{max-width:94%}.composer{border-radius:14px}.hint{display:none}}
</style><style>.activity{max-width:820px;margin:0 auto 18px;border:1px solid #34405b;border-radius:12px;background:#10182a}.activity summary{padding:10px 14px;cursor:pointer;color:#9aa8c2;font-size:12px;font-weight:650;list-style:none}.activity summary::-webkit-details-marker{display:none}.activity summary::before{content:'›';display:inline-block;margin-right:8px;color:#7dd3fc;font-size:18px;line-height:10px;transition:transform .15s}.activity[open] summary::before{transform:rotate(90deg)}.activity-body{padding:0 14px 13px}.activity-line{padding:9px 0;border-top:1px solid #273552;color:#c2cce0;font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere}.copy{float:right;border:1px solid #3a4d70;border-radius:6px;background:#142139;color:#b9d8f6;padding:3px 7px;font:600 10px ui-sans-serif,system-ui;cursor:pointer}.copy:hover{background:#1d3455}.copy-all{float:none;margin-left:10px}</style></head><body><main class=\"app\"><header class=\"topbar\"><div class=\"brand\"><span class=\"mark\">λ</span><span>cl-agent</span></div><div class=\"status\"><span id=\"stats\">Connecting…</span><button class=\"copy copy-all\" id=\"copy-all\" type=\"button\">Copy chat</button></div></header><section class=\"chat\"><div class=\"messages\" id=\"messages\" aria-live=\"polite\"></div><button class=\"jump\" id=\"jump\" hidden>Jump to latest ↓</button></section><form class=\"composer\" id=\"form\"><textarea id=\"input\" rows=\"1\" autocomplete=\"off\" placeholder=\"Message cl-agent…\" autofocus></textarea><button class=\"send\" id=\"send\" type=\"submit\">Send</button><span class=\"hint\">Enter to send · Shift+Enter for a new line</span></form></main>
<script>
const messages=document.getElementById('messages'),form=document.getElementById('form'),input=document.getElementById('input'),send=document.getElementById('send'),stats=document.getElementById('stats'),jump=document.getElementById('jump'),copyAll=document.getElementById('copy-all');let signature='',sending=false,lastTranscript='';
const esc=s=>String(s??'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\"/g,'&quot;').replace(/'/g,'&#39;');
const commands=[['/help','Show available commands'],['/tools','List enabled tools'],['/model','List or select a model'],['/mode','Show or change orchestration mode'],['/stats','Show session statistics'],['/provider','Show or select a provider'],['/call','Call a tool with JSON arguments'],['/hooks','List installed hooks'],['/extensions','List extensions'],['/reload','Reload extensions'],['/mcp','Manage MCP servers'],['/exit','End this session']];let commandMatches=[],commandIndex=0;const suggestions=document.createElement('div');suggestions.hidden=true;suggestions.setAttribute('role','listbox');suggestions.style.cssText='position:absolute;z-index:3;left:11px;right:11px;bottom:100%;margin-bottom:8px;max-height:220px;overflow:auto;border:1px solid #3a4d70;border-radius:11px;background:#101a2d;box-shadow:0 12px 32px #0009;padding:5px';form.prepend(suggestions);function hideSuggestions(){suggestions.hidden=true;commandMatches=[]}function commandToken(value){if(value.charAt(0)!=='/')return null;const end=value.indexOf(' ');return end<0?value:value.slice(0,end)}function chooseCommand(command){const end=input.value.indexOf(' ');input.value=command+(end<0?' ':input.value.slice(end));input.setSelectionRange(input.value.length,input.value.length);hideSuggestions();input.focus()}function showSuggestions(){const token=commandToken(input.value);if(!token){hideSuggestions();return}commandMatches=commands.filter(c=>c[0].startsWith(token.toLowerCase()));if(!commandMatches.length){hideSuggestions();return}commandIndex=Math.min(commandIndex,commandMatches.length-1);suggestions.innerHTML=commandMatches.map((c,i)=>`<button type=\"button\" data-command=\"${c[0]}\" style=\"display:flex;width:100%;gap:12px;border:0;border-radius:7px;padding:8px 10px;background:${i===commandIndex?'#213451':'transparent'};color:#e7edf8;text-align:left;cursor:pointer;font:inherit\"><code style=\"color:#7dd3fc;font:600 12px ui-monospace,monospace\">${c[0]}</code><span style=\"color:#9aa8c2;font-size:12px\">${c[1]}</span></button>`).join('');suggestions.hidden=false}
function nearBottom(){return messages.scrollHeight-messages.scrollTop-messages.clientHeight<56}function scrollLatest(){messages.scrollTop=messages.scrollHeight;jump.hidden=true}
function cleanMarkdown(html){const allowed=new Set(['A','BLOCKQUOTE','BR','CODE','DEL','EM','H1','H2','H3','H4','H5','H6','HR','LI','OL','P','PRE','S','STRONG','TABLE','TBODY','TD','TH','THEAD','TR','UL']);const box=document.createElement('template');box.innerHTML=html;for(const node of [...box.content.querySelectorAll('*')]){if(!allowed.has(node.tagName)){node.replaceWith(document.createTextNode(node.textContent||''));continue}for(const attr of [...node.attributes]){if(node.tagName==='A'&&attr.name==='href'&&/^(https?:|mailto:|#)/i.test(attr.value))continue;node.removeAttribute(attr.name)}}return box.innerHTML}
function card(role,label,content,markdown=false,extra='',copyValue=content){return `<article class=\"message role-${role} ${extra}\"><div class=\"badge\">${role==='assistant'?'AI':role==='user'?'YOU':role==='tool'?'⌘':'·'}</div><div class=\"card\">${copyControl(copyValue)}<div class=\"meta\">${label}</div><div class=\"${markdown?'markdown':'plain'}\">${markdown?cleanMarkdown(content):esc(content)}</div></div></article>`}
function copyControl(value){return `<button class=\"copy\" type=\"button\" data-copy=\"${encodeURIComponent(value)}\">Copy</button>`}function decorateCopies(){for(const pre of messages.querySelectorAll('.markdown pre')){const code=pre.querySelector('code');if(!code)continue;const button=document.createElement('button');button.type='button';button.className='copy';button.dataset.copy=encodeURIComponent(code.innerText);button.textContent='Copy code';button.style.margin='0 0 8px 8px';pre.prepend(button)}}function activity(items){return `<details class=\"activity\"><summary>Agent activity · ${items.length} update${items.length===1?'':'s'}</summary><div class=\"activity-body\">${items.map(m=>`<div class=\"activity-line\">${copyControl(m.text)}${esc(m.text)}</div>`).join('')}</div></details>`}function compaction(summary){return `<details class=\"activity compaction\"><summary>Context compacted · View continuity summary</summary><div class=\"activity-body\"><div class=\"activity-line\">${copyControl(summary)}${esc(summary)}</div></div></details>`}function transcript(items){let html='',hidden=[];const flush=()=>{if(hidden.length){html+=activity(hidden);hidden=[]}};for(const m of items){if(m.role==='tool'||m.role==='system'){hidden.push(m)}else if(m.role==='compaction'){flush();html+=compaction(m.text)}else{flush();html+=card(m.role,m.role,m.html||m.text,m.role==='assistant','',m.text)}}flush();return html}
function clearMath(){const mathjax=window.MathJax;if(mathjax&&mathjax.typesetClear)mathjax.typesetClear([messages])}
function typesetMath(){const mathjax=window.MathJax;if(mathjax&&mathjax.typesetPromise)mathjax.typesetPromise([messages]).catch(()=>{})}
function render(data){const next=JSON.stringify([data.messages,data.pending,data.thinking]);lastTranscript=data.messages.map(m=>`${m.role.toUpperCase()}:\n${m.text}`).join('\n\n');if(next===signature)return;const follow=nearBottom();signature=next;let html=transcript(data.messages);if(data.pending)html+=card('assistant','cl-agent',data.pending,false,'pending',data.pending);else if(data.thinking)html+=card('system','cl-agent','Thinking…',false,'thinking');clearMath();messages.innerHTML=html||card('system','cl-agent','Start a conversation to see the agent here.',false);decorateCopies();typesetMath();if(follow)scrollLatest();else jump.hidden=false}
function renderStats(s){stats.innerHTML=s?`<strong>${esc(s.provider)} · ${esc(s.model)}</strong><br>${s.requests} requests · ${s.tool_calls} tools${s.total_tokens?` · ${s.total_tokens} tokens`:''}`:'Ready'}
async function poll(){try{const response=await fetch('/api/messages',{cache:'no-store'});if(!response.ok)throw Error(response.status);const data=await response.json();render(data);renderStats(data.stats)}catch(e){stats.textContent='Connection lost — retrying…'}setTimeout(poll,500)}
async function copyText(text,button){try{await navigator.clipboard.writeText(text);const old=button.textContent;button.textContent='Copied';setTimeout(()=>button.textContent=old,1100)}catch(e){button.textContent='Copy failed'}}messages.addEventListener('scroll',()=>{jump.hidden=nearBottom()});messages.addEventListener('click',e=>{const button=e.target.closest('[data-copy]');if(button)copyText(decodeURIComponent(button.dataset.copy),button)});copyAll.onclick=()=>copyText(lastTranscript,copyAll);jump.onclick=scrollLatest;input.addEventListener('input',()=>{input.style.height='auto';input.style.height=Math.min(input.scrollHeight,180)+'px'});input.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();form.requestSubmit()}});form.onsubmit=async e=>{e.preventDefault();const text=input.value.trim();if(!text||sending)return;sending=true;send.disabled=true;input.value='';input.style.height='auto';try{await fetch('/api/send',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'text='+encodeURIComponent(text)});scrollLatest()}finally{sending=false;send.disabled=false;input.focus()}};poll();
input.addEventListener('input',()=>{commandIndex=0;showSuggestions()});input.addEventListener('keydown',e=>{if(suggestions.hidden)return;if(e.key==='Tab'){e.preventDefault();chooseCommand(commandMatches[commandIndex][0]);return}if(e.key==='ArrowDown'||e.key==='ArrowUp'){e.preventDefault();commandIndex=(commandIndex+(e.key==='ArrowDown'?1:-1)+commandMatches.length)%commandMatches.length;showSuggestions();return}if(e.key==='Escape'){e.preventDefault();hideSuggestions()}},true);suggestions.addEventListener('click',e=>{const button=e.target.closest('[data-command]');if(button)chooseCommand(button.dataset.command)});input.addEventListener('blur',()=>setTimeout(hideSuggestions,120));
</script></body></html>"
  "The whole web frontend client, inline -- see this file's header
comment on why that's an acceptable PoC simplification. Polls
/api/messages twice a second (not pushed -- see header comment on
SSE/WebSocket being a real-product improvement this PoC skips) so the
in-progress reply (DATA.PENDING) and the thinking indicator feel
reasonably live without any new transport.")

(defun enhance-web-page-with-activity-pane ()
  "Install the independent, non-collapsing activity pane into the inline page."
  (setf *web-page-html*
        (replace-all-substrings
         *web-page-html* "</head><body>"
         "<style>.workspace{min-height:0;display:grid;grid-template-columns:minmax(0,1fr) minmax(270px,.42fr);gap:14px}.activity-pane{min-height:0;display:flex;flex-direction:column;background:#10182a;border:1px solid #34405b;border-radius:18px;overflow:hidden}.activity-head{display:flex;justify-content:space-between;align-items:center;padding:13px 15px;border-bottom:1px solid #273552;color:#c9d8ed;font-size:12px;font-weight:750;letter-spacing:.08em}.activity-scroll{min-height:0;overflow:auto;padding:12px}.activity-entry{margin-bottom:10px;border:1px solid #2e3c59;border-radius:10px;background:#0d1527;overflow:hidden}.activity-label{display:inline-block;margin:8px 9px 0;padding:2px 6px;border:1px solid #496587;border-radius:4px;background:#162944;color:#a9dafe;font:700 10px ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;letter-spacing:.06em}.activity-text{padding:7px 10px 10px;color:#c2cce0;font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere}.activity-empty{color:#8190aa;font-size:13px;padding:8px}@media(max-width:820px){.workspace{grid-template-columns:1fr;grid-template-rows:minmax(320px,1fr) minmax(180px,.45fr)}.activity-pane{border-radius:14px}}</style></head><body>"))
  (setf *web-page-html*
        (replace-all-substrings
         *web-page-html*
         "<section class=\"chat\"><div class=\"messages\" id=\"messages\" aria-live=\"polite\"></div><button class=\"jump\" id=\"jump\" hidden>Jump to latest ↓</button></section><form class=\"composer\""
         "<section class=\"workspace\"><section class=\"chat\"><div class=\"messages\" id=\"messages\" aria-live=\"polite\"></div><button class=\"jump\" id=\"jump\" hidden>Jump to latest ↓</button></section><aside class=\"activity-pane\" aria-label=\"Agent activity\"><div class=\"activity-head\">AGENT ACTIVITY <span id=\"activity-state\">Idle</span></div><div class=\"activity-scroll\" id=\"activity\"></div></aside></section><form class=\"composer\""))
  (setf *web-page-html*
        (replace-all-substrings
         *web-page-html*
         "const messages=document.getElementById('messages'),form="
         "const messages=document.getElementById('messages'),activityPane=document.getElementById('activity'),activityState=document.getElementById('activity-state'),form="))
  ;; System and tool entries remain in DATA.MESSAGES for backwards-compatible
  ;; API consumers, but are displayed only in the independent activity pane.
  (setf *web-page-html*
        (replace-all-substrings
         *web-page-html* "function clearMath(){"
         "function transcript(items){return items.filter(m=>m.role==='user'||m.role==='assistant'||m.role==='compaction').map(m=>m.role==='compaction'?compaction(m.text):card(m.role,m.role,m.html||m.text,m.role==='assistant','',m.text)).join('')}function clearMath(){"))
  (setf *web-page-html*
        (replace-all-substrings
         *web-page-html*
         "function render(data){const next=JSON.stringify([data.messages,data.pending,data.thinking]);"
         "function renderActivity(items,thinking){const pinned=activityPane.scrollHeight-activityPane.scrollTop-activityPane.clientHeight<40;activityState.textContent=thinking?'Thinking…':'Idle';activityPane.innerHTML=items.length?items.map(item=>\`<article class=\"activity-entry\"><div class=\"activity-label\">\${esc(item.label)}</div><div class=\"activity-text\">\${copyControl(item.text)}\${esc(item.text)}</div></article>\`).join(''):'<div class=\"activity-empty\">Tool calls, planning updates, and agent status will appear here.</div>';if(pinned)activityPane.scrollTop=activityPane.scrollHeight}function render(data){const next=JSON.stringify([data.messages,data.pending,data.thinking,data.activity]);"))
  (setf *web-page-html*
        (replace-all-substrings
         *web-page-html*
         "clearMath();messages.innerHTML=html||card('system','cl-agent','Start a conversation to see the agent here.',false);decorateCopies();"
         "clearMath();messages.innerHTML=html||card('system','cl-agent','Start a conversation to see the agent here.',false);renderActivity(data.activity||[],data.thinking);decorateCopies();"))
  (setf *web-page-html*
        (replace-all-substrings
         *web-page-html*
         "messages.addEventListener('scroll',()=>{jump.hidden=nearBottom()});messages.addEventListener('click',e=>{const button=e.target.closest('[data-copy]');if(button)copyText(decodeURIComponent(button.dataset.copy),button)});"
         "messages.addEventListener('scroll',()=>{jump.hidden=nearBottom()});for(const pane of [messages,activityPane])pane.addEventListener('click',e=>{const button=e.target.closest('[data-copy]');if(button)copyText(decodeURIComponent(button.dataset.copy),button)});")))

(enhance-web-page-with-activity-pane)

(defun enhance-web-page-with-subagents ()
  "Add a live subagent section above the activity feed, like a running-agents list."
  (flet ((patch (needle replacement)
           (let ((patched (replace-all-substrings *web-page-html* needle replacement)))
             (when (string= patched *web-page-html*)
               (error "Web page patch target not found: ~a" (subseq needle 0 (min 50 (length needle)))))
             (setf *web-page-html* patched))))
    (patch "</head><body>"
           "<style>.subagents{border-bottom:1px solid #273552;padding:10px 12px;display:grid;gap:8px}.subagents:empty{display:none}.sa-card{border:1px solid #2e3c59;border-radius:10px;background:#0d1527;padding:8px 10px;font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:#c2cce0}.sa-head{display:flex;gap:8px;align-items:baseline;flex-wrap:wrap}.sa-dot{font-size:11px}.sa-running .sa-dot{color:#7dd3fc;animation:sa-pulse 1.2s ease-in-out infinite}.sa-succeeded .sa-dot{color:#86efac}.sa-failed .sa-dot,.sa-cancelled .sa-dot{color:#fb7185}.sa-queued .sa-dot{color:#9aa8c2}.sa-id{font-weight:700;color:#e7edf8}.sa-meta{color:#9aa8c2}.sa-desc{margin-top:3px;color:#9aa8c2;overflow-wrap:anywhere}.sa-activity{margin-top:3px;color:#a9dafe;overflow-wrap:anywhere}.sa-done{opacity:.75}@keyframes sa-pulse{50%{opacity:.35}}</style></head><body>")
    (patch "<div class=\"activity-scroll\" id=\"activity\"></div>"
           "<div class=\"subagents\" id=\"subagents\" aria-label=\"Running subagents\"></div><div class=\"activity-scroll\" id=\"activity\"></div>")
    (patch "function renderActivity(items,thinking){"
           "function saElapsed(a,b){const s=Math.max(0,Math.floor(b-a));return s>=60?Math.floor(s/60)+'m'+String(s%60).padStart(2,'0')+'s':s+'s'}function renderSubagents(items){const el=document.getElementById('subagents');if(!el)return;const glyph={queued:'○',running:'●',succeeded:'✓',failed:'✗',cancelled:'⊘'};el.innerHTML=items.map(a=>`<div class=\"sa-card sa-${a.state}${a.finished?' sa-done':''}\"><div class=\"sa-head\"><span class=\"sa-dot\">${glyph[a.state]||'?'}</span><span class=\"sa-id\">${esc(a.id)}</span>${a.role?`<span class=\"sa-meta\">${esc(a.role)}</span>`:''}<span class=\"sa-meta\">${esc(a.state)}</span>${a.started?`<span class=\"sa-meta sa-time\" data-start=\"${a.started}\"${a.finished?` data-end=\"${a.finished}\"`:''}>${saElapsed(a.started,a.finished||Date.now()/1000)}</span>`:''}<span class=\"sa-meta\">${a.tool_calls} tool call${a.tool_calls===1?'':'s'}${a.tokens?' · '+a.tokens+' tokens':''}</span>${a.model?`<span class=\"sa-meta\">${esc(a.model)}</span>`:''}</div>${a.activity&&a.state==='running'?`<div class=\"sa-activity\">${esc(a.activity)}</div>`:''}${a.note&&(a.state==='failed'||a.state==='cancelled')?`<div class=\"sa-activity\">${esc(a.note)}</div>`:''}${a.description?`<div class=\"sa-desc\">${esc(a.description)}</div>`:''}</div>`).join('')}setInterval(()=>{for(const e of document.querySelectorAll('.sa-time:not([data-end])'))e.textContent=saElapsed(+e.dataset.start,Date.now()/1000)},1000);function renderActivity(items,thinking){")
    (patch "renderActivity(data.activity||[],data.thinking);"
           "renderSubagents(data.subagents||[]);renderActivity(data.activity||[],data.thinking);")
    (patch "data.thinking,data.activity]" "data.thinking,data.activity,data.subagents]")))

(enhance-web-page-with-subagents)

(hunchentoot:define-easy-handler (cl-agent-web-index :uri "/") ()
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  *web-page-html*)

(hunchentoot:define-easy-handler (cl-agent-web-messages :uri "/api/messages") ()
  (setf (hunchentoot:content-type*) "application/json")
  (if *web-frontend*
      (web-frontend-status-json *web-frontend*)
      (json-encode (jobj "messages" :empty-array "pending" "" "thinking" nil
                         "activity" :empty-array "subagents" :empty-array "stats" :null))))

(hunchentoot:define-easy-handler (cl-agent-web-send :uri "/api/send") (text)
  (setf (hunchentoot:content-type*) "application/json")
  (when (and *web-frontend* text (plusp (length text)))
    (web-frontend-push *web-frontend* "user" text)
    (trivial-channels:sendmsg (web-frontend-input-channel *web-frontend*) text))
  "{}")

(hunchentoot:define-easy-handler (cl-agent-web-quit :uri "/api/quit") ()
  (setf (hunchentoot:content-type*) "application/json")
  (when *web-frontend* (trivial-channels:sendmsg (web-frontend-input-channel *web-frontend*) nil))
  "{}")

(defun web-port-in-use-p (condition)
  "True when CONDITION is the platform's report of an occupied listen port."
  (let ((text (string-downcase (princ-to-string condition))))
    (or (search "address already in use" text)
        (search "address in use" text)
        (search "address-in-use" text)
        (search "eaddrinuse" text))))

(defun start-web-acceptor (frontend)
  "Start FRONTEND on its preferred port or one of the next 100 ports."
  (loop for port from (web-frontend-port frontend) below (+ (web-frontend-port frontend) 100)
        do (handler-case
               (let ((acceptor (make-instance 'hunchentoot:easy-acceptor
                                               :port port :address "127.0.0.1")))
                 (hunchentoot:start acceptor)
                 (setf (web-frontend-port frontend) port)
                 (return acceptor))
             (error (condition)
               (unless (web-port-in-use-p condition)
                 (error condition))))
        finally (error "Could not find a free web UI port starting at ~d."
                       (web-frontend-port frontend))))

(defmethod ui-start ((frontend web-frontend))
  (setf (web-frontend-acceptor frontend) (start-web-acceptor frontend)
        *web-frontend* frontend)
  (format t "~&cl-agent web UI: http://127.0.0.1:~d/~%" (web-frontend-port frontend)))

(defmethod ui-stop ((frontend web-frontend))
  (ignore-errors (hunchentoot:stop (web-frontend-acceptor frontend)))
  (when (eq *web-frontend* frontend) (setf *web-frontend* nil)))

(defmethod ui-prompt-input ((frontend web-frontend))
  (trivial-channels:recvmsg (web-frontend-input-channel frontend)))

(defmethod ui-assistant-text ((frontend web-frontend) text)
  (bt:with-lock-held ((web-frontend-state-lock frontend)) (setf (web-frontend-pending frontend) ""))
  (web-frontend-push frontend "assistant" text))

(defmethod ui-show-tool-call-assistant-text-p ((frontend web-frontend))
  (declare (ignore frontend))
  nil)

(defmethod ui-discard-assistant-pending ((frontend web-frontend))
  (bt:with-lock-held ((web-frontend-state-lock frontend))
    (setf (web-frontend-pending frontend) "")))

(defmethod ui-agent-activity ((frontend web-frontend) label text)
  (web-frontend-push-activity frontend "agent-narration" label text))

(defmethod ui-tool-started ((frontend web-frontend) tool-name arguments)
  (let ((summary (tool-call-summary tool-name arguments)))
    ;; Keep the legacy transcript event for API consumers, while the page
    ;; renders it in the dedicated activity pane.
    (web-frontend-push frontend "tool" (format nil "~~ ~a" summary))
    (web-frontend-push-activity frontend "tool-call" (format nil "TOOL · ~a" tool-name) summary)))

(defmethod ui-tool-finished ((frontend web-frontend) tool-name arguments result)
  (declare (ignore arguments))
  (web-frontend-push frontend "tool" result)
  (web-frontend-push-activity frontend "tool-output" (format nil "TOOL OUTPUT · ~a" tool-name) result))

(defmethod ui-system ((frontend web-frontend) text)
  (web-frontend-push frontend "system" text)
  (web-frontend-push-activity frontend "system" "AGENT STATUS" text))

(defmethod ui-context-compacted ((frontend web-frontend) summary before-tokens after-tokens)
  "Retain the exact continuity note for the web UI without showing it by default."
  (declare (ignore before-tokens after-tokens))
  (web-frontend-push frontend "compaction" summary))

(defmethod ui-assistant-delta ((frontend web-frontend) chunk)
  (bt:with-lock-held ((web-frontend-state-lock frontend))
    (setf (web-frontend-pending frontend) (concatenate 'string (web-frontend-pending frontend) chunk))))

(defmethod ui-thinking-started ((frontend web-frontend))
  (bt:with-lock-held ((web-frontend-state-lock frontend)) (setf (web-frontend-thinking-p frontend) t))
  (web-frontend-push-activity frontend "thinking" "AGENT" "Thinking…"))

(defmethod ui-thinking-stopped ((frontend web-frontend))
  (bt:with-lock-held ((web-frontend-state-lock frontend)) (setf (web-frontend-thinking-p frontend) nil)))

(defmethod ui-planning-started ((frontend web-frontend))
  (bt:with-lock-held ((web-frontend-state-lock frontend))
    (setf (web-frontend-thinking-p frontend) t))
  (web-frontend-push-activity frontend "planning" "PLAN MODE" "Planning the next steps…"))

(defmethod ui-planning-stopped ((frontend web-frontend))
  (bt:with-lock-held ((web-frontend-state-lock frontend))
    (setf (web-frontend-thinking-p frontend) nil)))

(defmethod ui-stats-updated ((frontend web-frontend) stats)
  (bt:with-lock-held ((web-frontend-state-lock frontend)) (setf (web-frontend-stats frontend) stats)))

(register-frontend-class :web 'web-frontend)
