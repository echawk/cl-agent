;;;; boot.lisp -- ocicl bootstrap, shared by `make run`, `make build`, and
;;;; `make test`.  This is the only file that needs to know ocicl exists;
;;;; everything else just does (asdf:load-system "cl-agent").
;;;;
;;;; What this does, in order:
;;;;  1. Loads the ocicl-runtime (if not already built into this Lisp image),
;;;;     which teaches ASDF how to auto-fetch a system it can't find by
;;;;     shelling out to the `ocicl` CLI.
;;;;  2. Points ASDF's source-registry at this project directory, so it
;;;;     finds cl-agent.asd, plus third-party/ (recursively), which
;;;;     holds small vendored ASDF systems that aren't ocicl packages
;;;;     themselves -- currently just opsis-conditions-stub, see that
;;;;     directory's header comment for why it exists.
;;;;  3. Registers one extra :DIRECTORY entry per package listed in
;;;;     ocicl.csv (see OCICL-PACKAGE-DIRECTORIES below) -- needed
;;;;     because ocicl.csv keys a package by its PRIMARY system name,
;;;;     so the ocicl-runtime's "fetch on demand" hook (loaded above)
;;;;     can resolve e.g. "cl-mcp" by name but not a SECONDARY system
;;;;     defined in the same .asd file, like "cl-mcp/client". A plain
;;;;     ASDF directory scan finds every system in a .asd file
;;;;     regardless of name, so this covers that gap. (A recursive
;;;;     :TREE over the whole ocicl/ directory would also do this, but
;;;;     risks ambiguity if more than one version of the same package
;;;;     ever ends up on disk at once; going exactly by ocicl.csv's own
;;;;     pinned paths doesn't have that risk.)
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

(defun ocicl-package-directories ()
  "Parse ocicl.csv (format: NAME, OCI-REF, RELATIVE/PATH/TO/SYSTEM.asd)
and return the unique set of directories its third column's .asd files
live in, as absolute pathnames under ocicl/. Returns NIL quietly if
ocicl.csv doesn't exist yet (first run, before `ocicl install`)."
  (let ((csv (merge-pathnames "ocicl.csv" (uiop:getcwd))))
    (when (probe-file csv)
      (remove-duplicates
       (with-open-file (in csv)
         (loop for line = (read-line in nil nil)
               while line
               for comma2 = (position #\, line :from-end t)
               when comma2
                 collect (uiop:pathname-directory-pathname
                          (merge-pathnames (string-trim " " (subseq line (1+ comma2)))
                                           (merge-pathnames "ocicl/" (uiop:getcwd))))))
       :test #'equal))))

(asdf:initialize-source-registry
 (list* :source-registry
        (list :directory (uiop:getcwd))
        (list :tree (merge-pathnames "third-party/" (uiop:getcwd)))
        (append (mapcar (lambda (dir) (list :directory dir)) (ocicl-package-directories))
                (list :inherit-configuration))))
