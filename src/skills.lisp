;;;; skills.lisp -- discovery and on-demand reads of Agent Skills.

(in-package :cl-agent)

(defvar *skill-catalog* nil "The current metadata-only cl-skills catalog.")

(defun skills-directory () (merge-pathnames "skills/" *config-directory*))
(defun project-skills-directory () (merge-pathnames ".agents/skills/" (uiop:getcwd)))
(defun skills-cache-directory () (merge-pathnames "skill-cache/" *config-directory*))

(defun skill-discovery-roots ()
  "Ordered existing roots. Project skills override user-wide skills."
  (remove-if-not #'probe-file (list (project-skills-directory) (skills-directory))))

(defun initialize-skills ()
  "Discover Skills without loading their instruction bodies.

The catalog is deliberately metadata-only until READ-SKILL asks cl-skills to
re-open the selected, validated source. Discovery is read-only: merely listing
Skills must work even where a config directory cannot be created."
  (setf *skill-catalog*
        (cl-skills:skill-catalog-discover (skill-discovery-roots)))
  ;; Skills are metadata-only at this stage; publishing them does not read their
  ;; instruction bodies or alter their normal on-demand loading behaviour.
  (dolist (row (list-skills))
    (destructuring-bind (name description path) row
      (publish-component :skill name :owner "skills"
                         :origin (list :skill path)
                         :metadata (list :description description :path path))))
  *skill-catalog*)

(defun ensure-skill-catalog () (or *skill-catalog* (initialize-skills)))

(defun list-skills ()
  "Return selected Skills as (NAME DESCRIPTION PATH) rows."
  (mapcar (lambda (skill)
            (list (cl-skills:skill-metadata-name skill)
                  (cl-skills:skill-metadata-description skill)
                  (namestring (cl-skills:skill-metadata-pathname skill))))
          (cl-skills:skill-catalog-skills (ensure-skill-catalog))))

(defun read-skill (name)
  "Read the instructions for the selected Skill NAME, or signal a useful error."
  (unless (and (stringp name) (plusp (length (string-trim " " name))))
    (error "Skill name must be a non-empty string"))
  (let ((skill (cl-skills:skill-catalog-find (ensure-skill-catalog) name)))
    (unless skill (error "No discovered Skill named ~s. Call list-skills first." name))
    (cl-skills:skill-metadata-read skill)))
