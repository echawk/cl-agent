#!/bin/sh
# scripts/update-deps.sh -- update cl-agent's dependencies, then check that
# it still loads them all from inside the project and that what it uses of
# slt's internals is still there (scripts/check-deps.lisp).
#
#   scripts/update-deps.sh                     the git submodules (slt), to their upstream's default branch
#   scripts/update-deps.sh slt [REF]           slt alone, to REF (a commit, tag or branch; default: upstream's head)
#   scripts/update-deps.sh ocicl [SYSTEM...]   ocicl's latest for SYSTEMs, or for every system in ocicl.csv
#   scripts/update-deps.sh all                 both
#
#   --test      run `make test` afterwards
#   --no-check  skip scripts/check-deps.lisp
#
# Nothing is committed: review `git diff` (the submodule's new commit,
# ocicl.csv's new pins), then commit.  Upstream's new commits are listed,
# with the files cl-agent touches flagged.

set -eu
cd "$(dirname "$0")/.."

SBCL=${SBCL:-sbcl}
test_after=no
check=yes
what=submodules
ref=
systems=

for arg in "$@"; do
  case "$arg" in
    --test) test_after=yes ;;
    --no-check) check=no ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) if [ "$what" = submodules ] && [ -z "$systems" ] && [ -z "$ref" ] && { [ "$arg" = slt ] || [ "$arg" = ocicl ] || [ "$arg" = all ]; }; then
         what=$arg
       elif [ "$what" = slt ]; then ref=$arg
       elif [ "$what" = ocicl ]; then systems="$systems $arg"
       else echo "update-deps: unexpected argument: $arg" >&2; exit 2
       fi ;;
  esac
done

# What cl-agent uses of a submodule: changes there are worth reading first.
watched_slt='src/web/web-frontend.lisp src/headless-frontend.lisp src/emulator.lisp src/transport.lisp src/controls.lisp src/frontend.lisp web/slt-terminal.js slt.asd'

update_submodule() {  # PATH [REF]
  path=$1 target=${2:-}
  echo "== $path"
  git submodule update --init -q "$path"
  git -C "$path" fetch -q origin
  [ -n "$target" ] || target=$(git -C "$path" rev-parse --abbrev-ref origin/HEAD)
  old=$(git -C "$path" rev-parse HEAD)
  git -C "$path" checkout -q "$target"
  new=$(git -C "$path" rev-parse HEAD)
  if [ "$old" = "$new" ]; then echo "   already at $(git -C "$path" log --oneline -1)"; return; fi
  echo "   $(git -C "$path" rev-parse --short "$old") -> $(git -C "$path" rev-parse --short "$new"):"
  git -C "$path" log --oneline "$old..$new" | sed 's/^/     /'
  if [ "$path" = third-party/slt ]; then
    changed=$(git -C "$path" diff --name-only "$old" "$new" -- $watched_slt)
    if [ -n "$changed" ]; then
      echo "   changed, and cl-agent uses them (src/terminal.lisp, static/terminal.js, emacs-view.js):"
      echo "$changed" | sed 's/^/     /'
    fi
  fi
}

update_submodules() {
  for path in $(git config -f .gitmodules --get-regexp 'submodule\..*\.path' | awk '{print $2}'); do
    update_submodule "$path"
  done
}

update_ocicl() {
  echo "== ocicl ${systems:-(every system in ocicl.csv)}"
  # shellcheck disable=SC2086
  ocicl latest $systems 2>&1 | grep -v 'certificate\|pure-tls\|^WARNING:$' || true
  git --no-pager diff --stat -- ocicl.csv
}

case "$what" in
  submodules) update_submodules ;;
  slt) update_submodule third-party/slt "$ref" ;;
  ocicl) update_ocicl ;;
  all) update_submodules; update_ocicl ;;
esac

if [ "$check" = yes ]; then
  echo "== checking (scripts/check-deps.lisp)"
  log=$(mktemp "${TMPDIR:-/tmp}/cl-agent-check-deps.XXXXXX")
  if "$SBCL" --noinform --non-interactive --no-userinit --load scripts/check-deps.lisp > "$log" 2>&1; then ok=yes; else ok=no; fi
  # Its own lines only: not the compiler's.
  grep -E '^\* |^  PROBLEM|names checked|All checks passed|problems?\.$' "$log" || true
  if [ "$ok" = no ]; then
    echo "update-deps: the checks failed; the whole output is in $log" >&2
    exit 1
  fi
  rm -f "$log"
fi

if [ "$test_after" = yes ]; then
  echo "== make test"
  make test
fi

echo "== done: review git diff, then commit"
