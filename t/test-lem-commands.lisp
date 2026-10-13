;;;; t/test-lem-commands.lisp -- the agent running Lem's own commands with
;;;; the minibuffer bridge (lem/commands.lisp), and Lem's own web view
;;;; (lem/display.lisp).

(in-package :cl-agent)

(defmacro with-lem-test-file ((path text) &body body)
  `(let ((,path (uiop:native-namestring (merge-pathnames (format nil "lem-~36r.txt" (random (expt 36 6))) *config-directory*))))
     (ensure-directories-exist ,path)
     (with-open-file (out ,path :direction :output :if-exists :supersede) (write-string ,text out))
     (unwind-protect (progn ,@body)
       (ignore-errors (editor-close-file ,path :force t)))))

(defun lem-buffer-text-of (path)
  (lem-call (lambda () (editor-buffer-text (editor-find-buffer path)))))

(deftest lem-commands-answer-their-prompts-from-the-agent ()
  (with-lem-test-file (path (format nil "one beta two beta~%beta three~%"))
    (let ((result (run-lem-command "query-replace" :path path :line 1 :answers '("beta" "BETA" "y" "n" "y"))))
      (check (null (getf result :error)) (getf result :error))
      (check-equal (lem-buffer-text-of path) (format nil "one BETA two beta~%BETA three~%")
                   "y, n, y: one answer per match, read as keys")
      (check-equal (length (getf result :asked)) 5)
      (check (search "Lines 1-2 changed" (getf result :changes)))
      (check (getf result :modified) "changed in the editor, not saved")
      (check-equal (uiop:read-file-string path) (format nil "one beta two beta~%beta three~%")))
    (let ((result (run-lem-command "query-replace" :path path :line 1 :answers '("three" "four" "!" "extra"))))
      (check-equal (lem-buffer-text-of path) (format nil "one BETA two beta~%BETA four~%") "! replaces the rest")
      (check-equal (getf result :unused) '("extra") "an answer not asked for is reported"))))

(deftest a-lem-prompt-without-an-answer-never-blocks ()
  (with-lem-test-file (path "text")
    (let* ((start (get-internal-real-time))
           (result (run-lem-command "query-replace" :path path :answers '("text"))))
      (check (search "no answer was left" (getf result :error)))
      (check (search "After" (getf result :error)) "says what it asked")
      (check (< (- (get-internal-real-time) start) (* 5 internal-time-units-per-second)))
      (check-equal (lem-call (lambda () :still-answering)) :still-answering "the editor thread is free"))))

(deftest lem-commands-run-on-a-region-with-keys-and-messages ()
  (with-lem-test-file (path (format nil "alpha~%beta~%gamma~%"))
    (run-lem-command "uppercase-region" :path path :line 1 :end-line 2 :end-column 5)
    (check-equal (lem-buffer-text-of path) (format nil "ALPHA~%BETA~%gamma~%") "the region from line 1 to 2:5")
    (let ((result (run-lem-command nil :keys "C-e" :path path :line 3)))
      (check-equal (getf result :point) '(3 6) "keys run as typed"))
    (check (getf (run-lem-command "current-directory" :path path) :messages) "Lem's messages come back")
    (check (search "no command named" (getf (run-lem-command "no-such-command-xyz" :path path) :error)))))

(deftest lem-commands-leave-the-users-view-alone ()
  (with-lem-test-file (path "shown")
    (with-lem-test-file (other "worked on")
      (lem-call (lambda () (lem:switch-to-buffer (lem:find-file-buffer path))))
      (run-lem-command "delete-trailing-whitespace" :path other)
      (check-equal (lem-call (lambda () (lem:buffer-filename (lem:window-buffer (lem:current-window)))))
                   (lem-call (lambda () (lem:buffer-filename (editor-find-buffer path))))
                   "the window shows what it showed before"))))

(deftest the-lem-command-tool ()
  (with-lem-test-file (path (format nil "x = 1   ~%"))
    (let ((text (call-tool "lem-command" (jobj "command" "delete-trailing-whitespace" "path" path "save" t))))
      (check (search "Ran delete-trailing-whitespace" text) text)
      (check (search "the buffer is saved" text) text))
    (check-equal (uiop:read-file-string path) (format nil "x = 1~%") "save writes through Lem")
    (check (search "Stopped" (call-tool "lem-command" (jobj "command" "query-replace" "path" path))))
    (check (search "delete-trailing-whitespace" (call-tool "lem-command" (jobj "action" "search" "query" "trailing"))))))

;;; --- the web view ---

(defun lem-display-request (path &rest headers)
  (multiple-value-bind (body status)
      (drakma:http-request (format nil "http://127.0.0.1:~d~a" (lem-display-start) path) :additional-headers headers)
    (values (if (stringp body) body (and body (babel:octets-to-string body :encoding :utf-8 :errorp nil))) status)))

(defun websocket-upgrade-status (origin)
  (nth-value 1 (ignore-errors
                (drakma:http-request (format nil "http://127.0.0.1:~d/" (lem-display-start))
                                     :want-stream t
                                     :additional-headers `(("Upgrade" . "websocket") ("Connection" . "Upgrade")
                                                           ("Sec-WebSocket-Key" . "dGhlIHNhbXBsZSBub25jZQ==")
                                                           ("Sec-WebSocket-Version" . "13") ("Origin" . ,origin))))))

(deftest lems-web-view-is-served-safely ()
  (check (typep (lem-call (lambda () (lem:implementation))) 'lem-host-display) "Lem renders through its web frontend")
  (check (search "http://127.0.0.1:" (lem-display-url)))
  (check-equal (nth-value 1 (lem-display-request "/")) 200)
  (let ((script (lem-display-request "/assets/index.js")))
    (check (search "addEventListener(\"blur\",i=>{})" script) "it no longer pulls focus back")
    (check (search "get(\"font\")" script) "it takes the page's font")
    (check (search "document.fonts.load(f)" script) "and loads it before measuring")
    (check (search "return[i.width," script) "glyphs at their own width, not squeezed"))
  (check (null (patch-lem-client)) "every patch still finds its place in Lem's client")
  (let ((page (lem-display-request "/")))
    (check (search "IBM+Plex+Mono" page) "the page's font")
    (check (search "--cl-rule" page) "chrome in the page's style"))
  (check-equal (nth-value 1 (lem-display-request "/local/etc/hosts")) 404 "no file from disk")
  (check-equal (nth-value 1 (lem-display-request "/" '("Host" . "evil.example"))) 403 "no DNS rebinding")
  (check-equal (websocket-upgrade-status "http://evil.example") 403 "no other web page drives Lem")
  (check-equal (websocket-upgrade-status (format nil "http://127.0.0.1:~d" (lem-display-start))) 101))

(deftest lem-view-routes-visit-and-refuse-blind-commands ()
  (with-lem-test-file (path "visited")
    (with-test-web-frontend (frontend)
      (check (search "http://127.0.0.1:" (gethash "url" (web-get-json frontend "/api/lem/display"))))
      (let ((json (json-decode (web-post frontend "/api/lem/visit" :json (jobj "path" path)))))
        (check-equal (gethash "path" json) (namestring (truename path))))
      (check-equal (lem-call (lambda () (lem:buffer-filename (lem:window-buffer (lem:current-window)))))
                   (namestring (truename path)) "shown in Lem's window")
      (unless (lem-display-connected-p)
        (check-equal (nth-value 1 (web-post frontend "/api/lem/run" :json (jobj "command" "find-file"))) 400
                     "no view open: its prompt would wait for good")))))

(deftest lem-takes-the-pages-colours ()
  (let ((colors (make-hash-table :test #'equal)))
    (setf (gethash "paper" colors) "#14122a" (gethash "ink" colors) "#eeeaff"
          (gethash "select" colors) "#5b1d57" (gethash "syn-keyword" colors) "#b56cff"
          (gethash "title-bg" colors) "#2b1f63" (gethash "blue" colors) "#4f8dff"
          (gethash "red" colors) "url(evil)")
    (let ((specs (lem-page-theme-specs "dark" colors)))
      (check-equal (assoc :background specs) '(:background "#14122a"))
      (check-equal (assoc :base0d specs) '(:base0d "#4f8dff") "base16 slots, for Lem's own attributes")
      (check-equal (assoc :base08 specs) '(:base08 nil) "only #rrggbb colours are taken")
      (check-equal (rest (assoc 'lem:syntax-keyword-attribute specs)) '(:foreground "#b56cff")))
    (unwind-protect
         (progn
           (with-test-web-frontend (frontend)
             (check-equal (gethash "theme" (json-decode (web-post frontend "/api/lem/theme"
                                                                  :json (jobj "mode" "dark" "colors" colors))))
                          "cl-agent"))
           (lem-call (lambda ()
                       (check-equal (lem:attribute-background (lem:ensure-attribute 'lem:region)) "#5b1d57"
                                    "the region is the page's selection")
                       (check-equal (lem:attribute-foreground (lem:ensure-attribute 'lem:syntax-keyword-attribute))
                                    "#b56cff")
                       (check (null (lem:config :color-theme)) "the user's Lem config is left alone"))))
      (lem-call (lambda () (lem:load-theme "lem-default" nil))))))

(deftest lems-tab-bar-takes-the-pages-colours ()
  (let ((colors (make-hash-table :test #'equal)))
    (setf (gethash "paper" colors) "#fcf9f0" (gethash "paper-2" colors) "#f2ede0" (gethash "ink" colors) "#1c1a33")
    (unwind-protect
         (progn
           (lem-apply-page-theme "light" colors)
           (let ((html (lem-call (lambda () (lem/tabbar::generate-html)))))
             (check (search "--tab-bg: #f2ede0" html) "the theme's colours")
             (check (search "IBM Plex Mono" html) "the page's font")
             (check (not (search "#181818" html)) "not Lem's own dark tabs")))
      (lem-call (lambda () (lem:load-theme "lem-default" nil))))
    (check (search "#181818" (lem-call (lambda () (lem/tabbar::generate-html))))
           "another theme's tab bar is left as Lem made it")))
