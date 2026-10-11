;;;; ui/web/markdown.lisp -- server-side Markdown -> HTML for assistant
;;;; replies in the web UI.
;;;;
;;;; 3BMD does the real work; everything here repairs the near-Markdown
;;;; shapes chat models commonly emit (one-line tables and bullet lists,
;;;; fences whose info string shares a line with the code) before 3BMD
;;;; sees it. The browser still sanitizes the result against an
;;;; allowlist (see static/render.js), so this file never has to be a
;;;; security boundary -- only a formatting one.

(in-package :cl-agent)

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
