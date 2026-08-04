#!/usr/bin/env python3
"""Semantic classifier for the PreToolUse git guards.

WHY THIS EXISTS. Both guards used to match option *spellings* with regexes, and
git's own parser accepts spellings no regex author enumerates. Measured against
real git (2.54):

    git reset --h HEAD~1        -> "HEAD is now at ..."   the reset happened
    git reset --ha / --har      -> same
    git clean --for             -> runs as --force
    git commit --no-verif       -> commits past a failing pre-commit hook
    git --no-pager checkout -f  -> the flag-absorber only stripped the five
                                   VALUE-taking globals, so this walked past
    git reset \\<newline> --hard  -> the newline rewrite tracked quotes but not a
                                   preceding backslash, so a continuation became
                                   a command separator and adjacency never matched

Matching spellings will keep losing to git's parser, so this parses instead:
strip global options the way git does, find the subcommand, then resolve each
long option by PREFIX against the destructive canonical names. Git accepts any
unambiguous prefix; a guard resolves a prefix that *could* mean a destructive
option AS that option, which is fail-closed and needs no full option table.

Reads the command on stdin. Writes a one-line reason to stdout when blocking.

Exit codes:
    0  allow
    2  block (reason on stdout)
    3  cannot parse with confidence — the caller must fall back to its own
       block-biased regex rules. NEVER means "allow".

Modes: --mode destructive | --mode no-verify.  --relax 1 permits the
worktree-local forms (caller proves it is inside one of our worktrees).
"""

import os
import re
import shlex
import sys

# A leading `NAME=value` word is an env assignment, not the command.
ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# A token that is NOTHING BUT a variable reference (`$BODY`, `${DIR}`). In
# ARGUMENT position such a token expands to data the command receives — it
# cannot re-enter a shell and it cannot fuse with adjacent characters to
# assemble a flag, because there are no adjacent characters. Bailing on these
# turned both guards into raw-payload scanners for any command that mentioned
# a variable, which blocked `grep -rn "git reset --hard" "$DIR"` — a read-only
# search. A `$` fused to other text (`--hard$X`) or in command position still
# bails: there the expansion can change what runs.
PURE_VAR_RE = re.compile(r"^\$([A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})$")

# Tokens that can hand the string back to a shell, an interpreter, or another
# host. Deliberately broad and matched on basename. Only meaningful in COMMAND
# position: `.` is the source builtin there and the commonest path argument
# everywhere else.
INTERP = {
    "sh", "bash", "zsh", "ksh", "dash", "fish", "csh", "tcsh", "ash", "busybox",
    "python", "python2", "python3", "perl", "ruby", "node", "bun", "deno", "php",
    "lua", "tclsh", "awk", "gawk", "mawk", "nawk", "expect",
    "eval", "exec", "source", ".", "command", "builtin",
    "env", "sudo", "doas", "su", "nohup", "setsid", "timeout", "time", "watch",
    "ssh", "scp", "rsync", "docker", "podman", "kubectl", "vagrant",
    "xargs", "parallel", "find", "make", "just", "task", "entr",
    "screen", "tmux", "script", "nice", "ionice", "chroot", "unshare", "flock",
}

OPS = {";", "|", "&", "&&", "||", ";;", "(", ")"}

# Every canonical long option this file treats as destructive. Used to stop a
# prefix like `--h` from being read as `--help` when git itself reads it as
# `--hard`.
DESTRUCTIVE_NAMES = (
    "hard", "keep", "merge", "force", "delete", "worktree", "exec", "extcmd",
    "reset", "recursive", "no-verify", "no-gpg-sign",
    "abort", "force-with-lease", "force-if-includes", "prune", "mirror",
    "force-create", "stdin", "discard-changes",
)

# git global options that consume a following argument.
GLOBAL_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace",
                     "--exec-path", "--config-env", "--attr-source"}


def unfold(s):
    """Remove backslash-newline (line continuation) outside quotes, then turn
    remaining unquoted newlines into explicit `;` separators.

    A shell deletes a backslash-newline pair entirely: `git reset \\<nl> --hard`
    is one command. The old rewrite did not track the backslash, so it inserted
    a separator there and the reset never looked adjacent to anything.
    """
    out, i, n, quote = [], 0, len(s), None
    while i < n:
        c = s[i]
        if quote:
            out.append(c)
            if c == "\\" and quote == '"' and i + 1 < n:
                out.append(s[i + 1]); i += 2; continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c == "\\" and i + 1 < n and s[i + 1] == "\n":
            out.append(" "); i += 2; continue        # continuation: splice
        if c in ("'", '"'):
            quote = c; out.append(c); i += 1; continue
        out.append(" ; " if c == "\n" else c)
        i += 1
    return "".join(out)


# Brace expansion is multiplicative, so it is BOUNDED. Unbounded, `{a,b}`
# repeated 26 times produced 67,108,864 words in 26 seconds — inside a
# PreToolUse hook, where Claude Code treats a timeout or error as a hook
# FAILURE and lets the command run. That turns a decorative prefix into a
# denial-of-guard: pad a destructive command with brace groups and the guard
# never reaches a verdict. Past the cap we fall back to the old
# blank-the-punctuation behaviour, which loses the prefix but is linear and
# still yields every alternative as a separate word to match against.
_BRACE_WORD_CAP = 256


def expand_braces(tok, _budget=None):
    """`pre{a,b}post` is one token to shlex and several words to bash.

    The PREFIX has to survive. Blanking the punctuation turned
    `--{hard,hard}` into ['--', 'hard', 'hard'], and a bare `--` is the
    pathspec separator — so `git reset --{hard,hard}`, which bash runs as
    `git reset --hard --hard`, parsed as a reset with NO flags and was
    allowed. Same for `git clean --{force,force}` and `rm -rf .{git,x}`.
    """
    if "{" not in tok or "}" not in tok or "," not in tok:
        return [tok]
    if _budget is None:
        _budget = [_BRACE_WORD_CAP]
    open_i = tok.index("{")
    # `find`, not `index`: with a start offset `index` can only raise, never
    # return a smaller value, so the `close_i < open_i` guard below could not
    # fire and a token like `}{a,b` raised ValueError out of tokenize().
    # main() caught it as exit 3, which reads as "cannot parse" and drops the
    # whole command to the spelling rules — so ONE poisoned token anywhere on
    # the line disarmed the semantic layer: `echo '}{a,b' ; git reset --h` was
    # allowed while `git reset --h` alone was blocked.
    close_i = tok.find("}", open_i)
    if close_i < 0:
        return [tok]
    pre, body, post = tok[:open_i], tok[open_i + 1:close_i], tok[close_i + 1:]
    if "," not in body:
        return [tok]
    out = []
    for alt in body.split(","):
        if _budget[0] <= 0:
            # Cap hit: degrade to the linear form rather than keep multiplying.
            return [w for w in tok.replace("{", " ").replace("}", " ")
                    .replace(",", " ").split() if w] or [tok]
        _budget[0] -= 1
        out.extend(expand_braces(pre + alt + post, _budget))
    return out or [tok]


def tokenize(cmd):
    lex = shlex.shlex(unfold(cmd), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    return [w for tok in lex for w in expand_braces(tok)]


def segments(tokens):
    """Split a token stream into single invocations on shell operators.

    Rules describing ONE invocation have to be evaluated against one
    invocation: `git checkout -b tmp && git checkout main` read as a whole let
    the creation exemption cover the real branch switch.
    """
    segs, cur = [], []
    for t in tokens:
        if t in OPS:
            if cur:
                segs.append(cur)
            cur = []
        else:
            cur.append(t)
    if cur:
        segs.append(cur)
    return segs


def long_opt_name(tok):
    """`--foo=bar` -> 'foo'; `--foo` -> 'foo'; not a long option -> None."""
    if not tok.startswith("--") or tok == "--":
        return None
    return tok[2:].split("=", 1)[0]


def resolves_to(tok, canonical):
    """True when a long-option token could mean `canonical` to git.

    Git accepts any unambiguous prefix, so `--h`/`--ha`/`--har` all reach
    `--hard`. A guard must treat a prefix that COULD mean a destructive option
    as that option. `--format=x` does not resolve to `--force`: the name part
    is 'format', which is not a prefix of 'force'.
    """
    name = long_opt_name(tok)
    if name is None or name == "":
        return False
    return canonical.startswith(name)


def has_long(flags, canonical):
    return any(resolves_to(f, canonical) for f in flags)


def has_short(flags, letter):
    """A combined short cluster carries every letter in it: `-fd` is -f and -d."""
    for f in flags:
        if f.startswith("-") and not f.startswith("--") and letter in f[1:]:
            return True
    return False


class Invocation(object):
    """One parsed `git` invocation: globals stripped, subcommand, args."""

    def __init__(self, argv):
        self.ok = False
        self.config_pairs = []      # -c k=v values
        self.sub = None
        self.args = []              # everything after the subcommand
        self.pathspec = []          # args after a literal `--`
        i = 0
        n = len(argv)
        # Skip launcher words up to the `git` token. `caffeinate git commit
        # --no-verify` committed with hooks bypassed when argv[0] was required.
        while i < n and os.path.basename(argv[i]) not in ("git", "git.exe"):
            i += 1
        if i >= n:
            return
        i += 1
        # Global options. Both `--opt value` and `--opt=value` forms, plus the
        # VALUELESS globals (-p, -P/--no-pager, --bare, ...) that the old
        # normalizer ignored entirely — which is how `git --no-pager checkout
        # -f main` reached the tree.
        while i < n:
            t = argv[i]
            if t in GLOBAL_VALUE_OPTS:
                if t == "-c" and i + 1 < n:
                    self.config_pairs.append(argv[i + 1])
                i += 2
                continue
            if t.startswith("--") and "=" in t and \
                    ("--" + long_opt_name(t)) in GLOBAL_VALUE_OPTS:
                if long_opt_name(t) == "config-env":
                    self.config_pairs.append(t.split("=", 1)[1])
                i += 1
                continue
            if t.startswith("-"):
                i += 1              # valueless global
                continue
            break
        if i >= n:
            return
        self.sub = argv[i]
        i += 1
        seen_ddash = False
        while i < n:
            t = argv[i]
            if t == "--":
                seen_ddash = True
                i += 1
                continue
            (self.pathspec if seen_ddash else self.args).append(t)
            i += 1
        self.ok = True

    @property
    def flags(self):
        return [a for a in self.args if a.startswith("-") and a != "-"]

    @property
    def positionals(self):
        return [a for a in self.args if not a.startswith("-")]

    @property
    def is_help(self):
        """A help invocation touches nothing — but only when the token really
        means help.

        Git resolves `git reset --h` to `--hard`, not `--help` (verified
        against git 2.54: it printed "HEAD is now at ..." and moved the tree).
        A prefix that could name a destructive option is therefore NOT help,
        or `--h` would buy a free bypass through the help exemption.
        """
        if self.sub == "help":
            return True
        for f in self.flags:
            if f == "-h" or f == "--help":
                return True
            if resolves_to(f, "help") and not any(
                    resolves_to(f, d) for d in DESTRUCTIVE_NAMES):
                return True
        return False


def classify_destructive(inv, relax):
    """Return a block reason, or None to allow. `relax` = inside our worktree."""
    sub, flags, pos = inv.sub, inv.flags, inv.positionals

    # `--help` never touches the tree. Blocking it (the guard did) teaches users
    # the guard is noise, which is how a data-loss guard gets switched off.
    if inv.is_help:
        return None

    # An inline alias runs arbitrary shell and hides its payload from every
    # option-level rule: `git -c alias.pwn='!rm -rf .git' pwn` destroyed a repo
    # while the guard's own -c stripper deleted the payload before any rule.
    for pair in inv.config_pairs:
        low = pair.lower()
        if low.startswith("alias."):
            return ("git -c alias.<name>=... — defines an alias inline and runs "
                    "it; an alias body starting with '!' is arbitrary shell")
        for key in ("pager", "editor", "extcmd", "hookspath", "sshcommand"):
            if key in low.split("=", 1)[0]:
                return ("git -c %s override — a shell re-entry point the guard "
                        "cannot see through" % pair.split("=", 1)[0])

    # Subcommands whose whole purpose is running an arbitrary command.
    if sub == "submodule" and "foreach" in pos:
        return "git submodule foreach — executes an arbitrary command"
    if sub == "bisect" and "run" in pos:
        return "git bisect run — executes an arbitrary command"
    if sub == "filter-branch":
        return "git filter-branch — rewrites history and executes arbitrary commands"
    if sub == "rebase" and (has_long(flags, "exec") or has_short(flags, "x")):
        return "git rebase --exec — executes an arbitrary command"
    if sub == "difftool" and has_long(flags, "extcmd"):
        return "git difftool --extcmd — executes an arbitrary command"

    # --- always blocked, worktree or not: these reach BEYOND the worktree -----
    if sub == "stash":
        verb = pos[0] if pos else ""
        if verb in ("drop", "clear", "branch"):
            return ("git stash %s — destroys entries on the repo-global stash "
                    "stack shared with the main checkout and sibling worktrees"
                    % verb)
        if verb in ("pop", "apply") and any(p.startswith("stash@") for p in pos[1:]):
            return ("git stash %s stash@{N} — consumes a specific entry on the "
                    "shared stash stack" % verb)
    if sub == "branch":
        # --force is what removes git's protection, whatever the delete verb's
        # spelling. Measured on git 2.54 against an unmerged branch:
        #   git branch -d feat     -> rc=1, branch kept (git protects)
        #   git branch -d -f feat  -> rc=0, branch DESTROYED
        #   git branch -df feat    -> rc=0, branch DESTROYED
        # Requiring the exact `-D` or `--delete`+`--force` pair missed both.
        deleting = (has_short(flags, "d") or has_short(flags, "D")
                    or has_long(flags, "delete"))
        forcing = has_short(flags, "f") or has_short(flags, "D") \
            or has_long(flags, "force")
        if deleting and forcing:
            return ("git branch -D / -d --force — force-deletes a branch, "
                    "dropping unmerged commits")
        # A force RENAME drops the destination branch exactly as -D would:
        # `git branch -M main other` overwrites `other`. Same protection
        # removal, different verb.
        if (has_short(flags, "M") or
                (has_long(flags, "move") and
                 (has_long(flags, "force") or has_short(flags, "f")))):
            return ("git branch -M / --move --force — force-renames over an "
                    "existing branch, dropping its unmerged commits")
    if sub == "worktree" and pos[:1] == ["remove"]:
        if has_long(flags, "force") or has_short(flags, "f"):
            return "git worktree remove --force — discards a worktree's uncommitted changes"
    if sub == "update-ref":
        # Plumbing ref deletion: `git update-ref -d refs/heads/X` deletes a
        # branch with none of porcelain's protections (measured: branch gone).
        # --stdin batches arbitrary ref updates/deletes the flags never show.
        if has_short(flags, "d") or has_short(flags, "D") or has_long(flags, "stdin"):
            return ("git update-ref -d / --stdin — deletes or rewrites refs "
                    "directly, bypassing every porcelain protection")
    if sub == "push":
        # Remote destruction is the LEAST recoverable class this guard covers:
        # a force-push rewrites shared history (measured against a bare remote:
        # main went from 3 commits to 1) and a deleted remote branch has no
        # reflog you own. --force-with-lease is blocked too, deliberately: the
        # lease only protects against refs moved since YOUR last fetch, and on
        # a shared checkout with parallel agents that state is exactly what you
        # cannot trust — it is still history rewriting, so it still needs the
        # explicit human opt-in (ORCH_ALLOW_DESTRUCTIVE_GIT=1).
        for f in flags:
            name = long_opt_name(f)
            if name and ("force".startswith(name)
                         or "force-with-lease".startswith(name)
                         or "force-if-includes".startswith(name)
                         or "delete".startswith(name)
                         or "prune".startswith(name)
                         or "mirror".startswith(name)):
                return ("git push --force/--force-with-lease/--delete/--prune/"
                        "--mirror — rewrites or deletes refs on the shared "
                        "remote; unrecoverable from this checkout")
        if has_short(flags, "f") or has_short(flags, "d"):
            return ("git push -f/-d — force-pushes or deletes a ref on the "
                    "shared remote; unrecoverable from this checkout")
        for p in pos:
            if (p.startswith(":") and len(p) > 1) or p.startswith("+"):
                return ("git push with a ':<ref>' or '+<ref>' refspec — "
                        "deletes or force-overwrites the remote ref")
    if sub in ("checkout", "switch"):
        # -B / -C / --force-create RESET an existing branch to a new start
        # point. `git checkout -B main HEAD~2` rode the branch-CREATION
        # exemption and dropped commits (measured: c3 c2 c1 -> c1) — the same
        # harm `git branch -M` is blocked for above, so it is blocked in the
        # same always-on tier: branch refs are repo-global, worktree or not.
        forced_create = has_short(flags, "B") \
            or (sub == "switch" and has_short(flags, "C"))
        for f in flags:
            name = long_opt_name(f)
            if name and "force-create".startswith(name) \
                    and not "force".startswith(name):
                forced_create = True
        if forced_create:
            return ("git checkout -B / switch -C — force-resets an existing "
                    "branch to a new start point, dropping its commits "
                    "(plain -b/-c creation is allowed)")

    if relax:
        return None

    # --- blocked on the shared checkout, allowed inside our own worktree ------
    if sub == "stash":
        verb = pos[0] if pos else ""
        # `create` prints a commit object without touching the tree or the
        # stash ref; `store` records a given sha as a stash entry without
        # touching the tree. Neither can lose work, so neither is blocked.
        if verb in ("list", "show", "create", "store"):
            return None                     # read-only / no tree mutation
        return ("git stash — 'save' runs an internal 'git reset --hard'; "
                "pop/apply overwrite whatever files the stash touches")
    if sub in ("merge", "rebase", "am", "cherry-pick", "revert"):
        # --abort runs an internal hard reset back to the pre-operation state,
        # discarding conflict-resolution work sitting in the tree (measured:
        # resolved hunks gone after `git merge --abort`). Worktree-local harm,
        # so it is relax-scoped like `reset --hard`; `--quit` (which leaves the
        # tree alone) is deliberately not matched.
        if has_long(flags, "abort"):
            return ("git %s --abort — internally hard-resets to the "
                    "pre-operation state, discarding conflict-resolution "
                    "work in the tree" % sub)
    if sub == "reset":
        for mode in ("hard", "keep", "merge"):
            if has_long(flags, mode):
                return ("git reset --%s — discards uncommitted changes "
                        "(use --soft to keep work staged)" % mode)
    if sub == "clean":
        if has_long(flags, "force") or has_short(flags, "f"):
            return "git clean -f — deletes untracked files irrecoverably"
    if sub in ("checkout", "switch"):
        # --force REVOKES the creation exemption. Measured against git 2.54:
        #
        #   git checkout -b safe        -> "Switched to a new branch"; the
        #                                  uncommitted edit CARRIED OVER intact
        #   git checkout -f -b forced   -> "Switched to a new branch"; the
        #                                  uncommitted edit was GONE
        #
        # Plain creation is safe precisely because git refuses (or carries the
        # work over) rather than clobber; -f is the flag that removes that
        # protection, so it cannot ride along inside the exemption. Same for
        # `switch --force`/`-f` and `--discard-changes`.
        forcing = (has_short(flags, "f") or has_long(flags, "force")
                   or has_long(flags, "discard-changes"))
        # Pure branch CREATION is the documented exception. -B / -C /
        # --force-create are NOT creation — they reset an existing branch and
        # are always-blocked above, so they never reach this exemption.
        creating = (has_short(flags, "b") or has_long(flags, "create")
                    or (sub == "switch" and has_short(flags, "c")))
        if forcing:
            return ("git %s --force — discards uncommitted changes to every "
                    "differing tracked file, including alongside -b/-c branch "
                    "creation" % sub)
        if creating:
            return None
        if sub == "checkout" and (inv.pathspec or pos == ["."]):
            return ("git checkout -- <path> — discards uncommitted changes to "
                    "those paths")
        return ("git %s <branch> — a branch switch overwrites every differing "
                "tracked file, discarding uncommitted work on the shared "
                "checkout (only creation with -b/-c is allowed here)" % sub)
    if sub == "restore":
        staged = has_long(flags, "staged") or has_short(flags, "S")
        worktree = has_long(flags, "worktree") or has_short(flags, "W")
        if worktree or not staged:
            return "git restore (worktree) — discards uncommitted changes"
    if sub == "rm":
        # --cached removes from the INDEX ONLY and never touches the working
        # tree — it is the documented remedy git itself prints for an
        # accidentally-added embedded repo, and the standard way to un-track a
        # file. -n/--dry-run touches nothing at all. Blocking these taught
        # users the guard is noise (it blocked the fix git recommends).
        # Safe because --cached/-n neutralize the tree-touching forms
        # entirely: `git rm -rf --cached x` is still index-only.
        # A `--c*` prefix can only mean --cached here (no destructive rm long
        # option starts with 'c'), and `--d*` only --dry-run.
        if has_long(flags, "cached") or has_long(flags, "dry-run") \
                or has_short(flags, "n"):
            return None
        if has_long(flags, "force") or has_short(flags, "f") or has_short(flags, "r"):
            return "git rm -f/-r — force-deletes tracked files from index and worktree"
    if sub == "read-tree":
        if has_long(flags, "reset") or has_short(flags, "u"):
            return "git read-tree --reset — overwrites tracked files like 'reset --hard'"
    if sub == "checkout-index":
        if has_long(flags, "force") or has_short(flags, "f"):
            return "git checkout-index -f — overwrites tracked files"
    return None


def classify_no_verify(inv):
    """Block the hook/signing bypasses on a git invocation."""
    if inv.is_help:
        return None
    for pair in inv.config_pairs:
        low = pair.replace(" ", "").lower()
        if low.startswith("alias."):
            return "git -c alias.<name>=... — can carry the bypass past every option rule"
        if low.startswith("commit.gpgsign=false") or low.startswith("commit.gpgsign=0"):
            return "git -c commit.gpgsign=false — signing bypass"
        if "hookspath" in low.split("=", 1)[0]:
            return ("git -c core.hooksPath override — redirects hook lookup, "
                    "so every hook this guard exists to protect is skipped")
    # `git config core.hooksPath <dir>` PERMANENTLY disables every hook for
    # all future commands — one invocation, and every later `git commit` looks
    # clean to this guard forever (proven: a plain commit then passed a
    # failing pre-commit hook). Same class: `git config commit.gpgsign false`.
    # Config keys are case-insensitive; the read form is blocked too — losing
    # a rare `--get` costs one round-trip, missing the write costs the guard.
    if inv.sub == "config":
        for p in inv.positionals:
            if p.lower() in ("core.hookspath", "commit.gpgsign"):
                return ("git config %s — permanently disables hook execution "
                        "or commit signing for every future git command "
                        "in this repository" % p)
    flags = inv.flags
    if has_long(flags, "no-verify"):
        return "--no-verify — bypasses the project's pre-commit/pre-push hooks"
    if has_long(flags, "no-gpg-sign"):
        return "--no-gpg-sign — bypasses commit signing"
    # `-n` is git's documented shorthand for --no-verify on COMMIT only:
    # `git log -n 5` is a count and `git push -n` is a dry run.
    if inv.sub == "commit":
        prev_takes_value = False
        for tok in inv.args:
            if prev_takes_value:
                prev_takes_value = False
                continue
            if tok in ("-m", "-F", "-C", "-c", "-t"):
                prev_takes_value = True
                continue
            if tok.startswith("--"):
                continue
            if tok.startswith("-") and len(tok) > 1:
                # Scan the cluster left to right, stopping at the first letter
                # that takes a value — everything after it IS that value.
                # `-an` is [a][n] (the bypass); `-tn` is [t] taking "n".
                for ch in tok[1:]:
                    if ch == "n":
                        return "-n — git's two-character shorthand for --no-verify on commit"
                    if ch in "mFCct":
                        break
    return None


def main():
    mode = "destructive"
    relax = False
    paranoid = False
    argv = sys.argv[1:]
    while argv:
        if argv[0] == "--mode":
            mode = argv[1]; argv = argv[2:]
        elif argv[0] == "--relax":
            relax = argv[1] == "1"; argv = argv[2:]
        elif argv[0] == "--paranoid":
            paranoid = argv[1] == "1"; argv = argv[2:]
        else:
            argv = argv[1:]

    cmd = sys.stdin.read()
    if not cmd.strip():
        sys.exit(3)

    if paranoid:
        # Second pass, requested by the caller after a confident-mode exit 3.
        # Any failure here (CannotParse or a crash) is exit 3, never a crash
        # code — the caller's raw rules are the last line, and a hook error
        # reads as ALLOW.
        try:
            reason = paranoid_scan(cmd, mode, relax)
        except Exception:
            sys.exit(3)
        if reason:
            print(reason)
            sys.exit(2)
        sys.exit(0)

    try:
        tokens = tokenize(cmd)
    except Exception:
        sys.exit(3)                 # unbalanced quotes etc.
    if not tokens:
        sys.exit(3)

    # A re-entry point means quoted text becomes code again and we cannot know
    # what runs. Hand back to the caller — which re-runs this file in paranoid
    # mode. But bail PRECISELY: bailing on every `$` made both guards
    # raw-payload scanners for any command that mentioned a variable, which
    # blocked `grep -rn "git reset --hard" "$DIR"` — a read-only search. A
    # token that is nothing but a variable reference, in argument position, is
    # data: it cannot re-enter a shell and has no adjacent characters to fuse
    # with. Everything else `$`-shaped still bails — command position (the
    # command itself becomes unknowable), a fused token like `--hard$X` (the
    # expansion completes a flag), `$(...)` and backticks (code, anywhere).
    at_cmd_position = True
    for t in tokens:
        if "`" in t or "$(" in t:
            sys.exit(3)
        if t in OPS:
            at_cmd_position = True
            continue
        if "$" in t and (at_cmd_position or not PURE_VAR_RE.match(t)):
            sys.exit(3)
        # `FOO=1 bash -c '...'` still runs bash. An env-assignment word does
        # NOT consume the command position, so it must not clear the flag —
        # otherwise the interpreter behind it is never seen and the whole
        # command is classified as if the quoted payload were inert data.
        if at_cmd_position and ASSIGNMENT_RE.match(t):
            continue
        if at_cmd_position and os.path.basename(t) in INTERP:
            sys.exit(3)
        at_cmd_position = False

    reason = scan_segments(tokens, mode, relax)
    if reason:
        print(reason)
        sys.exit(2)
    sys.exit(0)


def scan_segments(tokens, mode, relax):
    """Apply the per-segment rules to a token stream. Reason string, or None."""
    for seg in segments(tokens):
        if mode == "destructive":
            # Raw filesystem destruction of the work containers themselves is
            # not a git command, so no git rule can ever see it.
            #
            # The command word is found by SKIPPING env assignments, the same
            # way the interpreter scan does. This rule is the only positional
            # one in the file, and testing seg[0] directly meant `FOO=1 rm -rf
            # .git` had `FOO=1` as its command word, matched nothing, and — via
            # the classifier's confident exit 0 — was allowed outright with no
            # fallback. `env rm -rf .git` was already caught (env is an
            # interpreter → exit 3), so the bare assignment prefix was the hole.
            # Launcher words are skipped the same way Invocation skips them
            # for git: on the paranoid path `nice rm -R .git` reaches this
            # rule with `nice` as seg[0], and requiring seg-position-0 to BE
            # rm let every wrapped form through. (On the confident path an
            # INTERP word has already forced exit 3, so the skip is inert.)
            _ci = 0
            while _ci < len(seg) and (ASSIGNMENT_RE.match(seg[_ci])
                                      or os.path.basename(seg[_ci]) in INTERP):
                _ci += 1
            if _ci < len(seg) and os.path.basename(seg[_ci]) == "rm":
                # `-R` is a documented recursive flag on GNU and BSD rm alike;
                # scanning only lowercase r/f missed `rm -R .git`, and the
                # spelling fallback has no uppercase R either.
                forceful = any(s.startswith("-") and not s.startswith("--")
                               and any(c in s[1:] for c in ("r", "R", "f"))
                               for s in seg)
                forceful = forceful or any(resolves_to(s, "recursive") or
                                           resolves_to(s, "force") for s in seg)
                if forceful:
                    for a in seg[_ci + 1:]:
                        # Any path COMPONENT, not just the last one: the target
                        # is usually a worktree INSIDE the container
                        # (`rm -rf .worktrees/feat-x`), which an endswith test
                        # misses entirely.
                        # Any path COMPONENT that IS `.git`/`.worktrees`, or a
                        # component ENDING in `.git` — the bare-repo naming
                        # convention (`myrepo.git`, `/srv/repos/proj.git`).
                        # Component-only matching fixed a `.github/` false
                        # positive but silently stopped covering bare repos,
                        # which is exactly the harm this rule names.
                        # Glob metacharacters are stripped before matching:
                        # shlex hands us the LITERAL token `.git*`, which bash
                        # expands to `.git` at execution, so an exact-string
                        # test missed `rm -rf .git*` and `rm -rf .worktrees*`
                        # entirely.
                        parts = [p.rstrip("*?") for p in a.split("/") if p]
                        if ".git" in parts or ".worktrees" in parts \
                                or any(p.endswith(".git") for p in parts):
                            return ("rm -rf of .git/.worktrees — irrecoverably "
                                    "destroys a repository or an isolated "
                                    "worktree")
        if not any(os.path.basename(t) in ("git", "git.exe") for t in seg):
            continue
        inv = Invocation(seg)
        if not inv.ok:
            continue
        reason = classify_destructive(inv, relax) if mode == "destructive" \
            else classify_no_verify(inv)
        if reason:
            return reason
    return None


class CannotParse(Exception):
    """Paranoid mode could not extract tokens; the caller's raw rules decide."""


# `$VAR` / `${VAR}` references, stripped in paranoid mode. Stripping is the
# block-biased direction: `--hard$X` (which bash may expand to `--hard`)
# becomes `--hard` and matches; a reference that expands to something benign
# costs nothing, because on this path an allow was never going to be refined
# further anyway.
VAR_STRIP_RE = re.compile(r"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*")


def paranoid_tokenize(text):
    # ${IFS} is the classic whitespace stand-in (`git${IFS}reset`); make it
    # real whitespace so adjacency reappears. Backticks become separators so
    # a backtick-substituted `git reset --hard` contributes its words to the
    # stream instead of fusing into unmatchable tokens.
    text = re.sub(r"\$\{IFS\}|\$IFS", " ", text)
    text = text.replace("`", " ")
    text = VAR_STRIP_RE.sub("", text)
    try:
        return tokenize(text)
    except Exception:
        # Unbalanced quotes: retry with quote characters blanked. That can
        # only EXPOSE more words to match against — a mention inside a broken
        # quote now looks like an invocation, which errs toward blocking.
        try:
            return tokenize(text.replace("'", " ").replace('"', " "))
        except Exception:
            raise CannotParse()


def paranoid_scan(text, mode, relax, depth=0):
    """Block-biased re-parse for commands the confident path refused.

    WHY THIS EXISTS. Exit 3 used to hand the command to the caller's spelling
    regexes, and those only match full canonical spellings — so every prefix
    form the classifier exists to catch came back the moment a `$`, a
    backtick, or a launcher word appeared: `nice git reset --h HEAD~1` and
    `git reset --h HEAD~1 && echo $HOME` were both measured ALLOWED while
    really resetting against git 2.54. A weaker second rule set will always
    drift from the first; re-running the SAME classifier in a paranoid mode
    keeps one source of truth.

    Paranoid rules: no bailing on `$`/interpreters; variable references are
    stripped (see VAR_STRIP_RE); and any token that still carries whitespace
    or an operator character — a quoted blob — is recursively scanned, because
    on this path an interpreter that can make quoted text run again is either
    present or unprovable. The recursion is why `bash -c "git reset --hard"`
    and an os.system() payload inside `python3 -c '...'` both block. A quoted
    blob blocks only when it contains a full git invocation: a heredoc or
    string that merely QUOTES `--no-verify` scans clean, because the flag
    never sits inside a git segment.

    Verdicts: a reason string blocks; None allows; CannotParse propagates so
    the caller's raw-text rules run (noisy, never fail-open).
    """
    if depth > 5:
        raise CannotParse()
    tokens = paranoid_tokenize(text)
    reason = scan_segments(tokens, mode, relax)
    if reason:
        return reason
    for t in tokens:
        if t in OPS:
            continue
        if any(c.isspace() for c in t) or any(c in ";|&" for c in t):
            reason = paranoid_scan(t, mode, relax, depth + 1)
            if reason:
                return reason
    return None


if __name__ == "__main__":
    main()
