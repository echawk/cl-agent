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

(defun web-markdown-html (text)
  "Render assistant Markdown for the web client.

3BMD intentionally supports raw HTML, so the browser applies its allowlist
before inserting this output into the document.  Keeping the Markdown source
  in the API as well makes that sanitization auditable and provides a graceful
plain-text fallback if rendering fails."
  (handler-case
      (let ((3bmd-tables:*tables* t))
        (with-output-to-string (stream)
          (3bmd:parse-string-and-print-to-stream
           (normalize-compact-markdown-table (or text "")) stream)))
    (error () "")))

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
           "stats" (let ((s (web-frontend-stats frontend)))
                     (if s
                         (jobj "provider" (getf s :provider) "model" (getf s :model)
                               "requests" (getf s :requests) "tool_calls" (getf s :tool-calls)
                               "elapsed_seconds" (getf s :elapsed-seconds)
                               "total_tokens" (getf s :total-tokens))
                         :null))))))

(defparameter *web-page-html*
  "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
<title>cl-agent</title><style>
:root{color-scheme:dark;--bg:#0b1020;--panel:#121a2d;--panel-2:#19233a;--line:#2b3855;--text:#e7edf8;--muted:#9aa8c2;--accent:#7dd3fc;--accent-2:#a78bfa;--user:#17395a;--tool:#302846;--danger:#fb7185}*{box-sizing:border-box}body{margin:0;min-width:320px;background:radial-gradient(circle at 8% 0%,#1b3152 0,transparent 30rem),var(--bg);color:var(--text);font:15px/1.55 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif}.app{width:min(1120px,100%);height:100dvh;margin:auto;display:grid;grid-template-rows:auto minmax(0,1fr) auto;padding:18px 22px 16px;gap:14px}.topbar{display:flex;align-items:center;justify-content:space-between;gap:16px}.brand{display:flex;align-items:center;gap:11px;font-weight:720;letter-spacing:-.02em}.mark{display:grid;place-items:center;width:34px;height:34px;border-radius:11px;background:linear-gradient(135deg,var(--accent),var(--accent-2));color:#0b1020;font:800 19px ui-monospace,monospace}.status{color:var(--muted);font-size:12px;text-align:right}.status strong{color:var(--text);font-weight:650}.chat{position:relative;min-height:0;background:color-mix(in srgb,var(--panel) 90%,transparent);border:1px solid var(--line);border-radius:18px;box-shadow:0 24px 70px #0005;overflow:hidden}.messages{height:100%;overflow-y:auto;padding:25px clamp(16px,4vw,48px) 38px;scroll-behavior:smooth}.message{display:grid;grid-template-columns:30px minmax(0,1fr);gap:10px;margin:0 auto 20px;max-width:820px}.badge{display:grid;place-items:center;width:28px;height:28px;border-radius:9px;background:#24314d;color:var(--accent);font:700 12px ui-monospace,monospace}.card{min-width:0;padding:13px 16px;border:1px solid transparent;border-radius:4px 15px 15px 15px;background:var(--panel-2);box-shadow:0 4px 12px #0002}.meta{margin-bottom:7px;color:var(--muted);font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase}.role-user{grid-template-columns:minmax(0,1fr) 30px}.role-user .badge{grid-column:2;background:var(--user);color:#b8e3ff}.role-user .card{grid-column:1;grid-row:1;justify-self:end;border-top-right-radius:4px;border-top-left-radius:15px;background:var(--user);max-width:88%}.role-tool .badge{background:var(--tool);color:#d8c0ff}.role-tool .card{background:#1d2034;border-color:#393251}.role-system{opacity:.9}.role-system .card{background:transparent;border-color:#34405b;color:var(--muted);font-size:13px}.plain{white-space:pre-wrap;overflow-wrap:anywhere}.markdown{overflow-wrap:anywhere}.markdown>*:first-child{margin-top:0}.markdown>*:last-child{margin-bottom:0}.markdown h1,.markdown h2,.markdown h3{line-height:1.2;letter-spacing:-.025em;margin:1.15em 0 .5em}.markdown h1{font-size:1.55em}.markdown h2{font-size:1.3em}.markdown h3{font-size:1.12em}.markdown p,.markdown ul,.markdown ol,.markdown blockquote{margin:.7em 0}.markdown ul,.markdown ol{padding-left:1.45em}.markdown blockquote{padding:.15em 0 .15em .9em;border-left:3px solid var(--accent-2);color:#c7d0e4}.markdown code,.plain{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}.markdown :not(pre)>code{padding:.12em .35em;border-radius:5px;background:#0d1527;color:#c5e7ff;font-size:.9em}.markdown pre{overflow:auto;padding:13px;border:1px solid #303d5a;border-radius:10px;background:#090f1d}.markdown pre code{font-size:.88em}.markdown a{color:var(--accent);text-decoration-thickness:1px}.markdown table{display:block;max-width:100%;overflow:auto;border-collapse:collapse}.markdown th,.markdown td{padding:.45em .65em;border:1px solid #34405b;text-align:left}.markdown hr{border:0;border-top:1px solid var(--line);margin:1.2em 0}.pending .card{border-color:#3a5475}.thinking .card{color:var(--muted);font-style:italic}.jump{position:absolute;right:24px;bottom:20px;border:1px solid #426184;border-radius:999px;padding:8px 12px;background:#152946ee;color:#d9efff;box-shadow:0 5px 18px #0007;cursor:pointer;font:600 12px inherit}.jump[hidden]{display:none}.composer{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:10px;align-items:end;background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:10px 11px;box-shadow:0 10px 34px #0003}.composer textarea{resize:none;min-height:44px;max-height:180px;border:0;outline:0;background:transparent;color:var(--text);font:inherit;line-height:1.45;padding:10px}.composer textarea::placeholder{color:#73819c}.send{border:0;border-radius:11px;padding:11px 16px;background:linear-gradient(135deg,var(--accent),#8bbcff);color:#07111e;font:700 14px inherit;cursor:pointer}.send:disabled{opacity:.55;cursor:wait}.hint{grid-column:1/-1;margin:-4px 10px 0;color:var(--muted);font-size:11px}@media(max-width:600px){.app{padding:12px;gap:10px}.status{display:none}.messages{padding:18px 14px 30px}.role-user .card{max-width:94%}.composer{border-radius:14px}.hint{display:none}}
</style><style>.activity{max-width:820px;margin:0 auto 18px;border:1px solid #34405b;border-radius:12px;background:#10182a}.activity summary{padding:10px 14px;cursor:pointer;color:#9aa8c2;font-size:12px;font-weight:650;list-style:none}.activity summary::-webkit-details-marker{display:none}.activity summary::before{content:'›';display:inline-block;margin-right:8px;color:#7dd3fc;font-size:18px;line-height:10px;transition:transform .15s}.activity[open] summary::before{transform:rotate(90deg)}.activity-body{padding:0 14px 13px}.activity-line{padding:9px 0;border-top:1px solid #273552;color:#c2cce0;font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere}.copy{float:right;border:1px solid #3a4d70;border-radius:6px;background:#142139;color:#b9d8f6;padding:3px 7px;font:600 10px ui-sans-serif,system-ui;cursor:pointer}.copy:hover{background:#1d3455}.copy-all{float:none;margin-left:10px}</style></head><body><main class=\"app\"><header class=\"topbar\"><div class=\"brand\"><span class=\"mark\">λ</span><span>cl-agent</span></div><div class=\"status\"><span id=\"stats\">Connecting…</span><button class=\"copy copy-all\" id=\"copy-all\" type=\"button\">Copy chat</button></div></header><section class=\"chat\"><div class=\"messages\" id=\"messages\" aria-live=\"polite\"></div><button class=\"jump\" id=\"jump\" hidden>Jump to latest ↓</button></section><form class=\"composer\" id=\"form\"><textarea id=\"input\" rows=\"1\" autocomplete=\"off\" placeholder=\"Message cl-agent…\" autofocus></textarea><button class=\"send\" id=\"send\" type=\"submit\">Send</button><span class=\"hint\">Enter to send · Shift+Enter for a new line</span></form></main>
<script>
const messages=document.getElementById('messages'),form=document.getElementById('form'),input=document.getElementById('input'),send=document.getElementById('send'),stats=document.getElementById('stats'),jump=document.getElementById('jump'),copyAll=document.getElementById('copy-all');let signature='',sending=false,lastTranscript='';
const esc=s=>String(s??'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\"/g,'&quot;').replace(/'/g,'&#39;');
function nearBottom(){return messages.scrollHeight-messages.scrollTop-messages.clientHeight<56}function scrollLatest(){messages.scrollTop=messages.scrollHeight;jump.hidden=true}
function cleanMarkdown(html){const allowed=new Set(['A','BLOCKQUOTE','BR','CODE','DEL','EM','H1','H2','H3','H4','H5','H6','HR','LI','OL','P','PRE','S','STRONG','TABLE','TBODY','TD','TH','THEAD','TR','UL']);const box=document.createElement('template');box.innerHTML=html;for(const node of [...box.content.querySelectorAll('*')]){if(!allowed.has(node.tagName)){node.replaceWith(document.createTextNode(node.textContent||''));continue}for(const attr of [...node.attributes]){if(node.tagName==='A'&&attr.name==='href'&&/^(https?:|mailto:|#)/i.test(attr.value))continue;node.removeAttribute(attr.name)}}return box.innerHTML}
function card(role,label,content,markdown=false,extra=''){return `<article class=\"message role-${role} ${extra}\"><div class=\"badge\">${role==='assistant'?'AI':role==='user'?'YOU':role==='tool'?'⌘':'·'}</div><div class=\"card\"><div class=\"meta\">${label}</div><div class=\"${markdown?'markdown':'plain'}\">${markdown?cleanMarkdown(content):esc(content)}</div></div></article>`}
function copyControl(value){return `<button class=\"copy\" type=\"button\" data-copy=\"${encodeURIComponent(value)}\">Copy</button>`}function decorateCopies(){for(const node of messages.querySelectorAll('.card,.activity-line')){const text=(node.querySelector('.markdown,.plain')||node).innerText;if(text)node.insertAdjacentHTML('afterbegin',copyControl(text))}}function activity(items){return `<details class=\"activity\"><summary>Agent activity · ${items.length} update${items.length===1?'':'s'}</summary><div class=\"activity-body\">${items.map(m=>`<div class=\"activity-line\">${esc(m.text)}</div>`).join('')}</div></details>`}function transcript(items){let html='',hidden=[];const flush=()=>{if(hidden.length){html+=activity(hidden);hidden=[]}};for(const m of items){if(m.role==='tool'||m.role==='system'){hidden.push(m)}else{flush();html+=card(m.role,m.role,m.html||m.text,m.role==='assistant')}}flush();return html}function render(data){const next=JSON.stringify([data.messages,data.pending,data.thinking]);lastTranscript=data.messages.map(m=>`${m.role.toUpperCase()}:\n${m.text}`).join('\n\n');if(next===signature)return;const follow=nearBottom();signature=next;let html=transcript(data.messages);if(data.pending)html+=card('assistant','cl-agent',data.pending,false,'pending');else if(data.thinking)html+=card('system','cl-agent','Thinking…',false,'thinking');messages.innerHTML=html||card('system','cl-agent','Start a conversation to see the agent here.',false);decorateCopies();if(follow)scrollLatest();else jump.hidden=false}
function renderStats(s){stats.innerHTML=s?`<strong>${esc(s.provider)} · ${esc(s.model)}</strong><br>${s.requests} requests · ${s.tool_calls} tools${s.total_tokens?` · ${s.total_tokens} tokens`:''}`:'Ready'}
async function poll(){try{const response=await fetch('/api/messages',{cache:'no-store'});if(!response.ok)throw Error(response.status);const data=await response.json();render(data);renderStats(data.stats)}catch(e){stats.textContent='Connection lost — retrying…'}setTimeout(poll,500)}
async function copyText(text,button){try{await navigator.clipboard.writeText(text);const old=button.textContent;button.textContent='Copied';setTimeout(()=>button.textContent=old,1100)}catch(e){button.textContent='Copy failed'}}messages.addEventListener('scroll',()=>{jump.hidden=nearBottom()});messages.addEventListener('click',e=>{const button=e.target.closest('[data-copy]');if(button)copyText(decodeURIComponent(button.dataset.copy),button)});copyAll.onclick=()=>copyText(lastTranscript,copyAll);jump.onclick=scrollLatest;input.addEventListener('input',()=>{input.style.height='auto';input.style.height=Math.min(input.scrollHeight,180)+'px'});input.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();form.requestSubmit()}});form.onsubmit=async e=>{e.preventDefault();const text=input.value.trim();if(!text||sending)return;sending=true;send.disabled=true;input.value='';input.style.height='auto';try{await fetch('/api/send',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'text='+encodeURIComponent(text)});scrollLatest()}finally{sending=false;send.disabled=false;input.focus()}};poll();
</script></body></html>"
  "The whole web frontend client, inline -- see this file's header
comment on why that's an acceptable PoC simplification. Polls
/api/messages twice a second (not pushed -- see header comment on
SSE/WebSocket being a real-product improvement this PoC skips) so the
in-progress reply (DATA.PENDING) and the thinking indicator feel
reasonably live without any new transport.")

(hunchentoot:define-easy-handler (cl-agent-web-index :uri "/") ()
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  *web-page-html*)

(hunchentoot:define-easy-handler (cl-agent-web-messages :uri "/api/messages") ()
  (setf (hunchentoot:content-type*) "application/json")
  (if *web-frontend*
      (web-frontend-status-json *web-frontend*)
      (json-encode (jobj "messages" :empty-array "pending" "" "thinking" nil "stats" :null))))

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

(defmethod ui-start ((frontend web-frontend))
  (setf *web-frontend* frontend)
  (setf (web-frontend-acceptor frontend)
        (make-instance 'hunchentoot:easy-acceptor :port (web-frontend-port frontend) :address "127.0.0.1"))
  (hunchentoot:start (web-frontend-acceptor frontend))
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

(defmethod ui-tool-started ((frontend web-frontend) tool-name arguments)
  (web-frontend-push frontend "tool" (format nil "~~ ~a" (tool-call-summary tool-name arguments))))

(defmethod ui-tool-finished ((frontend web-frontend) tool-name arguments result)
  (declare (ignore tool-name arguments))
  (web-frontend-push frontend "tool" result))

(defmethod ui-system ((frontend web-frontend) text)
  (web-frontend-push frontend "system" text))

(defmethod ui-assistant-delta ((frontend web-frontend) chunk)
  (bt:with-lock-held ((web-frontend-state-lock frontend))
    (setf (web-frontend-pending frontend) (concatenate 'string (web-frontend-pending frontend) chunk))))

(defmethod ui-thinking-started ((frontend web-frontend))
  (bt:with-lock-held ((web-frontend-state-lock frontend)) (setf (web-frontend-thinking-p frontend) t)))

(defmethod ui-thinking-stopped ((frontend web-frontend))
  (bt:with-lock-held ((web-frontend-state-lock frontend)) (setf (web-frontend-thinking-p frontend) nil)))

(defmethod ui-stats-updated ((frontend web-frontend) stats)
  (bt:with-lock-held ((web-frontend-state-lock frontend)) (setf (web-frontend-stats frontend) stats)))

(register-frontend-class :web 'web-frontend)
