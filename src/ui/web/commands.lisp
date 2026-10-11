;;;; ui/web/commands.lisp -- slash commands and completions for the web
;;;; UI.  Loaded after repl.lisp (DEFINE-SLASH-COMMAND lives there), so it
;;;; is a separate ASDF module from the rest of ui/web/.

(in-package :cl-agent)

(define-slash-command theme (session arg)
  "Switch open web pages to the light or dark theme: /theme light|dark|toggle."
  (let ((choice (string-downcase (string-trim " " arg)))
        (frontend (session-frontend session)))
    (cond ((not (member choice '("light" "dark" "toggle") :test #'string=))
           (ui-system frontend "Usage: /theme light|dark|toggle"))
          ((null *web-frontends*)
           (ui-system frontend "No web page is open; /theme only affects the web UI."))
          (t (web-ui-command "theme" (jobj "theme" choice))
             (ui-system frontend (format nil "Theme: ~a." choice)))))
  t)

(define-slash-command ui (session arg)
  "Inspect or undo web UI customizations: /ui [list], /ui reset PATH|all, /ui revert PATH, /ui reload."
  (let* ((frontend (session-frontend session))
         (words (remove "" (uiop:split-string (string-trim " " arg) :separator " ") :test #'string=))
         (action (or (first words) "list"))
         (path (second words)))
    (handler-case
        (ui-system frontend
                   (cond ((string-equal action "list") (format-web-asset-list))
                         ((and (string-equal action "reset") (equal path "all"))
                          (format nil "Removed overrides: ~{~a~^, ~}." (or (reset-all-web-assets) '("none"))))
                         ((and (string-equal action "reset") path) (reset-web-asset path))
                         ((and (string-equal action "revert") path) (reset-web-asset path :to :previous))
                         ((string-equal action "reload")
                          (web-ui-command "reload")
                          "Asked open pages to reload.")
                         (t "Usage: /ui [list], /ui reset PATH|all, /ui revert PATH, /ui reload")))
      (error (condition) (ui-system frontend (princ-to-string condition)))))
  t)

(define-word-completer "theme"
  '(("light" . "Paper and ink, the default") ("dark" . "Night shift") ("toggle" . "Switch")))

(define-word-completer "ui"
  '(("list" . "Show every asset and the layer serving it")
    ("reset" . "Remove an override (kept in history)")
    ("revert" . "Restore an asset's previous override")
    ("reload" . "Reload open pages"))
  (cond ((string-equal (first (getf context :args)) "reset")
         (cons "all" (web-asset-override-paths)))
        ((string-equal (first (getf context :args)) "revert")
         (remove-if-not #'web-asset-history (web-asset-override-paths)))))
