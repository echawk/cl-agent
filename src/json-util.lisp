;;;; json-util.lisp -- thin, deliberately boring wrappers around shasht.
;;;;
;;;; shasht is very configurable (see its README for the full set of
;;;; *READ-*/*WRITE-* dynamic variables); rather than spread
;;;; configuration decisions across every file that touches JSON, we
;;;; make exactly one choice here and give it a name:
;;;;
;;;;   JSON objects <-> hash tables with STRING keys (shasht's default).
;;;;   JSON arrays   <-> plain Lisp lists (not vectors).
;;;;   JSON true/false/null <-> T / NIL / :NULL (shasht's default).
;;;;
;;;; Every other file in this project should go through JSON-ENCODE,
;;;; JSON-DECODE, JOBJ, and JGET rather than calling SHASHT: functions
;;;; directly, so that choice only has to be made once.

(in-package :cl-agent)

(defparameter *json-array-format* :list
  "We read JSON arrays as Lisp lists (not the shasht default of
vectors) because every array this project reads (tool-call lists,
message lists, choices...) is naturally processed with MAPCAR/DOLIST.")

(defun json-decode (string)
  "Parse STRING as JSON. Objects become hash tables keyed by string;
arrays become lists; true/false/null become T/NIL/:NULL."
  (let ((shasht:*read-default-array-format* *json-array-format*))
    (shasht:read-json string)))

(defun json-encode (value &key pretty)
  "Serialize VALUE (built from JOBJ / hash tables / lists / strings /
numbers / T / NIL / :NULL, see JOBJ's docstring) to a JSON string."
  (shasht:write-json* value :stream nil :pretty pretty))

(defun json-object-p (value)
  "True when VALUE is a JSON object in cl-agent's hash-table representation."
  (hash-table-p value))

(defun decode-json-object (text)
  "Decode TEXT as a JSON object.

Returns two values: the decoded hash table and NIL on success, or a harmless
empty object and a readable error on failure.  Tool-call arguments must be
objects even though JSON itself also permits arrays and scalars."
  (handler-case
      (let ((value (json-decode text)))
        (if (json-object-p value)
            (values value nil)
            (values (jobj) "expected a JSON object")))
    (error (condition)
      (values (jobj) (format nil "invalid JSON: ~a" condition)))))

(defun json-schema-validation-error (value schema &optional (path "arguments"))
  "Return NIL when VALUE conforms to the supported JSON-Schema subset.

The agent's tool schemas use object properties, required fields, primitive
types, arrays, and occasionally enum.  Validating that subset locally keeps
malformed model tool calls from reaching a handler without pretending to
implement all of JSON Schema.  The non-NIL return value is a model-readable
description of the first violation."
  (labels ((fail (format-control &rest arguments)
             (apply #'format nil format-control arguments))
           (matches-one-type-p (candidate type)
             (cond ((string= type "object") (json-object-p candidate))
                   ((string= type "array") (listp candidate))
                   ((string= type "string") (stringp candidate))
                   ((string= type "integer") (integerp candidate))
                   ((string= type "number") (numberp candidate))
                   ((string= type "boolean") (or (eq candidate t) (null candidate)))
                   ((string= type "null") (eq candidate :null))
                   ;; Unknown JSON-Schema types are outside this deliberately
                   ;; small validator and remain the provider's concern.
                   (t t)))
           (matches-type-p (candidate type)
             ;; JSON Schema permits either one type string or an array of
             ;; alternatives. MCP tools commonly use the latter, e.g.
             ;; ["boolean", "string"]. Treat it as a union instead of
             ;; passing the whole Lisp list to STRING=.
             (cond ((null type) t)
                   ((stringp type) (matches-one-type-p candidate type))
                   ((listp type) (some (lambda (option)
                                         (and (stringp option)
                                              (matches-one-type-p candidate option)))
                                       type))
                   (t t)))
           (type-description (type)
             (if (listp type)
                 (format nil "~{~a~^ or ~}" type)
                 type))
           (validate (candidate current-schema current-path)
             (let ((type (jget current-schema "type")))
               (cond
                 ((and type (not (matches-type-p candidate type)))
                  (fail "~a must be a JSON ~a" current-path (type-description type)))
                 ((and (jget current-schema "enum")
                       (not (member candidate (jget current-schema "enum") :test #'equal)))
                  (fail "~a must be one of the values allowed by its enum" current-path))
                 ((json-object-p candidate)
                  (let ((required (jget current-schema "required"))
                        (properties (jget current-schema "properties")))
                    ;; :EMPTY-ARRAY is our JSON-encoding sentinel for [];
                    ;; it denotes no required fields just like an empty list.
                    (dolist (name (if (listp required) required nil))
                      (unless (nth-value 1 (gethash name candidate))
                        (return-from validate (fail "~a.~a is required" current-path name))))
                    (when (json-object-p properties)
                      (loop for name being the hash-keys of properties using (hash-value property-schema)
                            do (multiple-value-bind (property presentp) (gethash name candidate)
                                 (when presentp
                                   (let ((problem (validate property property-schema
                                                            (format nil "~a.~a" current-path name))))
                                     (when problem (return-from validate problem)))))))))
                 ((and (listp candidate) (jget current-schema "items"))
                  (loop for item in candidate
                        for index from 0
                        for problem = (validate item (jget current-schema "items")
                                                (format nil "~a[~d]" current-path index))
                        when problem do (return problem)))))))
    (when (json-object-p schema)
      (validate value schema path))))

(defun jobj (&rest plist)
  "Build a JSON object (a hash table with STRING keys) from PLIST,
whose keys may be strings or symbols (symbols are converted with
STRING-DOWNCASE, so :TOOL-CALL-ID becomes \"tool-call-id\" -- for
wire fields with underscores, like \"tool_call_id\", pass the key as
a literal string instead). A value of NIL is written as JSON false and
:NULL as JSON null; use :EMPTY-OBJECT / :EMPTY-ARRAY for {} / [], an
ordinary empty list NIL is otherwise ambiguous with false.
Example: (jobj \"role\" \"user\" \"content\" text) => {\"role\":\"user\",...}"
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on plist by #'cddr
          do (setf (gethash (if (stringp k) k (string-downcase (string k))) h) v))
    h))

(defun jget (object key &optional default)
  "Look up KEY (a string, or a symbol converted via STRING-DOWNCASE)
in OBJECT, which must be a hash table as produced by JSON-DECODE.
Returns DEFAULT (NIL unless supplied) if OBJECT is not a hash table,
or the key is absent, or the key's value is the JSON null marker
:NULL -- callers never need to special-case :NULL themselves."
  (if (hash-table-p object)
      (let ((k (if (stringp key) key (string-downcase (string key)))))
        (multiple-value-bind (v presentp) (gethash k object)
          (if (and presentp (not (eq v :null))) v default)))
      default))

(defun jpath (object &rest keys)
  "Chained JGET: (jpath obj \"choices\" 0 \"message\" \"content\")
walks hash-table keys with JGET and list indices with NTH, returning
NIL as soon as any step is missing instead of signalling."
  (dolist (k keys object)
    (setf object
          (cond ((null object) (return nil))
                ((integerp k) (nth k object))
                (t (jget object k))))))

;;; --- bridging to libraries that represent JSON as alists ---
;;;
;;; Some of our dependencies (notably cl-mcp, see src/mcp/*.lisp) parse
;;; JSON into alists of (STRING . value) pairs rather than hash tables
;;; -- a perfectly normal, equally valid choice, just a different one
;;; than JSON-DECODE's (see this file's header comment for why we
;;; picked hash tables). Rather than let that difference leak into
;;; src/mcp/*.lisp as ad-hoc conversions, JALIST->HASH and JHASH->ALIST
;;; are the one place that translation happens, symmetric with JOBJ/
;;; JGET being the one place our own convention is defined.

(defun jalist-p (x)
  "True if X looks like an alist of (STRING . value) pairs, as
produced by a JSON parser configured for :object-as :alist. NIL itself
is ambiguous (an empty alist vs. an empty list vs. JSON false) and is
therefore NOT considered an alist here -- callers that know they have
an empty JSON object should just use (JOBJ)."
  (and (consp x) (every (lambda (pair) (and (consp pair) (stringp (car pair)))) x)))

(defun jalist->hash (x)
  "Recursively convert X -- as returned by a JSON parser configured
for :object-as :alist -- into the hash-table/list representation
JSON-DECODE produces, so the rest of cl-agent (JGET, JOBJ, JSON-ENCODE,
tool parameter schemas, ...) never needs to know the difference. Lists
that aren't alists are assumed to be JSON arrays and are mapped
element-wise; anything else (strings, numbers, T, NIL) passes through."
  (cond
    ((jalist-p x) (let ((h (make-hash-table :test 'equal)))
                    (dolist (pair x h) (setf (gethash (car pair) h) (jalist->hash (cdr pair))))))
    ((consp x) (mapcar #'jalist->hash x))
    (t x)))

(defun jhash->alist (x)
  "Inverse of JALIST->HASH: recursively convert hash tables (and the
plain lists JSON-ENCODE already treats as arrays) in X into the
alist-of-strings representation a library like cl-mcp expects."
  (cond
    ((hash-table-p x) (loop for k being the hash-keys of x using (hash-value v)
                             collect (cons k (jhash->alist v))))
    ((consp x) (mapcar #'jhash->alist x))
    (t x)))
