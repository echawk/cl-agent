;;;; http.lisp -- thin wrapper around drakma for the JSON-over-HTTPS POST
;;;; requests every LLM provider makes.
;;;;
;;;; Gotcha this file exists to hide from the rest of the codebase:
;;;; drakma only treats a response as text (and hands your code a
;;;; STRING) if its Content-Type matches *TEXT-CONTENT-TYPES*, which by
;;;; default is just "text/*" -- NOT "application/json". Without the
;;;; PUSH below, every API response would come back as a raw octet
;;;; vector. We fix this once, here, at load time.

(in-package :cl-agent)

(pushnew (cons "application" "json") drakma:*text-content-types* :test #'equal)

(defun http-post-json (url &key body headers (timeout 120))
  "POST BODY (a Lisp value as accepted by JSON-ENCODE, usually built
with JOBJ) as a JSON request body to URL, with HEADERS as an alist of
(string . string) additional request headers (for e.g. Authorization).
Returns two values: the decoded JSON response body (see JSON-DECODE)
and the HTTP status code, on ANY response drakma manages to get back,
2xx or not -- callers are responsible for checking the status code,
since what counts as an error varies by provider (some put a useful
message in a non-2xx JSON body that's worth showing the user).
Signals PROVIDER-ERROR if the connection itself fails or the response
body is not valid JSON."
  (handler-case
      (multiple-value-bind (raw-body status)
          (drakma:http-request url
                                :method :post
                                :content-type "application/json"
                                :content (json-encode body)
                                :additional-headers headers
                                :connection-timeout timeout
                                :external-format-out :utf-8
                                :external-format-in :utf-8)
        (let ((text (if (stringp raw-body)
                         raw-body
                         (flexi-streams:octets-to-string raw-body :external-format :utf-8))))
          (values (handler-case (json-decode text)
                    (error (c)
                      (error 'provider-error :provider url
                             :message (format nil "could not parse response as JSON: ~a~%body: ~a"
                                               c (subseq text 0 (min 500 (length text)))))))
                  status)))
    (provider-error (c) (error c))
    (error (c)
      (error 'provider-error :provider url
             :message (format nil "HTTP request failed: ~a" c)))))
