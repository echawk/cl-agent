;;;; package.lisp -- the one package cl-agent lives in.
;;;;
;;;; DESIGN NOTE FOR FUTURE EXTENDERS (including an LLM extending itself
;;;; at runtime via the `write-extension` / `eval-lisp` tools, see
;;;; extensions.lisp): this whole project deliberately lives in a single
;;;; package, :cl-agent.  A multi-package layout is more "proper" for a
;;;; large project, but it is actively hostile to an agent that writes
;;;; its own extension files on the fly -- it would have to track which
;;;; symbols live in which package.  Everything here is exported from
;;;; :cl-agent (nickname :agent) and extension files are expected to
;;;; start with (in-package :cl-agent) and just use whatever they need.
;;;;
;;;; If you are an LLM reading this to extend the agent: you are
;;;; encouraged to DEFINE new functions, classes, and hooks in this
;;;; package. You are also encouraged to use DEFGENERIC/DEFMETHOD and
;;;; CLOS subclassing rather than editing existing functions in place --
;;;; it is much safer to add a new provider class or wrap an existing
;;;; generic function with an :around method than to redefine a core
;;;; function from scratch, since a typo in a from-scratch redefinition
;;;; can brick the running image. See hooks.lisp for a lower-risk way to
;;;; alter behavior without redefining anything.

(defpackage :cl-agent
  (:nicknames :agent)
  (:use :cl)
  ;; MAIN is the only exported symbol: it's cl-agent.asd's :entry-point,
  ;; which ASDF reads with a package-qualified symbol (CL-AGENT:MAIN)
  ;; that must resolve to an external one. Nothing else needs exporting
  ;; -- see the design note above: everything else, extension code
  ;; included, is expected to just (in-package :cl-agent) and use
  ;; internal symbols directly rather than go through package exports.
  (:export #:main)
  (:documentation
   "cl-agent: a small, provider-agnostic, self-extending command-line
    coding agent.

    Subsystems, in load order (see cl-agent.asd):
      conditions.lisp          - condition types signalled throughout
      hooks.lisp                - the extension-point (hook) mechanism
      json-util.lisp            - shasht convenience wrappers
      http.lisp                  - drakma convenience wrappers
      config.lisp                - ~/.config/cl-agent/config.lisp loader
      tools.lisp                  - the TOOL class + registry + DEFINE-TOOL
      providers/*.lisp             - the LLM-PROVIDER class hierarchy
      extensions.lisp               - the self-modification subsystem
      tools/*.lisp                   - built-in tools (shell, self-extend)
      repl.lisp                       - the chat loop and REPL
      main.lisp                        - CLI entry point"))
