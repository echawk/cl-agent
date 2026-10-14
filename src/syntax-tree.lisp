;;;; syntax-tree.lisp -- the agent's structural edits in any language, by
;;;; tree-sitter syntax trees (tree-sitter-cl, the bindings Lem's own
;;;; tree-sitter support uses): outline a file, show or query its nodes, and
;;;; replace, delete or insert next to a node picked by name, line or query.
;;;;
;;;;   - Edits go through the hosted Lem, like lem-command's: the file's Lem
;;;;     buffer (with any unsaved changes the user has), shown live, unsaved
;;;;     unless asked to save.
;;;;   - An edit that leaves the file with more syntax errors than it had is
;;;;     refused, saying where (allow_errors to make it anyway): the point of
;;;;     editing by tree instead of by text.
;;;;   - New text is written as if at column 0 and indented to the node it
;;;;     replaces or sits next to.
;;;;
;;;; Everything native lives in one place, the config directory's tree-sitter/
;;;; (TREE-SITTER-DIRECTORY), built on first use with the C compiler (cc):
;;;;
;;;;   tree-sitter/grammars/<language>.dylib (.so)   one build of each grammar,
;;;;                                  shared by everything that parses
;;;;   tree-sitter/sgconfig.yaml      ast-grep's view of the same grammars: its
;;;;                                  customLanguages, for the languages ast-grep
;;;;                                  does not build in (AST-GREP-CONFIG-FOR), so
;;;;                                  the structural-query tools and an ast-grep
;;;;                                  MCP server use these builds, not their own
;;;;   tree-sitter/lib/libts-wrapper  tree-sitter-cl's wrapper (below)
;;;;   tree-sitter/build/             checkouts while building, then removed
;;;;
;;;; In detail:
;;;;   - libtree-sitter itself comes from the system (Homebrew's tree-sitter,
;;;;     or a distribution's libtree-sitter-dev), found by its header;
;;;;   - libts-wrapper: tree-sitter-cl's C wrapper, built here against that
;;;;     library (its prebuilt copy names one library version), plus one
;;;;     function of ours: field names (tree-sitter-cl's tree cursor binding
;;;;     calls the by-value C API with pointers, and crashes);
;;;;   - a grammar per language, from its upstream repository at a pinned tag
;;;;     and commit (*SYNTAX-GRAMMARS*), cloned, checked and compiled once.
;;;;     Its generated parser.c is all it takes: no tree-sitter CLI, no Node.

(in-package :cl-agent)

;;; --- the grammars ---

(defparameter *syntax-grammars*
  '((:name "c" :repo "tree-sitter/tree-sitter-c" :tag "v0.24.2"
     :commit "b780e47fc780ddc8da13afa35a3f4ed5c157823d" :extensions ("c" "h"))
    (:name "cpp" :repo "tree-sitter/tree-sitter-cpp" :tag "v0.23.4"
     :commit "f41e1a044c8a84ea9fa8577fdd2eab92ec96de02" :extensions ("cpp" "cc" "cxx" "hpp" "hh" "hxx"))
    (:name "python" :repo "tree-sitter/tree-sitter-python" :tag "v0.25.0"
     :commit "293fdc02038ee2bf0e2e206711b69c90ac0d413f" :extensions ("py" "pyi"))
    (:name "javascript" :repo "tree-sitter/tree-sitter-javascript" :tag "v0.25.0"
     :commit "44c892e0be055ac465d5eeddae6d3e194424e7de" :extensions ("js" "mjs" "cjs" "jsx"))
    (:name "typescript" :repo "tree-sitter/tree-sitter-typescript" :tag "v0.23.2"
     :commit "f975a621f4e7f532fe322e13c4f79495e0a7b2e7" :extensions ("ts" "mts" "cts") :subdirectory "typescript")
    (:name "tsx" :repo "tree-sitter/tree-sitter-typescript" :tag "v0.23.2"
     :commit "f975a621f4e7f532fe322e13c4f79495e0a7b2e7" :extensions ("tsx") :subdirectory "tsx")
    (:name "rust" :repo "tree-sitter/tree-sitter-rust" :tag "v0.24.2"
     :commit "77a3747266f4d621d0757825e6b11edcbf991ca5" :extensions ("rs"))
    (:name "go" :repo "tree-sitter/tree-sitter-go" :tag "v0.25.0"
     :commit "1547678a9da59885853f5f5cc8a99cc203fa2e2c" :extensions ("go"))
    (:name "ruby" :repo "tree-sitter/tree-sitter-ruby" :tag "v0.23.1"
     :commit "71bd32fb7607035768799732addba884a37a6210" :extensions ("rb" "rake" "gemspec"))
    (:name "java" :repo "tree-sitter/tree-sitter-java" :tag "v0.23.5"
     :commit "94703d5a6bed02b98e438d7cad1136c01a60ba2c" :extensions ("java"))
    (:name "json" :repo "tree-sitter/tree-sitter-json" :tag "v0.24.8"
     :commit "ee35a6ebefcef0c5c416c0d1ccec7370cfca5a24" :extensions ("json"))
    (:name "bash" :repo "tree-sitter/tree-sitter-bash" :tag "v0.25.1"
     :commit "a06c2e4415e9bc0346c6b86d401879ffb44058f7" :extensions ("sh" "bash"))
    (:name "css" :repo "tree-sitter/tree-sitter-css" :tag "v0.25.0"
     :commit "dda5cfc5722c429eaba1c910ca32c2c0c5bb1a3f" :extensions ("css"))
    (:name "html" :repo "tree-sitter/tree-sitter-html" :tag "v0.23.2"
     :commit "5a5ca8551a179998360b4a4ca2c0f366a35acc03" :extensions ("html" "htm"))
    (:name "commonlisp" :repo "tree-sitter-grammars/tree-sitter-commonlisp" :tag "v0.4.1"
     :commit "9db594efb43574c5fe4a1f880568b1f0d0ee6057" :extensions ("lisp" "cl" "lsp" "asd")
     :ast-grep :custom))
  "The languages the agent can edit by syntax tree: each grammar's upstream
repository, pinned to a tag and the commit it names.  :AST-GREP :CUSTOM
marks one ast-grep does not build in: it gets this build, through
sgconfig.yaml.")

(defun syntax-grammar (name)
  (find name *syntax-grammars* :key (lambda (grammar) (getf grammar :name)) :test #'string-equal))

(defun syntax-language-for (path &optional language)
  "The grammar name for PATH (by its extension), or LANGUAGE when given."
  (if (and (stringp language) (plusp (length language)))
      (or (getf (syntax-grammar language) :name)
          (error "No tree-sitter grammar for ~s: the languages are ~{~a~^, ~}."
                 language (mapcar (lambda (grammar) (getf grammar :name)) *syntax-grammars*)))
      (let ((type (and path (pathname-type path))))
        (or (and type (getf (find-if (lambda (grammar) (member type (getf grammar :extensions) :test #'string-equal))
                                     *syntax-grammars*)
                            :name))
            (error "No tree-sitter grammar for ~a files; give language (one of ~{~a~^, ~})."
                   (or type "extension-less") (mapcar (lambda (grammar) (getf grammar :name)) *syntax-grammars*))))))

;;; --- building the native side ---

(defun tree-sitter-directory ()
  (merge-pathnames "tree-sitter/" *config-directory*))

(defun shared-library-path (name &optional (subdirectory "lib/"))
  (merge-pathnames (format nil "~a~a.~a" subdirectory name (if (uiop:os-macosx-p) "dylib" "so"))
                   (tree-sitter-directory)))

(defun syntax-grammar-library (name)
  "Where the one build of grammar NAME lives."
  (shared-library-path name "grammars/"))

(defun tree-sitter-prefix ()
  "The installation prefix of the system's libtree-sitter (its header and
library), or NIL.  CL_AGENT_TREE_SITTER_PREFIX names one."
  (find-if (lambda (prefix)
             (and (probe-file (format nil "~a/include/tree_sitter/api.h" prefix))
                  (or (probe-file (format nil "~a/lib/libtree-sitter.dylib" prefix))
                      (probe-file (format nil "~a/lib/libtree-sitter.so" prefix))
                      (probe-file (format nil "~a/lib/x86_64-linux-gnu/libtree-sitter.so" prefix))
                      (probe-file (format nil "~a/lib/aarch64-linux-gnu/libtree-sitter.so" prefix)))))
           (remove nil (list (uiop:getenv "CL_AGENT_TREE_SITTER_PREFIX")
                             "/opt/homebrew" "/usr/local" "/usr" "/opt/local"))))

(defun compile-shared-library (output sources &key includes prefix)
  "Compile C SOURCES into the shared library OUTPUT with cc, linking
libtree-sitter from PREFIX when given."
  (ensure-directories-exist output)
  (let ((command (append (list "cc" "-O2" "-fPIC" "-shared")
                         (and (uiop:os-macosx-p) (list "-dynamiclib"))
                         (list "-o" (uiop:native-namestring output))
                         (mapcar (lambda (directory) (format nil "-I~a" (uiop:native-namestring directory))) includes)
                         (mapcar #'uiop:native-namestring sources)
                         (and prefix (list (format nil "-L~a/lib" prefix) "-ltree-sitter")))))
    (multiple-value-bind (output-text error-text status)
        (uiop:run-program command :output :string :error-output :string :ignore-error-status t)
      (declare (ignore output-text))
      (unless (zerop status)
        (error "Building ~a failed (cc exited ~d):~%~a" (file-namestring output) status
               (subseq error-text 0 (min 2000 (length error-text))))))
    output))

(defparameter *syntax-tree-c-source*
  "#include <tree_sitter/api.h>
const char *cl_agent_ts_field_name_for_child(const TSNode *node, uint32_t index) {
  return ts_node_field_name_for_child(*node, index);
}
"
  "Our addition to tree-sitter-cl's wrapper library: a child's field name.")

(cffi:defcfun ("cl_agent_ts_field_name_for_child" %ts-field-name-for-child) :string
  (node :pointer) (index :uint32))

(defvar *tree-sitter-ready* nil)
(defvar *tree-sitter-lock* (bt:make-recursive-lock "tree-sitter"))

(defun tree-sitter-forget ()
  ;; A restarted image has none of the libraries or languages it had.
  (setf *tree-sitter-ready* nil)
  (ignore-errors (clrhash tree-sitter/language::*languages*)))

(pushnew 'tree-sitter-forget sb-ext:*init-hooks*)

(defun build-tree-sitter-wrapper (prefix)
  (let ((extra (merge-pathnames "build/cl-agent-ts.c" (tree-sitter-directory))))
    (ensure-directories-exist extra)
    (with-open-file (out extra :direction :output :if-exists :supersede)
      (write-string *syntax-tree-c-source* out))
    (compile-shared-library (shared-library-path "libts-wrapper")
                            (list (asdf:system-relative-pathname :tree-sitter-cl "c-wrapper/ts-wrapper.c") extra)
                            :includes (list (format nil "~a/include" prefix))
                            :prefix prefix)))

(defun ensure-tree-sitter ()
  "Load libtree-sitter and our build of the wrapper, building it if need be."
  (bt:with-recursive-lock-held (*tree-sitter-lock*)
    (unless *tree-sitter-ready*
      (let ((prefix (tree-sitter-prefix)))
        (unless prefix
          (error "tree-sitter's library is not installed: brew install tree-sitter (or your system's libtree-sitter-dev package), then retry."))
        (cffi:load-foreign-library (or (probe-file (format nil "~a/lib/libtree-sitter.dylib" prefix))
                                       (probe-file (format nil "~a/lib/libtree-sitter.so" prefix))
                                       (first (directory (format nil "~a/lib/*/libtree-sitter.so" prefix)))))
        (setf tree-sitter/ffi::*tree-sitter-loaded* t)
        (let ((wrapper (shared-library-path "libts-wrapper")))
          (unless (probe-file wrapper) (build-tree-sitter-wrapper prefix))
          (handler-case (cffi:load-foreign-library wrapper)
            ;; Built against a library version since replaced: again.
            (error ()
              (delete-file wrapper)
              (build-tree-sitter-wrapper prefix)
              (cffi:load-foreign-library wrapper))))
        (setf tree-sitter/ffi::*ts-wrapper-loaded* t
              *tree-sitter-ready* t)))))

(defun build-grammar (name source)
  "Compile the grammar NAME from SOURCE, a grammar's directory (with
src/parser.c), into its place in the grammars directory.  Returns the
library."
  (let* ((src (merge-pathnames "src/" (uiop:ensure-directory-pathname source)))
         (scanner (probe-file (merge-pathnames "scanner.c" src))))
    (unless (probe-file (merge-pathnames "parser.c" src))
      (error "~a has no src/parser.c: not a tree-sitter grammar." source))
    (compile-shared-library (syntax-grammar-library name)
                            (remove nil (list (merge-pathnames "parser.c" src) scanner))
                            :includes (list src))))

(defun install-grammar (name)
  "Fetch NAME's grammar at its pinned commit and build it.  Returns a line
saying so."
  (let* ((grammar (or (syntax-grammar name) (error "No tree-sitter grammar named ~s." name)))
         (checkout (merge-pathnames (format nil "build/~a-~36r/" name (random (expt 36 6))) (tree-sitter-directory)))
         (url (format nil "https://github.com/~a" (getf grammar :repo))))
    (ensure-directories-exist checkout)
    (unwind-protect
         (flet ((git (&rest arguments)
                  (multiple-value-bind (out err status)
                      (uiop:run-program (list* "git" arguments) :output :string :error-output :string :ignore-error-status t)
                    (unless (zerop status)
                      (error "git ~a failed: ~a" (first arguments) (string-trim '(#\Newline) err)))
                    (string-trim '(#\Newline #\Space) out))))
           (git "clone" "--quiet" "--depth" "1" "--branch" (getf grammar :tag) url (uiop:native-namestring checkout))
           (let ((head (git "-C" (uiop:native-namestring checkout) "rev-parse" "HEAD")))
             (unless (string= head (getf grammar :commit))
               (error "~a ~a is commit ~a, not the pinned ~a: not building it."
                      (getf grammar :repo) (getf grammar :tag) head (getf grammar :commit))))
           (build-grammar name (if (getf grammar :subdirectory)
                                   (merge-pathnames (format nil "~a/" (getf grammar :subdirectory)) checkout)
                                   checkout))
           (format nil "Installed the ~a grammar (~a ~a) in ~a." name (getf grammar :repo) (getf grammar :tag)
                   (uiop:native-namestring (tree-sitter-directory))))
      (uiop:delete-directory-tree checkout :validate t :if-does-not-exist :ignore))))

;; *SYNTAX-NOTES* (structural.lisp): lines to report with a tool's result,
;; grammars installed meanwhile.

(defun ensure-syntax-grammar (name)
  "The library of grammar NAME, installed the first time.  Needs git and cc,
not libtree-sitter: ast-grep loads it itself."
  (bt:with-recursive-lock-held (*tree-sitter-lock*)
    (let ((library (syntax-grammar-library name)))
      (unless (probe-file library)
        (push (install-grammar name) *syntax-notes*))
      library)))

(defun syntax-language (name)
  "The tree-sitter language NAME, loaded (and installed, the first time)."
  (ensure-tree-sitter)
  (bt:with-recursive-lock-held (*tree-sitter-lock*)
    (or (ts:get-language name)
        (ts:load-language name (uiop:native-namestring (ensure-syntax-grammar name))))))

;;; --- ast-grep, on the same grammars ---

(defun ast-grep-config-path ()
  (merge-pathnames "sgconfig.yaml" (tree-sitter-directory)))

(defun write-ast-grep-config ()
  "Write sgconfig.yaml: ast-grep's customLanguages, one per installed
grammar ast-grep does not build in, each at its library here.  Returns it."
  (let ((path (ast-grep-config-path)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede)
      (format out "# Written by cl-agent (syntax-tree.lisp) from ~a: edits are overwritten.~%customLanguages:~%"
              (uiop:native-namestring (merge-pathnames "grammars/" (tree-sitter-directory))))
      (dolist (grammar *syntax-grammars*)
        (let ((library (syntax-grammar-library (getf grammar :name))))
          (when (and (eq (getf grammar :ast-grep) :custom) (probe-file library))
            (format out "  ~a:~%    libraryPath: ~a~%    extensions: [~{~s~^, ~}]~%"
                    (getf grammar :name) (uiop:native-namestring library) (getf grammar :extensions))))))
    path))

(defun ast-grep-custom-language-p (language)
  (eq (getf (syntax-grammar language) :ast-grep) :custom))

(defun ast-grep-config-for (language)
  "The sgconfig.yaml ast-grep needs for LANGUAGE -- its grammar built and
listed -- or NIL when ast-grep builds LANGUAGE in."
  (when (ast-grep-custom-language-p language)
    (ensure-syntax-grammar (getf (syntax-grammar language) :name))
    (write-ast-grep-config)))

;;; --- trees over text ---

(defun utf8-length (char)
  (let ((code (char-code char)))
    (cond ((< code #x80) 1) ((< code #x800) 2) ((< code #x10000) 3) (t 4))))

(defun byte-to-char-function (text)
  "A function from a UTF-8 byte offset in TEXT to its character offset."
  (if (every (lambda (char) (< (char-code char) #x80)) text)
      #'identity
      (let ((starts (make-array (1+ (length text)) :element-type 'fixnum)) (byte 0))
        (loop for i below (length text)
              do (setf (aref starts i) byte)
                 (incf byte (utf8-length (char text i))))
        (setf (aref starts (length text)) byte)
        (lambda (offset)
          (let ((low 0) (high (length text)))
            (loop while (< low high)
                  do (let ((middle (ceiling (+ low high) 2)))
                       (if (<= (aref starts middle) offset) (setf low middle) (setf high (1- middle)))))
            low)))))

(defstruct (syntax-tree (:constructor %make-syntax-tree))
  text language tree root char)

(defun parse-syntax (text language)
  "TEXT parsed as LANGUAGE (a grammar name)."
  (let ((parser (ts:make-parser (syntax-language language))))
    (unwind-protect
         (let ((tree (ts:parser-parse-string parser text)))
           (unless tree (error "tree-sitter could not parse the text as ~a." language))
           (%make-syntax-tree :text text :language language :tree tree
                              :root (ts:tree-root-node tree) :char (byte-to-char-function text)))
      (ts:parser-delete parser))))

(defun node-start (tree node) (funcall (syntax-tree-char tree) (ts:node-start-byte node)))
(defun node-end (tree node) (funcall (syntax-tree-char tree) (ts:node-end-byte node)))
(defun node-text (tree node) (subseq (syntax-tree-text tree) (node-start tree node) (node-end tree node)))
(defun node-first-line (node) (1+ (ts:point-row (ts:node-start-point node))))
(defun node-last-line (node) (1+ (ts:point-row (ts:node-end-point node))))

(defun node-fields (node)
  "NODE's children as (field-name . child), FIELD-NAME NIL for most."
  (loop for i below (ts:node-child-count node)
        collect (cons (%ts-field-name-for-child (tree-sitter/types:ts-node-buffer node) i)
                      (ts:node-child node i))))

(defun node-field (node name)
  (cdr (assoc name (node-fields node) :test #'equal)))

(defun syntax-errors (tree)
  "The ERROR and missing nodes of TREE, in order."
  (let ((errors '()))
    (labels ((walk (node)
               (cond ((ts:node-missing-p node) (push node errors))
                     ((string= (ts:node-type node) "ERROR") (push node errors))
                     ((ts:node-has-error-p node) (mapc #'walk (ts:node-children node))))))
      (walk (syntax-tree-root tree)))
    (nreverse errors)))

(defun describe-syntax-error (tree node)
  (if (ts:node-missing-p node)
      (format nil "line ~d: missing ~a" (node-first-line node) (ts:node-type node))
      (format nil "line ~d: unexpected ~s" (node-first-line node)
              (let ((text (node-text tree node)))
                (if (> (length text) 40) (concatenate 'string (subseq text 0 40) "...") text)))))

;;; --- definitions: what an outline lists, and what a name finds ---

(defparameter *definition-words*
  '("definition" "declaration" "function" "method" "class" "struct" "enum" "union" "interface"
    "trait" "impl" "module" "namespace" "_item" "type_spec" "type_alias" "pair" "constructor"
    "variable_declarator" "rule_set" "element" "defun")
  "A named node whose type contains one of these, and that has a name, is a
definition for outlines and names.")

(defparameter *not-definition-words*
  '("parameter" "argument" "identifier" "expression" "call" "_declarator" "specifier_list")
  "... unless its type contains one of these.")

(defparameter *function-words* '("function" "method" "constructor" "lambda" "closure" "arrow" "defun")
  "Definitions an outline does not look inside.")

(defun type-has-word-p (type words)
  (some (lambda (word) (search word type)) words))

(defun unquote-name (text)
  (let ((text (string-trim '(#\Space #\Tab #\Newline) text)))
    (if (and (>= (length text) 2) (member (char text 0) '(#\" #\')) (char= (char text 0) (char text (1- (length text)))))
        (subseq text 1 (1- (length text)))
        text)))

(defun node-name (tree node)
  "The name NODE defines, or NIL."
  (let ((name (or (node-field node "name") (node-field node "key") (node-field node "function_name")
                  ;; Common Lisp: (defun NAME ...) keeps it in a header.
                  (let ((header (find "defun_header" (ts:node-children node) :key #'ts:node-type :test #'string=)))
                    (and header (node-field header "function_name")))
                  (and (search "impl" (ts:node-type node)) (node-field node "type")))))
    (if name
        (unquote-name (node-text tree name))
        (let ((declarator (node-field node "declarator")))
          (loop repeat 8
                while declarator
                do (if (member (ts:node-type declarator)
                               '("identifier" "field_identifier" "type_identifier" "qualified_identifier"
                                 "destructor_name" "operator_name" "property_identifier")
                               :test #'string=)
                       (return (node-text tree declarator))
                       (setf declarator (or (node-field declarator "declarator") (node-field declarator "name")))))))))

(defun definition-p (tree node)
  (let ((type (ts:node-type node)))
    (and (ts:node-named-p node)
         (or (string= type "variable_declarator")
             (and (type-has-word-p type *definition-words*)
                  (not (type-has-word-p type *not-definition-words*))))
         (node-name tree node))))

(defun syntax-outline (tree)
  "TREE's definitions, outermost first: plists (:node :name :qualified :type
:depth)."
  (let ((entries '()))
    (labels ((walk (node path depth)
               (let ((name (definition-p tree node)))
                 (if name
                     (let ((qualified (format nil "~{~a~^.~}" (append path (list name)))))
                       (push (list :node node :name name :qualified qualified
                                   :type (ts:node-type node) :depth depth)
                             entries)
                       (unless (type-has-word-p (ts:node-type node) *function-words*)
                         (dolist (child (ts:node-named-children node))
                           (walk child (append path (list name)) (1+ depth)))))
                     (dolist (child (ts:node-named-children node))
                       (walk child path depth))))))
      (walk (syntax-tree-root tree) '() 0))
    (nreverse entries)))

;;; --- picking a node ---

(defun normalize-qualified-name (name)
  (let ((name (substitute #\. #\# name)))
    (loop for at = (search "::" name)
          while at
          do (setf name (concatenate 'string (subseq name 0 at) "." (subseq name (+ at 2)))))
    name))

(defun node-candidates-text (nodes)
  (format nil "~{~a~^; ~}"
          (loop for node in nodes repeat 12
                collect (format nil "~a at line ~d" (ts:node-type node) (node-first-line node)))))

(defun pick-one (tree nodes what occurrence)
  (cond ((null nodes) (error "No node matches ~a." what))
        (occurrence
         (or (nth (1- occurrence) nodes)
             (error "~a matches ~d node~:p, so there is no occurrence ~d." what (length nodes) occurrence)))
        ((rest nodes)
         (error "~a matches ~d nodes (~a): give occurrence (1-based), kind or a line."
                what (length nodes) (node-candidates-text nodes)))
        (t (first nodes))))

(defun node-at (tree line column)
  "The node a line (and column, else its first non-blank character) points
at: the largest named node starting there, inside the smallest one around it."
  (let* ((text (syntax-tree-text tree))
         (lines (uiop:split-string text :separator '(#\Newline)))
         (line-text (or (nth (1- line) lines) (error "The text has only ~d lines." (length lines))))
         (column (or (and column (max 0 (1- column)))
                     (or (position-if-not (lambda (c) (member c '(#\Space #\Tab))) line-text) 0)))
         (offset (+ (loop for l in lines repeat (1- line) sum (1+ (length l))) column))
         (node (syntax-tree-root tree)))
    ;; Down to the smallest named node holding OFFSET.
    (loop for child = (find-if (lambda (child)
                                 (and (<= (node-start tree child) offset) (< offset (node-end tree child))))
                               (ts:node-named-children node))
          while child
          do (setf node child))
    ;; Up while the parent starts at the same place: the statement, not its
    ;; first token.
    (loop for parent = (ts:node-parent node)
          while (and parent (not (ts:node-null-p parent)) (ts:node-parent parent)
                     (not (ts:node-null-p (ts:node-parent parent)))
                     (= (node-start tree parent) (node-start tree node)))
          do (setf node parent))
    node))

(defun climb-to-kind (node kind)
  (loop for current = node then (ts:node-parent current)
        while (and current (not (ts:node-null-p current)))
        when (search kind (ts:node-type current)) return current))

(defun syntax-query-captures (tree query-source &key capture)
  "The nodes QUERY-SOURCE (a tree-sitter query) captures in TREE, as
(capture-name . node), CAPTURE only when given."
  (let ((query (handler-case (ts:query-compile (syntax-language (syntax-tree-language tree)) query-source)
                 (error (condition) (error "The query does not compile: ~a" condition)))))
    (remove-if-not (lambda (pair) (or (null capture) (string= (car pair) (string-left-trim "@" capture))))
                   (mapcar (lambda (c) (cons (ts:capture-name c) (ts:capture-node c)))
                           (ts:query-captures query (syntax-tree-root tree))))))

(defun syntax-target (tree &key name kind occurrence line column query capture)
  "The node an edit or a look is about: by NAME (a definition's name, or
its qualified name Outer.inner), by LINE (and COLUMN), or by QUERY's
captures; KIND narrows by node type (and with LINE climbs to it)."
  (cond (name
         (let* ((wanted (normalize-qualified-name name))
                (entries (remove-if-not (lambda (entry)
                                          (and (or (string= (getf entry :name) wanted)
                                                   (string= (getf entry :qualified) wanted))
                                               (or (null kind) (search kind (getf entry :type)))))
                                        (syntax-outline tree))))
           (pick-one tree (mapcar (lambda (entry) (getf entry :node)) entries)
                     (format nil "the name ~s~@[ (~a)~]" name kind) occurrence)))
        (line
         (let ((node (node-at tree line column)))
           (if kind
               (or (climb-to-kind node kind) (error "Nothing of kind ~s holds line ~d." kind line))
               node)))
        (query
         (let ((nodes (mapcar #'cdr (syntax-query-captures tree query :capture capture))))
           (pick-one tree (if kind (remove-if-not (lambda (node) (search kind (ts:node-type node))) nodes) nodes)
                     "the query" occurrence)))
        (t (error "Say which node: give name, line, or query."))))

;;; --- edits ---

(defun line-start-of (text offset)
  (let ((newline (position #\Newline text :end offset :from-end t)))
    (if newline (1+ newline) 0)))

(defun line-end-of (text offset)
  (or (position #\Newline text :start offset) (length text)))

(defun blank-text-p (text start end)
  (every (lambda (c) (member c '(#\Space #\Tab #\Return))) (subseq text start end)))

(defun reindent (text indentation &key (first-line t))
  "TEXT without its common indentation, each non-blank line then indented
by INDENTATION (the first one too when FIRST-LINE)."
  (let* ((lines (uiop:split-string text :separator '(#\Newline)))
         (common (loop for line in lines
                       unless (blank-text-p line 0 (length line))
                         minimize (or (position-if-not (lambda (c) (member c '(#\Space #\Tab))) line) 0))))
    (format nil "~{~a~^~%~}"
            (loop for line in lines
                  for i from 0
                  collect (cond ((blank-text-p line 0 (length line)) "")
                                ((and (zerop i) (not first-line)) (subseq line (min common (length line))))
                                (t (concatenate 'string indentation (subseq line (min common (length line))))))))))

(defun syntax-edit-range (tree node action text)
  "Where ACTION on NODE changes TREE's text, and what goes there: (values
start end new-text), character offsets."
  (let* ((source (syntax-tree-text tree))
         (start (node-start tree node))
         (end (let ((end (node-end tree node)))
                ;; A separator after the node goes with it when it is
                ;; deleted or followed: "a": 1, -- f(x);
                (if (member action '(:delete :insert-after))
                    (let ((next (position-if-not (lambda (c) (member c '(#\Space #\Tab))) source :start end)))
                      (if (and next (member (char source next) '(#\, #\;))) (1+ next) end))
                    end)))
         (line-start (line-start-of source start))
         (line-end (line-end-of source end))
         (alone-before (blank-text-p source line-start start))
         (alone-after (blank-text-p source end line-end))
         ;; The node's line's own indentation.
         (indentation (subseq source line-start
                              (or (position-if-not (lambda (c) (member c '(#\Space #\Tab)))
                                                   source :start line-start :end start)
                                  start))))
    (ecase action
      (:replace (values start end (reindent text indentation :first-line nil)))
      (:delete
       (if (and alone-before alone-after)
           ;; Whole lines: take them, and their newline.
           (values line-start (min (length source) (1+ line-end)) "")
           (values start end "")))
      (:insert-before
       (if alone-before
           (values line-start line-start (format nil "~a~%" (reindent text indentation)))
           (values start start (format nil "~a~%~a" (reindent text indentation :first-line nil) indentation))))
      (:insert-after
       (if alone-after
           (values line-end line-end (format nil "~%~a" (reindent text indentation)))
           (values end end (format nil "~%~a" (reindent text indentation))))))))

(defun describe-node (tree node)
  (let ((name (node-name tree node)))
    (format nil "~a~@[ ~a~] (line~:[s ~d-~d~;~*~d~])" (ts:node-type node) (and name (format nil "`~a`" name))
            (= (node-first-line node) (node-last-line node)) (node-first-line node) (node-last-line node))))

(defun syntax-edit-text (text language action target-options new-text &key allow-errors)
  "TEXT with ACTION done to the node TARGET-OPTIONS pick (see SYNTAX-TARGET).
Returns (values new-text start end description), or signals an error --
also when the result has more syntax errors than TEXT did and ALLOW-ERRORS
is false."
  (let* ((tree (parse-syntax text language))
         (node (apply #'syntax-target tree target-options))
         (description (describe-node tree node)))
    (when (and (member action '(:replace :insert-before :insert-after)) (not (stringp new-text)))
      (error "Give the text to put there."))
    (multiple-value-bind (start end replacement) (syntax-edit-range tree node action (or new-text ""))
      (let* ((result (concatenate 'string (subseq text 0 start) replacement (subseq text end)))
             (before (syntax-errors tree))
             (after-tree (parse-syntax result language))
             (after (syntax-errors after-tree)))
        (when (and (> (length after) (length before)) (not allow-errors))
          (error "Not done: after it the file would not parse as ~a (~{~a~^; ~})~:[~*~; -- it had ~d error~:p already~]. Fix the text, or give allow_errors to make the edit anyway."
                 language (mapcar (lambda (node) (describe-syntax-error after-tree node))
                                  (subseq after 0 (min 3 (length after))))
                 before (length before)))
        (values result start end description (length after))))))

;;; --- files, through Lem ---

(defun syntax-file-text (path)
  "PATH's text as the user has it: its Lem buffer's when open, else the file's."
  (or (and (lem-host-available-p)
           (lem-call (lambda () (let ((buffer (editor-find-buffer path))) (and buffer (editor-buffer-text buffer))))))
      (uiop:read-file-string (expand-user-path path))))

(defun syntax-edit-file (path action target-options text &key language allow-errors save)
  "Do ACTION (:replace :delete :insert-before :insert-after) to the node
TARGET-OPTIONS pick in the file at PATH, in its Lem buffer; then save it
when SAVE.  Returns a plist (:description :changes :errors :saved :path)."
  (let ((language (syntax-language-for path language)))
    (syntax-language language)          ; installed before the editor waits on it
    (if (not (lem-host-available-p))
        ;; No editor: straight to disk.
        (let ((before (uiop:read-file-string (expand-user-path path))))
          (multiple-value-bind (after start end description errors)
              (syntax-edit-text before language action target-options text :allow-errors allow-errors)
            (declare (ignore start end))
            (write-string-atomically (expand-user-path path) after)
            (list :description description :changes (changed-lines before after) :errors errors
                  :saved :saved :path (uiop:native-namestring (expand-user-path path)))))
        (let ((result
                (lem-call
                 (lambda ()
                   (let* ((buffer (lem-buffer-for path))
                          (before (editor-buffer-text buffer)))
                     (multiple-value-bind (after start end description errors)
                         (syntax-edit-text before language action target-options text :allow-errors allow-errors)
                       (lem:with-point ((from (lem:buffer-point buffer)) (to (lem:buffer-point buffer)))
                         (lem:move-to-position from (1+ start))
                         (lem:move-to-position to (1+ end))
                         (lem:delete-between-points from to)
                         (lem:insert-string from (subseq after start (- (length after) (- (length before) end)))))
                       (let ((now (editor-buffer-text buffer)))
                         (unless (string= now after)
                           (error "The buffer did not take the edit as planned; nothing more was done."))
                         (editor-bump-version buffer)
                         (list :description description :changes (changed-lines before now) :errors errors
                               :path (lem:buffer-filename buffer) :text now :version (editor-version buffer)
                               :modified (and (lem:buffer-modified-p buffer) t)))))))))
          (editor-publish "file-buffer" (jobj "path" (getf result :path) "version" (getf result :version)
                                              "text" (getf result :text) "modified" (getf result :modified)
                                              "by" "agent"))
          (when save
            (setf (getf result :saved) (editor-save-file (getf result :path) :by "agent-editor")))
          result))))

(defun syntax-outline-text (path &key language)
  (let* ((language (syntax-language-for path language))
         (tree (parse-syntax (syntax-file-text path) language))
         (entries (syntax-outline tree))
         (errors (syntax-errors tree)))
    (format nil "~a (~a): ~d definition~:p~@[, ~a~]~%~{~a~^~%~}~@[~%... ~d more~]"
            path language (length entries)
            (and errors (format nil "~d syntax error~:p (~a)" (length errors) (describe-syntax-error tree (first errors))))
            (loop for entry in entries repeat 400
                  collect (let ((node (getf entry :node)))
                            (format nil "~a~5d-~d  ~a ~a" (make-string (* 2 (getf entry :depth)) :initial-element #\Space)
                                    (node-first-line node) (node-last-line node)
                                    (getf entry :type) (getf entry :name))))
            (and (> (length entries) 400) (- (length entries) 400)))))

(defun syntax-numbered-lines (text first-line &key (limit 120))
  (let ((lines (uiop:split-string text :separator '(#\Newline))))
    (format nil "~{~a~^~%~}~@[~%... ~d more line~:p~]"
            (loop for line in lines for n from first-line repeat limit collect (format nil "~5d  ~a" n line))
            (and (> (length lines) limit) (- (length lines) limit)))))

(defun syntax-show-text (path target-options &key language)
  (let* ((language (syntax-language-for path language))
         (tree (parse-syntax (syntax-file-text path) language))
         (node (apply #'syntax-target tree target-options)))
    (format nil "~a~%~a~%~%Parts: ~{~a~^, ~}"
            (describe-node tree node)
            (syntax-numbered-lines (let ((text (syntax-tree-text tree)))
                                     ;; From its line's start, so the lines line up.
                                     (subseq text (line-start-of text (node-start tree node)) (node-end tree node)))
                                   (node-first-line node))
            (or (loop for (field . child) in (node-fields node)
                      when (ts:node-named-p child)
                        collect (format nil "~@[~a: ~]~a (line ~d)" field (ts:node-type child) (node-first-line child)))
                '("none")))))

(defun syntax-query-text (path query &key language capture)
  (let* ((language (syntax-language-for path language))
         (tree (parse-syntax (syntax-file-text path) language))
         (captures (syntax-query-captures tree query :capture capture)))
    (format nil "~d capture~:p~{~%~a~}~@[~%... ~d more~]"
            (length captures)
            (loop for (name . node) in captures repeat 100
                  collect (let ((text (node-text tree node)))
                            (format nil "  @~a  ~a  line~:[s ~d-~d~;~*~d~]  ~a" name (ts:node-type node)
                                    (= (node-first-line node) (node-last-line node))
                                    (node-first-line node) (node-last-line node)
                                    (first-line (string-trim '(#\Space #\Tab) text)))))
            (and (> (length captures) 100) (- (length captures) 100)))))

(defun syntax-languages-text ()
  (format nil "Languages (grammars build on first use into ~a):~{~%  ~a~}~@[~%~a~]"
          (uiop:native-namestring (merge-pathnames "grammars/" (tree-sitter-directory)))
          (mapcar (lambda (grammar)
                    (format nil "~a (~{.~a~^ ~})~:[~; -- installed~]" (getf grammar :name) (getf grammar :extensions)
                            (probe-file (syntax-grammar-library (getf grammar :name)))))
                  *syntax-grammars*)
          (and (null (tree-sitter-prefix))
               "tree-sitter's library is not installed: brew install tree-sitter (or libtree-sitter-dev).")))

;;; --- the tool ---

(defun syntax-target-options (args)
  (let ((options '()))
    (loop for (key json) in '((:name "name") (:kind "kind") (:occurrence "occurrence") (:line "line")
                              (:column "column") (:query "query") (:capture "capture"))
          do (let ((value (jget args json)))
               (when value (setf options (list* key value options)))))
    options))

(define-tool syntax-tree (args)
    (:description "Structural code edits in C, C++, Python, JavaScript, TypeScript/TSX, Rust, Go, Ruby, Java, JSON, Bash, CSS, HTML and Common Lisp, by tree-sitter syntax tree. action=outline lists a file's definitions (functions, classes, methods, structs, keys...) with their lines; show prints one node with its parts; query runs a tree-sitter query (e.g. \"(function_definition name: (identifier) @name)\") and lists captures. Edits: replace, delete, insert_before, insert_after a node picked by name (a definition's name or Outer.inner), by line (+ column; kind climbs to an enclosing node type, e.g. line 40 kind \"function\" = the function around line 40), or by query (+ capture). Give occurrence when several match. Write text unindented: it is indented to the node's column; blank lines at its ends are kept (start it with an empty line to separate definitions). An edit that would leave the file with more syntax errors than before is refused, saying where. Edits go through the file's Lem buffer (the user's unsaved changes included, shown live) and stay unsaved unless save is true. For Lisp the Lisp tools know more (packages, the live image); this one is still handy for outlines and queries. A language's grammar is fetched and built on first use."
     :effects '(:write-workspace)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "action" (jobj "type" "string"
                                "enum" (list "outline" "show" "query" "replace" "delete" "insert_before" "insert_after" "languages"))
                 "path" (jobj "type" "string" "description" "The file.")
                 "language" (jobj "type" "string" "description" "Grammar name, when the extension does not say (c, cpp, python, javascript, typescript, tsx, rust, go, ruby, java, json, bash, css, html, commonlisp).")
                 "name" (jobj "type" "string" "description" "A definition's name, or qualified: Class.method.")
                 "kind" (jobj "type" "string" "description" "Part of a node type: function, class, if_statement, ...")
                 "occurrence" (jobj "type" "integer" "description" "Which match, 1-based, when several do.")
                 "line" (jobj "type" "integer" "description" "1-based line of the node.")
                 "column" (jobj "type" "integer" "description" "1-based column; default the line's first non-blank character.")
                 "query" (jobj "type" "string" "description" "A tree-sitter query, for action=query or to pick a node.")
                 "capture" (jobj "type" "string" "description" "The query capture to use, e.g. @name.")
                 "text" (jobj "type" "string" "description" "The new code for replace / insert_before / insert_after.")
                 "allow_errors" (jobj "type" "boolean" "description" "Make an edit even if it adds syntax errors.")
                 "save" (jobj "type" "boolean" "description" "Save the file after the edit."))
           "required" (list "action")))
  (let* ((action (or (jget args "action") "outline"))
         (path (jget args "path"))
         (language (jget args "language"))
         (*syntax-notes* '()))
    (unless (or (string= action "languages") (and (stringp path) (plusp (length path))))
      (error "Give the file's path."))
    (let ((text
            (cond
              ((string= action "languages") (syntax-languages-text))
              ((string= action "outline") (syntax-outline-text path :language language))
              ((string= action "show") (syntax-show-text path (syntax-target-options args) :language language))
              ((string= action "query")
               (let ((query (jget args "query")))
                 (unless (stringp query) (error "Give the query."))
                 (syntax-query-text path query :language language :capture (jget args "capture"))))
              (t
               (let* ((edit (or (cdr (assoc action '(("replace" . :replace) ("delete" . :delete)
                                                     ("insert_before" . :insert-before) ("insert_after" . :insert-after))
                                            :test #'string=))
                                (error "Unknown action ~s." action)))
                      (result (syntax-edit-file path edit (syntax-target-options args) (jget args "text")
                                                :language language :allow-errors (jget args "allow_errors")
                                                :save (jget args "save"))))
                 (format nil "~a ~a in ~a.~%~a~%~:[The file parses cleanly.~;~:*The file has ~d syntax error~:p, no more than before.~]~%~a"
                         (string-capitalize (substitute #\Space #\_ action) :end 1) (getf result :description)
                         (getf result :path) (getf result :changes)
                         (and (plusp (getf result :errors)) (getf result :errors))
                         (if (eq (getf result :saved) :saved)
                             "Saved."
                             "Unsaved in the editor (save: true writes it).")))))))
      (format nil "~{~a~%~}~a" (reverse *syntax-notes*) text))))
