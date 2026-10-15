;;;; lem/display.lisp -- the hosted Lem, shown in the browser by Lem's own
;;;; web frontend: the Code tab's editor *is* Lem (windows, mode line, M-x,
;;;; the minibuffer, dired, the user's init file and keys).
;;;;
;;;; LEM-HOST-DISPLAY is Lem's own JSON-RPC frontend class (lem-server), so
;;;; every view, line and cursor is rendered by Lem's code, unchanged; what
;;;; differs is how it is hosted:
;;;;   - the editor thread is cl-agent's (lem/host.lisp), started without
;;;;     waiting for a browser, and nothing calls UIOP:QUIT on exit;
;;;;   - the websocket server starts on demand (LEM-DISPLAY-URL), on a free
;;;;     port of 127.0.0.1, behind LEM-DISPLAY-CLACK-HANDLER: a loopback Host
;;;;     only (no DNS rebinding), websocket upgrades only from the Lem page's
;;;;     own origin (so no other web page can drive Lem -- browsers always
;;;;     send Origin), and only the client's own files: lem-server's /local/
;;;;     route, which serves any file on disk, is refused;
;;;;   - the client is served patched (*LEM-CLIENT-PATCHES*): it no longer
;;;;     pulls focus back into itself on blur (it lives in an iframe beside
;;;;     cl-agent's own inputs), it takes the page's font (?font=&size=),
;;;;     loads it before measuring, draws glyphs at their own width, and its
;;;;     chrome (mode lines, borders, popups) is square and ruled like the
;;;;     page's;
;;;;   - its colours are the page's: LEM-APPLY-PAGE-THEME makes a Lem colour
;;;;     theme from the page's theme tokens (light or dark, customised or not).

(in-package :cl-agent)

(defclass lem-host-display (lem-server:jsonrpc) ()
  (:documentation "cl-agent's Lem frontend: lem-server's renderer, hosted here."))

(defmethod initialize-instance :after ((display lem-host-display) &key)
  ;; Unbound until a browser logs in, yet Lem asks for them before that.
  (setf (lem-server::jsonrpc-background-color display) (lem:make-color 255 255 255)
        (lem-server::jsonrpc-foreground-color display) (lem:make-color 0 0 0)
        (lem-server::jsonrpc-display-width display) 120
        (lem-server::jsonrpc-display-height display) 40))

(defmethod lem-if:invoke ((display lem-host-display) function)
  ;; FUNCTION starts cl-agent's editor thread and returns it.
  (setf (lem-server::jsonrpc-editor-thread display) (funcall function)))

(defun lem-display-connected-p (&optional (display (lem:implementation)))
  (and (typep display 'lem-host-display)
       (ignore-errors (jsonrpc/server::server-client-connections (lem-server::jsonrpc-server display)))
       t))

(defmethod lem-if:js-eval ((display lem-host-display) view code &key wait)
  ;; Waiting for an answer from no browser would hang the editor thread.
  (call-next-method display view code :wait (and wait (lem-display-connected-p display))))

;;; --- the client, as served ---

(defparameter *lem-client-chrome*
  "<link rel=\"stylesheet\" href=\"https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:ital,wght@0,400;0,700;1,400&display=swap\">
<style>
/* cl-agent: Lem's chrome in the page's style (square, ruled, flat). */
html, body { background: var(--cl-paper, transparent); }
.lem-editor__mode-line { border-radius: 0; box-shadow: none; }
.lem-editor__floating-window--bordered {
  padding: 4px; border-radius: 0; backdrop-filter: none;
  background: var(--cl-paper, transparent);
  border: 2px solid var(--cl-rule, #888);
  box-shadow: 4px 4px 0 var(--cl-shadow, #000);
}
.lem-editor__vertical-border {
  background: linear-gradient(to right, transparent 4px, var(--cl-rule-soft, #555) 4px 6px, transparent 6px);
}
.lem-editor__horizontal-border {
  background: linear-gradient(to bottom, transparent 4px, var(--cl-rule-soft, #555) 4px 6px, transparent 6px);
}
</style>
<script>
/* cl-agent: the page's colours, from the URL and then from the page itself. */
(function () {
  var set = function (vars) {
    for (var name in vars)
      if (/^[a-z-]+$/.test(name) && /^#[0-9a-f]{6}$/i.test(vars[name]))
        document.documentElement.style.setProperty('--cl-' + name, vars[name]);
  };
  var query = new URLSearchParams(location.search), vars = {};
  ['paper', 'rule', 'rule-soft', 'shadow'].forEach(function (name) { if (query.get(name)) vars[name] = query.get(name); });
  set(vars);
  window.addEventListener('message', function (event) {
    if (event.source !== window.parent || !event.data) return;
    if (event.data.type === 'cl-agent-style') set(event.data.vars || {});
    // The page's layout changed this frame's size: measure again, as a
    // resize of this window would -- and once more when the views have
    // their new sizes, or a mode line keeps the width it was drawn at.
    if (event.data.type === 'cl-agent-resize') {
      window.dispatchEvent(new Event('resize'));
      setTimeout(function () { window.dispatchEvent(new Event('resize')); }, 350);
    }
  });
})();
</script>
"
  "Put into the Lem page's head: the page's font, and Lem's chrome in
cl-agent's style.  Colours come as --cl-* variables (see the Lem view in
code.js).")

(defparameter *lem-client-patches*
  `(("frontend/dist/assets/index.js"
     ;; It no longer pulls focus back into itself: it lives in an iframe
     ;; beside cl-agent's own inputs.
     ("this.input.addEventListener(\"blur\",i=>{this.input.focus()})"
      "this.input.addEventListener(\"blur\",i=>{})")
     ;; The page's font (?font=&size=) ...
     ("fontName:\"Monospace\",fontSize:18"
      "fontName:new URLSearchParams(location.search).get(\"font\")||\"Monospace\",fontSize:+(new URLSearchParams(location.search).get(\"size\")||18)")
     ;; ... loaded before the client measures it (a fallback's metrics
     ;; would stick) ...
     ("await document.fonts.ready;"
      "await document.fonts.ready;{const q=new URLSearchParams(location.search),f=(q.get(\"size\")||18)+\"px \"+(q.get(\"font\")||\"Monospace\");await Promise.all([document.fonts.load(f),document.fonts.load(\"bold \"+f)]).catch(()=>{})}")
     ;; ... and drawn at its own width: the cell was the width rounded
     ;; down, and every glyph squeezed into it.  Fills snap to whole pixels
     ;; so neighbouring cells leave no seams.
     ("return[Math.floor(i.width),"
      "return[i.width,")
     ("function drawBlock({ctx:o,x:e,y:t,width:i,height:n,style:s}){o.fillStyle=s,o.fillRect(e,t,i,n)}"
      "function drawBlock({ctx:o,x:e,y:t,width:i,height:n,style:s}){o.fillStyle=s;const a=Math.round(e),b=Math.round(t);o.fillRect(a,b,Math.round(e+i)-a,Math.round(t+n)-b)}")
     ;; The page shows through until Lem draws, not a grey box.
     ("document.getElementsByTagName(\"html\")[0].style[\"background-color\"]=\"#333\""
      "document.getElementsByTagName(\"html\")[0].style[\"background-color\"]=\"transparent\""))
    ("frontend/dist/index.html"
     ("</head>" ,(concatenate 'string *lem-client-chrome* "</head>"))))
  "(file (old new) ...): lem-server's built client, as cl-agent serves it.")

(defun replace-once (text old new)
  (let ((at (search old text)))
    (if at (concatenate 'string (subseq text 0 at) new (subseq text (+ at (length old)))) text)))

(defun patch-lem-client ()
  "Patch lem-server's in-memory copy of its built client (*LEM-CLIENT-PATCHES*).
Returns the patches that found nothing to replace: none, unless Lem changed."
  (let ((missed '()))
    (loop for (file . patches) in *lem-client-patches*
          for entry = (assoc file lem-server::*dist* :test #'equal)
          do (if (null entry)
                 (push file missed)
                 (let ((text (babel:octets-to-string (cdr entry) :encoding :utf-8)))
                   (loop for (old new) in patches
                         do (cond ((search new text))     ; patched already
                                  ((search old text) (setf text (replace-once text old new)))
                                  (t (push (list file old) missed))))
                   (setf (cdr entry) (babel:string-to-octets text :encoding :utf-8)))))
    (nreverse missed)))

(patch-lem-client)

(defun lem-display-clack-handler (env)
  "Guard, then serve, every request to the Lem display server (see the
header).  NIL lets a websocket upgrade through to Lem."
  (let* ((headers (getf env :headers))
         (host (and headers (gethash "host" headers)))
         (origin (and headers (gethash "origin" headers)))
         (path (or (getf env :path-info) "/")))
    (cond ((not (loopback-host-p host))
           '(403 (:content-type "text/plain") ("Forbidden: Lem only answers on 127.0.0.1.")))
          ((wsd:websocket-p env)
           (if (and origin (string= origin (format nil "http://~a" host)))
               nil
               '(403 (:content-type "text/plain") ("Forbidden: not from the Lem page."))))
          ((or (string= path "/") (uiop:string-prefix-p "/assets/" path))
           (lem-server::clack-handler env))
          (t '(404 (:content-type "text/plain") ("Not found."))))))

;;; --- the server, started when the page first asks for it ---

(defvar *lem-display-port* nil)
(defvar *lem-display-lock* (bt:make-lock "lem-display"))

(defun free-local-port ()
  (let ((socket (usocket:socket-listen "127.0.0.1" 0 :reuse-address t)))
    (prog1 (usocket:get-local-port socket) (usocket:socket-close socket))))

(defun lem-display-redraw-all ()
  (lem:send-event (lambda ()
                    (lem-core::adjust-all-window-size)
                    ;; A new browser has drawn nothing: Lem's per-window line
                    ;; cache would skip every unchanged line (as LOAD-THEME notes).
                    (dolist (window (append (lem:window-list)
                                            (lem-core::frame-header-windows (lem:current-frame))
                                            (lem-core::frame-floating-windows (lem:current-frame))))
                      (lem-core::need-to-redraw window))
                    ;; The tab bar sends its HTML only when marked for it: a
                    ;; page that has just connected would show an empty bar.
                    (when (fboundp 'lem/tabbar::update) (funcall 'lem/tabbar::update))
                    (lem:redraw-display :force t))))

(defparameter *lem-display-minimum-size* '(10 . 3)
  "Columns and rows below which a size from the page is ignored: an iframe
that is hidden measures 0x0, and Lem shrunk to nothing redraws badly.")

(defun lem-display-size-usable-p (size)
  (let ((width (and (hash-table-p size) (gethash "width" size)))
        (height (and (hash-table-p size) (gethash "height" size))))
    (and (integerp width) (integerp height)
         (>= width (car *lem-display-minimum-size*))
         (>= height (cdr *lem-display-minimum-size*)))))

(defun lem-display-sane-login (params display)
  "PARAMS of a page's login, its size Lem's current one when the page
measured none (a hidden frame: 0x0, and Lem's windows would be 0 wide, its
every redraw an error -- nothing shown)."
  (when (and (hash-table-p params) (not (lem-display-size-usable-p (gethash "size" params))))
    (setf (gethash "size" params)
          (jobj "width" (lem-server::jsonrpc-display-width display)
                "height" (lem-server::jsonrpc-display-height display))))
  params)

(defun lem-display-redraw (args)
  "The page's \"redraw\": lem-server's, with a size only when it is real,
and every window redrawn in full (Lem's line cache would skip lines
already sent at the old size)."
  (let ((size (and (hash-table-p args) (gethash "size" args))))
    (when (or (null size) (lem-display-size-usable-p size))
      (lem-server::redraw args))
    (lem-display-redraw-all)))

(defun lem-display-start ()
  "Start the display's websocket server (once) and return its port."
  (unless (lem-host-available-p)
    (error 'lem-host-unavailable :reason *lem-host-problem*))
  (bt:with-lock-held (*lem-display-lock*)
    (or *lem-display-port*
        (let* ((display (lem:implementation))
               (server (lem-server::jsonrpc-server display))
               (port (free-local-port)))
          (unless (typep display 'lem-host-display)
            (error "Lem is not running with cl-agent's display."))
          (let ((login (lem-server::login display #'lem-display-redraw-all)))
            (jsonrpc:expose server "login"
                            (lambda (params)
                              (prog1 (funcall login (lem-display-sane-login params display))
                                ;; The page shows "Starting Lem..." until now.
                                (lem-publish-async "lem-display" (jobj "connected" t))))))
          (jsonrpc:expose server "input" (lambda (args) (lem-server::input-callback display args)))
          (jsonrpc:expose server "redraw" 'lem-display-redraw)
          (jsonrpc:expose server "got-clipboard-text" 'lem-server::got-clipboard-text)
          (jsonrpc:expose server "invoke" 'lem-server::invoke)
          (as-agent-itself
            (bt:make-thread
             (lambda ()
               (let ((*error-output* (make-broadcast-stream)) (*trace-output* (make-broadcast-stream)))
                 (jsonrpc:server-listen server :mode :websocket :port port :host "127.0.0.1"
                                               :debug nil :silent t :clack-handler 'lem-display-clack-handler)))
             :name "lem-display-server"))
          ;; Answering yet?
          (loop repeat 100
                until (ignore-errors (usocket:socket-close (usocket:socket-connect "127.0.0.1" port)) t)
                do (sleep 0.05))
          (setf *lem-display-port* port)))))

(defun lem-display-url (&key (font "Monospace") (size 14))
  "The URL of the Lem display page, starting its server if need be."
  (format nil "http://127.0.0.1:~d/?font=~a&size=~d" (lem-display-start)
          (quri:url-encode font) size))

;;; --- what Lem shows, told to the page ---
;;;
;;; The page follows Lem: whatever buffer its window shows -- visited from
;;; the page, with C-x C-f or C-x b in Lem itself, by the agent -- is the
;;; Code tab's current file, and its modified state the Open list's dot.

(defvar *lem-shown* nil
  "(buffer . modified-p) last told to the page.")

;;; The editor thread never publishes itself: a page's state lock may be
;;; held by a thread waiting on Lem (a reply's code highlighted by it), and
;;; the two would wait on each other.  Its events go through a channel to a
;;; thread of their own, in order.

(defvar *lem-publish-channel* nil)
(defvar *lem-publish-lock* (bt:make-lock "lem-publish"))

(defun lem-in-background (function)
  "Run FUNCTION on the editor's helper thread, in order with the rest: for
what the editor thread must not do itself (publish to pages, save a file
other code locks)."
  (let ((channel (bt:with-lock-held (*lem-publish-lock*)
                   (or *lem-publish-channel*
                       (let ((channel (trivial-channels:make-channel)))
                         (as-agent-itself
                           (bt:make-thread (lambda ()
                                             (loop (let ((job (trivial-channels:recvmsg channel)))
                                                     (ignore-errors (funcall job)))))
                                           :name "lem-publish"))
                         (setf *lem-publish-channel* channel))))))
    (trivial-channels:sendmsg channel function)))

(defun lem-publish-async (type payload)
  (lem-in-background (lambda () (editor-publish type payload))))

(defun lem-shown-buffer-json (buffer)
  (if (lem:buffer-filename buffer)
      (editor-buffer-json buffer)
      (jobj "path" :null "name" (lem:buffer-name buffer)
            "mode" (json-or-null (ignore-errors (lem:mode-name (lem:buffer-major-mode buffer)))))))

(defun lem-note-shown-buffer (&rest arguments)
  "Tell the page when the buffer Lem's window shows, or whether it is
modified, has changed (from Lem's post-command hook; editor thread)."
  (declare (ignore arguments))
  (ignore-errors
   (let* ((window (lem:current-window))
          ;; Not the minibuffer or a pop-up: the window the person edits in.
          (buffer (and (member window (lem:window-list)) (lem:window-buffer window))))
     (when buffer
       (let ((shown (cons buffer (and (lem:buffer-modified-p buffer) t))))
         (unless (and (eq (car shown) (car *lem-shown*)) (eq (cdr shown) (cdr *lem-shown*)))
           (setf *lem-shown* shown)
           (lem-publish-async "lem-buffer" (lem-shown-buffer-json buffer))))))))

(lem:add-hook lem:*post-command-hook* 'lem-note-shown-buffer)

(defun lem-visit (path &key line)
  "Show PATH in the Lem display's current window (as C-x C-f), at LINE."
  (let ((opened nil))
    (prog1 (lem-call
            (lambda ()
              (let ((full (expand-user-path path)))
                (multiple-value-bind (buffer new-p) (lem:find-file-buffer full)
                  (setf opened (and new-p (lem:buffer-filename buffer)))
                  (lem:switch-to-buffer buffer)
                  (when line
                    (lem:move-to-line (lem:buffer-point buffer) line)
                    (lem:line-start (lem:buffer-point buffer)))
                  (lem:redraw-display :force t)
                  (lem-note-shown-buffer)
                  (editor-buffer-json buffer)))))
      (when opened
        (run-hook :file-opened opened)
        (editor-publish "file-buffers" (jobj "opened" opened))))))

;;; --- the page's colours ---

(defparameter *lem-page-theme*
  '((:base00 "paper") (:base01 "paper-2") (:base02 "paper-3") (:base03 "syn-comment")
    (:base04 "ink-3") (:base05 "ink-2") (:base06 "ink") (:base07 "ink")
    (:base08 "red") (:base09 "orange") (:base0a "yellow") (:base0b "green")
    (:base0c "cyan") (:base0d "blue") (:base0e "violet") (:base0f "pink")
    ("LEM" "CURSOR" :background "ink")
    ("LEM" "REGION" :foreground nil :background "select")
    ("LEM" "MODELINE" :foreground "title-fg" :background "title-bg" :bold t)
    ("LEM" "MODELINE-INACTIVE" :foreground "ink-2" :background "paper-3" :bold t)
    ("LEM-CORE" "MODELINE-NAME-ATTRIBUTE" :foreground "yellow")
    ("LEM-CORE" "INACTIVE-MODELINE-NAME-ATTRIBUTE" :foreground "ink-2")
    ("LEM-CORE" "MODELINE-MAJOR-MODE-ATTRIBUTE" :foreground "cyan")
    ("LEM-CORE" "INACTIVE-MODELINE-MAJOR-MODE-ATTRIBUTE" :foreground "ink-3")
    ("LEM-CORE" "MODELINE-MINOR-MODES-ATTRIBUTE" :foreground "title-fg")
    ("LEM-CORE" "INACTIVE-MODELINE-MINOR-MODES-ATTRIBUTE" :foreground "ink-3")
    ("LEM-CORE" "MODELINE-POSITION-ATTRIBUTE" :foreground "on-yellow" :background "yellow")
    ("LEM-CORE" "INACTIVE-MODELINE-POSITION-ATTRIBUTE" :foreground "ink-2" :background "paper-2")
    ("LEM-CORE" "MODELINE-POSLINE-ATTRIBUTE" :foreground "on-pink" :background "pink")
    ("LEM-CORE" "INACTIVE-MODELINE-POSLINE-ATTRIBUTE" :foreground "ink-2" :background "paper-2")
    ("LEM-CORE" "MODELINE-VERSION-ATTRIBUTE" :foreground "ink-3")
    ("LEM-CORE" "INACTIVE-MODELINE-VERSION-ATTRIBUTE" :foreground "ink-3")
    ("LEM" "SYNTAX-WARNING-ATTRIBUTE" :foreground "red")
    ("LEM" "SYNTAX-STRING-ATTRIBUTE" :foreground "syn-string")
    ("LEM" "SYNTAX-COMMENT-ATTRIBUTE" :foreground "syn-comment")
    ("LEM" "SYNTAX-KEYWORD-ATTRIBUTE" :foreground "syn-keyword")
    ("LEM" "SYNTAX-CONSTANT-ATTRIBUTE" :foreground "syn-constant")
    ("LEM" "SYNTAX-FUNCTION-NAME-ATTRIBUTE" :foreground "syn-def" :bold t)
    ("LEM" "SYNTAX-VARIABLE-ATTRIBUTE" :foreground "syn-special")
    ("LEM" "SYNTAX-TYPE-ATTRIBUTE" :foreground "syn-constant" :bold t)
    ("LEM" "SYNTAX-BUILTIN-ATTRIBUTE" :foreground "syn-operator")
    ("LEM" "DOCUMENT-HEADER1-ATTRIBUTE" :foreground "syn-def" :bold t)
    ("LEM" "DOCUMENT-HEADER2-ATTRIBUTE" :foreground "syn-def" :bold t)
    ("LEM" "DOCUMENT-HEADER3-ATTRIBUTE" :foreground "syn-def" :bold t)
    ("LEM" "DOCUMENT-HEADER4-ATTRIBUTE" :foreground "syn-def" :bold t)
    ("LEM" "DOCUMENT-HEADER5-ATTRIBUTE" :foreground "syn-def" :bold t)
    ("LEM" "DOCUMENT-HEADER6-ATTRIBUTE" :foreground "syn-def" :bold t)
    ("LEM" "DOCUMENT-ITALIC-ATTRIBUTE" :foreground "ink-2")
    ("LEM" "DOCUMENT-LINK-ATTRIBUTE" :foreground "syn-operator" :underline t)
    ("LEM" "DOCUMENT-LIST-ATTRIBUTE" :foreground "syn-keyword" :bold t)
    ("LEM" "DOCUMENT-CODE-BLOCK-ATTRIBUTE" :foreground "syn-string" :background "paper-2")
    ("LEM" "DOCUMENT-INLINE-CODE-ATTRIBUTE" :foreground "syn-string" :background "code-inline")
    ("LEM" "DOCUMENT-BLOCKQUOTE-ATTRIBUTE" :foreground "syn-comment")
    ("LEM" "DOCUMENT-TABLE-ATTRIBUTE" :foreground "syn-constant" :background nil)
    ("LEM" "DOCUMENT-TASK-LIST-ATTRIBUTE" :foreground "syn-keyword")
    ("LEM" "DOCUMENT-METADATA-ATTRIBUTE" :foreground "syn-comment")
    ("LEM/SHOW-PAREN" "SHOWPAREN-ATTRIBUTE" :foreground "ink" :background "select")
    ("LEM/POPUP-MENU" "POPUP-MENU-ATTRIBUTE" :foreground "ink" :background "select")
    ("LEM/POPUP-MENU" "NON-FOCUS-POPUP-MENU-ATTRIBUTE" :foreground "ink" :background "paper")
    ("LEM/ISEARCH" "ISEARCH-HIGHLIGHT-ATTRIBUTE" :foreground "ink" :background "select")
    ("LEM/ISEARCH" "ISEARCH-HIGHLIGHT-ACTIVE-ATTRIBUTE" :foreground "on-yellow" :background "yellow")
    ("LEM/LINE-NUMBERS" "LINE-NUMBERS-ATTRIBUTE" :foreground "ink-3" :background "paper")
    ("LEM/LINE-NUMBERS" "ACTIVE-LINE-NUMBER-ATTRIBUTE" :foreground "ink" :background "paper-2")
    ("LEM/PROMPT-WINDOW" "PROMPT-ATTRIBUTE" :foreground "pink" :bold t)
    ("LEM/TABBAR" "TABBAR-ACTIVE-TAB-ATTRIBUTE" :foreground "ink" :background "paper")
    ("LEM/TABBAR" "TABBAR-ATTRIBUTE" :foreground "ink-2" :background "paper-2")
    ("LEM/TABBAR" "TABBAR-BACKGROUND-ATTRIBUTE" :background "paper-2")
    ("CL-AGENT" "COPILOT-SUGGESTION-ATTRIBUTE" :foreground "ink-3"))
  "Lem's colours as the page's theme tokens (theme.css): base16 slots, then
(package attribute . arguments), a string argument naming a token.")

(defun page-color-p (value)
  (and (stringp value) (= (length value) 7) (char= (char value 0) #\#)
       (every (lambda (c) (digit-char-p c 16)) (subseq value 1))))

(defun lem-page-theme-specs (mode colors)
  "The specs of a Lem colour theme for the page in MODE (\"light\" or
\"dark\"), with COLORS (hash: token name -> #rrggbb)."
  (flet ((color (token)
           (let ((value (and (stringp token) (gethash token colors))))
             (and (page-color-p value) value))))
    (append
     `((:display-background-mode ,(if (equal mode "light") :light :dark))
       (:foreground ,(color "ink"))
       (:background ,(color "paper"))
       (:inactive-window-background nil))
     (loop for spec in *lem-page-theme*
           if (keywordp (first spec))
             collect (list (first spec) (color (second spec)))
           else
             append (destructuring-bind (package name &rest arguments) spec
                      (let ((symbol (and (find-package package) (find-symbol name package))))
                        (when symbol
                          (list (cons symbol (loop for (key value) on arguments by #'cddr
                                                   collect key
                                                   collect (if (stringp value) (color value) value)))))))))))

(defun lem-apply-page-theme (mode colors)
  "Make Lem look like the page: load a colour theme made from the page's
theme tokens (LEM-PAGE-THEME-SPECS).  Not saved to the user's Lem config."
  (let ((theme (lem-core::make-color-theme :specs (lem-page-theme-specs mode colors)
                                           :parent "lem-default")))
    (lem-call (lambda ()
                (setf (gethash "cl-agent" lem-core::*color-themes*) theme)
                (lem:load-theme "cl-agent" nil)
                (lem-core::current-theme)))))

;;; Lem's tab bar is a little HTML page of its own (lem-server's
;;; tabbar.lisp), in fixed dark colours: in cl-agent's theme, it takes the
;;; theme's colours and the page's font and square tabs instead.

(defun lem-theme-color (slot)
  (let ((color (ignore-errors (lem-core::base-color slot))))
    (and (page-color-p color) color)))

(defun page-styled-tabbar (html)
  (let* ((start (search ":root {" html))
         (end (and start (search "}" html :start2 start))))
    (if (not (and end (equal (lem-core::current-theme) "cl-agent")))
        html
        (flet ((c (slot fallback) (or (lem-theme-color slot) fallback)))
          (concatenate
           'string
           (replace-once (subseq html 0 start) "<head>"
                         "<head><link rel=\"stylesheet\" href=\"https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@600&display=swap\">")
           (format nil ":root {
  --tab-bg: ~a; --tab-bg-hover: ~a; --tab-bg-active: ~a;
  --tab-fg: ~a; --tab-fg-active: ~a; --tab-border: ~a;
  --tab-accent: ~a; --tab-dirty: ~a;
}
.lem-editor__tabbar-button { font: 600 12px/1 'IBM Plex Mono', ui-monospace, Menlo, monospace; letter-spacing: .02em; }
.lem-editor__tabbar-button.active { box-shadow: inset 0 -2px 0 0 var(--tab-accent); }
.tab-close { border-radius: 0; }"
                   (c :base01 "#181818") (c :base02 "#252525") (c :base00 "#2d2d2d")
                   (c :base05 "#8b8b8b") (c :base06 "#e0e0e0") (c :base02 "#2a2a2a")
                   (c :base0f "#4cc2ff") (c :base0a "#e5c07b"))
           (subseq html (1+ end)))))))

(when (fboundp 'lem/tabbar::generate-html)
  (sb-int:encapsulate 'lem/tabbar::generate-html 'cl-agent-page-style
                      (lambda (function &rest arguments)
                        (page-styled-tabbar (apply function arguments)))))
