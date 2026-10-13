"""A minimal Language Server Protocol server for cl-agent's tests
(t/test-scratch.lisp): standard library only, stdio transport.

It keeps each opened document's text, publishes one warning diagnostic for
every "FIXME" in it, answers hover with "fake hover: WORD" for the word at
the position, and completes with COMPLETIONS below (".member" replacing from
the dot before the position, when there is one).  Every other request gets a
null result.
"""

import json
import re
import sys

documents = {}

# sortText puts greet_all before greeting; callme is a snippet.
COMPLETIONS = [
    {"label": "greeting", "kind": 6, "detail": "a variable", "sortText": "b"},
    {"label": "greet_all", "kind": 3, "detail": "void greet_all(void)", "sortText": "a"},
    {"label": "grumble", "kind": 3, "sortText": "c"},
    {"label": "callme", "kind": 3, "insertText": "callme(${1:arg})$0", "insertTextFormat": 2, "sortText": "d"},
]


def read_message():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.decode("ascii").strip()
        if not line:
            break
        key, value = line.split(":", 1)
        headers[key.lower()] = value.strip()
    return json.loads(sys.stdin.buffer.read(int(headers["content-length"])))


def send(message):
    message["jsonrpc"] = "2.0"
    body = json.dumps(message).encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()


def publish(uri, version):
    diagnostics = []
    for number, line in enumerate(documents[uri].split("\n")):
        for match in re.finditer("FIXME", line):
            diagnostics.append({
                "range": {"start": {"line": number, "character": match.start()},
                          "end": {"line": number, "character": match.end()}},
                "severity": 2, "message": "fake: fix this", "source": "fake-lsp"})
    send({"method": "textDocument/publishDiagnostics",
          "params": {"uri": uri, "version": version, "diagnostics": diagnostics}})


def word_at(text, line, character):
    lines = text.split("\n")
    if line >= len(lines):
        return ""
    for match in re.finditer(r"\w+", lines[line]):
        if match.start() <= character <= match.end():
            return match.group(0)
    return ""


while True:
    message = read_message()
    if message is None:
        break
    method, ident, params = message.get("method"), message.get("id"), message.get("params") or {}
    if method == "initialize":
        send({"id": ident, "result": {"capabilities": {
            "textDocumentSync": 1, "hoverProvider": True,
            "completionProvider": {"triggerCharacters": [".", "->"]}}}})
    elif method == "textDocument/completion":
        position = params["position"]
        lines = documents.get(params["textDocument"]["uri"], "").split("\n")
        line = lines[position["line"]] if position["line"] < len(lines) else ""
        items = list(COMPLETIONS)
        if 0 < position["character"] <= len(line) and line[position["character"] - 1] == ".":
            start = {"line": position["line"], "character": position["character"] - 1}
            items.append({"label": "member", "kind": 5, "sortText": "0",
                          "textEdit": {"newText": ".member", "range": {"start": start, "end": position}}})
        send({"id": ident, "result": {"isIncomplete": False, "items": items}})
    elif method == "shutdown":
        send({"id": ident, "result": None})
    elif method == "exit":
        break
    elif method == "textDocument/didOpen":
        document = params["textDocument"]
        documents[document["uri"]] = document["text"]
        publish(document["uri"], document["version"])
    elif method == "textDocument/didChange":
        document = params["textDocument"]
        documents[document["uri"]] = params["contentChanges"][-1]["text"]
        publish(document["uri"], document["version"])
    elif method == "textDocument/hover":
        position = params["position"]
        word = word_at(documents.get(params["textDocument"]["uri"], ""), position["line"], position["character"])
        send({"id": ident, "result": {"contents": {"kind": "markdown", "value": "fake hover: " + word}}})
    elif ident is not None:
        send({"id": ident, "result": None})
