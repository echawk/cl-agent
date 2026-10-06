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
    (asdf:load-system name :verbose nil)
    (let ((system (asdf:find-system name)))
      (format nil "Loaded ASDF system ~a~@[ version ~a~]."
              (asdf:component-name system) (asdf:component-version system)))))
