;;;; t/test-syntax-tree.lisp -- the agent's structural edits by tree-sitter
;;;; syntax tree (syntax-tree.lisp), on the JSON grammar built offline from
;;;; t/fixtures/tree-sitter-json.  Skipped where libtree-sitter is missing.

(in-package :cl-agent)

(defun syntax-test-ready-p ()
  "Whether tree-sitter works here, the JSON grammar built from the fixture."
  (and (tree-sitter-prefix)
       (progn
         (ensure-tree-sitter)
         (or (ts:get-language "json")
             (ts:load-language "json" (uiop:native-namestring
                                       (build-grammar "json" (asdf:system-relative-pathname
                                                              :cl-agent "t/fixtures/tree-sitter-json/")))))
         t)))

(defmacro with-syntax-test (() &body body)
  `(if (syntax-test-ready-p)
       (progn ,@body)
       (check t "skipped: tree-sitter's library is not installed")))

(defparameter *syntax-json*
  (format nil "{~%  \"name\": \"cl-agent\",~%  \"version\": 1,~%  \"deps\": {~%    \"lem\": \"2.0\"~%  }~%}~%"))

(defun syntax-edit (action target &optional text &rest options)
  (apply #'syntax-edit-text *syntax-json* "json" action target text options))

(deftest syntax-trees-outline-and-pick-nodes ()
  (with-syntax-test ()
    (let* ((tree (parse-syntax *syntax-json* "json"))
           (outline (syntax-outline tree)))
      (check-equal (mapcar (lambda (entry) (getf entry :qualified)) outline)
                   '("name" "version" "deps" "deps.lem") "nested, qualified")
      (check-equal (node-text tree (syntax-target tree :name "deps.lem")) "\"lem\": \"2.0\"")
      (check-equal (node-text tree (syntax-target tree :line 3)) "\"version\": 1" "a line: the node starting it")
      (check-equal (ts:node-type (syntax-target tree :line 5 :kind "object")) "object" "kind climbs")
      (check-equal (length (syntax-query-captures tree "(pair key: (string) @k)")) 4)
      (check (search "matches 4 nodes" (handler-case (syntax-target tree :query "(pair) @p")
                                         (error (condition) (princ-to-string condition))))
             "several matches: say which")
      (check-equal (node-text tree (syntax-target tree :query "(pair) @p" :occurrence 2)) "\"version\": 1"))))

(deftest syntax-edits-keep-the-file-parsing ()
  (with-syntax-test ()
    (check-equal (syntax-edit :replace '(:name "version") "\"version\": 2")
                 (format nil "{~%  \"name\": \"cl-agent\",~%  \"version\": 2,~%  \"deps\": {~%    \"lem\": \"2.0\"~%  }~%}~%"))
    (check-equal (syntax-edit :replace '(:name "deps.lem") (format nil "\"lem\": {~%  \"ref\": \"887b\"~%}"))
                 (format nil "{~%  \"name\": \"cl-agent\",~%  \"version\": 1,~%  \"deps\": {~%    \"lem\": {~%      \"ref\": \"887b\"~%    }~%  }~%}~%")
                 "new lines indented to the node's column")
    (check-equal (syntax-edit :delete '(:name "version"))
                 (format nil "{~%  \"name\": \"cl-agent\",~%  \"deps\": {~%    \"lem\": \"2.0\"~%  }~%}~%")
                 "the whole line, its comma too")
    (check-equal (syntax-edit :insert-after '(:name "name") "\"license\": \"MIT\",")
                 (format nil "{~%  \"name\": \"cl-agent\",~%  \"license\": \"MIT\",~%  \"version\": 1,~%  \"deps\": {~%    \"lem\": \"2.0\"~%  }~%}~%")
                 "after the node and its comma")
    (check-equal (syntax-edit :insert-before '(:name "deps") "\"private\": true,")
                 (format nil "{~%  \"name\": \"cl-agent\",~%  \"version\": 1,~%  \"private\": true,~%  \"deps\": {~%    \"lem\": \"2.0\"~%  }~%}~%"))
    (let ((refusal (handler-case (progn (syntax-edit :replace '(:name "version") "\"version\": ") nil)
                     (error (condition) (princ-to-string condition)))))
      (check (search "Not done" refusal) "an edit that breaks the syntax is refused")
      (check (search "line 3" refusal) "saying where"))
    (check (search "\"version\": ," (syntax-edit :replace '(:name "version") "\"version\": " :allow-errors t))
           "unless allowed")))

(deftest syntax-edits-count-characters-not-bytes ()
  (with-syntax-test ()
    (let ((text (format nil "{\"é\": \"ü\", \"x\": 1}")))
      (check-equal (syntax-edit-text text "json" :replace '(:name "x") "\"x\": 2") (format nil "{\"é\": \"ü\", \"x\": 2}")))))

(deftest syntax-edits-go-through-the-files-lem-buffer ()
  (with-syntax-test ()
    (let ((path (uiop:native-namestring (merge-pathnames "package.json" *config-directory*))))
      (ensure-directories-exist path)
      (with-open-file (out path :direction :output :if-exists :supersede) (write-string *syntax-json* out))
      (unwind-protect
           (let ((result (call-tool "syntax-tree" (jobj "action" "replace" "path" path "name" "version"
                                                        "text" "\"version\": 3"))))
             (check (search "Replace pair `version`" result) result)
             (check (search "Unsaved" result))
             (check (search "\"version\": 3" (lem-buffer-text-of path)) "in the editor")
             (check (search "\"version\": 1" (uiop:read-file-string path)) "not yet on disk")
             (check (search "Saved" (call-tool "syntax-tree" (jobj "action" "delete" "path" path "name" "deps.lem" "save" t
                                                                   "allow_errors" t))))
             (check (search "\"version\": 3" (uiop:read-file-string path)) "both edits saved")
             (let ((outline (call-tool "syntax-tree" (jobj "action" "outline" "path" path))))
               (check (search "pair deps" outline) outline))
             (check (search "Not done" (call-tool "syntax-tree" (jobj "action" "replace" "path" path "name" "name" "text" "{")))
                    "a refusal comes back to the agent")
             (check (search "No tree-sitter grammar for txt files"
                            (call-tool "syntax-tree" (jobj "action" "outline" "path" "/x/notes.txt")))))
        (ignore-errors (editor-close-file path :force t))))))
