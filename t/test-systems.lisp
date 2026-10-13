;;;; t/test-systems.lisp -- ASDF systems in a saved image, and ocicl fetching
;;;; into the config directory, never the working directory (systems.lisp).

(in-package :cl-agent)

(defmacro with-saved-ocicl-runtime (() &body body)
  "Run BODY, then put back the ocicl runtime's settings, the search functions,
the init hooks and *AGENT-SYSTEMS-ACTIVE*."
  `(let ((saved (mapcar (lambda (name) (let ((symbol (ocicl-runtime-symbol name)))
                                         (and symbol (cons symbol (symbol-value symbol)))))
                        '("*DOWNLOAD*" "*LOCAL-SYSTEMS-DIR*" "*LOCAL-SYSTEMS-CSV*" "*LOCAL-OCICL-SYSTEMS*"
                          "*LOCAL-SYSTEMS-CSV-TIMESTAMP*")))
         (search asdf:*system-definition-search-functions*)
         (init sb-ext:*init-hooks*)
         (active *agent-systems-active*)
         (files *image-system-files*))
     (unwind-protect (progn ,@body)
       (dolist (pair saved) (when pair (setf (symbol-value (car pair)) (cdr pair))))
       (setf asdf:*system-definition-search-functions* search
             sb-ext:*init-hooks* init
             *agent-systems-active* active
             *image-system-files* files))))

(deftest a-saved-image-finds-its-systems-again ()
  (with-saved-ocicl-runtime ()
    (check (member 'prepare-image-systems uiop:*image-dump-hook*) "runs when the image is saved")
    (prepare-image-systems)
    (check-equal (first sb-ext:*init-hooks*) 'cl-agent-image-init
                 "first, before a library's own init hook asks ASDF for itself")
    (check (uiop:pathname-equal (image-system-searcher "cl-agent")
                                (truename (asdf:system-source-file (asdf:find-system "cl-agent")))))
    (check (null (image-system-searcher "no-such-system-xyz")))
    (set-ocicl-fetching t)
    (cl-agent-image-init)
    (check-equal (first asdf:*system-definition-search-functions*) 'image-system-searcher)
    (when (ocicl-runtime-symbol "*DOWNLOAD*")
      (check (null (symbol-value (ocicl-runtime-symbol "*DOWNLOAD*"))) "no fetching on its own"))))

(deftest ocicl-installs-into-the-config-directory-not-the-working-one ()
  (if (null (ocicl-runtime-symbol "OCICL-INSTALL"))
      (format t "~&  (skipped: no ocicl runtime in this image)~%")
      (with-saved-ocicl-runtime ()
        ;; A fake ocicl that records where it ran.
        (let* ((bin (merge-pathnames "fake-bin/" *config-directory*))
               (record (merge-pathnames "ran-in.txt" *config-directory*))
               (path (uiop:getenv "PATH")))
          (ensure-directories-exist bin)
          (with-open-file (out (merge-pathnames "ocicl" bin) :direction :output :if-exists :supersede)
            (format out "#!/bin/sh~%pwd -P > '~a'~%" (uiop:native-namestring record)))
          (uiop:run-program (list "chmod" "+x" (uiop:native-namestring (merge-pathnames "ocicl" bin))))
          (unwind-protect
               (progn
                 (setf (uiop:getenv "PATH") (format nil "~a:~a" (uiop:native-namestring bin) path))
                 (let ((directory (use-agent-systems-directory)))
                   (check (uiop:pathname-equal directory (merge-pathnames "systems/" *config-directory*)))
                   (check (uiop:pathname-equal (symbol-value (ocicl-runtime-symbol "*LOCAL-SYSTEMS-CSV*"))
                                               (merge-pathnames "systems/ocicl.csv" *config-directory*)))
                   (funcall (ocicl-runtime-symbol "OCICL-INSTALL") "some-system")
                   (check (uiop:pathname-equal
                           (uiop:ensure-directory-pathname (string-trim '(#\Newline) (uiop:read-file-string record)))
                           (truename directory))
                          "ran in config/systems/, not the working directory")))
            (setf (uiop:getenv "PATH") path))))))

(deftest only-load-asdf-system-may-fetch ()
  (with-saved-ocicl-runtime ()
    (let ((download (ocicl-runtime-symbol "*DOWNLOAD*")))
      (when download
        (set-ocicl-fetching nil)
        (with-ocicl-fetching ()
          (check (symbol-value download) "inside the tool's load"))
        (check (null (symbol-value download)) "and off again after")))
    (check (search "Loaded ASDF system alexandria" (call-tool "load-asdf-system" (jobj "system" "alexandria"))))))
