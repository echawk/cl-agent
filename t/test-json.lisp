(in-package :cl-agent)

(deftest json-roundtrip ()
  (let* ((obj (jobj "role" "assistant" "content" "hi" "n" 3))
         (decoded (json-decode (json-encode obj))))
    (check-equal (jget decoded "role") "assistant")
    (check-equal (jget decoded "content") "hi")
    (check-equal (jget decoded "n") 3)))

(deftest json-arrays-are-lists ()
  (let ((decoded (json-decode "{\"xs\":[1,2,3]}")))
    (check (listp (jget decoded "xs")) "array decodes to a list")
    (check-equal (jget decoded "xs") '(1 2 3))))

(deftest json-null-becomes-default ()
  (let ((decoded (json-decode "{\"x\":null}")))
    (check-equal (jget decoded "x") nil "JSON null maps to JGET's default")
    (check-equal (jget decoded "x" :sentinel) :sentinel "custom default honored for null too")))

(deftest json-false-is-distinguishable-from-absent ()
  (let ((decoded (json-decode "{\"x\":false}")))
    (check-equal (jget decoded "x" :sentinel) nil "false decodes to NIL, not the default")
    (check-equal (jget decoded "missing-key" :sentinel) :sentinel "absent key uses the default")))

(deftest jpath-walks-nested-structure ()
  (let ((decoded (json-decode "{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}")))
    (check-equal (jpath decoded "choices" 0 "message" "content") "hi")
    (check-equal (jpath decoded "choices" 0 "nope" "content") nil "missing path returns nil, not an error")))

(deftest jobj-symbol-keys-downcase ()
  (let ((decoded (json-decode (json-encode (jobj :role "user")))))
    (check-equal (jget decoded "role") "user" "keyword key is downcased to its wire name")))
