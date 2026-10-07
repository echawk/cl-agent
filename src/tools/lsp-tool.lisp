;;;; tools/lsp-tool.lisp -- model-facing, read-only queries to lazy LSP servers.

(in-package :cl-agent)

(defun lsp-render (value)
  "Render LSP's JSON/hash-table and plist results as JSON for a tool result."
  (json-encode value :pretty t))

(define-tool list-lsp-servers (args)
    (:description "List language servers configured for cl-agent and currently available on PATH. Servers are started lazily only when lsp-query or lsp-diagnostics is used on a matching file."
     :parameters (jobj "type" "object" "properties" (jobj)))
  (ignore-errors args)
  (let ((servers (lsp-server-statuses)))
    (if servers
        (format nil "~{~a (~a): ~{~a~^, ~}~^~%~}"
                (mapcar (lambda (server)
                          (list (getf server :name) (getf server :command)
                                (getf server :extensions)))
                        servers))
        (format nil "No available LSP servers. Add ~a using cl-lsp's (:version 1 :servers ...) format."
                (namestring (lsp-configuration-path))))))

(define-tool lsp-query (args)
    (:description "Ask a configured language server a read-only semantic question about an existing source file. Operations are definition, references, hover, implementation, type-definition, document-symbols, or workspace-symbols. line and character are zero-based UTF-16 coordinates and are required except for document-symbols; workspace-symbols requires query. The matching server starts lazily and is reused for later requests."
     :parameters (jobj "type" "object"
                       "properties" (jobj "path" (jobj "type" "string")
                                          "operation" (jobj "type" "string"
                                                            "enum" (list "definition" "references" "hover" "implementation" "type-definition" "document-symbols" "workspace-symbols"))
                                          "line" (jobj "type" "integer" "minimum" 0)
                                          "character" (jobj "type" "integer" "minimum" 0)
                                          "query" (jobj "type" "string"))
                       "required" (list "path" "operation")))
  (let ((operation (jget args "operation"))
        (line (jget args "line"))
        (character (jget args "character"))
        (query (jget args "query")))
    (unless (member operation '("definition" "references" "hover" "implementation" "type-definition" "document-symbols" "workspace-symbols") :test #'string=)
      (error "Unsupported LSP operation ~s" operation))
    (when (and (not (member operation '("document-symbols" "workspace-symbols") :test #'string=))
               (not (and (integerp line) (not (minusp line))
                         (integerp character) (not (minusp character)))))
      (error "LSP ~a requires non-negative zero-based line and character" operation))
    (when (and (string= operation "workspace-symbols") (not (stringp query)))
      (error "workspace-symbols requires query"))
    (lsp-render (lsp-query-file (jget args "path") operation
                                :line line :character character :query query))))

(define-tool lsp-diagnostics (args)
    (:description "Ask configured language servers for current diagnostics on an existing source file. This is read-only; it synchronizes the saved file contents and returns structured push/pull diagnostic reports."
     :parameters (jobj "type" "object"
                       "properties" (jobj "path" (jobj "type" "string")
                                          "wait_seconds" (jobj "type" "integer" "minimum" 0 "description" "Optional time to wait for push diagnostics; default 1."))
                       "required" (list "path")))
  (let ((wait (jget args "wait_seconds" 1)))
    (unless (and (integerp wait) (not (minusp wait)))
      (error "wait_seconds must be a non-negative integer"))
    (lsp-render (lsp-file-diagnostics (jget args "path") :wait-seconds wait))))

(define-tool reload-lsp-servers (args)
    (:description "Reload the declarative LSP configuration and shut down any running language-server processes. Use after changing config-dir/lsp.sexp or installing a language server."
     :parameters (jobj "type" "object" "properties" (jobj)))
  (ignore-errors args)
  (multiple-value-bind (available unavailable) (initialize-lsp)
    (format nil "Reloaded ~d available LSP server~:p~@[; unavailable commands: ~{~a~^, ~}~]."
            (length available) unavailable)))
