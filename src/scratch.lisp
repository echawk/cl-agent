;;;; scratch.lisp -- scratch buffers in any language, shared by the user (the
;;;; web UI's Code tab) and the agent (tools/scratch-tool.lisp).
;;;;
;;;; A buffer is a real file, scratch/NAME.EXT in the config directory, so
;;;; its language follows its extension and everything that works on files
;;;; works on it: Lem highlights it by Lem's own mode for the extension
;;;; (lem/highlight.lisp), and the LSP tools and SCRATCH-BUFFER-DIAGNOSTICS
;;;; ask the language server configured for that extension (lsp.lisp).
;;;;
;;;; Saves are versioned like the Lisp tab's scratch buffer: a writer says
;;;; which version it last saw (BASE) and a stale write is refused with the
;;;; current text, so the user's typing and the agent's edits never silently
;;;; overwrite each other.  The agent's writes back up the text they replace
;;;; in scratch/.history/.  Every save is published to open pages as a
;;;; "scratch-buffer" event.

(in-package :cl-agent)

(defvar *scratch-lock* (bt:make-lock "cl-agent-scratch"))
(defvar *scratch-records* (make-hash-table :test 'equal)
  "Pathname namestring -> (TEXT VERSION STAMP) of each buffer read, STAMP
being the file's (WRITE-DATE . SIZE) when it was read.")

;; SCRATCH-DIRECTORY (extensions.lisp) is config/scratch/, where the agent's
;; one-off files also go: those with a buffer name show up here too.
(defun scratch-history-directory () (merge-pathnames "scratch/.history/" *config-directory*))

(defun scratch-name-p (name)
  "Buffer names are file names without an extension: a letter or digit,
then letters, digits, - and _, at most 64."
  (and (stringp name) (<= 1 (length name) 64)
       (alphanumericp (char name 0))
       (every (lambda (c) (or (and (alphanumericp c) (< (char-code c) 128)) (member c '(#\- #\_)))) name)))

(defun scratch-extension-p (extension)
  (and (stringp extension) (<= 1 (length extension) 16)
       (every (lambda (c) (and (< (char-code c) 128) (or (alphanumericp c) (member c '(#\- #\_ #\+))))) extension)))

(defun scratch-buffer-files ()
  (sort (remove-if (lambda (file)
                     (or (null (pathname-type file))
                         (not (scratch-name-p (pathname-name file)))))
                   (ignore-errors (uiop:directory-files (scratch-directory))))
        #'string< :key #'pathname-name))

(defun find-scratch-buffer (name)
  "The file of scratch buffer NAME, or NIL."
  (and (scratch-name-p name)
       (find name (scratch-buffer-files) :key #'pathname-name :test #'string=)))

(defun require-scratch-buffer (name)
  (or (find-scratch-buffer name)
      (error "No scratch buffer named ~s.~@[ There are: ~{~a~^, ~}.~]" name
             (mapcar #'pathname-name (scratch-buffer-files)))))

;;; --- languages ---

(defparameter *scratch-preferred-extensions*
  '(("Lisp" . "lisp") ("C" . "c") ("JavaScript" . "js") ("TypeScript" . "ts") ("Markdown" . "md")
    ("Python" . "py") ("Ruby" . "rb") ("Shell" . "sh") ("posix-shell" . "sh") ("YAML" . "yaml"))
  "A mode's usual extension, where its file types offer several.")

(defun scratch-languages ()
  "The languages a scratch buffer can be in, as (NAME . EXTENSION): every
mode Lem highlights by file type, plus plain text."
  (let ((by-mode (make-hash-table :test 'eq)))
    (ignore-errors
     (when (lem-host-available-p)
       (lem-call
        (lambda ()
          (loop for (type . mode) in lem-core::*file-type-relationals*
                when (and (stringp type) (scratch-extension-p type) (lem-mode-for-pathname (format nil "x.~a" type)))
                  do (push type (gethash mode by-mode)))))))
    (let ((languages
            (loop for mode being the hash-keys of by-mode using (hash-value types)
                  for name = (lem:mode-name mode)
                  for preferred = (cdr (assoc name *scratch-preferred-extensions* :test #'string-equal))
                  collect (cons name (if (member preferred types :test #'string=)
                                         preferred
                                         (first (sort (copy-list types)
                                                      (lambda (a b) (if (= (length a) (length b))
                                                                        (string< a b)
                                                                        (< (length a) (length b)))))))))))
      (append (sort languages #'string-lessp :key #'car) (list (cons "Text" "txt"))))))

(defun scratch-extension-for-language (language)
  "The file extension for LANGUAGE (\"Ruby\", \"c\", \"py\", or an extension)."
  (let ((name (string-trim " " (or language ""))))
    (when (zerop (length name)) (error "Say which language the buffer is in."))
    (or (cdr (assoc name (scratch-languages) :test #'string-equal))
        (let ((mode-name (ignore-errors
                          (and (lem-host-available-p)
                               (lem-call (lambda () (let ((mode (lem-mode-for-language name)))
                                                      (and mode (lem:mode-name mode)))))))))
          (and mode-name (cdr (assoc mode-name (scratch-languages) :test #'string-equal))))
        (let ((extension (string-downcase (string-left-trim "." name))))
          (if (scratch-extension-p extension)
              extension
              (error "Unknown language ~s." language))))))

(defun scratch-buffer-language (path)
  "The name of the mode Lem highlights PATH with, or its extension."
  (or (ignore-errors
       (and (lem-host-available-p)
            (lem-call (lambda () (let ((mode (lem-mode-for-pathname path))) (and mode (lem:mode-name mode)))))))
      (if (equal (pathname-type path) "txt") "Text" (pathname-type path))))

;;; --- contents and saving ---

(defun scratch-file-stamp (path)
  "(WRITE-DATE . SIZE) of PATH, or NIL.  Dates have one-second resolution,
so the size also catches most edits made within the same second."
  (ignore-errors (cons (file-write-date path) (with-open-file (s path) (file-length s)))))

(defun %scratch-record (path)
  "PATH's (TEXT VERSION STAMP), reread when the file changed underneath.
Caller holds *SCRATCH-LOCK*."
  (let* ((key (namestring path))
         (record (gethash key *scratch-records*))
         (stamp (scratch-file-stamp path)))
    (unless (and record (equal (third record) stamp))
      (setf record (list (if stamp (read-text-file path) "")
                         (1+ (if record (second record) 0))
                         stamp)
            (gethash key *scratch-records*) record))
    record))

(defun scratch-buffer-contents (name)
  "(values TEXT VERSION PATHNAME) of scratch buffer NAME."
  (let ((path (require-scratch-buffer name)))
    (bt:with-lock-held (*scratch-lock*)
      (destructuring-bind (text version date) (%scratch-record path)
        (declare (ignore date))
        (values text version path)))))

(defun scratch-buffer-json (path &key (text nil text-p) version)
  (jobj "name" (pathname-name path) "extension" (pathname-type path)
        "language" (scratch-buffer-language path)
        "path" (uiop:native-namestring path)
        "size" (or (ignore-errors (with-open-file (s path) (file-length s))) 0)
        "modified" (or (ignore-errors (file-write-date path)) :null)
        "text" (if text-p text :null)
        "version" (or version :null)))

(defun scratch-buffers ()
  "Every scratch buffer as a JOBJ, by name."
  (mapcar #'scratch-buffer-json (scratch-buffer-files)))

(defun scratch-publish (type payload)
  (when (and (boundp '*web-frontends*) *web-frontends*) (web-ui-broadcast type payload)))

(defun scratch-history-files (name)
  "The backups of buffer NAME in scratch/.history/."
  (directory (merge-pathnames (format nil "~a-*.*" name) (scratch-history-directory))))

(defun scratch-backup (path text version)
  (let ((directory (scratch-history-directory)))
    (ensure-directories-exist directory)
    (write-string-atomically
     (merge-pathnames (format nil "~a-~d-v~d.~a" (pathname-name path) (get-universal-time) version (pathname-type path))
                      directory)
     text)
    (let ((old (sort (scratch-history-files (pathname-name path)) #'string> :key #'namestring)))
      (mapc (lambda (file) (ignore-errors (delete-file file))) (nthcdr 20 old)))))

(defun scratch-buffer-save (name text &key base (by "user") client)
  "Replace scratch buffer NAME with TEXT, written by BY (\"user\" or
\"agent\").  BASE is the version the writer last saw: when the buffer has
changed since, nothing is written and the result is (values :CONFLICT
VERSION CURRENT); otherwise (values :SAVED VERSION)."
  (let ((path (require-scratch-buffer name)) (result nil) (published nil))
    (bt:with-lock-held (*scratch-lock*)
      (destructuring-bind (current version date) (%scratch-record path)
        (declare (ignore date))
        (cond ((and base (/= base version) (string/= text current))
               (setf result (list :conflict version current)))
              ((string= text current)
               (setf result (list :saved version)))
              (t
               (when (equal by "agent") (scratch-backup path current version))
               (write-string-atomically path text)
               (setf (gethash (namestring path) *scratch-records*) (list text (1+ version) (scratch-file-stamp path))
                     result (list :saved (1+ version))
                     published (jobj "name" name "version" (1+ version) "text" text "by" by
                                     "client" (json-or-null client)))))))
    (when published (scratch-publish "scratch-buffer" published))
    (values-list result)))

(defun scratch-buffer-create (name language &key (text "") (by "user"))
  "Make scratch buffer NAME in LANGUAGE (see SCRATCH-EXTENSION-FOR-LANGUAGE)
holding TEXT, and return its pathname."
  (unless (scratch-name-p name)
    (error "~s is not a usable buffer name: use letters, digits, - and _ (at most 64)." name))
  (when (find-scratch-buffer name)
    (error "There is already a scratch buffer named ~s." name))
  (let ((path (merge-pathnames (make-pathname :name name :type (scratch-extension-for-language language))
                               (scratch-directory))))
    (ensure-directories-exist path)
    (write-string-atomically path (or text ""))
    (scratch-publish "scratch-buffers" (jobj "created" name "by" by))
    path))

(defun scratch-buffer-delete (name)
  "Delete scratch buffer NAME, keeping its text in scratch/.history/."
  (let ((path (require-scratch-buffer name)))
    (bt:with-lock-held (*scratch-lock*)
      (destructuring-bind (text version date) (%scratch-record path)
        (declare (ignore date))
        (scratch-backup path text version))
      (delete-file path)
      (remhash (namestring path) *scratch-records*))
    (scratch-publish "scratch-buffers" (jobj "deleted" name))
    t))

;;; --- the language server ---

(defun scratch-buffer-lsp-servers (path)
  "Names of the available language servers configured for PATH's extension."
  (let ((extension (format nil ".~a" (pathname-type path))))
    (loop for server in (ignore-errors (lsp-server-statuses))
          when (and (getf server :available)
                    (member extension (getf server :extensions) :test #'string-equal))
            collect (getf server :name))))

;;; The language server reads a file from disk; to show it a file's unsaved
;;; text (a buffer being edited in the Code tab), cl-lsp's one reader is
;;; wrapped: while *LSP-UNSAVED-TEXT* names a file, its text is what the
;;; server is sent for that file.  Nothing else changes.

(defvar *lsp-unsaved-text* nil
  "(NAMESTRING . TEXT): the text the language server sees for that file.")

(sb-int:unencapsulate 'cl-lsp::lsp--read-document 'cl-agent-unsaved-text)
(sb-int:encapsulate 'cl-lsp::lsp--read-document 'cl-agent-unsaved-text
                    (lambda (read path)
                      (let ((unsaved *lsp-unsaved-text*))
                        (if (and unsaved (string= (namestring path) (car unsaved)))
                            (cdr unsaved)
                            (funcall read path)))))

(defmacro with-lsp-text ((path text) &body body)
  "Run BODY with the language server seeing TEXT (when non-NIL) as PATH's."
  `(let ((*lsp-unsaved-text* (if ,text (cons (namestring (truename ,path)) ,text) *lsp-unsaved-text*)))
     ,@body))

(defun require-lsp-servers (path)
  (or (scratch-buffer-lsp-servers path)
      (error "No language server is configured for .~a files. Add one to ~a."
             (pathname-type path) (uiop:native-namestring (lsp-configuration-path)))))

(defun path-diagnostics (path &key (wait-seconds 2) text)
  "What the configured language servers report for the file PATH (as TEXT,
when given, else as saved): a list of plists (:server :line :character
:end-line :end-character :severity :message :source), 0-based.  Signals an
error when no server is configured for its extension."
  (require-lsp-servers path)
  (with-lsp-text (path text)
    (loop for row in (lsp-file-diagnostics (namestring (truename path)) :wait-seconds wait-seconds)
          append (lsp-diagnostic-rows row))))

(defun scratch-buffer-diagnostics (name &key (wait-seconds 2))
  "PATH-DIAGNOSTICS for scratch buffer NAME, as saved."
  (path-diagnostics (require-scratch-buffer name) :wait-seconds wait-seconds))

(defun json-path (object &rest keys)
  (dolist (key keys object)
    (setf object (and (hash-table-p object) (gethash key object)))))

(defun lsp-diagnostic-rows (row)
  "Flatten one server's row from LSP-FILE-DIAGNOSTICS, (:SERVER NAME :RESULT
REPORT) or (:SERVER NAME :ERROR CONDITION), into diagnostic plists."
  (let* ((server (getf row :server))
         (items (json-path (getf row :result) "items")))
    (when (getf row :error)
      (return-from lsp-diagnostic-rows
        (list (list :server server :severity "error" :line nil :character nil :end-line nil :end-character nil
                    :message (format nil "The language server failed: ~a" (getf row :error)) :source "cl-agent"))))
    (loop for item across (if (vectorp items) items (coerce (or items nil) 'vector))
          collect (list :server (and server (princ-to-string server))
                        :line (json-path item "range" "start" "line")
                        :character (json-path item "range" "start" "character")
                        :end-line (json-path item "range" "end" "line")
                        :end-character (json-path item "range" "end" "character")
                        :severity (case (json-path item "severity") (1 "error") (2 "warning") (3 "info") (4 "hint") (t "error"))
                        :message (json-path item "message")
                        :source (json-path item "source")))))

(defun scratch-buffer-hover (name line character)
  "PATH-HOVER for scratch buffer NAME, as saved."
  (path-hover (require-scratch-buffer name) line character))

(defun path-hover (path line character &key text)
  "The language server's hover text at LINE and CHARACTER (0-based) in the
file PATH (as TEXT, when given), or NIL."
  (require-lsp-servers path)
  (with-lsp-text (path text)
    (let ((texts nil))
      (dolist (row (lsp-query-file (namestring (truename path)) "hover" :line line :character character))
        (let ((contents (json-path (getf row :result) "contents")))
          (labels ((collect (value)
                     (cond ((stringp value) (when (plusp (length value)) (push value texts)))
                           ((hash-table-p value) (collect (gethash "value" value)))
                           ((vectorp value) (map nil #'collect value))
                           ((consp value) (mapc #'collect value)))))
            (collect contents))))
      (and texts (format nil "~{~a~^~%~%~}" (nreverse texts))))))

;;; --- completion, the way Lem's lsp-mode completes ---
;;;
;;; Like Lem's TEXT-DOCUMENT/COMPLETION (lem-lsp-mode), but over the same
;;; cl-lsp connection Check and hover use, so a file has one server: the
;;; server's items, sorted by sortText, each replacing from its textEdit's
;;; start (or the word before the cursor), filtered by that word (prefix,
;;; then SLY's flex).  Without a server -- or when it offers nothing -- the
;;; buffer's own words complete, nearest first, as M-/ would.  Positions
;;; crossing the browser are UTF-16 offsets, as LSP's are.

(defparameter *lsp-completion-kinds*
  #("text" "method" "function" "constructor" "field" "variable" "class" "interface" "module"
    "property" "unit" "value" "enum" "keyword" "snippet" "color" "file" "reference" "folder"
    "enum-member" "constant" "struct" "event" "operator" "type-parameter")
  "LSP's CompletionItemKind names, 1-based.")

(defparameter *lsp-completion-timeout* 10
  "Seconds to wait for a language server's completions.")

(defun lsp-completion-kind (number)
  (and (integerp number) (<= 1 number (length *lsp-completion-kinds*))
       (aref *lsp-completion-kinds* (1- number))))

(defun completion-menu-kind (kind)
  "The completion menu's kind class (menu.js colours these) for LSP KIND."
  (cond ((member kind '("method" "function" "constructor") :test #'equal) "function")
        ((member kind '("field" "variable" "property" "value") :test #'equal) "variable")
        ((member kind '("class" "interface" "struct" "enum" "type-parameter") :test #'equal) "class")
        ((member kind '("keyword" "operator") :test #'equal) "keyword")
        ((member kind '("module" "file" "folder") :test #'equal) "package")
        (t (or kind "symbol"))))

(defun utf16-units (char) (if (>= (char-code char) #x10000) 2 1))

(defun char-index-at-utf16 (text offset)
  "The character index in TEXT at UTF-16 OFFSET (clamped)."
  (loop with units = 0
        for i from 0 below (length text)
        while (< units offset)
        do (incf units (utf16-units (char text i)))
        finally (return (min i (length text)))))

(defun utf16-offset-at (text index)
  (loop for i from 0 below (min index (length text)) sum (utf16-units (char text i))))

(defun lsp-position-of (text index)
  "The LSP (LINE . CHARACTER) of character INDEX in TEXT."
  (let* ((line-start (1+ (or (position #\Newline text :end index :from-end t) -1))))
    (cons (count #\Newline text :end index)
          (utf16-offset-at (subseq text line-start index) (- index line-start)))))

(defun lsp-position-index (text line character)
  "The character index in TEXT of LSP position LINE, CHARACTER (clamped)."
  (let ((start 0))
    (dotimes (i line) (setf start (1+ (or (position #\Newline text :start start) (1- (length text))))))
    (let ((end (or (position #\Newline text :start (min start (length text))) (length text))))
      (+ start (char-index-at-utf16 (subseq text (min start end) end) character)))))

(defun identifier-char-p (char)
  (or (alphanumericp char) (member char '(#\_ #\$))))

(defun word-start-before (text index)
  (loop while (and (> index 0) (identifier-char-p (char text (1- index)))) do (decf index))
  index)

(defun strip-snippet (text)
  "TEXT, an LSP snippet, as plain text: ${1:x} is x, $1 and $0 vanish."
  (with-output-to-string (out)
    (loop with i = 0 with n = (length text)
          while (< i n)
          do (let ((c (char text i)))
               (cond ((and (char= c #\\) (< (1+ i) n)) (write-char (char text (1+ i)) out) (incf i 2))
                     ((and (char= c #\$) (< (1+ i) n) (char= (char text (1+ i)) #\{))
                      (let* ((close (or (position #\} text :start i) (1- n)))
                             (colon (position #\: text :start i :end close)))
                        (when colon (write-string (strip-snippet (subseq text (1+ colon) close)) out))
                        (setf i (1+ close))))
                     ((and (char= c #\$) (< (1+ i) n) (digit-char-p (char text (1+ i))))
                      (incf i 2)
                      (loop while (and (< i n) (digit-char-p (char text i))) do (incf i)))
                     (t (write-char c out) (incf i)))))))

(defun lsp-completion-items (path line character)
  "The completion items PATH's language servers give at LINE, CHARACTER;
their trigger characters; and the errors of servers that failed."
  (let ((items nil) (triggers nil) (errors nil))
    (dolist (row (cl-lsp:lsp-manager-map-file
                  (ensure-lsp-initialized) (truename path) (lsp-workspace-boundary (truename path))
                  (lambda (client document)
                    (let ((provider (json-path (cl-lsp:lsp-client-capabilities client) "completionProvider")))
                      (when provider
                        (let ((characters (json-path provider "triggerCharacters")))
                          (when (vectorp characters) (setf triggers (append triggers (coerce characters 'list)))))
                        (cl-lsp:lsp-transport-request
                         (cl-lsp:lsp-client-transport client) "textDocument/completion"
                         (cl-lsp:json-object
                          "textDocument" (cl-lsp:json-object "uri" (cl-lsp:lsp-path-uri (cl-lsp:lsp-document-path document)))
                          "position" (cl-lsp:json-object "line" line "character" character)
                          "context" (cl-lsp:json-object "triggerKind" 1))
                         :timeout *lsp-completion-timeout*))))))
      (when (getf row :error) (push (format nil "~a: ~a" (getf row :server) (getf row :error)) errors))
      (let* ((result (getf row :result))
             (list (if (hash-table-p result) (gethash "items" result) result)))
        (when (vectorp list) (setf items (append items (coerce list 'list))))))
    (values items (remove-duplicates triggers :test #'equal) (nreverse errors))))

(defun scratch-buffer-lsp-start (name)
  "PATH-LSP-START for scratch buffer NAME."
  (path-lsp-start (require-scratch-buffer name)))

(defun path-lsp-start (path)
  "Start the file PATH's language servers, as Lem's lsp-mode does when a
file opens, and return their completion trigger characters."
  (let ((triggers nil))
    (when (scratch-buffer-lsp-servers path)
      (dolist (row (cl-lsp:lsp-manager-map-file
                    (ensure-lsp-initialized) (truename path) (lsp-workspace-boundary (truename path))
                    (lambda (client document)
                      (declare (ignore document))
                      (json-path (cl-lsp:lsp-client-capabilities client) "completionProvider" "triggerCharacters"))))
        (let ((characters (getf row :result)))
          (when (vectorp characters) (setf triggers (append triggers (coerce characters 'list)))))))
    (remove-duplicates triggers :test #'equal)))

(defun lsp-item-candidate (item text index word-start)
  "One completion candidate plist from LSP ITEM, Lem's way: its textEdit's
new text from the edit's start, else its insertText or label from the word."
  (let* ((label (string-trim " " (or (gethash "label" item) "")))
         (edit (gethash "textEdit" item))
         (range (and (hash-table-p edit) (or (gethash "range" edit) (gethash "insert" edit))))
         (start (if range
                    (min index (lsp-position-index text (json-path range "start" "line")
                                                   (json-path range "start" "character")))
                    word-start))
         (snippet (eql (gethash "insertTextFormat" item) 2))
         (raw (or (and (hash-table-p edit) (gethash "newText" edit)) (gethash "insertText" item) label))
         (value (if snippet (strip-snippet raw) raw))
         (kind (lsp-completion-kind (gethash "kind" item))))
    (list :value value :display label :start start
          :filter (or (gethash "filterText" item) label)
          :sort (or (gethash "sortText" item) label)
          :kind (completion-menu-kind kind) :kind-name kind
          :doc (let ((detail (gethash "detail" item)))
                 (and (stringp detail) (first-line detail))))))

(defun buffer-word-candidates (text index word-start)
  "Words in TEXT that extend the one before INDEX, nearest first."
  (let ((prefix (subseq text word-start index))
        (seen (make-hash-table :test 'equal))
        (words nil))
    (when (plusp (length prefix))
      (loop with i = 0 with n = (length text)
            while (< i n)
            do (if (identifier-char-p (char text i))
                   (let ((end (or (position-if-not #'identifier-char-p text :start i) n)))
                     (let ((word (subseq text i end)))
                       (when (and (/= i word-start) (> (length word) (length prefix))
                                  (string-equal prefix word :end2 (length prefix))
                                  (not (gethash word seen)))
                         (setf (gethash word seen) t)
                         (push (cons (abs (- i index)) word) words)))
                     (setf i end))
                   (incf i))))
    (mapcar (lambda (entry)
              (list :value (cdr entry) :display (cdr entry) :start word-start :filter (cdr entry)
                    :kind "word" :doc "a word in this buffer"))
            (stable-sort (nreverse words) #'< :key #'car))))

(defun filter-completion-candidates (candidates prefix)
  "CANDIDATES matching PREFIX (by their :filter text): by prefix, else by SLY's
flex matching, each with :match ranges of its display."
  (if (zerop (length prefix))
      candidates
      (flet ((matching (style)
               (loop for candidate in candidates
                     for ranges = (lisp-name-match style prefix (getf candidate :filter))
                     when ranges
                       collect (append (list :match (and (string= (getf candidate :filter) (getf candidate :display))
                                                         ranges))
                                       candidate))))
        (or (matching :prefix) (matching :flex)))))

(defun scratch-buffer-complete (name text cursor)
  "PATH-COMPLETE for scratch buffer NAME, whose saved text is TEXT."
  (path-complete (require-scratch-buffer name) text cursor))

(defun path-complete (path text cursor &key unsaved)
  "Completion at UTF-16 offset CURSOR of TEXT, the file PATH's text (saved,
or with UNSAVED the editor's unsaved copy, which the server is then sent):
a plist like COMPLETE-INPUT's, offsets in UTF-16, plus :TRIGGERS (the
server's trigger characters) and :MESSAGE (why the server could not help,
when it could not)."
  (let* ((index (char-index-at-utf16 text cursor))
         (word-start (word-start-before text index))
         (prefix (subseq text word-start index))
         (position (lsp-position-of text index))
         (items nil) (triggers nil) (message nil) (source "lsp"))
    (when (and (probe-file path) (scratch-buffer-lsp-servers path))
      (handler-case
          (multiple-value-bind (found trigger-strings errors)
              (with-lsp-text (path (and unsaved text)) (lsp-completion-items path (car position) (cdr position)))
            (setf items found triggers trigger-strings)
            (when (and errors (null found))
              (setf message (format nil "The language server could not complete: ~{~a~^; ~}" errors))))
        (error (condition) (setf message (format nil "The language server could not complete: ~a" condition)))))
    (let ((candidates (filter-completion-candidates
                       (stable-sort (mapcar (lambda (item) (lsp-item-candidate item text index word-start))
                                            (remove-if-not #'hash-table-p items))
                                    #'string< :key (lambda (c) (getf c :sort)))
                       prefix)))
      (unless candidates
        (setf candidates (buffer-word-candidates text index word-start) source "buffer-words"))
      (list :start (utf16-offset-at text word-start) :end cursor :token prefix
            :candidates (mapcar (lambda (c)
                                  (append (list :start (and (/= (getf c :start) word-start)
                                                            (utf16-offset-at text (getf c :start))))
                                          c))
                                (subseq candidates 0 (min (length candidates) *completion-limit*)))
            :total (length candidates) :source source
            :triggers triggers :message message))))
