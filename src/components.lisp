;;;; components.lisp -- data-only reflection over cl-agent extension points.

(in-package :cl-agent)

(defstruct component-descriptor
  id kind name origin source-digest owner version status enabled-p
  provides requires effects config-schema health metadata)

(defvar *components* (make-hash-table :test #'equal)
  "Logical component ID -> COMPONENT-DESCRIPTOR.  Behaviour stays in the
existing registries; this table is its inspectable projection.")

(defvar *registration-origin* nil
  "Dynamically bound by extension and MCP loaders to provenance data.")
(defvar *registration-owner* nil
  "Dynamically bound owner ID for components registered by a loader.")

(defun component-id (kind name)
  (format nil "~(~a~):~a" kind (string-downcase (string name))))

(defun registration-source ()
  "Best available source provenance without requiring implementation internals."
  (or *registration-origin*
      (list :core (if *load-truename* (namestring *load-truename*) "runtime"))))

(defun registration-source-digest (origin)
  "Return a lightweight content fingerprint for a pathname origin, if readable.

This is intentionally an advisory fingerprint, not a cryptographic integrity
claim; the durable store will later provide content-addressed SHA-256 blobs."
  (let ((path (and (consp origin) (second origin))))
    (when (and path (probe-file path) (not (uiop:directory-pathname-p path)))
      (ignore-errors (format nil "sxhash:~36r" (sxhash (uiop:read-file-string path)))))))

(defun publish-component (kind name &rest initargs)
  "Publish or replace a data-only descriptor while leaving existing registry
contracts untouched.  Replacement increments the logical component version."
  (let* ((id (component-id kind name))
         (old (gethash id *components*))
         (origin (or (getf initargs :origin) (registration-source)))
         (owner (or (getf initargs :owner) *registration-owner* "core"))
         (descriptor
           (make-component-descriptor
            :id id :kind kind :name (string-downcase (string name))
            :origin origin :source-digest (or (getf initargs :source-digest)
                                              (registration-source-digest origin))
            :owner owner
            :version (1+ (or (and old (component-descriptor-version old)) 0))
            :status (or (getf initargs :status) :active)
            :enabled-p (if (member :enabled-p initargs)
                           (getf initargs :enabled-p) t)
            :provides (getf initargs :provides)
            :requires (getf initargs :requires)
            :effects (getf initargs :effects)
            :config-schema (getf initargs :config-schema)
            :health (or (getf initargs :health) (list :status :unknown))
            :metadata (getf initargs :metadata))))
    (setf (gethash id *components*) descriptor)
    (emit-event (if old :component-replaced :component-registered)
                :component id :payload (component->plist descriptor))
    descriptor))

(defun unpublish-component (kind name)
  "Remove a descriptor and emit an observation event."
  (let* ((id (component-id kind name)) (old (gethash id *components*)))
    (when old
      (remhash id *components*)
      (emit-event :component-unregistered :component id
                  :payload (component->plist old)))
    old))

(defun retire-components-owned-by (owner)
  "Retire descriptors owned by OWNER.  Callers remain responsible for removing
the corresponding behaviour from their registry before calling this helper."
  (let ((retired nil))
    (maphash (lambda (id descriptor)
               (when (equal owner (component-descriptor-owner descriptor))
                 (push descriptor retired) (remhash id *components*)
                 (emit-event :component-unregistered :component id
                             :payload (component->plist descriptor))))
             *components*)
    (nreverse retired)))

(defun list-components (&key kind owner)
  "Return descriptors, deterministically sorted by stable component ID."
  (sort (loop for descriptor being the hash-values of *components*
              when (and (or (null kind) (eql kind (component-descriptor-kind descriptor)))
                        (or (null owner) (equal owner (component-descriptor-owner descriptor))))
              collect descriptor)
        #'string< :key #'component-descriptor-id))

(defun describe-component (id)
  "Return the descriptor for stable ID, or NIL when it is inactive/unknown."
  (gethash (string-downcase (string id)) *components*))

(defun component->plist (descriptor)
  "Serialize DESCRIPTOR without exposing functions, classes, or registry objects."
  (when descriptor
    (list :id (component-descriptor-id descriptor)
          :kind (component-descriptor-kind descriptor)
          :name (component-descriptor-name descriptor)
          :origin (component-data-only (component-descriptor-origin descriptor))
          :source-digest (component-data-only (component-descriptor-source-digest descriptor))
          :owner (component-descriptor-owner descriptor)
          :version (component-descriptor-version descriptor)
          :status (component-descriptor-status descriptor)
          :enabled-p (component-descriptor-enabled-p descriptor)
          :provides (component-data-only (component-descriptor-provides descriptor))
          :requires (component-data-only (component-descriptor-requires descriptor))
          :effects (component-data-only (component-descriptor-effects descriptor))
          :config-schema (component-data-only (component-descriptor-config-schema descriptor))
          :health (component-data-only (component-descriptor-health descriptor))
          :metadata (component-data-only (component-descriptor-metadata descriptor)))))

(defun component-data-only (value)
  "Convert extension-supplied descriptor fields to inspectable data.

The reflection API must never accidentally hand a JSON/UI caller a function,
class, CLOS instance, or hash table containing one. Unknown objects therefore
become their readable representation rather than retaining live identity."
  (typecase value
    ((or null string number character keyword symbol pathname) value)
    (function "<function>")
    (class (format nil "<class ~a>" (class-name value)))
    (hash-table (loop for key being the hash-keys of value using (hash-value item)
                      collect (cons (component-data-only key) (component-data-only item))))
    (cons (mapcar #'component-data-only value))
    (t (princ-to-string value))))

(defun component-graph ()
  "Return a readable data graph of component dependency/provenance edges."
  (loop for descriptor in (list-components)
        append (append
                (mapcar (lambda (required) (list :from (component-descriptor-id descriptor)
                                                  :relation :requires :to required))
                        (or (component-descriptor-requires descriptor) '()))
                (list (list :from (component-descriptor-id descriptor)
                            :relation :owned-by :to (component-descriptor-owner descriptor))))))

(defun component-summary (descriptor)
  "One-line, UI-neutral descriptor rendering."
  (format nil "~a [~(~a~), owner ~a, v~d]"
          (component-descriptor-id descriptor) (component-descriptor-kind descriptor)
          (component-descriptor-owner descriptor) (component-descriptor-version descriptor)))
