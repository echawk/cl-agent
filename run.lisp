;;;; run.lisp -- dev entry point: `sbcl --script run.lisp -- [args...]`
;;;; Loads the system from source (no build step) and calls cl-agent:main.
;;;; `make run` uses this.

(load (merge-pathnames "boot.lisp" *load-pathname*))
(asdf:load-system "cl-agent")
(cl-agent:main)
