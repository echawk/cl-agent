;;;; tools/source-tool.lisp -- the agent reads the Lisp source of itself and
;;;; of every library it runs on (source-archive.lisp): in a built
;;;; bin/cl-agent, the copy compiled into the image, so it works without the
;;;; source tree; in a development image, the loaded systems' files.

(in-package :cl-agent)

(defparameter *lisp-source-actions* '("systems" "files" "read" "search" "definition"))

(defun lisp-source-systems-text ()
  (let ((systems (source-archive-systems)))
    (format nil "~:[Loaded systems (read from disk: this image has no archived sources)~;Systems whose source is in this image~]: ~d.~%~{~a~^~%~}"
            (plusp (hash-table-count *source-archive*)) (length systems)
            (mapcar (lambda (pair) (format nil "~a (~d file~:p)" (car pair) (cdr pair))) systems))))

(defun lisp-source-files-text (system)
  (let ((files (source-archive-files system)))
    (if files
        (format nil "~a: ~d file~:p~%~{~a~^~%~}" system (length files)
                (mapcar (lambda (pair) (format nil "~a/~a" system (archived-source-path (cdr pair)))) files))
        (format nil "No source files for system ~s. Use action \"systems\" to list them." system))))

(defun lisp-source-read-text (path start end)
  (let ((found (find-archived-source path)))
    (unless found
      (error "No source file ~s. Give SYSTEM/PATH as action \"files\" lists it (cl-agent/src/repl.lisp)." path))
    (destructuring-bind (key . entry) found
      (let* ((text (or (archived-source-text key entry) (error "Cannot read ~a." key)))
             (lines (1+ (count #\Newline text)))
             (start (max 1 (or start 1)))
             (end (min lines (or end (+ start 299)))))
        (format nil "~a/~a (~d lines~:[~;, from this image~]), lines ~d-~d:~%~a"
                (archived-source-system entry) (archived-source-path entry) lines
                (archived-source-octets entry) start end (numbered-lines text :start start :end end))))))

(defun lisp-source-search-text (query system limit)
  (when (zerop (length query)) (error "Give a query to search for."))
  (let ((hits nil) (count 0)
        (files (if (string-equal system "all")
                   (loop for key being the hash-keys of (source-index) using (hash-value entry)
                         collect (cons key entry))
                   (source-archive-files system))))
    (block search
      (dolist (pair files)
        (let ((text (archived-source-text (car pair) (cdr pair))))
          (when text
            (loop for line in (uiop:split-string text :separator '(#\Newline))
                  for number from 1
                  when (search query line :test #'char-equal)
                    do (incf count)
                       (when (<= count limit)
                         (push (format nil "~a/~a:~d: ~a" (archived-source-system (cdr pair))
                                       (archived-source-path (cdr pair)) number
                                       (string-trim " " (subseq line 0 (min (length line) 200))))
                               hits)))))))
    (if hits
        (format nil "~d ~a for ~s~a:~%~{~a~^~%~}"
                count (if (= count 1) "match" "matches") query
                (if (> count limit) (format nil " (first ~d shown)" limit) "")
                (nreverse hits))
        (format nil "No matches for ~s in ~a." query system))))

(defun lisp-source-definition-text (symbol package-name)
  (let* ((package (or (and package-name (find-package (string-upcase package-name))) (find-package :cl-agent)))
         (definitions (lisp-repl-definitions symbol package)))
    (if definitions
        (format nil "~{~a~^~%~%~}"
                (mapcar (lambda (d)
                          (format nil "~a ~a~@[:~d~]~:[~; (from this image)~]~%~@[~a~]"
                                  (getf d :type) (getf d :file) (getf d :line)
                                  (equal (getf d :origin) "archive") (getf d :snippet)))
                        definitions))
        (format nil "No recorded definition of ~a in ~a." symbol (package-name package)))))

(define-tool lisp-source (args)
    (:description "Read the Common Lisp source code of cl-agent itself and of every library loaded into it (Lem, slynk, hunchentoot, ...). In a built bin/cl-agent this is the source compiled into the image, so it works even where the source tree is absent or has changed since. action=\"definition\" shows where SYMBOL (in PACKAGE, default cl-agent) is defined, with its source; \"search\" finds QUERY (case-insensitive) in SYSTEM's files (default cl-agent; \"all\" for every system); \"read\" returns PATH (as SYSTEM/RELATIVE-PATH, e.g. cl-agent/src/repl.lisp) with line numbers, optionally start_line..end_line; \"files\" lists SYSTEM's files; \"systems\" lists the systems."
     :effects '(:read-workspace)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "action" (jobj "type" "string" "enum" *lisp-source-actions*)
                 "symbol" (jobj "type" "string")
                 "package" (jobj "type" "string")
                 "system" (jobj "type" "string")
                 "path" (jobj "type" "string")
                 "query" (jobj "type" "string")
                 "start_line" (jobj "type" "integer")
                 "end_line" (jobj "type" "integer")
                 "max_results" (jobj "type" "integer"))
           "required" (list "action")))
  (let ((action (jget args "action")))
    (cond ((equal action "systems") (lisp-source-systems-text))
          ((equal action "files") (lisp-source-files-text (or (jget args "system") "cl-agent")))
          ((equal action "read") (lisp-source-read-text (or (jget args "path") "") (jget args "start_line") (jget args "end_line")))
          ((equal action "search") (lisp-source-search-text (or (jget args "query") "") (or (jget args "system") "cl-agent")
                                                            (max 1 (min 200 (or (jget args "max_results") 50)))))
          ((equal action "definition") (lisp-source-definition-text (or (jget args "symbol") "") (jget args "package")))
          (t (error "action must be one of ~{~a~^, ~}." *lisp-source-actions*)))))
