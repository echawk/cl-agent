;;;; asdf-tool.lisp -- load libraries through the ocicl-enabled ASDF image.

(in-package :cl-agent)

(define-tool load-asdf-system (args)
    (:description "Load a Common Lisp library by ASDF system name into the running agent image. ASDF is configured by boot.lisp with ocicl's missing-system hook, so an unavailable dependency is fetched through ocicl automatically; do not curl .asd files. Returns the loaded system's name and version, or an actionable ASDF/ocicl error."
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "system" (jobj "type" "string" "description" "ASDF system name, e.g. alexandria or cl-ppcre."))
           "required" (list "system")))
  (let ((name (jget args "system")))
    (unless (and (stringp name) (plusp (length name)))
      (error "load-asdf-system requires a non-empty string \"system\" argument"))
    (handler-case
        (progn
          (asdf:load-system name :verbose nil)
          (let ((system (asdf:find-system name)))
            (format nil "Loaded ASDF system ~a~@[ version ~a~]."
                    (asdf:component-name system) (asdf:component-version system))))
      (error (condition)
        ;; This path is often an ocicl/ASDF resolution failure, not evidence
        ;; that the requested library lives somewhere else on disk.  Return a
        ;; bounded diagnostic to the model so it can reason about the package
        ;; manager instead of launching broad filesystem searches.
        (format nil "Could not load ASDF system ~a: ~a~%~
                     Dependency resolution failed before the system loaded. ~
                     Do not search the filesystem broadly for the library; ~
                     inspect the package-manager or ASDF error directly."
                name condition)))))
