;;;; boot.lisp -- ocicl bootstrap, shared by `make run`, `make build`, and
;;;; `make test`.  This is the only file that needs to know ocicl exists;
;;;; everything else just does (asdf:load-system "cl-agent").
;;;;
;;;; What this does, in order:
;;;;  1. Loads the ocicl-runtime (if not already built into this Lisp image),
;;;;     which teaches ASDF how to auto-fetch a system it can't find by
;;;;     shelling out to the `ocicl` CLI.
;;;;  2. Points ASDF's source-registry at this project directory, so it
;;;;     finds cl-agent.asd and the ./ocicl/*/*.asd trees that `ocicl
;;;;     install` populates from the committed ocicl.csv lockfile.
;;;;
;;;; Safe to load more than once.

#-ocicl
(let ((runtime (merge-pathnames ".local/share/ocicl/ocicl-runtime.lisp"
                                 (user-homedir-pathname))))
  (if (probe-file runtime)
      (load runtime)
      (error "ocicl-runtime.lisp not found at ~a~%~
              Install ocicl first: https://github.com/ocicl/ocicl~%~
              then run `ocicl setup` once." runtime)))

(asdf:initialize-source-registry
 (list :source-registry
       (list :directory (uiop:getcwd))
       :inherit-configuration))
