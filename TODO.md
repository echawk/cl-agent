# Apfel tool-call continuation

Investigate and implement an Apfel-specific continuation adapter for tool
calls.

## Observed failure

After cl-agent executes a tool, it currently sends the next Apfel request with
an assistant tool-call message followed by one or more `role: "tool"` result
messages. The final message is therefore a tool result. Apfel rejects that
conversation shape with HTTP 400 (reported as invalid JSON by the server).

Apfel's tool-calling guide documents that the final message must have
`role: "user"`; its successful round-trip examples add a user follow-up after
the tool result.

## Proposed fix

For `apfel-provider` only, when the most recent conversation messages are tool
results, append a synthetic user message before issuing the next chat request,
for example:

> Use the tool result above to continue the user's request.

Add it once after all results from an assistant tool-call round, preserving the
assistant tool-call and normal `role: "tool"` result messages that Apfel uses
to associate output with call IDs.

Also handle Apfel's streaming behavior: it may stream tool-call-shaped JSON as
ordinary assistant text before emitting the final structured tool call. Once a
structured call is present, do not retain/replay that raw text as assistant
content in the next request.

## Related hardening

Malformed or schema-invalid tool arguments are now blocked locally and returned
to the model as corrective tool feedback. This prevents the earlier
`eval-lisp` failure where a missing `form` value reached Lisp code as `NIL`, but
does not address Apfel's required trailing user message.

Reference: https://github.com/Arthur-Ficial/apfel/blob/main/docs/tool-calling-guide.md
