;;;; tools/file-tool.lisp -- direct, explicit file access for ordinary work.

(in-package :cl-agent)

(defun file-tool-path (path tool-name)
  "Validate PATH for a file tool and return its existing pathname.

Read/range/edit operations intentionally require an existing regular file;
WRITE-FILE is the one operation that creates a new path."
  (unless (and (stringp path) (plusp (length (string-trim " " path))))
    (error "~a requires a non-empty string path" tool-name))
  (let ((resolved (probe-file path)))
    (unless resolved (error "~a file does not exist: ~a" tool-name path))
    (when (uiop:directory-pathname-p resolved)
      (error "~a path names a directory, not a file: ~a" tool-name path))
    resolved))

(defun file-line-starts (contents)
  "Return zero-based offsets for each logical line in CONTENTS.

The final empty line after a trailing newline is intentional: line N+1,
column 1 is a useful insertion position at end of a newline-terminated file."
  (let ((starts (list 0)))
    (loop for index from 0 below (length contents)
          when (char= (char contents index) #\Newline)
            do (push (1+ index) starts))
    (nreverse starts)))

(defun file-position-index (contents line column)
  "Map 1-based LINE/COLUMN to a zero-based, non-newline character offset.

Columns are character positions within a line.  A column one past a line's
last character is valid and denotes the position immediately before its line
ending.  Ranges use these positions as a half-open interval, so equal start
and end positions express insertion without a separate operation."
  (unless (and (integerp line) (plusp line) (integerp column) (plusp column))
    (error "line and column must be positive integers (1-based)"))
  (let ((starts (file-line-starts contents)))
    (unless (<= line (length starts))
      (error "line ~d is outside this ~d-line file" line (length starts)))
    (let* ((start (nth (1- line) starts))
           (next-start (and (< line (length starts)) (nth line starts)))
           ;; Exclude LF, and also CR in a CRLF ending, from valid columns.
           (end (or (and next-start (1- next-start)) (length contents))))
      (when (and (> end start) (char= (char contents (1- end)) #\Return))
        (decf end))
      (let ((index (+ start (1- column))))
        (unless (<= index end)
          (error "column ~d is outside line ~d (maximum is ~d)"
                 column line (1+ (- end start))))
        index))))

(defun file-range-indices (contents start-line start-column end-line end-column)
  "Validate and return the half-open range selected by two file positions."
  (let ((start (file-position-index contents start-line start-column))
        (end (file-position-index contents end-line end-column)))
    (when (> start end)
      (error "range start must not come after range end"))
    (values start end)))

(define-tool read-file (args)
    (:description "Read a text file directly by explicit path. Use this instead of shell commands such as cat, sed, or head when you need file contents. Optional max_chars bounds large reads; if omitted, 30000 characters are returned. This tool reads files, not directories or globs."
     :parameters (jobj "type" "object"
                       "properties" (jobj "path" (jobj "type" "string" "description" "Explicit file path, relative to the current directory or absolute.")
                                          "max_chars" (jobj "type" "integer" "description" "Optional positive maximum number of characters to return."))
                       "required" (list "path")))
  (let* ((path (jget args "path"))
         (limit (jget args "max_chars" 30000)))
    (unless (and (stringp path) (plusp (length (string-trim " " path))))
      (error "read-file requires a non-empty string path"))
    (unless (and (integerp limit) (plusp limit))
      (error "read-file max_chars must be a positive integer"))
    (let ((contents (uiop:read-file-string path)))
      (if (> (length contents) limit)
          (format nil "~a~%~%[Read truncated at ~d of ~d characters; call read-file again with a larger max_chars if needed.]"
                  (subseq contents 0 limit) limit (length contents))
          contents))))

(define-tool write-file (args)
    (:description "Write text to an explicit file path, creating parent directories when needed and replacing an existing file's contents. Use this for ordinary project files; use write-scratch-file for a disposable config scratch artifact and write-extension only for a durable cl-agent capability that must load into the agent."
     :parameters (jobj "type" "object"
                       "properties" (jobj "path" (jobj "type" "string" "description" "Explicit output file path, relative to the current directory or absolute.")
                                          "contents" (jobj "type" "string" "description" "Complete replacement contents for the file."))
                       "required" (list "path" "contents")))
  (let ((path (jget args "path")) (contents (jget args "contents")))
    (unless (and (stringp path) (plusp (length (string-trim " " path))))
      (error "write-file requires a non-empty string path"))
    (unless (stringp contents) (error "write-file contents must be a string"))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede :if-does-not-exist :create)
      (write-string contents out))
    (format nil "Wrote ~d character~:p to ~a." (length contents) path)))

(define-tool read-file-range (args)
    (:description "Read an exact half-open range from an existing text file using 1-based line and column positions. The start is included and the end is excluded. Use this before edit-file to obtain the precise current text and positions; equal positions select an empty insertion point. For a whole line including its newline, end at column 1 of the next line."
     :parameters (jobj "type" "object"
                       "properties" (jobj "path" (jobj "type" "string" "description" "Existing file path, relative to the current directory or absolute.")
                                          "start_line" (jobj "type" "integer" "minimum" 1 "description" "1-based inclusive start line.")
                                          "start_column" (jobj "type" "integer" "minimum" 1 "description" "1-based inclusive start column.")
                                          "end_line" (jobj "type" "integer" "minimum" 1 "description" "1-based exclusive end line.")
                                          "end_column" (jobj "type" "integer" "minimum" 1 "description" "1-based exclusive end column."))
                       "required" (list "path" "start_line" "start_column" "end_line" "end_column")))
  (let* ((path (jget args "path"))
         (resolved (file-tool-path path "read-file-range"))
         (contents (uiop:read-file-string resolved)))
    (multiple-value-bind (start end)
        (file-range-indices contents (jget args "start_line") (jget args "start_column")
                            (jget args "end_line") (jget args "end_column"))
      (subseq contents start end))))

(define-tool edit-file (args)
    (:description "Precisely replace or insert text in an existing file using a half-open, 1-based line/column range. The start is included and the end is excluded; set start and end equal to insert. Supply expected_text whenever possible: the edit aborts unless the currently selected text exactly matches it, protecting against stale positions or an unintended overwrite. Workflow: read-file-range, then edit-file with its returned text as expected_text."
     :parameters (jobj "type" "object"
                       "properties" (jobj "path" (jobj "type" "string" "description" "Existing file path, relative to the current directory or absolute.")
                                          "start_line" (jobj "type" "integer" "minimum" 1 "description" "1-based inclusive start line.")
                                          "start_column" (jobj "type" "integer" "minimum" 1 "description" "1-based inclusive start column.")
                                          "end_line" (jobj "type" "integer" "minimum" 1 "description" "1-based exclusive end line.")
                                          "end_column" (jobj "type" "integer" "minimum" 1 "description" "1-based exclusive end column.")
                                          "replacement" (jobj "type" "string" "description" "Text that replaces the selected range; may be empty to delete it.")
                                          "expected_text" (jobj "type" "string" "description" "Optional exact text expected in the selected range; the edit aborts if it differs."))
                       "required" (list "path" "start_line" "start_column" "end_line" "end_column" "replacement")))
  (let* ((path (jget args "path"))
         (replacement (jget args "replacement"))
         (expected (jget args "expected_text" :missing))
         (resolved (file-tool-path path "edit-file"))
         (contents (uiop:read-file-string resolved)))
    (unless (stringp replacement) (error "edit-file replacement must be a string"))
    (unless (or (eq expected :missing) (stringp expected))
      (error "edit-file expected_text must be a string when supplied"))
    (multiple-value-bind (start end)
        (file-range-indices contents (jget args "start_line") (jget args "start_column")
                            (jget args "end_line") (jget args "end_column"))
      (let ((actual (subseq contents start end)))
        (when (and (not (eq expected :missing)) (not (string= expected actual)))
          (error "edit-file expected_text did not match the selected range; re-read it before editing"))
        (with-open-file (out resolved :direction :output :if-exists :supersede)
          (write-string contents out :end start)
          (write-string replacement out)
          (write-string contents out :start end))
        (format nil "Edited ~a at ~d:~d through ~d:~d; replaced ~d character~:p with ~d character~:p."
                path (jget args "start_line") (jget args "start_column")
                (jget args "end_line") (jget args "end_column")
                (- end start) (length replacement))))))
