;;;; tools/skills-tool.lisp -- metadata-first Agent Skills for the model.

(in-package :cl-agent)

(define-tool list-skills (args)
    (:description "List available Agent Skills by name and description. Skills contain focused instructions and are not loaded into context until you choose one with read-skill. Use this before work that may have a specialized workflow."
     :parameters (jobj "type" "object" "properties" (jobj)))
  (ignore-errors args)
  (let ((skills (list-skills)))
    (if skills
        (format nil "~{~a — ~a~^~%~}" skills)
        "No Skills discovered. Add standard SKILL.md files under .agents/skills/ in this project or ~/.config/cl-agent/skills/.")))

(define-tool read-skill (args)
    (:description "Read the complete instructions for one Skill previously listed by list-skills. Use the Skill's exact name. The instructions are validated and read on demand."
     :parameters (jobj "type" "object"
                       "properties" (jobj "name" (jobj "type" "string"))
                       "required" (list "name")))
  (read-skill (jget args "name")))

(define-tool reload-skills (args)
    (:description "Rescan project and user Skill directories after adding, removing, or changing a Skill. This only refreshes metadata; use read-skill to load instructions."
     :parameters (jobj "type" "object" "properties" (jobj)))
  (ignore-errors args)
  (let ((catalog (initialize-skills)))
    (format nil "Discovered ~d Skill~:p~@[; ~d scan diagnostic~:p~]."
            (length (cl-skills:skill-catalog-skills catalog))
            (length (cl-skills:skill-catalog-diagnostics catalog)))))
