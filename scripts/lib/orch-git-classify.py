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


def expand_braces(tok):
    """`pre{a,b}post` is one token to shlex and several words to bash.

    The PREFIX has to survive. Blanking the punctuation turned
    `--{hard,hard}` into ['--', 'hard', 'hard'], and a bare `--` is the
    pathspec separator — so `git reset --{hard,hard}`, which bash runs as
    `git reset --hard --hard`, parsed as a reset with NO flags and was
    allowed. Same for `git clean --{force,force}` and `rm -rf .{git,x}`.
    """
    if "{" not in tok or "}" not in tok or "," not in tok:
        return [tok]
    open_i = tok.index("{")
    close_i = tok.index("}", open_i)
    if close_i < open_i:
        return [tok]
    pre, body, post = tok[:open_i], tok[open_i + 1:close_i], tok[close_i + 1:]
    if "," not in body:
        return [tok]
    out = []
    for alt in body.split(","):
        # Recurse so a second group in the same word also expands.
        out.extend(expand_braces(pre + alt + post))
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
    if sub == "worktree" and pos[:1] == ["remove"]:
        if has_long(flags, "force") or has_short(flags, "f"):
            return "git worktree remove --force — discards a worktree's uncommitted changes"

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
        # Pure branch CREATION is the documented exception.
        creating = (has_short(flags, "b") or has_short(flags, "B")
                    or has_long(flags, "create") or has_long(flags, "force-create")
                    or (sub == "switch" and (has_short(flags, "c") or has_short(flags, "C"))))
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
    argv = sys.argv[1:]
    while argv:
        if argv[0] == "--mode":
            mode = argv[1]; argv = argv[2:]
        elif argv[0] == "--relax":
            relax = argv[1] == "1"; argv = argv[2:]
        else:
            argv = argv[1:]

    cmd = sys.stdin.read()
    if not cmd.strip():
        sys.exit(3)
    try:
        tokens = tokenize(cmd)
    except Exception:
        sys.exit(3)                 # unbalanced quotes etc.
    if not tokens:
        sys.exit(3)

    # An unexpanded expansion or a re-entry point means quoted text becomes code
    # again and we cannot know what runs. Hand back to the caller's raw rules.
    at_cmd_position = True
    for t in tokens:
        if "$" in t or "`" in t:
            sys.exit(3)
        if t in OPS:
            at_cmd_position = True
            continue
        # `FOO=1 bash -c '...'` still runs bash. An env-assignment word does
        # NOT consume the command position, so it must not clear the flag —
        # otherwise the interpreter behind it is never seen and the whole
        # command is classified as if the quoted payload were inert data.
        if at_cmd_position and ASSIGNMENT_RE.match(t):
            continue
        if at_cmd_position and os.path.basename(t) in INTERP:
            sys.exit(3)
        at_cmd_position = False

    for seg in segments(tokens):
        if mode == "destructive":
            # Raw filesystem destruction of the work containers themselves is
            # not a git command, so no git rule can ever see it.
            if seg and os.path.basename(seg[0]) == "rm":
                forceful = any(s.startswith("-") and not s.startswith("--")
                               and ("r" in s[1:] or "f" in s[1:]) for s in seg)
                forceful = forceful or any(resolves_to(s, "recursive") or
                                           resolves_to(s, "force") for s in seg)
                if forceful:
                    for a in seg[1:]:
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
                        parts = [p for p in a.split("/") if p]
                        if ".git" in parts or ".worktrees" in parts \
                                or any(p.endswith(".git") for p in parts):
                            print("rm -rf of .git/.worktrees — irrecoverably "
                                  "destroys a repository or an isolated worktree")
                            sys.exit(2)
        if not any(os.path.basename(t) in ("git", "git.exe") for t in seg):
            continue
        inv = Invocation(seg)
        if not inv.ok:
            continue
        reason = classify_destructive(inv, relax) if mode == "destructive" \
            else classify_no_verify(inv)
        if reason:
            print(reason)
            sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
