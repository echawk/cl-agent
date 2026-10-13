;;;; lem/highlight.lisp -- syntax highlighting by Lem's own language modes
;;;; (docs/lem-integration.md, section 7).
;;;;
;;;; LEM-HIGHLIGHT-RUNS scans text with a language mode's syntax table (its
;;;; TextMate grammar, or tree-sitter where Lem has it) in a scratch Lem
;;;; buffer and returns the attribute runs Lem would colour.  The mode is
;;;; never switched on, so no mode hook runs (lisp-mode would start micros,
;;;; and many modes would start a language server); only its scanner.
;;;; LEM-HIGHLIGHT-HTML turns runs into <span class="sx-...">, the classes
;;;; the page already themes; a language Lem does not know gives NIL, and
;;;; the caller shows plain text.
;;;;
;;;; A language name finds its mode by Lem's mode names, then through a file
;;;; extension and Lem's own file-type table (DEFINE-FILE-TYPE), so a mode
;;;; the user's Lem init file adds works here too.

(in-package :cl-agent)

(defparameter *lem-language-extensions*
  '(("c" . "c") ("h" . "c") ("cpp" . "c") ("c++" . "c") ("cc" . "c") ("cxx" . "c") ("hpp" . "c")
    ("objc" . "c") ("python" . "py") ("python3" . "py") ("py3" . "py") ("javascript" . "js")
    ("node" . "js") ("jsx" . "js") ("mjs" . "js") ("typescript" . "ts") ("tsx" . "ts") ("ruby" . "rb")
    ("rust" . "rs") ("golang" . "go") ("shell" . "sh") ("bash" . "sh") ("zsh" . "sh") ("console" . "sh")
    ("yml" . "yaml") ("markdown" . "md") ("haskell" . "hs") ("kotlin" . "kt") ("elixir" . "ex")
    ("erlang" . "erl") ("clojure" . "clj") ("ocaml" . "ml") ("perl" . "pl") ("csharp" . "cs")
    ("lisp" . "lisp") ("common-lisp" . "lisp") ("commonlisp" . "lisp") ("cl" . "lisp")
    ("emacs-lisp" . "el") ("elisp" . "el") ("scheme" . "scm") ("makefile" . "mk") ("make" . "mk")
    ("diff" . "diff") ("patch" . "diff") ("xml" . "xml") ("svg" . "xml") ("dockerfile" . "dockerfile"))
  "Fence and language names that are not themselves a file extension Lem knows.")

(defun lem-mode-for-language (language)
  "The major mode Lem uses for LANGUAGE (\"c\", \"Ruby\", \"py\"), or NIL.
Runs on the editor thread."
  (let ((name (string-downcase (string-trim " " (or language "")))))
    (when (plusp (length name))
      (flet ((usable (mode)
               (and mode (lem:mode-syntax-table mode)
                    (lem:syntax-table-parser (lem:mode-syntax-table mode))
                    mode)))
        (or (usable (lem:find-mode name))
            (usable (ignore-errors
                     (lem:get-file-mode
                      (make-pathname :name "cl-agent"
                                     :type (or (cdr (assoc name *lem-language-extensions* :test #'string=))
                                               name)))))
            (usable (ignore-errors (lem-markdown-mode/languages:find-mode-by-language-name name))))))))

(defun lem-mode-for-pathname (pathname)
  "The major mode Lem would open PATHNAME in, if it highlights. Editor thread."
  (let ((mode (ignore-errors (lem:get-file-mode (pathname pathname)))))
    (and mode (lem:mode-syntax-table mode)
         (lem:syntax-table-parser (lem:mode-syntax-table mode))
         mode)))

(defvar *lem-highlight-buffer* nil)

(defun lem-highlight-buffer ()
  (if (and *lem-highlight-buffer* (not (lem:deleted-buffer-p *lem-highlight-buffer*)))
      *lem-highlight-buffer*
      (let ((buffer (lem:make-buffer "*cl-agent highlight*" :temporary t :enable-undo-p nil)))
        ;; Language modes turn this on when they are enabled; ours never are.
        (setf (lem:variable-value 'lem:enable-syntax-highlight :buffer buffer) t)
        (setf *lem-highlight-buffer* buffer))))

(defun lem-attribute-class (attribute)
  "The page's CSS class for Lem ATTRIBUTE: syntax-keyword-attribute gives
sx-keyword, document-header1-attribute sx-header1.  NIL for attributes
that are not named."
  (when (and attribute (symbolp attribute))
    (let ((name (string-downcase (symbol-name attribute))))
      (dolist (prefix '("syntax-" "document-"))
        (when (uiop:string-prefix-p prefix name) (setf name (subseq name (length prefix)))))
      (when (uiop:string-suffix-p name "-attribute")
        (setf name (subseq name 0 (- (length name) (length "-attribute")))))
      (when (and (plusp (length name)) (every (lambda (c) (or (alphanumericp c) (char= c #\-))) name))
        (format nil "sx-~a" name)))))

(defun lem-scan-runs (text mode)
  "Scan TEXT with MODE's syntax table: ((START END CLASS) ...), 0-based
character offsets.  Editor thread."
  (let ((buffer (lem-highlight-buffer)))
    (lem:erase-buffer buffer)
    (lem:insert-string (lem:buffer-point buffer) text)
    (lem-buffer-runs buffer :syntax-table (lem:mode-syntax-table mode))))

(defun lem-buffer-runs (buffer &key syntax-table)
  "Scan BUFFER (with SYNTAX-TABLE, else its own) and return its attribute
runs, ((START END CLASS) ...) in 0-based character offsets.  Editor thread."
  (let ((runs nil))
    (lem:with-point ((start (lem:buffer-start-point buffer))
                     (end (lem:buffer-end-point buffer)))
      (lem:syntax-scan-region start end :syntax-table syntax-table))
    (lem:with-point ((point (lem:buffer-start-point buffer))
                     (end (lem:buffer-end-point buffer)))
      (loop
        (let* ((from (1- (lem:position-at-point point)))
               (class (lem-attribute-class (lem:text-property-at point :attribute))))
          (unless (lem:next-single-property-change point :attribute end)
            (lem:move-point point end))
          (let ((to (1- (lem:position-at-point point))))
            (when (and class (< from to)) (push (list from to class) runs))
            (when (or (<= to from) (lem:point>= point end)) (return))))))
    (nreverse runs)))

(defun lem-highlight-runs (text &key language pathname)
  "Lem's highlighting of TEXT in LANGUAGE (or the mode for PATHNAME):
((START END CLASS) ...), or NIL when Lem knows no such language or is not
available.  Two values: the runs and the mode's name."
  (when (and (stringp text) (plusp (length text)) (or language pathname)
             (ignore-errors (lem-host-available-p)))
    (handler-case
        (destructuring-bind (&optional runs mode-name)
            (lem-call (lambda ()
                        (let ((mode (if pathname (lem-mode-for-pathname pathname) (lem-mode-for-language language))))
                          (when mode
                            (list (lem-scan-runs text mode) (lem:mode-name mode))))))
          (values runs mode-name))
      (error () nil))))

(defun lem-runs-html (text runs)
  "TEXT escaped, with RUNS wrapped in <span class=CLASS>."
  (with-output-to-string (out)
    (let ((at 0))
      (dolist (run runs)
        (destructuring-bind (start end class) run
          (when (>= start at)
            (write-string (html-escape (subseq text at start)) out)
            (format out "<span class=\"~a\">~a</span>" class (html-escape (subseq text start end)))
            (setf at end))))
      (write-string (html-escape (subseq text at)) out))))

(defvar *lem-highlight-cache* (make-hash-table :test 'equal))
(defvar *lem-highlight-cache-lock* (bordeaux-threads:make-lock "lem-highlight-cache"))
(defparameter *lem-highlight-cache-size* 500)

(defun lem-highlight-html (text language)
  "TEXT in LANGUAGE as highlighted HTML, or NIL (show it plain).  Cached,
so re-rendering a transcript never scans the same block twice."
  (when (and (stringp text) (stringp language) (plusp (length language)))
    (let ((key (cons (string-downcase language) text)))
      (multiple-value-bind (html found)
          (bordeaux-threads:with-lock-held (*lem-highlight-cache-lock*) (gethash key *lem-highlight-cache*))
        (if found
            html
            (let* ((runs (lem-highlight-runs text :language language))
                   (html (and runs (lem-runs-html text runs))))
              (when (or html (eq *lem-host-state* :running))
                (bordeaux-threads:with-lock-held (*lem-highlight-cache-lock*)
                  (when (>= (hash-table-count *lem-highlight-cache*) *lem-highlight-cache-size*)
                    (clrhash *lem-highlight-cache*))
                  (setf (gethash key *lem-highlight-cache*) html)))
              html))))))

(defun utf16-offsets (text)
  "A function from character offsets in TEXT to UTF-16 offsets (the
browser's), for text with characters beyond the Basic Multilingual Plane."
  (if (every (lambda (c) (< (char-code c) #x10000)) text)
      #'identity
      (let ((table (make-array (1+ (length text)) :element-type 'fixnum)))
        (loop for i from 0 below (length text)
              do (setf (aref table (1+ i)) (+ (aref table i) (if (>= (char-code (char text i)) #x10000) 2 1))))
        (lambda (offset) (aref table offset)))))
