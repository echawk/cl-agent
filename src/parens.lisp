;;;; parens.lisp -- fixing a Lisp text's parentheses from its indentation.
;;;;
;;;; Models, smaller ones especially, indent Lisp well and count closing
;;;; parentheses badly, and can loop for a long time adding and removing
;;;; them.  FIX-PARENS ends that: like Parinfer's indent mode, it trusts the
;;;; indentation and rebuilds every line's trailing closers from it --
;;;;
;;;;   - the closers at the end of each line (its "trail") are taken off;
;;;;   - a code line indented to column X closes every paren still open at
;;;;     column X or more, at the end of the code line before it (a paren's
;;;;     contents are always indented past it);
;;;;   - a closer in the middle of a line closes the innermost open paren,
;;;;     or, with none open, is dropped;
;;;;   - the end of the text closes whatever is still open.
;;;;
;;;; Strings (also over several lines), ; and #| |# comments, #\( and #\)
;;;; characters, |quoted symbols| and \escapes are read as the reader would,
;;;; so their parentheses never count.  Blank and comment-only lines and
;;;; lines that start inside a string do not take part in indentation.
;;;;
;;;; :AUTO, the default, touches only the toplevel forms that are unbalanced
;;;; (a form starting at column 0, up to the next): a balanced form is left as
;;;; written, even where its indentation is loose, so fixing one broken
;;;; definition never rewires another.  :INDENT rebuilds the whole text.

(in-package :cl-agent)

(defstruct (paren-line (:constructor make-paren-line (text)))
  text
  (indent nil)            ; column of its first code character, if it takes part
  (trail-start nil)       ; where its trailing closers start (or end of code)
  (trail-end nil)         ; just after its last trailing closer
  (target-p nil)          ; it ends outside strings and comments: closers can go there
  (dropped '())           ; columns of closers taken out
  (added 0))              ; closers to put at TRAIL-START

(defun lisp-paren-tokens (lines)
  "Lex LINES (strings) as Lisp.  Returns, per line, its PAREN-LINE and its
tokens: (:open col) and (:close col), in order."
  (let ((in-string nil) (comment-depth 0) (result '()))
    (dolist (text lines (nreverse result))
      (let* ((line (make-paren-line text))
             (n (length text))
             (tokens '())
             (starts-outside (and (not in-string) (zerop comment-depth)))
             (last-code nil)        ; column after the last non-closer code character
             (i 0))
        (flet ((code (end) (setf last-code end)))
          (loop while (< i n)
                do (let ((ch (char text i)))
                     (cond
                       (in-string
                        (cond ((char= ch #\\) (incf i 2))
                              ((char= ch #\") (setf in-string nil) (incf i) (code i))
                              (t (incf i)))
                        (code (min i n)))
                       ((plusp comment-depth)
                        (cond ((and (char= ch #\|) (< (1+ i) n) (char= (char text (1+ i)) #\#))
                               (decf comment-depth) (incf i 2))
                              ((and (char= ch #\#) (< (1+ i) n) (char= (char text (1+ i)) #\|))
                               (incf comment-depth) (incf i 2))
                              (t (incf i))))
                       ((char= ch #\;) (setf i n))
                       ((and (char= ch #\#) (< (1+ i) n) (char= (char text (1+ i)) #\|))
                        (incf comment-depth) (incf i 2))
                       ((and (char= ch #\#) (< (1+ i) n) (char= (char text (1+ i)) #\\))
                        ;; #\x, #\( or #\Newline: one character, or a name.
                        (incf i 3)
                        (loop while (and (< i n) (alphanumericp (char text i))) do (incf i))
                        (setf i (min i n))
                        (code i))
                       ((char= ch #\") (setf in-string t) (incf i) (code i))
                       ((char= ch #\|)
                        (incf i)
                        (loop while (and (< i n) (char/= (char text i) #\|))
                              do (incf i (if (char= (char text i) #\\) 2 1)))
                        (setf i (min (1+ i) n))
                        (code i))
                       ((char= ch #\\) (incf i 2) (setf i (min i n)) (code i))
                       ((char= ch #\() (push (list :open i) tokens) (incf i) (code i))
                       ((char= ch #\)) (push (list :close i) tokens) (incf i))
                       ((member ch '(#\Space #\Tab #\Return)) (incf i))
                       (t (incf i) (code i))))))
        (setf tokens (nreverse tokens))
        ;; The trail: the closers after the last other code on the line.
        (let ((trail (remove-if-not (lambda (token) (and (eq (first token) :close)
                                                         (>= (second token) (or last-code 0))))
                                    tokens)))
          (setf (paren-line-trail-start line) (or last-code 0)
                (paren-line-trail-end line) (if trail (1+ (second (car (last trail)))) (or last-code 0))))
        (let ((first-code (position-if-not (lambda (c) (member c '(#\Space #\Tab #\Return))) text)))
          ;; A line of only closers does not count: they go where the
          ;; indentation says, and the line goes.
          (when (and starts-outside first-code last-code (char/= (char text first-code) #\;)
                     (char/= (char text first-code) #\))
                     (not (and (char= (char text first-code) #\#) (< (1+ first-code) n)
                               (char= (char text (1+ first-code)) #\|))))
            (setf (paren-line-indent line) first-code)))
        (setf (paren-line-target-p line) (and (not in-string) (zerop comment-depth) last-code t))
        (push (list line tokens) result)))))

(defun paren-problems (text)
  "TEXT's unmatched parentheses: a list of (:extra line col) for closers
with nothing open and (:unclosed line col) for openers never closed;
lines and columns 1-based.  NIL when balanced."
  (let ((stack '()) (problems '()))
    (loop for (nil tokens) in (lisp-paren-tokens (uiop:split-string text :separator '(#\Newline)))
          for line from 1
          do (dolist (token tokens)
               (if (eq (first token) :open)
                   (push (list line (1+ (second token))) stack)
                   (if stack
                       (pop stack)
                       (push (list :extra line (1+ (second token))) problems)))))
    (append (nreverse problems)
            (mapcar (lambda (open) (list* :unclosed open)) (reverse stack)))))

(defun fix-parens (text &key (mode :auto))
  "TEXT with its parentheses rebuilt from its indentation (see the header).
Returns (values fixed-text changes), CHANGES a list of (line old new)
for the lines that changed; TEXT itself, with no changes, when MODE is
:AUTO and TEXT is balanced."
  (when (eq mode :auto)
    (return-from fix-parens (fix-parens-by-form text)))
  (let* ((source-lines (uiop:split-string text :separator '(#\Newline)))
         (lexed (lisp-paren-tokens source-lines))
         (stack '())                    ; open parens: (paren-line . col)
         (target nil))                  ; the last code line closers can go on
    (flet ((close-from (column)
             ;; Close every open paren at COLUMN or right of it.
             (loop while (and stack (>= (cdr (first stack)) column))
                   do (pop stack)
                      (when target (incf (paren-line-added target))))))
      (loop for (line tokens) in lexed
            do (let ((indent (paren-line-indent line)))
                 (when indent (close-from indent))
                 (dolist (token tokens)
                   (destructuring-bind (kind column) token
                     (cond ((eq kind :open) (push (cons line column) stack))
                           ;; Trailing closers are rebuilt from the indentation.
                           ((>= column (paren-line-trail-start line))
                            (push column (paren-line-dropped line)))
                           (stack (pop stack))
                           (t (push column (paren-line-dropped line))))))
                 (when (paren-line-target-p line) (setf target line))))
      (close-from 0))
    (let* ((changes '())
           (fixed
            (loop for (line) in lexed
                  for number from 1
                  for new = (let* ((text (paren-line-text line))
                                 (dropped (paren-line-dropped line))
                                 (start (paren-line-trail-start line))
                                 (end (paren-line-trail-end line))
                                 (new (if (and (null dropped) (zerop (paren-line-added line)))
                                          text
                                          (concatenate
                                           'string
                                           ;; Up to the trail, without dropped mid-line closers.
                                           (coerce (loop for i below start
                                                         unless (member i dropped) collect (char text i))
                                                   'string)
                                           (make-string (paren-line-added line) :initial-element #\))
                                           (subseq text (min end (length text)))))))
                            (unless (string= new text) (push (list number text new) changes))
                            new)
                  ;; A line that was only closers, now empty, goes.
                  unless (and (string/= new (paren-line-text line))
                              (string= "" (string-trim '(#\Space #\Tab #\Return) new)))
                    collect new)))
      (values (format nil "~{~a~^~%~}" fixed) (nreverse changes)))))

(defun describe-paren-problems (problems)
  (format nil "~{~a~^; ~}"
          (loop for (kind line column) in problems repeat 8
                collect (if (eq kind :extra)
                            (format nil "extra \")\" at line ~d, column ~d" line column)
                            (format nil "\"(\" at line ~d, column ~d never closed" line column)))))

(defun describe-paren-fix (changes &key (limit 12))
  (format nil "~{~a~^~%~}~@[~%... ~d more changed line~:p~]"
          (loop for (line old new) in changes repeat limit
                collect (format nil "  line ~d: ~a~%      now: ~a" line (string-trim " " old) (string-trim " " new)))
          (and (> (length changes) limit) (- (length changes) limit))))

(defun fix-parens-by-form (text)
  "FIX-PARENS's :AUTO: rebuild only the unbalanced toplevel forms of TEXT."
  (let* ((lines (uiop:split-string text :separator '(#\Newline)))
         (starts (or (loop for (line) in (lisp-paren-tokens lines)
                           for i from 0
                           when (eql (paren-line-indent line) 0) collect i)
                     (list 0)))
         (starts (if (zerop (first starts)) starts (cons 0 starts)))
         (out '())
         (changes '()))
    (loop for (start end) on starts
          do (let* ((chunk-lines (subseq lines start (or end (length lines))))
                    (chunk (format nil "~{~a~^~%~}" chunk-lines)))
               (if (paren-problems chunk)
                   (multiple-value-bind (fixed chunk-changes) (fix-parens chunk :mode :indent)
                     (push fixed out)
                     (dolist (change chunk-changes)
                       (push (cons (+ start (first change)) (rest change)) changes)))
                   (push chunk out))))
    (if changes
        (values (format nil "~{~a~^~%~}" (nreverse out)) (nreverse changes))
        (values text '()))))

(defun paren-fix-message (text &key (whole-up-to 40))
  "For TEXT with unbalanced parentheses: what is wrong and how FIX-PARENS
would mend it -- the whole fixed text when short, else the changed lines.
Returns (values message fixed-text), or NIL when TEXT is balanced."
  (let ((problems (paren-problems text)))
    (when problems
      (multiple-value-bind (fixed changes) (fix-parens text)
        (values
         (format nil "Unbalanced parentheses: ~a.~%Fixed from its indentation, it would ~:[change these lines:~%~a~;read:~%~a~]~%Retry with fix_parens: true to use that, or correct it yourself."
                 (describe-paren-problems problems)
                 (<= (count #\Newline fixed) whole-up-to)
                 (if (<= (count #\Newline fixed) whole-up-to) fixed (describe-paren-fix changes)))
         fixed)))))
