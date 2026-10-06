(in-package :cl-agent)

(deftest write-extension-file-writes-under-extensions-dir ()
  (with-temp-config-dir ()
    (let ((path (write-extension-file "foo" "(in-package :cl-agent)")))
      (check (probe-file path))
      (check-equal (pathname-name path) "foo")
      (check-equal (pathname-type path) "lisp")
      (check-equal (pathname-directory path) (pathname-directory (extensions-directory))))))

(deftest write-extension-file-adds-lisp-suffix-if-missing ()
  (with-temp-config-dir ()
    (let ((path (write-extension-file "bar" "(in-package :cl-agent)")))
      (check-equal (file-namestring path) "bar.lisp"))))

(deftest write-extension-file-suffix-not-doubled ()
  (with-temp-config-dir ()
    (let ((path (write-extension-file "baz.lisp" "(in-package :cl-agent)")))
      (check-equal (file-namestring path) "baz.lisp"))))

(deftest write-scratch-file-is-confined-and-not-an-extension ()
  (with-temp-config-dir ()
    (let ((path (write-scratch-file "experiment.lisp" "(format t \"hello\")")))
      (check (probe-file path))
      (check-equal (pathname-directory path) (pathname-directory (scratch-directory)))
      (check-equal (uiop:read-file-string path) "(format t \"hello\")")
      (check-equal (list-extension-files) nil))
    (check-condition error (write-scratch-file "../outside.lisp" "nope"))))

(deftest write-scratch-file-tool-saves-without-evaluation ()
  (with-temp-config-dir ()
    (let ((result (call-tool "write-scratch-file"
                             (jobj "filename" "one-off.lisp"
                                   "contents" "(error \"must not run\")"))))
      (check (search "not compiled, loaded, enabled, or evaluated" result))
      (check (probe-file (merge-pathnames "one-off.lisp" (scratch-directory)))))))

(deftest write-extension-rejects-standalone-programs ()
  (with-temp-config-dir ()
    (let ((result (call-tool "write-extension"
                             (jobj "filename" "scratch-by-mistake.lisp"
                                   "source" "(in-package :cl-agent) (defun* scratch-only () 42)"))))
      (check (search "does not add a durable cl-agent integration" result))
      (check (not (probe-file (merge-pathnames "scratch-by-mistake.lisp"
                                                   (extensions-directory))))))))

(deftest fresh-install-enables-everything-by-default ()
  (with-temp-config-dir ()
    (ensure-config-directory)
    (check (extension-enabled-p "anything.lisp")
           "no enabled.lisp yet => :all => everything is enabled")))

(deftest set-extension-enabled-is-persistent-and-selective ()
  (with-temp-config-dir ()
    (ensure-config-directory)
    (write-extension-file "a" "(in-package :cl-agent)")
    (write-extension-file "b" "(in-package :cl-agent)")
    (set-extension-enabled "a.lisp" nil)
    (check-equal (extension-enabled-p "a.lisp") nil)
    (check (extension-enabled-p "b.lisp")
           "disabling a.lisp converted :all to an explicit list that still includes b.lisp")
    (set-extension-enabled "a.lisp" t)
    (check (extension-enabled-p "a.lisp"))))

(deftest load-extension-file-actually-loads-into-the-image ()
  (with-temp-config-dir ()
    (let ((path (write-extension-file
                 "live"
                 "(in-package :cl-agent)
                  (define-tool extension-smoke-test-tool (args) (:description \"d\")
                    \"loaded-ok\")")))
      (load-extension-file path)
      (check-equal (call-tool "extension-smoke-test-tool" (jobj)) "loaded-ok")
      (unregister-tool "extension-smoke-test-tool"))))

(deftest load-extension-file-wraps-errors ()
  (with-temp-config-dir ()
    (let ((path (write-extension-file "broken" "(in-package :cl-agent) (this-is-not-a-real-function)")))
      (check-condition extension-error (load-extension-file path)))))

(deftest load-enabled-extensions-skips-disabled-ones ()
  (with-temp-config-dir ()
    (write-extension-file "enabled-one"
                           "(in-package :cl-agent)
                            (define-tool ext-enabled-marker (args) (:description \"d\") \"x\")")
    (write-extension-file "disabled-one"
                           "(in-package :cl-agent)
                            (define-tool ext-disabled-marker (args) (:description \"d\") \"x\")")
    (set-extension-enabled "disabled-one.lisp" nil)
    (load-enabled-extensions)
    (check (find-tool "ext-enabled-marker"))
    (check-equal (find-tool "ext-disabled-marker") nil)
    (unregister-tool "ext-enabled-marker")))

(deftest load-enabled-extensions-one-broken-file-does-not-stop-others ()
  (with-temp-config-dir ()
    (write-extension-file "a-broken" "(in-package :cl-agent) (clearly-undefined-fn-xyz)")
    (write-extension-file "z-good"
                           "(in-package :cl-agent)
                            (define-tool ext-good-marker (args) (:description \"d\") \"x\")")
    (multiple-value-bind (loaded failed) (load-enabled-extensions :report-stream (make-broadcast-stream))
      (check-equal (length failed) 1)
      (check-equal (length loaded) 1))
    (check (find-tool "ext-good-marker"))
    (unregister-tool "ext-good-marker")))
