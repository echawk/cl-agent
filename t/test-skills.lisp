(in-package :cl-agent)

(deftest skills-discover-metadata-and-read-on-demand ()
  (with-temp-config-dir ()
    ;; Project skills come from the working directory's .agents/skills/: a
    ;; session in the temporary one, not the checkout this runs in.
    (let* ((*current-session* (make-session (make-instance 'ollama-provider :model "m")
                                            :working-directory (uiop:ensure-directory-pathname *config-directory*)))
           (*skill-catalog* nil)
           (directory (merge-pathnames "release-notes/" (skills-directory)))
           (source (merge-pathnames "SKILL.sexp" directory)))
      (ensure-directories-exist source)
      (with-open-file (out source :direction :output :if-exists :supersede)
        (format out "(:autolith-skill :version 1 :name \"release-notes\"~% :description \"Prepare release notes.\"~% :instructions \"Read CHANGELOG.md and summarize user-visible changes.\")"))
      (check-equal (mapcar #'first (list-skills)) '("release-notes"))
      (check (search "summarize user-visible" (read-skill "release-notes")))
      (check (find-tool "list-skills"))
      (check (find-tool "read-skill")))))
