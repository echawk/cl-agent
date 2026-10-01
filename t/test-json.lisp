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

(deftest jalist->hash-converts-nested-alists ()
  (let* ((alist '(("role" . "user") ("meta" . (("nested" . "yes") ("n" . 3)))))
         (h (jalist->hash alist)))
    (check (hash-table-p h))
    (check-equal (jget h "role") "user")
    (check (hash-table-p (jget h "meta")))
    (check-equal (jget (jget h "meta") "nested") "yes")
    (check-equal (jget (jget h "meta") "n") 3)))

(deftest jalist->hash-maps-arrays-elementwise ()
  ;; A JSON array of two objects parses (via yason :object-as :alist)
  ;; as a list of two alists -- each element, not the list itself,
  ;; should become a hash table.
  (let ((h (jalist->hash '(("xs" . ((("a" . 1)) (("a" . 2))))))))
    (check (listp (jget h "xs")))
    (check-equal (length (jget h "xs")) 2)
    (check-equal (jget (first (jget h "xs")) "a") 1)
    (check-equal (jget (second (jget h "xs")) "a") 2)))

(deftest jalist->hash-passes-through-scalars ()
  (check-equal (jalist->hash "plain") "plain")
  (check-equal (jalist->hash 42) 42)
  (check-equal (jalist->hash nil) nil))

(deftest jhash->alist-converts-nested-hashes ()
  (let* ((h (jobj "role" "user" "meta" (jobj "nested" "yes")))
         (alist (jhash->alist h)))
    (check-equal (cdr (assoc "role" alist :test #'string=)) "user")
    (check (jalist-p (cdr (assoc "meta" alist :test #'string=))))))

(deftest jhash-jalist-round-trip ()
  (let* ((h (jobj "a" 1 "b" (jobj "c" (list 1 2 3))))
         (round-tripped (jalist->hash (jhash->alist h))))
    (check-equal (jget round-tripped "a") 1)
    (check-equal (jget (jget round-tripped "b") "c") '(1 2 3))))
