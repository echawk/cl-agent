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
;;;; channel, same as the TUI frontend, and UI-ASSISTANT-TEXT etc. just
;;;; append to a lock-protected transcript list that the polling GET
;;;; handler serves as JSON.

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
   (transcript-lock :initform (bt:make-lock "cl-agent-web-transcript") :accessor web-frontend-transcript-lock)
   (input-channel :initform (trivial-channels:make-channel) :accessor web-frontend-input-channel))
  (:documentation "Browser chat UI at http://127.0.0.1:PORT/. See this
file's header comment for scope and the threading model."))

(defun web-frontend-push (frontend role text)
  (bt:with-lock-held ((web-frontend-transcript-lock frontend))
    (push (list :role role :text text) (web-frontend-transcript frontend))))

(defun web-frontend-transcript-json (frontend)
  (bt:with-lock-held ((web-frontend-transcript-lock frontend))
    (json-encode (mapcar (lambda (entry) (jobj "role" (getf entry :role) "text" (getf entry :text)))
                          (reverse (web-frontend-transcript frontend))))))

(defparameter *web-page-html*
  "<!doctype html><html><head><meta charset=\"utf-8\">
<title>cl-agent</title>
<style>
body{font-family:ui-monospace,Menlo,Consolas,monospace;max-width:760px;margin:2rem auto;padding:0 1rem;background:#1e1e1e;color:#ddd}
#t{white-space:pre-wrap;border:1px solid #444;border-radius:6px;padding:1rem;height:60vh;overflow-y:auto;margin-bottom:1rem}
.role-user{color:#7fc}.role-assistant{color:#ddd}.role-tool{color:#fc7}.role-system{color:#888;font-style:italic}
#f{display:flex;gap:.5rem} #i{flex:1;font:inherit;background:#2a2a2a;color:#ddd;border:1px solid #444;border-radius:6px;padding:.5rem}
button{font:inherit;background:#2a2a2a;color:#ddd;border:1px solid #444;border-radius:6px;padding:.5rem 1rem;cursor:pointer}
</style></head><body>
<h3>cl-agent</h3>
<div id=\"t\"></div>
<form id=\"f\"><input id=\"i\" autocomplete=\"off\" placeholder=\"Message cl-agent...\" autofocus><button>Send</button></form>
<script>
const t=document.getElementById('t'),f=document.getElementById('f'),i=document.getElementById('i');
async function poll(){
  try{const r=await fetch('/api/messages');const msgs=await r.json();
    t.innerHTML=msgs.map(m=>`<div class=\"role-${m.role}\">${m.text.replace(/&/g,'&amp;').replace(/</g,'&lt;')}</div>`).join('');
    t.scrollTop=t.scrollHeight;}catch(e){}
  setTimeout(poll,1000);
}
f.onsubmit=async(e)=>{e.preventDefault();const text=i.value;if(!text.trim())return;i.value='';
  await fetch('/api/send',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'text='+encodeURIComponent(text)});};
poll();
</script></body></html>"
  "The whole web frontend client, inline -- see this file's header
comment on why that's an acceptable PoC simplification.")

(hunchentoot:define-easy-handler (cl-agent-web-index :uri "/") ()
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  *web-page-html*)

(hunchentoot:define-easy-handler (cl-agent-web-messages :uri "/api/messages") ()
  (setf (hunchentoot:content-type*) "application/json")
  (if *web-frontend* (web-frontend-transcript-json *web-frontend*) "[]"))

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
  (web-frontend-push frontend "assistant" text))

(defmethod ui-tool-started ((frontend web-frontend) tool-name arguments)
  (web-frontend-push frontend "tool" (format nil "~~ ~a" (tool-call-summary tool-name arguments))))

(defmethod ui-tool-finished ((frontend web-frontend) tool-name arguments result)
  (declare (ignore tool-name arguments))
  (web-frontend-push frontend "tool" result))

(defmethod ui-system ((frontend web-frontend) text)
  (web-frontend-push frontend "system" text))

(register-frontend-class :web 'web-frontend)
