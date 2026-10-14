;;;; logic.lisp -- a logic engine for the agent: knowledge bases of facts,
;;;; rules and constraints it can query, check and order, on cl-kanren.
;;;;
;;;; A model plans by guessing; this lets it prove instead.  It writes what it
;;;; knows as facts -- (depends-on "api.py" "db.py") -- or has them read out of
;;;; the source (INDEX-SOURCE-FACTS: files, definitions, references, calls,
;;;; imports, by tree-sitter); adds rules -- (<- (reaches ?a ?c) (depends-on
;;;; ?a ?b) (reaches ?b ?c)); asks questions -- (reaches "main.py" ?x); states
;;;; constraints that must hold -- (constraint no-cycle "?a needs itself"
;;;; (reaches ?a ?a)) -- and checks them after every step of a refactor; and
;;;; orders work by a dependency relation, cycles called out.
;;;;
;;;; Terms are read from text with *READ-EVAL* off into a package of their
;;;; own: ?x is a variable (? and ?_ anonymous), a string or number is
;;;; itself, any other symbol is its name, downcased.  Facts are atoms only.
;;;;
;;;; Queries run on cl-kanren's microKanren: a fact goal is a kanren goal
;;;; (state -> stream) over the knowledge base, using a hash index on any
;;;; argument already bound; (and ...) and (or ...) are its CONJ and DISJ;
;;;; (not G) is negation as failure; = unifies; /= < <= > >= contains prefix
;;;; suffix compare bound values.  In a conjunction the positive goals run
;;;; first, so negations and comparisons see their variables bound.
;;;;
;;;; Rules are materialized bottom-up to a fixpoint (each body a kanren
;;;; query): recursive rules -- transitive closure -- always terminate, even
;;;; over cyclic graphs, where a top-down miniKanren search would not.  Rules
;;;; using not are stratified: a relation is derived before any rule negates
;;;; it, and negation through recursion is refused.
;;;;
;;;; The kanren layer is LOGIC-FACT-GOAL, LOGIC-CONJ/DISJ, LOGIC-NOT and
;;;; LOGIC-RUN-GOAL: a faster miniKanren (si-kanren) would replace just those.
;;;; Knowledge bases persist under config/logic/<name>.sexp.

(in-package :cl-agent)

(defparameter *logic-max-derived* 400000
  "The most facts rules may derive in one knowledge base.")

(defparameter *logic-max-forms* 20000
  "The most forms one call may read.")

;;; --- relations and knowledge bases ---

(defstruct (logic-relation (:constructor make-logic-relation (name)))
  name
  (tuples '())
  (count 0)
  (set (make-hash-table :test 'equal))
  (index (make-hash-table :test 'equal)))

(defun relation-add (relation tuple)
  "Add TUPLE (a list of atoms) to RELATION; NIL when it was there."
  (unless (gethash tuple (logic-relation-set relation))
    (setf (gethash tuple (logic-relation-set relation)) t)
    (push tuple (logic-relation-tuples relation))
    (incf (logic-relation-count relation))
    (loop for value in tuple
          for position from 0
          do (push tuple (gethash (cons position value) (logic-relation-index relation))))
    t))

(defun relation-candidates (relation position value)
  (if position
      (gethash (cons position value) (logic-relation-index relation))
      (logic-relation-tuples relation)))

(defstruct (logic-kb (:constructor make-logic-kb (name)))
  name
  (base (make-hash-table :test 'equal))      ; relation name -> LOGIC-RELATION
  (derived (make-hash-table :test 'equal))   ; what the rules derived
  (rules '())                                ; (head . body) forms, in order
  (constraints '())                          ; (name message . goals)
  (stale t))                                 ; rules not yet derived since a change

(defvar *logic-kbs* (make-hash-table :test 'equal))
(defvar *logic-lock* (bt:make-recursive-lock "logic"))

;;; --- reading terms ---

(defpackage :cl-agent-logic-terms (:use))

(defun read-logic-forms (text)
  "The forms in TEXT, read safely (no #., symbols kept apart)."
  (unless (stringp text) (error "Give the forms as text."))
  (let ((*read-eval* nil)
        (*package* (find-package :cl-agent-logic-terms))
        (*read-default-float-format* 'double-float)
        (forms '()))
    (with-input-from-string (in text)
      (loop for form = (handler-case (read in nil in)
                         (reader-error (condition) (error "Could not read the forms: ~a" condition))
                         (end-of-file () (error "The forms end early: a parenthesis is not closed.")))
            until (eq form in)
            do (push form forms)
               (when (> (length forms) *logic-max-forms*)
                 (error "More than ~d forms in one call." *logic-max-forms*))))
    (nreverse forms)))

(defun logic-variable-p (term)
  (and (symbolp term) (not (keywordp term)) term
       (let ((name (symbol-name term))) (and (plusp (length name)) (char= (char name 0) #\?)))))

(defun logic-atom (term)
  "TERM as a stored value: a string or number."
  (cond ((stringp term) term)
        ((integerp term) term)
        ((realp term) term)
        ((and (symbolp term) term) (string-downcase (symbol-name term)))
        ((null term) "nil")
        (t (error "~s is not an atom: facts hold strings, numbers and names." term))))

(defun logic-name (term)
  (if (and (symbolp term) term (not (logic-variable-p term)))
      (string-downcase (symbol-name term))
      (error "~s is not a relation name." term)))

(defun format-logic-value (value)
  (cond ((stringp value) (prin1-to-string value))
        ((mu-kanren:mu-var-p value) "_")
        (t (princ-to-string value))))

(defun format-logic-tuple (name tuple)
  (format nil "(~a~{ ~a~})" name (mapcar #'format-logic-value tuple)))

;;; --- the kanren layer ---
;;;
;;; cl-kanren's TAKE and its BIND/MPLUS over fully built (mature) streams
;;; recurse once per element, which exhausts the stack on thousands of
;;; facts.  So a fact goal yields its matches lazily -- each tail a thunk,
;;; which BIND and MPLUS interleave without recursing -- and LOGIC-TAKE pulls
;;; a stream in a loop.

(defun lazy-states (states)
  "STATES (a list) as a kanren stream whose every tail is a thunk."
  (when states
    (cons (car states) (lambda () (lazy-states (cdr states))))))

(defun logic-take (n stream)
  "The first N states of kanren STREAM (all of them when N is NIL), iteratively."
  (let ((out '()) (count 0))
    (loop
      (when (and n (>= count n)) (return))
      (loop while (functionp stream) do (setf stream (funcall stream)))
      (when (null stream) (return))
      (push (car stream) out)
      (incf count)
      (setf stream (cdr stream)))
    (nreverse out)))

(defun logic-relations-named (kb name)
  (remove nil (list (gethash name (logic-kb-base kb)) (gethash name (logic-kb-derived kb)))))

(defun logic-fact-goal (kb name args)
  "A kanren goal: ARGS (terms: kanren variables or atoms) unify with a fact
of relation NAME, by the index on its first bound argument."
  (lambda (s/c)
    (let* ((subst (car s/c))
           (walked (mapcar (lambda (arg) (mu-kanren:walk arg subst)) args))
           (bound (position-if-not #'mu-kanren:mu-var-p walked))
           (states '()))
      (dolist (relation (logic-relations-named kb name))
        (dolist (tuple (relation-candidates relation bound (and bound (nth bound walked))))
          (when (= (length tuple) (length walked))
            (let ((s subst))
              (loop for arg in walked
                    for value in tuple
                    do (setf s (mu-kanren:unify arg value s))
                    until (mu-kanren:failed-unification-p s))
              (unless (mu-kanren:failed-unification-p s)
                (push (cons s (cdr s/c)) states))))))
      (lazy-states (nreverse states)))))

(defun logic-conj (goals)
  (if (null goals) (lambda (s/c) (mu-kanren:unit s/c)) (reduce #'mu-kanren:conj goals)))

(defun logic-disj (goals)
  (if (null goals) (lambda (s/c) (declare (ignore s/c)) mu-kanren:+mzero+) (reduce #'mu-kanren:disj goals)))

(defun logic-not (goal)
  "Negation as failure: succeed, binding nothing, when GOAL has no solution."
  (lambda (s/c)
    (if (logic-take 1 (funcall goal s/c)) mu-kanren:+mzero+ (mu-kanren:unit s/c))))

(defun logic-test (name test args)
  "A goal true when TEST holds of ARGS' values, which must be bound."
  (lambda (s/c)
    (let ((values (mapcar (lambda (arg) (interface:walk* arg (car s/c))) args)))
      (when (some #'mu-kanren:mu-var-p values)
        (error "(~a ...) needs its variables bound by a fact goal before it." name))
      (if (apply test values) (mu-kanren:unit s/c) mu-kanren:+mzero+))))

(defun logic-run-goal (goal variable-count limit)
  "The first LIMIT (all, when NIL) states GOAL reaches from the empty state."
  (let ((stream (funcall goal (cons '() variable-count))))
    (logic-take limit stream)))

;;; --- compiling goals ---

(defparameter *logic-tests*
  `(("/=" . ,(lambda (a b) (not (equalp a b))))
    ("<" . ,(lambda (a b) (if (and (realp a) (realp b)) (< a b) (and (string< (princ-to-string a) (princ-to-string b)) t))))
    ("<=" . ,(lambda (a b) (if (and (realp a) (realp b)) (<= a b) (and (string<= (princ-to-string a) (princ-to-string b)) t))))
    (">" . ,(lambda (a b) (if (and (realp a) (realp b)) (> a b) (and (string> (princ-to-string a) (princ-to-string b)) t))))
    (">=" . ,(lambda (a b) (if (and (realp a) (realp b)) (>= a b) (and (string>= (princ-to-string a) (princ-to-string b)) t))))
    ("contains" . ,(lambda (a b) (and (search (princ-to-string b) (princ-to-string a)) t)))
    ("prefix" . ,(lambda (a b) (uiop:string-prefix-p (princ-to-string b) (princ-to-string a))))
    ("suffix" . ,(lambda (a b) (uiop:string-suffix-p (princ-to-string a) (princ-to-string b)))))
  "Tests on bound values: (/= a b), (< a b), (contains text part), ...")

(defun check-relation-name (name)
  "NAME, unless it is one of the goals the engine itself knows."
  (when (or (member name '("and" "or" "not" "=" "<-" "constraint") :test #'string=)
            (assoc name *logic-tests* :test #'string=))
    (error "~a is a built-in goal, not a relation of yours: choose another name." name))
  name)

(defstruct (logic-scope (:constructor make-logic-scope ())) (variables '()) (count 0))

(defun logic-term (scope term)
  "TERM in a goal: a kanren variable for ?x (a fresh one for ? and ?_), else an atom."
  (if (logic-variable-p term)
      (let ((name (string-downcase (symbol-name term))))
        (if (member name '("?" "?_") :test #'string=)
            (mu-kanren:mu-var (1- (incf (logic-scope-count scope))))
            (or (cdr (assoc name (logic-scope-variables scope) :test #'string=))
                (let ((variable (mu-kanren:mu-var (1- (incf (logic-scope-count scope))))))
                  (push (cons name variable) (logic-scope-variables scope))
                  variable))))
      (logic-atom term)))

(defun logic-goal-kind (form)
  (let ((op (and (consp form) (symbolp (car form)) (string-downcase (symbol-name (car form))))))
    (cond ((null op) :bad)
          ((member op '("and" "or") :test #'string=) :positive)
          ((string= op "not") :late)
          ((assoc op *logic-tests* :test #'string=) :late)
          (t :positive))))

(defun compile-logic-goal (kb scope form)
  (unless (and (consp form) (symbolp (car form)))
    (error "~s is not a goal: write (relation arg ...)." form))
  (let ((op (string-downcase (symbol-name (car form))))
        (args (rest form)))
    (cond
      ((string= op "and") (compile-logic-conjunction kb scope args))
      ((string= op "or") (logic-disj (mapcar (lambda (goal) (compile-logic-goal kb scope goal)) args)))
      ((string= op "not")
       (unless (= (length args) 1) (error "(not GOAL) takes one goal."))
       (logic-not (compile-logic-goal kb scope (first args))))
      ((string= op "=")
       (unless (= (length args) 2) (error "(= a b) takes two terms."))
       (mu-kanren:== (logic-term scope (first args)) (logic-term scope (second args))))
      ((assoc op *logic-tests* :test #'string=)
       (unless (= (length args) 2) (error "(~a a b) takes two terms." op))
       (logic-test op (cdr (assoc op *logic-tests* :test #'string=))
                   (mapcar (lambda (arg) (logic-term scope arg)) args)))
      (t (logic-fact-goal kb op (mapcar (lambda (arg) (logic-term scope arg)) args))))))

(defun compile-logic-conjunction (kb scope forms)
  ;; Positive goals first: they bind what negations and tests look at.
  (let ((ordered (append (remove-if-not (lambda (form) (eq (logic-goal-kind form) :positive)) forms)
                         (remove-if-not (lambda (form) (eq (logic-goal-kind form) :late)) forms))))
    (when (some (lambda (form) (eq (logic-goal-kind form) :bad)) forms)
      (error "~s is not a goal." (find :bad forms :key #'logic-goal-kind)))
    (logic-conj (mapcar (lambda (form) (compile-logic-goal kb scope form)) ordered))))

(defun logic-solutions (kb goals &key limit)
  "Solve GOALS (forms, a conjunction) in KB.  Returns (values solutions
variable-names), each solution a list of values in VARIABLE-NAMES' order."
  (logic-ensure-derived kb)
  (let* ((scope (make-logic-scope))
         (goal (compile-logic-conjunction kb scope goals))
         (names (reverse (mapcar #'car (logic-scope-variables scope))))
         (variables (reverse (mapcar #'cdr (logic-scope-variables scope))))
         (states (logic-run-goal goal (logic-scope-count scope) limit)))
    (values (mapcar (lambda (state)
                      (mapcar (lambda (variable) (interface:walk* variable (car state))) variables))
                    states)
            names)))

;;; --- rules ---

(defun logic-variables-in (form &key positive-only)
  (cond ((logic-variable-p form)
         (unless (member (symbol-name form) '("?" "?_") :test #'string=) (list (string-downcase (symbol-name form)))))
        ((and (consp form) positive-only (symbolp (car form))
              (member (string-downcase (symbol-name (car form))) '("not") :test #'string=))
         '())
        ((consp form) (remove-duplicates (append (logic-variables-in (car form) :positive-only positive-only)
                                                 (logic-variables-in (cdr form) :positive-only positive-only))
                                         :test #'string=))
        (t '())))

(defun check-logic-rule (head body)
  (unless (and (consp head) (symbolp (car head)) (not (logic-variable-p (car head))))
    (error "A rule's head is (relation arg ...), not ~s." head))
  (check-relation-name (logic-name (car head)))
  (let ((unbound (set-difference (logic-variables-in (rest head))
                                 (logic-variables-in (remove-if-not (lambda (goal) (eq (logic-goal-kind goal) :positive)) body))
                                 :test #'string=)))
    (when unbound
      (error "In the rule for ~a, ~{~a~^, ~} must appear in a positive goal of its body." (logic-name (car head)) unbound))))

(defun logic-rule-negated-relations (body)
  "The relations BODY uses under not."
  (let ((names '()))
    (labels ((walk (form negated)
               (when (and (consp form) (symbolp (car form)))
                 (let ((op (string-downcase (symbol-name (car form)))))
                   (cond ((string= op "not") (mapc (lambda (goal) (walk goal t)) (rest form)))
                         ((member op '("and" "or") :test #'string=) (mapc (lambda (goal) (walk goal negated)) (rest form)))
                         ((assoc op *logic-tests* :test #'string=))
                         ((string= op "="))
                         (negated (pushnew op names :test #'string=)))))))
      (dolist (goal body) (walk goal nil)))
    names))

(defun logic-rule-relations (body)
  (let ((names '()))
    (labels ((walk (form)
               (when (and (consp form) (symbolp (car form)))
                 (let ((op (string-downcase (symbol-name (car form)))))
                   (cond ((member op '("and" "or" "not") :test #'string=) (mapc #'walk (rest form)))
                         ((or (string= op "=") (assoc op *logic-tests* :test #'string=)))
                         (t (pushnew op names :test #'string=)))))))
      (mapc #'walk body))
    names))

(defun logic-strata (kb)
  "KB's rules grouped in the order to derive them: a relation is complete
before a rule negates it."
  (let* ((rules (logic-kb-rules kb))
         (heads (remove-duplicates (mapcar (lambda (rule) (logic-name (car (car rule)))) rules) :test #'string=))
         (stratum (make-hash-table :test 'equal)))
    (dolist (head heads) (setf (gethash head stratum) 0))
    (loop repeat (1+ (length heads))
          for changed = nil
          do (dolist (rule rules)
               (let* ((head (logic-name (car (car rule))))
                      (level (gethash head stratum)))
                 (dolist (name (logic-rule-relations (cdr rule)))
                   (let ((needed (+ (or (gethash name stratum) 0)
                                    (if (member name (logic-rule-negated-relations (cdr rule)) :test #'string=) 1 0))))
                     (when (and (gethash name stratum) (> needed level))
                       (setf level needed changed t))))
                 (setf (gethash head stratum) level)))
          while changed
          finally (when changed
                    (error "The rules negate a relation that depends on itself through that negation: they have no single meaning.")))
    (let ((levels (sort (remove-duplicates (mapcar (lambda (head) (gethash head stratum)) heads)) #'<)))
      (mapcar (lambda (level)
                (remove-if-not (lambda (rule) (= (gethash (logic-name (car (car rule))) stratum) level)) rules))
              levels))))

(defun logic-derived-count (kb)
  (loop for relation being the hash-values of (logic-kb-derived kb) sum (logic-relation-count relation)))

(defun logic-ensure-derived (kb)
  "Derive KB's rules to a fixpoint, stratum by stratum, if facts or rules
changed since."
  (when (logic-kb-stale kb)
    (clrhash (logic-kb-derived kb))
    (dolist (rules (logic-strata kb))
      (loop
        (let ((added 0))
          (dolist (rule rules)
            (destructuring-bind (head . body) rule
              (let* ((scope (make-logic-scope))
                     (goal (compile-logic-conjunction kb scope body))
                     (head-terms (mapcar (lambda (term) (logic-term scope term)) (rest head)))
                     (name (logic-name (car head))))
                (dolist (state (logic-run-goal goal (logic-scope-count scope) nil))
                  (let ((tuple (mapcar (lambda (term) (interface:walk* term (car state))) head-terms)))
                    (unless (or (some #'mu-kanren:mu-var-p tuple)
                                (let ((base (gethash name (logic-kb-base kb))))
                                  (and base (gethash tuple (logic-relation-set base)))))
                      (when (relation-add (or (gethash name (logic-kb-derived kb))
                                              (setf (gethash name (logic-kb-derived kb)) (make-logic-relation name)))
                                          tuple)
                        (incf added))))))))
          (when (> (logic-derived-count kb) *logic-max-derived*)
            (clrhash (logic-kb-derived kb))
            (error "The rules derive more than ~d facts: narrow them." *logic-max-derived*))
          (when (zerop added) (return)))))
    (setf (logic-kb-stale kb) nil)))

;;; --- the knowledge base's contents ---

(defun logic-kb-path (name)
  (merge-pathnames (format nil "logic/~a.sexp" name) *config-directory*))

(defun default-logic-kb-name ()
  "The current project's knowledge base: its root directory's name and a
digest of its path, so two checkouts never share one."
  (let ((root (memory-project-root)))
    (format nil "~a-~a"
            (substitute-if #\- (lambda (c) (not (or (alphanumericp c) (member c '(#\- #\_)))))
                           (string-downcase (or (car (last (pathname-directory (uiop:ensure-directory-pathname root)))) "project")))
            (subseq (structural-file-revision root) 0 8))))

(defun normalize-logic-kb-name (name)
  (let ((name (if (and (stringp name) (plusp (length name))) (string-downcase name) (default-logic-kb-name))))
    (unless (every (lambda (c) (or (alphanumericp c) (member c '(#\- #\_)))) name)
      (error "A knowledge base's name is letters, digits, - and _."))
    name))

(defun find-logic-kb (name &key (create t))
  "The knowledge base NAME, loaded from disk the first time."
  (let ((name (normalize-logic-kb-name name)))
    (bt:with-recursive-lock-held (*logic-lock*)
      (or (gethash name *logic-kbs*)
          (let ((path (logic-kb-path name)))
            (cond ((probe-file path)
                   (setf (gethash name *logic-kbs*) (load-logic-kb name path)))
                  (create (setf (gethash name *logic-kbs*) (make-logic-kb name)))
                  (t nil)))))))

(defun logic-add-fact (kb name tuple)
  (when (relation-add (or (gethash name (logic-kb-base kb))
                          (setf (gethash name (logic-kb-base kb)) (make-logic-relation name)))
                      tuple)
    (setf (logic-kb-stale kb) t)
    t))

(defun logic-assert-forms (kb forms)
  "Add FORMS -- facts, (<- head body...) rules and (constraint name
\"message\" goal...) -- to KB.  Returns (values facts rules constraints)."
  (let ((facts 0) (rules 0) (constraints 0))
    (dolist (form forms)
      (unless (and (consp form) (symbolp (car form)) (car form))
        (error "~s is not a fact, rule or constraint." form))
      (let ((op (string-downcase (symbol-name (car form)))))
        (cond
          ((string= op "<-")
           (destructuring-bind (head &rest body) (rest form)
             (unless body (error "The rule for ~s has no body: assert a fact instead." head))
             (check-logic-rule head body)
             (unless (member (cons head body) (logic-kb-rules kb) :test #'equal)
               (setf (logic-kb-rules kb) (append (logic-kb-rules kb) (list (cons head body)))
                     (logic-kb-stale kb) t)
               (incf rules))))
          ((string= op "constraint")
           (destructuring-bind (name message &rest goals) (rest form)
             (unless (and (stringp message) goals)
               (error "Write (constraint name \"message, ?vars filled in\" goal ...)."))
             (setf (logic-kb-constraints kb)
                   (append (remove (logic-name name) (logic-kb-constraints kb) :key #'first :test #'string=)
                           (list (list* (logic-name name) message goals))))
             (incf constraints)))
          (t
           (when (some #'logic-variable-p (rest form))
             (error "~s has a variable: a fact is ground (a rule is (<- head body...))." form))
           (when (logic-add-fact kb (check-relation-name (logic-name (car form))) (mapcar #'logic-atom (rest form)))
             (incf facts))))))
    (values facts rules constraints)))

(defun logic-retract (kb pattern)
  "Remove KB's facts matching PATTERN (a goal; variables match anything).
Returns how many."
  (let* ((name (logic-name (car pattern)))
         (relation (gethash name (logic-kb-base kb))))
    (if (null relation)
        0
        (let* ((scope (make-logic-scope))
               (terms (mapcar (lambda (term) (logic-term scope term)) (rest pattern)))
               (keep (remove-if (lambda (tuple)
                                  (and (= (length tuple) (length terms))
                                       (let ((s '()))
                                         (loop for term in terms for value in tuple
                                               do (setf s (mu-kanren:unify term value s))
                                               never (mu-kanren:failed-unification-p s)))))
                                (logic-relation-tuples relation)))
               (removed (- (logic-relation-count relation) (length keep)))
               (fresh (make-logic-relation name)))
          (dolist (tuple (reverse keep)) (relation-add fresh tuple))
          (if keep
              (setf (gethash name (logic-kb-base kb)) fresh)
              (remhash name (logic-kb-base kb)))
          (when (plusp removed) (setf (logic-kb-stale kb) t))
          removed))))

(defun logic-check (kb &key name (limit 20))
  "KB's constraints (or the one NAME) and their violations: a list of
(name message-instances total)."
  (loop for (constraint message . goals) in (logic-kb-constraints kb)
        when (or (null name) (string= constraint (normalize-logic-kb-name name)))
          collect (multiple-value-bind (solutions names) (logic-solutions kb goals)
                    (list constraint
                          (mapcar (lambda (solution)
                                    (let ((text message))
                                      ;; ?abc before ?a, so a shorter name never eats a longer one.
                                      (loop for (variable . value) in (sort (mapcar #'cons names solution) #'>
                                                                              :key (lambda (pair) (length (car pair))))
                                            do (setf text (replace-all text variable (if (mu-kanren:mu-var-p value) "_" (princ-to-string value)))))
                                      text))
                                  (subseq solutions 0 (min limit (length solutions))))
                          (length solutions)))))

(defun replace-all (text old new)
  (with-output-to-string (out)
    (loop with start = 0
          for at = (search old text :start2 start)
          do (write-string text out :start start :end (or at (length text)))
          while at
          do (write-string new out)
             (setf start (+ at (length old))))))

(defun logic-order (kb relation &key reverse)
  "Order the nodes of binary RELATION -- (RELATION a b): a needs b, so b
comes first (REVERSE: a comes first) -- into layers: each layer's nodes need
only earlier layers'.  Nodes in a cycle come as one group.  Returns (values
layers cycles)."
  (logic-ensure-derived kb)
  (let ((edges (loop for relation in (logic-relations-named kb (logic-name relation))
                     append (remove-if-not (lambda (tuple) (= (length tuple) 2))
                                           (logic-relation-tuples relation))))
        (needs (make-hash-table :test 'equal))
        (nodes '()))
    (dolist (edge edges)
      (destructuring-bind (a b) (if reverse (reverse edge) edge)
        (pushnew a nodes :test #'equal)
        (pushnew b nodes :test #'equal)
        (unless (equal a b) (pushnew b (gethash a needs) :test #'equal))))
    ;; Strongly connected components (Tarjan), each one a unit.
    (let ((index 0) (stack '()) (indices (make-hash-table :test 'equal))
          (low (make-hash-table :test 'equal)) (on-stack (make-hash-table :test 'equal))
          (component (make-hash-table :test 'equal)) (components '()))
      (labels ((connect (node)
                 (setf (gethash node indices) index (gethash node low) index)
                 (incf index)
                 (push node stack)
                 (setf (gethash node on-stack) t)
                 (dolist (next (gethash node needs))
                   (cond ((not (gethash next indices))
                          (connect next)
                          (setf (gethash node low) (min (gethash node low) (gethash next low))))
                         ((gethash next on-stack)
                          (setf (gethash node low) (min (gethash node low) (gethash next indices))))))
                 (when (= (gethash node low) (gethash node indices))
                   (let ((members '()))
                     (loop for member = (pop stack)
                           do (setf (gethash member on-stack) nil
                                    (gethash member component) (length components))
                              (push member members)
                           until (equal member node))
                     (push members components)))))
        (dolist (node (reverse nodes))
          (unless (gethash node indices) (connect node))))
      ;; Tarjan finds components needed-first; a component's layer is one
      ;; past the deepest component it needs.
      (let* ((components (reverse components))
             (layer (make-array (length components) :initial-element 0)))
        (loop for members in components
              for c from 0
              do (dolist (node members)
                   (dolist (next (gethash node needs))
                     (let ((d (gethash next component)))
                       (unless (= d c)
                         (setf (aref layer c) (max (aref layer c) (1+ (aref layer d)))))))))
        (let ((layers (make-array (1+ (reduce #'max layer :initial-value -1)) :initial-element '()))
              (cycles '()))
          (loop for members in components
                for c from 0
                do (let ((group (sort (copy-list members) #'string< :key #'princ-to-string)))
                     (push group (aref layers (aref layer c)))
                     (when (rest members) (push group cycles))))
          (values (map 'list (lambda (groups)
                               (sort groups #'string< :key (lambda (group) (princ-to-string (first group)))))
                       layers)
                  (reverse cycles)))))))

;;; --- saving ---

(defun save-logic-kb (kb)
  (let ((path (logic-kb-path (logic-kb-name kb))))
    (ensure-directories-exist path)
    (write-string-atomically
     path
     (with-standard-io-syntax
       (let ((*package* (find-package :cl-agent-logic-terms)) (*print-readably* nil))
         (prin1-to-string
          (list :cl-agent-logic :version 1
                :facts (loop for name being the hash-keys of (logic-kb-base kb) using (hash-value relation)
                             collect (cons name (reverse (logic-relation-tuples relation))))
                :rules (logic-kb-rules kb)
                :constraints (logic-kb-constraints kb))))))
    path))

(defun load-logic-kb (name path)
  (let* ((record (with-standard-io-syntax
                   (let ((*read-eval* nil) (*package* (find-package :cl-agent-logic-terms)))
                     (read-from-string (uiop:read-file-string path)))))
         (kb (make-logic-kb name)))
    (unless (and (consp record) (eq (first record) :cl-agent-logic))
      (error "~a is not a knowledge base." path))
    (loop for (relation . tuples) in (getf (rest record) :facts)
          do (dolist (tuple tuples) (logic-add-fact kb relation tuple)))
    (setf (logic-kb-rules kb) (getf (rest record) :rules)
          (logic-kb-constraints kb) (getf (rest record) :constraints)
          (logic-kb-stale kb) t)
    kb))

(defun drop-logic-kb (name)
  (let ((name (normalize-logic-kb-name name)))
    (bt:with-recursive-lock-held (*logic-lock*)
      (remhash name *logic-kbs*)
      (let ((path (logic-kb-path name)))
        (when (probe-file path) (delete-file path) t)))))

;;; --- facts from source code ---

(defparameter *logic-import-queries*
  '(("python" . "(import_statement name: (dotted_name) @m) (import_from_statement module_name: (dotted_name) @m) (import_from_statement module_name: (relative_import) @m)")
    ("javascript" . "(import_statement source: (string) @m)")
    ("typescript" . "(import_statement source: (string) @m)")
    ("tsx" . "(import_statement source: (string) @m)")
    ("c" . "(preproc_include path: (_) @m)")
    ("cpp" . "(preproc_include path: (_) @m)")
    ("go" . "(import_spec path: (_) @m)")
    ("rust" . "(use_declaration argument: (_) @m)")
    ("java" . "(import_declaration (_) @m)"))
  "Per language, a tree-sitter query capturing what a file imports as @m.")

(defun identifier-node-p (node)
  (let ((type (ts:node-type node)))
    (or (uiop:string-suffix-p type "identifier") (member type '("constant" "sym_lit") :test #'string=))))

(defun source-files-under (path)
  "The files under PATH (a file or directory) a grammar can read, skipping
version control, dependency and build directories."
  (let ((root (probe-file (expand-user-path path))))
    (unless root (error "No such file or directory: ~a" path))
    (if (not (uiop:directory-pathname-p root))
        (list root)
        (let ((files '()))
          (uiop:collect-sub*directories
           root
           (lambda (directory)
             (not (member (car (last (pathname-directory directory)))
                          '(".git" "node_modules" "ocicl" "target" "build" "dist" "__pycache__" ".venv" "venv" "vendor")
                          :test #'string=)))
           (lambda (directory)
             (not (member (car (last (pathname-directory directory)))
                          '(".git" "node_modules" "ocicl" "target" "build" "dist" "__pycache__" ".venv" "venv" "vendor")
                          :test #'string=)))
           (lambda (directory)
             (dolist (file (uiop:directory-files directory))
               (when (ignore-errors (syntax-language-for (namestring file)))
                 (push file files)))))
          (nreverse files)))))

(defun index-source-facts (kb path &key (max-files 2000))
  "Read the source files under PATH into KB as facts:
  (file F language)  (defines F name kind line)  (encloses outer inner)
  (references F name line)  (calls caller callee)  (imports F target)
references and calls only to names defined somewhere indexed, in the same
language (by name: a local variable named like a function counts).  Returns
(values files facts skipped)."
  (let* ((files (source-files-under path))
         (root (let ((p (probe-file (expand-user-path path))))
                 (if (uiop:directory-pathname-p p) p (uiop:pathname-directory-pathname p))))
         (parsed '()) (skipped '()) (facts 0))
    (when (> (length files) max-files)
      (error "~d files under ~a: more than ~d; index a smaller part." (length files) path max-files))
    (flet ((fact (&rest form) (when (logic-add-fact kb (first form) (rest form)) (incf facts)))
           (relative (file) (enough-namestring file root)))
      ;; First the definitions, so references know what is defined.
      (dolist (file files)
        (handler-case
            (let* ((language (syntax-language-for (namestring file)))
                   (tree (parse-syntax (uiop:read-file-string file) language))
                   (name (relative file)))
              (push (list name language tree (syntax-outline tree)) parsed)
              (fact "file" name language))
          (error (condition) (push (format nil "~a (~a)" (relative file) condition) skipped))))
      ;; Names resolve within a language: a Lisp REMOVE is not a JavaScript one.
      (let ((defined (make-hash-table :test 'equal)))
        (loop for (file language nil outline) in parsed
              do (dolist (entry outline)
                   (setf (gethash (cons language (getf entry :name)) defined) t)
                   (fact "defines" file (getf entry :name) (getf entry :type) (node-first-line (getf entry :node)))
                   (let ((qualified (getf entry :qualified)))
                     (when (position #\. qualified)
                       (fact "encloses" (subseq qualified 0 (position #\. qualified :from-end t)) (getf entry :name))))))
        (loop for (file language tree outline) in parsed
              do (let ((spans (mapcar (lambda (entry)
                                        (list (node-start tree (getf entry :node)) (node-end tree (getf entry :node))
                                              (getf entry :name)
                                              (type-has-word-p (getf entry :type) *function-words*)))
                                      outline)))
                   (labels ((walk (node)
                              (if (identifier-node-p node)
                                  (let ((name (node-text tree node)))
                                    (when (gethash (cons language name) defined)
                                      (let* ((at (node-start tree node))
                                             (caller (third (first (sort (remove-if-not (lambda (span) (and (fourth span) (<= (first span) at) (< at (second span)))) spans)
                                                                         #'> :key #'first)))))
                                        (fact "references" file name (node-first-line node))
                                        (when (and caller (string/= caller name))
                                          (fact "calls" caller name)))))
                                  (mapc #'walk (ts:node-named-children node)))))
                     (walk (syntax-tree-root tree)))
                   (let ((query (cdr (assoc language *logic-import-queries* :test #'string=))))
                     (when query
                       (dolist (capture (ignore-errors (syntax-query-captures tree query :capture "m")))
                         (fact "imports" file (string-trim "\"'<> " (node-text tree (cdr capture))))))))))
      (values (length parsed) facts (nreverse skipped)))))

;;; --- the tool ---

(defun describe-logic-kb (kb)
  (logic-ensure-derived kb)
  (flet ((relations (table)
           (sort (loop for name being the hash-keys of table using (hash-value relation)
                       collect (format nil "~a/~d (~d)" name
                                       (length (first (logic-relation-tuples relation)))
                                       (logic-relation-count relation)))
                 #'string<)))
    (format nil "Knowledge base ~a~%Facts: ~:[none~;~:*~{~a~^, ~}~]~%Derived by rules: ~:[none~;~:*~{~a~^, ~}~]~%Rules:~:[ none~;~:*~{~%  ~a~}~]~%Constraints:~:[ none~;~:*~{~%  ~a~}~]"
            (logic-kb-name kb) (relations (logic-kb-base kb)) (relations (logic-kb-derived kb))
            (mapcar (lambda (rule) (format-logic-form (list* (intern "<-" :cl-agent-logic-terms) rule))) (logic-kb-rules kb))
            (mapcar (lambda (constraint) (format nil "~a: ~a" (first constraint) (second constraint)))
                    (logic-kb-constraints kb)))))

(defun format-logic-form (form)
  (with-standard-io-syntax
    (let ((*package* (find-package :cl-agent-logic-terms)) (*print-case* :downcase))
      (prin1-to-string form))))

(define-tool logic (args)
    (:description "A logic engine (miniKanren, via cl-kanren) for reasoning you can prove instead of guess: dependency and impact analysis, the order to do a refactor in, checking that the repository stays consistent after each step. A knowledge base (kb, default: this project's own, kept across sessions) holds facts, rules and constraints, written as s-expressions; ?x is a variable.
- assert: forms are facts (depends-on \"api.py\" \"db.py\"), rules (<- (reaches ?a ?c) (depends-on ?a ?b) (reaches ?b ?c)) -- recursive rules are fine, even over cycles -- and constraints (constraint no-cycle \"?a needs itself\" (reaches ?a ?a)): a constraint's goals must have NO solution.
- query: goals (a conjunction) to solve, e.g. (reaches \"main.py\" ?x) (not (tested ?x)). Goals: (relation args), (and ...), (or ...), (not G), (= a b), (/= a b), (< a b) <= > >=, (contains a b), (prefix a b), (suffix a b).
- check: every constraint's violations (after each refactor step).
- order: relation (binary, (rel a b) = a needs b) into layers: change layer 1 first, then 2, ...; a cycle is one group to change together.
- index: read source files under path (a file or directory, by tree-sitter) into facts: (file F language) (defines F name kind line) (encloses outer inner) (references F name line) (calls caller callee) (imports F target). Add your own facts on top -- from reading code, from structural-query (ast-grep) results, from a subagent's analysis.
- retract: remove facts matching the pattern forms. describe: what the kb holds. drop: delete the kb."
     :effects '(:write-workspace)
     :parameters
     (jobj "type" "object"
           "properties"
           (jobj "action" (jobj "type" "string" "enum" (list "assert" "query" "check" "order" "index" "retract" "describe" "drop" "list"))
                 "kb" (jobj "type" "string" "description" "Knowledge base name (default: this project's).")
                 "forms" (jobj "type" "string" "description" "S-expressions: facts/rules/constraints to assert, goals to query, patterns to retract.")
                 "relation" (jobj "type" "string" "description" "For order: the binary relation, e.g. calls or depends-on.")
                 "reverse" (jobj "type" "boolean" "description" "For order: (rel a b) means a comes first.")
                 "constraint" (jobj "type" "string" "description" "For check: just this constraint.")
                 "path" (jobj "type" "string" "description" "For index: a file or directory.")
                 "limit" (jobj "type" "integer" "description" "Most solutions to show (default 50)."))
           "required" (list "action")))
  (let* ((action (or (jget args "action") "describe"))
         (limit (let ((limit (jget args "limit"))) (if (and (integerp limit) (plusp limit)) limit 50)))
         (*syntax-notes* '()))
    (bt:with-recursive-lock-held (*logic-lock*)
      (if (string= action "list")
          (let ((names (sort (remove-duplicates
                              (append (alexandria:hash-table-keys *logic-kbs*)
                                      (mapcar #'pathname-name (directory (merge-pathnames "logic/*.sexp" *config-directory*))))
                              :test #'string=)
                             #'string<)))
            (format nil "Knowledge bases: ~:[none~;~:*~{~a~^, ~}~]" names))
          (let ((kb (find-logic-kb (jget args "kb"))))
            (flet ((forms () (read-logic-forms (or (jget args "forms") (error "Give forms.")))))
              (cond
                ((string= action "assert")
                 (multiple-value-bind (facts rules constraints) (logic-assert-forms kb (forms))
                   (save-logic-kb kb)
                   (format nil "~a: ~d new fact~:p, ~d rule~:p, ~d constraint~:p." (logic-kb-name kb) facts rules constraints)))
                ((string= action "query")
                 (multiple-value-bind (solutions names) (logic-solutions kb (forms) :limit (1+ limit))
                   ;; Variables only under not are existential: not shown.
                   (let ((shown (logic-variables-in (forms) :positive-only t)))
                     (setf solutions (mapcar (lambda (solution)
                                               (loop for name in names for value in solution
                                                     when (member name shown :test #'string=) collect value))
                                             solutions)
                           names (remove-if-not (lambda (name) (member name shown :test #'string=)) names)))
                   (cond ((null solutions) "No solutions.")
                         ((null names) "Yes (it holds; the query has no variables).")
                         (t (format nil "~:[~d~;more than ~d~] solution~:p:~%~{~a~%~}"
                                    (> (length solutions) limit) (min limit (length solutions))
                                    (mapcar (lambda (solution)
                                              (format nil "~{~a~^  ~}"
                                                      (mapcar (lambda (name value) (format nil "~a=~a" (string-left-trim "?" name) (format-logic-value value)))
                                                              names solution)))
                                            (subseq solutions 0 (min limit (length solutions)))))))))
                ((string= action "check")
                 (let ((results (logic-check kb :name (jget args "constraint"))))
                   (cond ((null (logic-kb-constraints kb)) "No constraints to check.")
                         ((every (lambda (result) (zerop (third result))) results)
                          (format nil "All ~d constraint~:p hold." (length results)))
                         (t (format nil "~{~a~^~%~}"
                                    (loop for (name messages total) in results
                                          collect (if (zerop total)
                                                      (format nil "~a: holds" name)
                                                      (format nil "~a: ~d violation~:p~{~%  ~a~}~@[~%  ...~]"
                                                              name total messages (> total (length messages))))))))))
                ((string= action "order")
                 (let ((relation (jget args "relation")))
                   (unless (stringp relation) (error "Give the relation to order by."))
                   (multiple-value-bind (layers cycles) (logic-order kb (intern (string-upcase relation) :cl-agent-logic-terms)
                                                                     :reverse (jget args "reverse"))
                     (if (null layers)
                         (format nil "No ~a facts to order." relation)
                         (format nil "~{~a~^~%~}~@[~%Cycles (each must change together): ~{~a~^; ~}~]"
                                 (loop for layer in layers for n from 1
                                       collect (format nil "~d. ~{~a~^, ~}~@[, ... (~d in all)~]" n
                                                       (mapcar (lambda (group) (format nil "~:[~a~;[~{~a~^ ~}]~]"
                                                                                       (rest group) (if (rest group) group (first group))))
                                                               (subseq layer 0 (min limit (length layer))))
                                                       (and (> (length layer) limit) (length layer))))
                                 (mapcar (lambda (cycle) (format nil "~{~a~^ <-> ~}" cycle)) cycles))))))
                ((string= action "index")
                 (let ((path (jget args "path")))
                   (unless (stringp path) (error "Give the path to index."))
                   (multiple-value-bind (files facts skipped) (index-source-facts kb path)
                     (save-logic-kb kb)
                     (format nil "~{~a~%~}Indexed ~d file~:p into ~a: ~d new fact~:p.~@[~%Skipped: ~{~a~^; ~}~]~%~a"
                             (reverse *syntax-notes*) files (logic-kb-name kb) facts skipped (describe-logic-kb kb)))))
                ((string= action "retract")
                 (let ((removed (reduce #'+ (mapcar (lambda (pattern) (logic-retract kb pattern)) (forms)))))
                   (save-logic-kb kb)
                   (format nil "Removed ~d fact~:p." removed)))
                ((string= action "describe") (describe-logic-kb kb))
                ((string= action "drop")
                 (format nil "~:[There was no saved knowledge base ~a~;Dropped ~a~]." (drop-logic-kb (logic-kb-name kb)) (logic-kb-name kb)))
                (t (error "Unknown action ~s." action)))))))))
