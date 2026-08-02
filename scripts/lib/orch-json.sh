#!/usr/bin/env bash
# orch-json.sh — decode a field out of a hook event payload.
#
# Hooks receive JSON on stdin. Several of them used to `grep` the RAW payload
# for the thing they cared about, which is wrong in two directions at once:
#
#   TOO WIDE — a guard grepping the whole payload matches text that is not the
#   command. `grep -rn -- '--no-verify' scripts/` was hard-blocked as if it
#   were a commit bypass, and a benign commit was blocked because the model's
#   own `description` field mentioned the flag. Read-only searches for the very
#   patterns a guard protects against are the guard's most common false hit.
#
#   TOO NARROW — a grepped string is still JSON-ENCODED. A newline inside the
#   value stays as the two characters `\` and `n`, and `n` is a word character,
#   so `\b` anchors silently fail on every line but the first. The research
#   gate was blind to any multi-line prompt for exactly this reason — and a
#   multi-line prompt is the normal shape of a spec.
#
# Decoding once, properly, fixes both. python3 is used when available; callers
# must treat an empty result as "unknown" and fall back to their fail-safe
# behaviour (for a blocking guard that means scanning the raw payload, which is
# noisy but never unsafe).
#
# Bash 3.2 compatible.

# orch_json_field <json-text> <dotted.path>
# Prints the decoded string value at <dotted.path>, or nothing.
# Non-string values (numbers, objects) print nothing — callers want text.
orch_json_field() {
  local json="$1" path="$2"
  command -v python3 >/dev/null 2>&1 || return 0
  printf '%s' "${json}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
cur = data
for key in sys.argv[1].split("."):
    if not isinstance(cur, dict) or key not in cur:
        sys.exit(0)
    cur = cur[key]
if isinstance(cur, str):
    sys.stdout.write(cur)
' "${path}" 2>/dev/null || true
}

# orch_scan_source <json-payload>
# Prints the text a PreToolUse guard should pattern-match against.
#
# THE COMMAND IS TOKENIZED, NOT STRING-EDITED. An earlier version blanked
# quoted spans with sed on the theory that "a pattern inside quotes is an
# argument". That premise is false for a shell, and an adversarial pass proved
# it with commands that execute exactly what the quotes appear to neutralise:
#
#   git -C "." reset --hard   → blanked to `git -C   reset --hard`, whereupon
#                               the guard's own -C stripper ate `reset` and the
#                               command sailed through. ALLOWED. Confirmed to
#                               wipe a tree.
#   git reset "--hard"        → ALLOWED. The shell strips the quotes and runs it.
#   git "checkout" main       → ALLOWED. Same.
#   echo "don't"; git reset --hard; echo "won't"
#                             → the two apostrophes PAIRED and blanked the real
#                               command between them. ALLOWED.
#
# Tokenizing resolves quoting the way the shell does, so quoting-for-literal and
# quoting-for-word-assembly stop being confusable. Rules, all biased to blocking:
#
#   1. Decode tool_input.command. Any failure → print the raw payload. A guard
#      can never be argued out of firing by a malformed event.
#   2. Tokenize with shlex (punctuation_chars, so `;` `|` `&&` are operators and
#      `# comments` are stripped — a trailing comment used to lend its flags to
#      the real command).
#   3. If any token is an interpreter/shell, or carries an unexpanded `$`/
#      backtick, print the RAW command: quoted text is code again there.
#      `printf %s '...' | sh`, `$SHELL -c '...'`, `awk 'BEGIN{system(...)}'`,
#      `ssh host '...'`, `sudo -s '...'`, `find -exec ...` all land here.
#   4. Otherwise re-emit the tokens space-joined, replacing any token that holds
#      whitespace or a shell metacharacter with a placeholder. Such a token can
#      only have come from quoting, so it is DATA — that is what keeps
#      `grep -rn "git reset --hard" scripts/` from being blocked, while
#      `git -C "." reset --hard` normalises to `git -C . reset --hard` and dies.
orch_scan_source() {
#
# OUTPUT CONTRACT. On the tokenized path the first line is `__ORCH_TOKENIZED__`;
# on every fallback path it is `__ORCH_RAW__`. Callers need to tell these apart:
# a precise token-level rule is only sound over tokens, and silently applying it
# to raw text is a fail-open. Use orch_scan_is_tokenized to test.
  local payload="$1" cmd=""
  declare -f orch_json_field >/dev/null 2>&1 && cmd=$(orch_json_field "${payload}" tool_input.command)
  if [[ -z "${cmd}" ]]; then
    printf '__ORCH_RAW__\n%s' "${payload}"
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || { printf '__ORCH_RAW__\n%s' "${cmd}"; return 0; }
  ORCH_RAW_CMD="${cmd}" python3 - <<'PYEOF' 2>/dev/null || printf '__ORCH_RAW__\n%s' "${cmd}"
import os, shlex, sys

cmd = os.environ.get("ORCH_RAW_CMD", "")

# Anything that can hand the string back to a shell, an interpreter, or another
# host. A fixed allowlist is a liability, so this is deliberately broad and is
# matched on the token's BASENAME (so /bin/sh and /usr/bin/env both land).
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
OPERATORS = {";", "|", "&", "&&", "||", ";;", "(", ")", "<", ">", ">>", "<<", "<<<"}
META = set(";|&<>()`$")

def newlines_to_separators(s):
    """Turn UNQUOTED newlines into explicit `;` separators.

    shlex treats a newline as ordinary whitespace, so `git checkout -b tmp` on
    line 1 and `git checkout main` on line 2 tokenized into a single stream and
    `orch_shell_segments` produced ONE segment — the creation exemption from the
    first command then covered the real branch switch in the second, and it was
    ALLOWED. That silently reverted the per-segment fix for the most natural way
    a model writes two commands. A newline IS a command separator in shell; make
    it one here. Newlines inside quotes are data and are left alone.
    """
    out, i, n, quote = [], 0, len(s), None
    while i < n:
        c = s[i]
        if quote:
            out.append(c)
            if c == "\\" and quote == chr(34) and i + 1 < n:
                out.append(s[i + 1]); i += 2; continue
            if c == quote:
                quote = None
            i += 1; continue
        if c in (chr(39), chr(34)):
            quote = c; out.append(c); i += 1; continue
        out.append(" ; " if c == "\n" else c)
        i += 1
    return "".join(out)


def expand_braces(tok):
    """`{a,b}` is one token to shlex and several words to bash.

    `git {reset,--hard}`, `rm {-rf,.git}` and `git {commit,--no-verify,-m,x}`
    all executed while scanning as a single unmatched token. Splitting the group
    into words restores what the shell will actually run. Conservative by
    construction: it can only ever produce MORE words to match against, and the
    cost is that a quoted literal `"{a,b}"` is also split.
    """
    if "{" in tok and "}" in tok and "," in tok:
        return [w for w in tok.replace("{", " ").replace("}", " ").replace(",", " ").split() if w]
    return [tok]


try:
    lex = shlex.shlex(newlines_to_separators(cmd), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    tokens = [w for tok in lex for w in expand_braces(tok)]
except Exception:
    sys.exit(1)          # unbalanced quotes etc. → caller falls back to raw

if not tokens:
    sys.exit(1)

OPS_BEFORE_CMD = {";", "|", "&", "&&", "||", ";;", "(", ")"}
at_cmd_position = True
for t in tokens:
    if "$" in t or "`" in t:
        sys.exit(1)      # unexpanded expansion — we cannot know what it becomes
    if t in OPS_BEFORE_CMD:
        at_cmd_position = True
        continue
    # Only a token in COMMAND POSITION can re-enter a shell. Checking every
    # token made `.` — the source builtin, and the commonest path argument in
    # existence — throw `git restore .` onto the raw path, where the rules that
    # would have caught it do not apply.
    if at_cmd_position and os.path.basename(t) in INTERP:
        sys.exit(1)      # re-entry point — the quoted payload is code
    at_cmd_position = False

out = []
for t in tokens:
    if t in OPERATORS:
        out.append(t)
    elif t == "" or any(c.isspace() for c in t) or any(c in META for c in t):
        out.append("__ORCH_ARG__")   # came from quoting ⇒ data, not invocation
    else:
        out.append(t)
sys.stdout.write("__ORCH_TOKENIZED__\n" + " ".join(out))
PYEOF
}

# orch_scan_is_tokenized <scan-output>
# True when orch_scan_source produced a token stream (so token-level rules are
# sound). False on every fallback, where only substring rules may be applied.
orch_scan_is_tokenized() {
  case "$1" in __ORCH_TOKENIZED__*) return 0 ;; *) return 1 ;; esac
}

# orch_shell_segments <command-text>
# Splits a shell command into top-level segments on ; && || | and newline,
# printing one segment per line.
#
# Guards that grep a whole compound command can be disarmed by a co-occurring
# token: `git checkout -b tmp && git checkout main` read as "this is a branch
# CREATION, allow it" and let the real branch switch through, clobbering every
# differing tracked file. Rules that describe a single invocation have to be
# evaluated against a single invocation.
#
# Quoted spans are protected so a separator inside a string does not split, and
# so `echo 'git checkout -b x'; git checkout main` cannot lend its flag to the
# second segment. This is a pragmatic splitter, not a shell parser: it does not
# handle nested command substitution. Segments it gets wrong stay conservative —
# a missed split means the old whole-string behaviour for that command.
orch_shell_segments() {
  command -v python3 >/dev/null 2>&1 || { printf '%s\n' "$1"; return 0; }
  local _out
  # Never return empty. A caller loops over the segments, so no output means the
  # rule body never runs at all — that turned an undecodable command (an invalid
  # UTF-8 byte is enough to make python3 bail) into an ALLOW. Falling back to the
  # whole string restores the pre-segmentation behaviour, which blocks.
  _out=$(python3 - "$1" <<'PYEOF' 2>/dev/null
import sys

s = sys.argv[1]
SQ = chr(39)
DQ = chr(34)
out, buf = [], []
i, n = 0, len(s)
quote = None
while i < n:
    c = s[i]
    if quote:
        buf.append(c)
        if c == "\\" and quote == DQ and i + 1 < n:
            buf.append(s[i + 1]); i += 2; continue
        if c == quote:
            quote = None
        i += 1
        continue
    if c == SQ or c == DQ:
        quote = c; buf.append(c); i += 1; continue
    if s[i:i + 2] in ("&&", "||"):
        out.append("".join(buf)); buf = []; i += 2; continue
    if c in (";", "|", "\n", "&"):
        out.append("".join(buf)); buf = []; i += 1; continue
    buf.append(c); i += 1
out.append("".join(buf))
for seg in out:
    seg = seg.strip()
    if seg:
        print(seg)
PYEOF
)
  if [[ -z "${_out}" ]]; then printf '%s\n' "$1"; else printf '%s\n' "${_out}"; fi
}
