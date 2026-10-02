;;; cl-agent.el --- Emacs glue for cl-agent -*- lexical-binding: t; -*-

;; This file is not an Emacs package in its own right (no MELPA
;; recipe, no autoload cookies beyond a couple of convenience ones);
;; it's a copy-into-your-init.el starting point, same spirit as
;; config/example-extension.lisp.lisp on the Lisp side. Load it with
;; e.g. (load "/path/to/cl-agent/integrations/emacs/cl-agent.el") or
;; just paste the parts you want.
;;
;; Two independent ways to query cl-agent from Emacs, pick what fits:
;;
;; 1. `cl-agent-ask' -- zero dependencies. Runs `cl-agent-executable'
;;    on a one-shot task and streams the output live into a buffer.
;;    Works with nothing else installed; good for "fix this" from a
;;    shell-adjacent mindset.
;;
;; 2. `cl-agent-gptel-mcp-server-entry' -- full, bidirectional tool
;;    use from inside gptel's own chat buffers, via MCP. cl-agent
;;    already runs as an MCP server (`cl-agent --mcp-serve', see
;;    src/mcp/server.lisp), and gptel already ships MCP client support
;;    (gptel-integrations.el, bundled with gptel itself) -- the only
;;    missing piece is `mcp.el' (https://github.com/lizqwerscott/mcp.el,
;;    the `mcp-hub' package gptel-integrations.el expects), which isn't
;;    on MELPA and installs the same way you likely already installed
;;    claude-code-ide.el: via Emacs 30+'s :vc package keyword. Once
;;    that's in place, every cl-agent tool -- shell, eval-lisp,
;;    write-extension, lookup-cl-spec, connect-mcp-server, and
;;    anything a loaded extension adds -- is callable directly from a
;;    gptel chat, including editing your own init.el if you ask it to
;;    (write-extension's shell tool is unsandboxed, same as running
;;    cl-agent from a terminal).
;;
;;    Setup:
;;
;;      (use-package mcp
;;        :vc (:url "https://github.com/lizqwerscott/mcp.el" :rev :newest))
;;
;;      (with-eval-after-load 'mcp
;;        (setq mcp-hub-servers (list (cl-agent-gptel-mcp-server-entry))))
;;
;;      (with-eval-after-load 'gptel
;;        (require 'gptel-integrations))
;;
;;    Then `M-x gptel-mcp-connect' (once per Emacs session, or hang it
;;    off a hook) and cl-agent's tools show up in gptel's tool list.

(defgroup cl-agent nil
  "Glue for talking to cl-agent from Emacs."
  :group 'tools)

(defcustom cl-agent-executable "cl-agent"
  "Path to the cl-agent executable (bin/cl-agent after `make build',
or just \"cl-agent\" if it's on PATH)."
  :type 'string
  :group 'cl-agent)

(defcustom cl-agent-provider nil
  "Provider to pass as --provider, or nil to use cl-agent's own
default resolution (CL_AGENT_PROVIDER env var, then config.lisp, then
reallms -- see src/main.lisp's RESOLVE-PROVIDER-KEYWORD)."
  :type '(choice (const :tag "cl-agent's own default" nil) string)
  :group 'cl-agent)

(defun cl-agent--base-args ()
  "Flags common to every cl-agent invocation below, honoring the
customizable variables above."
  (when cl-agent-provider (list "--provider" cl-agent-provider)))

;;;###autoload
(defun cl-agent-ask (task)
  "Run cl-agent on TASK as a one-shot command and stream its output
live into a *cl-agent* buffer. Non-blocking -- Emacs stays responsive
while cl-agent (and whatever LLM request it's making) runs.

This is the zero-dependency path: no gptel, no MCP, just a subprocess.
See `cl-agent-gptel-mcp-server-entry' for the richer alternative."
  (interactive "sAsk cl-agent: ")
  (let* ((buf (get-buffer-create "*cl-agent*"))
         (command (append (list cl-agent-executable) (cl-agent--base-args) (list task))))
    (with-current-buffer buf
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "$ %s\n\n" (mapconcat #'shell-quote-argument command " ")))))
    (display-buffer buf)
    (let ((proc
           (make-process
            :name "cl-agent"
            :buffer buf
            :command command
            :filter (lambda (proc chunk)
                      (when (buffer-live-p (process-buffer proc))
                        (with-current-buffer (process-buffer proc)
                          (let ((inhibit-read-only t)
                                (at-end (eobp)))
                            (save-excursion
                              (goto-char (point-max))
                              (insert chunk))
                            (when at-end (goto-char (point-max)))))))
            :sentinel (lambda (proc event)
                        (when (and (memq (process-status proc) '(exit signal))
                                   (buffer-live-p (process-buffer proc)))
                          (with-current-buffer (process-buffer proc)
                            (let ((inhibit-read-only t))
                              (goto-char (point-max))
                              (insert (format "\n[%s]" (string-trim event))))))))))
      ;; cl-agent always drops into its interactive REPL after running
      ;; an initial task (see src/repl.lisp's RUN-REPL) -- without this,
      ;; it would block forever reading a next line from stdin, which
      ;; nothing here ever supplies. Closing stdin now makes that read
      ;; return EOF (nil) right after this task's reply, so the
      ;; subprocess exits cleanly instead of hanging.
      (process-send-eof proc))))

;;;###autoload
(defun cl-agent-gptel-mcp-server-entry (&optional name)
  "Return an entry for `mcp-hub-servers' (mcp.el) that runs cl-agent
as an MCP server over stdio. Add it to `mcp-hub-servers', then
`gptel-mcp-connect' (from gptel-integrations.el, bundled with gptel)
picks up every cl-agent tool. NAME defaults to \"cl-agent\".

See this file's header comment for the full setup."
  (cons (or name "cl-agent")
        (list :command cl-agent-executable
              :args (append (cl-agent--base-args) (list "--mcp-serve")))))

(provide 'cl-agent)
;;; cl-agent.el ends here
