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

(defun web-frontend-status-json (frontend)
  "The single JSON object /api/messages serves: the transcript so far,
the in-progress streamed reply (if any), whether a request is
currently in flight, and the latest stats snapshot."
  (bt:with-lock-held ((web-frontend-state-lock frontend))
    (json-encode
     (jobj "messages" (or (mapcar (lambda (entry) (jobj "role" (getf entry :role) "text" (getf entry :text)))
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
  "<!doctype html><html><head><meta charset=\"utf-8\">
<title>cl-agent</title>
<style>
body{font-family:ui-monospace,Menlo,Consolas,monospace;max-width:760px;margin:2rem auto;padding:0 1rem;background:#1e1e1e;color:#ddd}
#stats{color:#888;font-size:.85em;margin-bottom:.5rem;min-height:1.2em}
#t{white-space:pre-wrap;border:1px solid #444;border-radius:6px;padding:1rem;height:60vh;overflow-y:auto;margin-bottom:1rem}
.role-user{color:#7fc}.role-assistant{color:#ddd}.role-tool{color:#fc7}.role-system{color:#888;font-style:italic}
.role-pending{color:#ddd;opacity:.7} .role-thinking{color:#888;font-style:italic}
#f{display:flex;gap:.5rem} #i{flex:1;font:inherit;background:#2a2a2a;color:#ddd;border:1px solid #444;border-radius:6px;padding:.5rem}
button{font:inherit;background:#2a2a2a;color:#ddd;border:1px solid #444;border-radius:6px;padding:.5rem 1rem;cursor:pointer}
</style></head><body>
<h3>cl-agent</h3>
<div id=\"stats\"></div>
<div id=\"t\"></div>
<form id=\"f\"><input id=\"i\" autocomplete=\"off\" placeholder=\"Message cl-agent...\" autofocus><button>Send</button></form>
<script>
const t=document.getElementById('t'),f=document.getElementById('f'),i=document.getElementById('i'),statsEl=document.getElementById('stats');
function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;');}
async function poll(){
  try{
    const r=await fetch('/api/messages');const data=await r.json();
    let html=data.messages.map(m=>`<div class=\"role-${m.role}\">${esc(m.text)}</div>`).join('');
    if(data.pending){html+=`<div class=\"role-pending\">${esc(data.pending)}</div>`;}
    else if(data.thinking){html+=`<div class=\"role-thinking\">&#8942; thinking...</div>`;}
    t.innerHTML=html;
    t.scrollTop=t.scrollHeight;
    if(data.stats){
      const s=data.stats;
      statsEl.textContent=`${s.provider} (${s.model}) | ${s.elapsed_seconds}s | ${s.requests} request(s), ${s.tool_calls} tool call(s)`+
        (s.total_tokens?` | ${s.total_tokens} tokens`:'');
    }
  }catch(e){}
  setTimeout(poll,500);
}
f.onsubmit=async(e)=>{e.preventDefault();const text=i.value;if(!text.trim())return;i.value='';
  await fetch('/api/send',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'text='+encodeURIComponent(text)});};
poll();
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
